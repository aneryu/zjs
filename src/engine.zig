const std = @import("std");
const core = @import("core/root.zig");
const exec = @import("exec/root.zig");
const frontend = @import("frontend/root.zig");

const ModuleEvalStep = union(enum) {
    completed: core.JSValue,
    suspended: struct {
        continuation: core.JSValue,
        awaited: core.JSValue,
    },
};

const ModuleContinuation = struct {
    source: []const u8,
    path: []const u8,
    continuation: core.JSValue,
    awaited: core.JSValue,
    keep_result: bool,
    completed: bool = false,
    symbol_root_mask: u2 = 0,
};

pub const Limits = struct {
    memory_bytes: ?usize = null,
    stack_bytes: ?usize = null,
    gc_threshold_bytes: ?usize = null,
};

pub const EngineOptions = struct {
    allocator: std.mem.Allocator,
    trace_writer: ?*std.Io.Writer = null,
    limits: Limits = .{},
};

pub const ValueHandle = core.JSValueHandle;
pub const EvalResult = ValueHandle;

pub const ExceptionInfo = struct {
    value: ValueHandle,

    pub fn deinit(self: *ExceptionInfo) void {
        self.value.deinit();
    }

    pub fn getMessage(self: ExceptionInfo, allocator: std.mem.Allocator) ![]const u8 {
        const rt = self.value.runtime orelse return error.InvalidEngineState;
        const value = self.value.get();
        if (value.isObject()) {
            const header = value.refHeader() orelse return error.InvalidEngineState;
            const object: *core.Object = @fieldParentPtr("header", header);
            
            const name_opt = try getPropertyString(rt, object, "name", allocator);
            errdefer if (name_opt) |n| allocator.free(n);
            const msg_opt = try getPropertyString(rt, object, "message", allocator);
            errdefer if (msg_opt) |m| allocator.free(m);

            if (name_opt) |name| {
                if (msg_opt) |msg| {
                    defer allocator.free(name);
                    defer allocator.free(msg);
                    return try std.fmt.allocPrint(allocator, "{s}: {s}", .{ name, msg });
                }
                return name;
            } else if (msg_opt) |msg| {
                return msg;
            }
        }
        
        // Fallback: format using appendValueString
        var temp_list = std.ArrayList(u8).empty;
        defer temp_list.deinit(rt.memory.allocator);
        try exec.value_ops.appendValueString(rt, &temp_list, value);
        return try allocator.dupe(u8, temp_list.items);
    }

    pub fn getStack(self: ExceptionInfo, allocator: std.mem.Allocator) !?[]const u8 {
        const rt = self.value.runtime orelse return error.InvalidEngineState;
        const value = self.value.get();
        if (!value.isObject()) return null;
        const header = value.refHeader() orelse return null;
        const object: *core.Object = @fieldParentPtr("header", header);
        return try getPropertyString(rt, object, "stack", allocator);
    }
};

fn getPropertyString(rt: *core.JSRuntime, obj: *core.Object, name: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    const val = obj.getProperty(key);
    defer val.free(rt);
    if (!val.isString()) return null;
    
    var temp_list = std.ArrayList(u8).empty;
    defer temp_list.deinit(rt.memory.allocator);
    try exec.value_ops.appendRawString(rt, &temp_list, val);
    return try allocator.dupe(u8, temp_list.items);
}

pub const HostHooks = struct {
    ptr: *anyopaque,
    resolveModule: *const fn (*anyopaque, []const u8, ?[]const u8, std.mem.Allocator) anyerror!ResolvedModule,
    loadModule: *const fn (*anyopaque, ResolvedModule, std.mem.Allocator) anyerror!LoadedModule,

    pub const ModuleKind = enum { esm, commonjs, json, wasm, builtin };

    pub const ResolvedModule = struct {
        specifier: []const u8,
        path: []const u8,
        kind: ModuleKind,
    };

    pub const LoadedModule = struct {
        source: []const u8,
        path: []const u8,
        kind: ModuleKind,
        owned: bool = false,
    };
};

pub const Engine = struct {
    runtime: *core.JSRuntime,
    context: *core.JSContext,

    pub fn init(allocator: std.mem.Allocator) !Engine {
        return initWithOptions(.{ .allocator = allocator });
    }

    pub fn initWithOptions(options: EngineOptions) !Engine {
        const rt = try core.JSRuntime.createWithOptions(options.allocator, .{
            .trace_writer = options.trace_writer,
            .memory_limit = options.limits.memory_bytes,
            .gc_threshold = options.limits.gc_threshold_bytes orelse core.runtime.default_gc_threshold,
            .stack_size = options.limits.stack_bytes orelse core.runtime.default_stack_size,
        });
        errdefer rt.destroy();
        const ctx = try core.JSContext.create(rt);
        errdefer ctx.destroy();
        return Engine{
            .runtime = rt,
            .context = ctx,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.runJobs() catch {};
        exec.zjs_vm.cleanupWorkersForRuntime(self.runtime);
        exec.zjs_vm.cleanupAtomicsWaitersForContext(self.context);
        self.context.destroy();
        self.runtime.destroy();
    }

    pub fn eval(self: *Engine, source_text: []const u8) exec.exceptions.RuntimeError!core.JSValue {
        return self.evalWithOptions(source_text, .{});
    }

    pub fn evalHandle(self: *Engine, source_text: []const u8) exec.exceptions.RuntimeError!ValueHandle {
        return self.evalHandleWithOptions(source_text, .{});
    }

    pub fn evalModule(self: *Engine, source_text: []const u8) exec.exceptions.RuntimeError!core.JSValue {
        return self.evalWithOptions(source_text, .{ .mode = .module });
    }

    pub fn evalModuleHandle(self: *Engine, source_text: []const u8) exec.exceptions.RuntimeError!ValueHandle {
        return self.evalHandleWithOptions(source_text, .{ .mode = .module });
    }

    pub fn evalWithOptions(self: *Engine, source_text: []const u8, options: core.context.EvalOptions) exec.exceptions.RuntimeError!core.JSValue {
        const filename = options.filename;
        const mode = options.mode;
        return self.context.eval(source_text, .{
            .mode = mode,
            .filename = filename,
            .source_kind = options.source_kind,
            .output = options.output,
            .parse_strict = options.parse_strict,
            .runtime_strict = options.runtime_strict,
            .return_completion = mode == .script and std.mem.eql(u8, filename, "<repl>"),
            .discard_script_result = mode == .script and !std.mem.eql(u8, filename, "<repl>"),
            .timing = options.timing,
        }) catch |err| return @errorCast(moduleResolutionError(err));
    }

    pub fn evalHandleWithOptions(self: *Engine, source_text: []const u8, options: core.context.EvalOptions) exec.exceptions.RuntimeError!ValueHandle {
        const val = try self.evalWithOptions(source_text, options);
        return try ValueHandle.init(self.runtime, val);
    }

    pub fn freeValue(self: *Engine, value: core.JSValue) void {
        value.free(self.runtime);
    }

    pub fn takeExceptionInfo(self: *Engine) !ExceptionInfo {
        const thrown = if (self.context.hasUnhandledRejection()) blk: {
            const rejection = self.context.takeUnhandledRejection();
            if (self.context.hasException()) self.context.clearException();
            break :blk rejection;
        } else self.context.takeException();

        return ExceptionInfo{
            .value = try ValueHandle.init(self.runtime, thrown),
        };
    }

    pub fn runJobs(self: *Engine) !void {
        self.runtime.job_queue.runAll();
        const global_object = try exec.zjs_vm.contextGlobal(self.context);
        try exec.zjs_vm.drainPendingPromiseJobs(self.context, null, global_object);
    }

    pub fn defineGlobalExternalHostFunction(
        self: *Engine,
        name: []const u8,
        length: i32,
        ptr: *anyopaque,
        call: core.host_function.ExternalCallFn,
        finalizer: ?core.host_function.ExternalFinalizer,
    ) !void {
        const rt = self.runtime;
        const ctx = self.context;
        const global_object = try exec.zjs_vm.contextGlobal(ctx);
        
        const id = try rt.registerExternalHostFunction(.{
            .ptr = ptr,
            .call = call,
            .finalizer = finalizer,
        });
        
        const function_value = try @import("builtins/function.zig").nativeFunction(rt, name, length);
        errdefer function_value.free(rt);

        const function_object = try exec.property_ops.expectObject(function_value);
        function_object.hostFunctionKindSlot().* = core.host_function.ids.external_host;
        function_object.externalHostFunctionIdSlot().* = id;
        try function_object.setFunctionRealmGlobalPtr(rt, global_object);

        const property_name = try rt.internAtom(name);
        defer rt.atoms.free(property_name);
        try global_object.defineOwnProperty(rt, property_name, core.Descriptor.data(function_value, true, false, true));
    }

    pub fn evalModuleWithHostHooks(
        self: *Engine,
        source_text: []const u8,
        filename: []const u8,
        host_hooks: HostHooks,
        allocator: std.mem.Allocator,
    ) !ValueHandle {
        const raw_val = try evalModuleWithHostHooksRaw(self.runtime, self.context, source_text, filename, host_hooks, allocator);
        return try ValueHandle.init(self.runtime, raw_val);
    }
};

fn moduleResolutionError(err: anytype) (@TypeOf(err) || error{SyntaxError}) {
    return switch (err) {
        error.MissingExport, error.AmbiguousExport => error.SyntaxError,
        else => err,
    };
}

fn evalModuleWithHostHooksRaw(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    source_text: []const u8,
    filename: []const u8,
    host_hooks: HostHooks,
    allocator: std.mem.Allocator,
) !core.JSValue {
    var module_postorder = std.ArrayList([]const u8).empty;
    defer {
        for (module_postorder.items) |path| allocator.free(path);
        module_postorder.deinit(allocator);
    }
    try preloadFileModuleGraphWithHostHooks(allocator, runtime, context, host_hooks, source_text, filename, &module_postorder);

    const root_module_name = try runtime.internAtom(filename);
    defer runtime.atoms.free(root_module_name);
    if (runtime.modules.find(root_module_name)) |record| record.import_meta_main = true;
    runtime.modules.linkModule(runtime, root_module_name) catch |err| return moduleResolutionError(err);
    const global_object = try exec.zjs_vm.contextGlobal(context);
    for (module_postorder.items) |path| {
        var raw_module_source: []const u8 = undefined;
        const is_root = std.mem.eql(u8, path, filename);
        var loaded_owned = false;
        var loaded_kind: HostHooks.ModuleKind = .esm;

        if (is_root) {
            raw_module_source = source_text;
        } else {
            const resolved = try host_hooks.resolveModule(host_hooks.ptr, path, null, allocator);
            defer allocator.free(resolved.specifier);
            defer allocator.free(resolved.path);

            const loaded = try host_hooks.loadModule(host_hooks.ptr, resolved, allocator);
            raw_module_source = loaded.source;
            loaded_owned = loaded.owned;
            loaded_kind = loaded.kind;
            defer allocator.free(loaded.path);
        }

        var module_source_allocated = false;
        const module_source = try wrapSourceByKind(allocator, loaded_kind, raw_module_source, path, &module_source_allocated);
        defer if (module_source_allocated) allocator.free(module_source);

        var compiled = try frontend.parser.parse(runtime, module_source, .{ .mode = .module, .filename = path });
        if (loaded_owned) allocator.free(raw_module_source);
        defer compiled.deinit();
        if (compiled.syntax_error) |err| {
            const exception_ops = @import("exec/vm_exception_ops.zig");
            var msg_buf = std.ArrayList(u8).empty;
            defer msg_buf.deinit(runtime.memory.allocator);
            try msg_buf.print(runtime.memory.allocator, "SYNTAX ERROR in evalModuleWithHostHooks {s}:{d}:{d} - {s}", .{ path, err.position.line, err.position.column, err.message });
            const error_val = try exception_ops.createNamedError(runtime, global_object, "SyntaxError", msg_buf.items);
            _ = context.throwValue(error_val);
            return error.SyntaxError;
        }
        const module_name = try runtime.internAtom(path);
        defer runtime.atoms.free(module_name);
        try exec.module.initializeModuleFunctionDeclarations(context, global_object, module_name, &compiled.function);
    }

    var continuations = std.ArrayList(ModuleContinuation).empty;
    defer freeModuleContinuations(runtime, allocator, &continuations);

    for (module_postorder.items) |path| {
        if (std.mem.eql(u8, path, filename)) continue;
        try drainModuleContinuationsForDependencies(runtime, context, allocator, &continuations, path);

        const resolved = try host_hooks.resolveModule(host_hooks.ptr, path, null, allocator);
        defer allocator.free(resolved.specifier);
        defer allocator.free(resolved.path);

        const loaded = try host_hooks.loadModule(host_hooks.ptr, resolved, allocator);
        defer if (loaded.owned) allocator.free(loaded.source);
        defer allocator.free(loaded.path);

        var module_source_allocated = false;
        const module_source = try wrapSourceByKind(allocator, loaded.kind, loaded.source, path, &module_source_allocated);
        defer if (module_source_allocated) allocator.free(module_source);

        const dep_step = try evalPreloadedFileModuleStep(runtime, context, module_source, path, null, null);
        try handleModuleEvalStep(runtime, allocator, &continuations, dep_step, module_source, path, false);
        try runJobsRaw(runtime, context);
        if (context.hasUnhandledRejection() or context.hasException()) return error.UnhandledPromiseRejection;
    }

    try drainModuleContinuationsForDependencies(runtime, context, allocator, &continuations, filename);
    const root_step = try evalPreloadedFileModuleStep(runtime, context, source_text, filename, null, null);
    try handleModuleEvalStep(runtime, allocator, &continuations, root_step, source_text, filename, true);
    return try drainModuleContinuations(runtime, context, allocator, &continuations);
}

fn preloadFileModuleGraphWithHostHooks(
    allocator: std.mem.Allocator,
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    host_hooks: HostHooks,
    root_source: []const u8,
    root_path: []const u8,
    postorder: *std.ArrayList([]const u8),
) !void {
    var seen = std.ArrayList([]const u8).empty;
    defer {
        for (seen.items) |path| allocator.free(path);
        seen.deinit(allocator);
    }
    try preloadFileModuleGraphWithHostHooksInner(allocator, runtime, context, host_hooks, root_source, root_path, &seen, postorder);
}

fn preloadFileModuleGraphWithHostHooksInner(
    allocator: std.mem.Allocator,
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    host_hooks: HostHooks,
    source_text: []const u8,
    path: []const u8,
    seen: *std.ArrayList([]const u8),
    postorder: *std.ArrayList([]const u8),
) !void {
    for (seen.items) |existing| {
        if (std.mem.eql(u8, existing, path)) return;
    }
    const owned_path = try allocator.dupe(u8, path);
    var seen_owns_path = false;
    errdefer if (!seen_owns_path) allocator.free(owned_path);
    try seen.append(allocator, owned_path);
    seen_owns_path = true;

    const module_name = try runtime.internAtom(path);
    defer runtime.atoms.free(module_name);

    var parsed = try frontend.parser.parse(runtime, source_text, .{ .mode = .module, .filename = path });
    defer parsed.deinit();
    if (parsed.syntax_error) |err| {
        const exception_ops = @import("exec/vm_exception_ops.zig");
        const global_object = try exec.zjs_vm.contextGlobal(context);
        var msg_buf = std.ArrayList(u8).empty;
        defer msg_buf.deinit(runtime.memory.allocator);
        try msg_buf.print(runtime.memory.allocator, "SYNTAX ERROR in preloadFileModuleGraphWithHostHooksInner {s}:{d}:{d} - {s}", .{ path, err.position.line, err.position.column, err.message });
        const error_val = try exception_ops.createNamedError(runtime, global_object, "SyntaxError", msg_buf.items);
        _ = context.throwValue(error_val);
        return error.SyntaxError;
    }

    _ = try exec.module.instantiateParsedRecordWithReferrer(runtime, module_name, &parsed.function, path);

    const record = parsed.function.module_record orelse return;
    for (record.requests) |request| {
        const specifier = runtime.atoms.name(request.module_name) orelse return error.InvalidAtom;

        const resolved = try host_hooks.resolveModule(host_hooks.ptr, specifier, path, allocator);
        defer allocator.free(resolved.specifier);
        defer allocator.free(resolved.path);

        const resolved_atom = try runtime.internAtom(resolved.path);
        defer runtime.atoms.free(resolved_atom);

        const specifier_atom = request.module_name;
        if (specifier_atom != resolved_atom) {
            if (runtime.modules.find(module_name)) |p_record| {
                for (p_record.requested_modules) |*req| {
                    if (req.* == specifier_atom) {
                        runtime.atoms.free(req.*);
                        req.* = runtime.atoms.dup(resolved_atom);
                    }
                }
                for (p_record.imports) |*imp| {
                    if (imp.module_name == specifier_atom) {
                        runtime.atoms.free(imp.module_name);
                        imp.module_name = runtime.atoms.dup(resolved_atom);
                    }
                }
                for (p_record.indirect_exports) |*ind| {
                    if (ind.module_name == specifier_atom) {
                        runtime.atoms.free(ind.module_name);
                        ind.module_name = runtime.atoms.dup(resolved_atom);
                    }
                }
                for (p_record.star_exports) |*star| {
                    if (star.module_name == specifier_atom) {
                        runtime.atoms.free(star.module_name);
                        star.module_name = runtime.atoms.dup(resolved_atom);
                    }
                }
                for (p_record.import_attributes) |*attr| {
                    if (attr.module_name == specifier_atom) {
                        runtime.atoms.free(attr.module_name);
                        attr.module_name = runtime.atoms.dup(resolved_atom);
                    }
                }
            }
        }

        const loaded = try host_hooks.loadModule(host_hooks.ptr, resolved, allocator);
        defer if (loaded.owned) allocator.free(loaded.source);
        defer allocator.free(loaded.path);

        var module_source_allocated = false;
        const module_source = try wrapSourceByKind(allocator, loaded.kind, loaded.source, loaded.path, &module_source_allocated);
        defer if (module_source_allocated) allocator.free(module_source);

        try preloadFileModuleGraphWithHostHooksInner(allocator, runtime, context, host_hooks, module_source, loaded.path, seen, postorder);
    }

    const order_path = try allocator.dupe(u8, path);
    errdefer allocator.free(order_path);
    try postorder.append(allocator, order_path);
}

fn wrapSourceByKind(
    allocator: std.mem.Allocator,
    kind: HostHooks.ModuleKind,
    source: []const u8,
    path: []const u8,
    allocated: *bool,
) ![]const u8 {
    switch (kind) {
        .esm, .builtin => {
            allocated.* = false;
            return source;
        },
        .json => {
            allocated.* = true;
            return try std.fmt.allocPrint(allocator, "export default {s};", .{source});
        },
        .commonjs => {
            const dirname = std.fs.path.dirname(path) orelse ".";
            allocated.* = true;
            return try std.fmt.allocPrint(allocator,
                \\var exports = {{}}, module = {{ exports: exports }};
                \\(function(exports, require, module, __filename, __dirname) {{
                \\{s}
                \\}})(exports, undefined, module, "{s}", "{s}");
                \\export default module.exports;
            , .{ source, path, dirname });
        },
        .wasm => {
            var bytes_list = std.ArrayList(u8).empty;
            errdefer bytes_list.deinit(allocator);
            try bytes_list.appendSlice(allocator, "const bytes = new Uint8Array([");
            for (source, 0..) |b, i| {
                if (i > 0) try bytes_list.appendSlice(allocator, ",");
                var buf: [16]u8 = undefined;
                const slice = try std.fmt.bufPrint(&buf, "{d}", .{b});
                try bytes_list.appendSlice(allocator, slice);
            }
            try bytes_list.appendSlice(allocator, "]);\nconst module = new WebAssembly.Module(bytes);\nconst instance = new WebAssembly.Instance(module);\nexport default instance.exports;\n");
            allocated.* = true;
            return try bytes_list.toOwnedSlice(allocator);
        },
    }
}

fn evalPreloadedFileModuleStep(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    source_text: []const u8,
    filename: []const u8,
    continuation_value: ?core.JSValue,
    resume_value: ?core.JSValue,
) !ModuleEvalStep {
    var input_continuation = continuation_value;
    errdefer if (input_continuation) |value| value.free(runtime);

    var compiled = try frontend.parser.parse(runtime, source_text, .{ .mode = .module, .filename = filename });
    defer compiled.deinit();
    if (compiled.syntax_error) |err| {
        const exception_ops = @import("exec/vm_exception_ops.zig");
        const global_object = try exec.zjs_vm.contextGlobal(context);
        var msg_buf = std.ArrayList(u8).empty;
        defer msg_buf.deinit(runtime.memory.allocator);
        try msg_buf.print(runtime.memory.allocator, "SYNTAX ERROR in evalPreloadedFileModuleStep {s}:{d}:{d} - {s}", .{ filename, err.position.line, err.position.column, err.message });
        const error_val = try exception_ops.createNamedError(runtime, global_object, "SyntaxError", msg_buf.items);
        _ = context.throwValue(error_val);
        return error.SyntaxError;
    }

    const module_name = try runtime.internAtom(filename);
    defer runtime.atoms.free(module_name);
    if (runtime.modules.find(module_name) == null) return error.ModuleNotFound;
    runtime.modules.linkModule(runtime, module_name) catch |err| {
        const exception_ops = @import("exec/vm_exception_ops.zig");
        const global_object = try exec.zjs_vm.contextGlobal(context);
        var msg_buf = std.ArrayList(u8).empty;
        defer msg_buf.deinit(runtime.memory.allocator);
        try msg_buf.print(runtime.memory.allocator, "LINK ERROR in evalPreloadedFileModuleStep for module {s}: {s}", .{ filename, @errorName(err) });
        const error_val = try exception_ops.createNamedError(runtime, global_object, "SyntaxError", msg_buf.items);
        _ = context.throwValue(error_val);
        return moduleResolutionError(err);
    };

    const module_var_refs = try exec.module.buildModuleVarRefs(context, module_name, &compiled.function);
    defer exec.module.freeModuleVarRefs(runtime, module_var_refs);
    var owned_continuation = if (input_continuation) |value| blk: {
        input_continuation = null;
        break :blk value;
    } else blk: {
        const object = try core.Object.create(runtime, core.class.ids.generator, null);
        break :blk object.value();
    };
    errdefer owned_continuation.free(runtime);
    const continuation = try exec.property_ops.expectObject(owned_continuation);
    var stack = exec.stack.Stack.init(&runtime.memory, context.stack_limit);
    defer stack.deinit(runtime);
    const result = exec.zjs_vm.runModuleWithOutputAndVarRefsState(context, &stack, &compiled.function, null, module_var_refs, continuation, resume_value) catch |err| return moduleResolutionError(err);
    if (continuation.generatorJustYielded() and !continuation.generatorDone()) {
        return .{ .suspended = .{
            .continuation = owned_continuation,
            .awaited = result,
        } };
    }
    owned_continuation.free(runtime);
    return .{ .completed = result };
}

fn runJobsRaw(runtime: *core.JSRuntime, context: *core.JSContext) !void {
    runtime.job_queue.runAll();
    const global_object = try exec.zjs_vm.contextGlobal(context);
    try exec.zjs_vm.drainPendingPromiseJobs(context, null, global_object);
}

fn drainModuleContinuationsForDependencies(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    allocator: std.mem.Allocator,
    continuations: *std.ArrayList(ModuleContinuation),
    filename: []const u8,
) !void {
    while (try hasActiveAsyncDependency(runtime, continuations, filename)) {
        if (try drainOneModuleContinuation(runtime, context, allocator, continuations)) |value| value.free(runtime);
    }
}

fn hasActiveAsyncDependency(
    runtime: *core.JSRuntime,
    continuations: *const std.ArrayList(ModuleContinuation),
    filename: []const u8,
) !bool {
    const module_name = try runtime.internAtom(filename);
    defer runtime.atoms.free(module_name);
    const record = runtime.modules.find(module_name) orelse return false;
    var visited = std.ArrayList(core.Atom).empty;
    defer visited.deinit(runtime.memory.allocator);
    return recordHasActiveAsyncDependency(runtime, continuations, record, &visited);
}

fn recordHasActiveAsyncDependency(
    runtime: *core.JSRuntime,
    continuations: *const std.ArrayList(ModuleContinuation),
    record: *const core.module.ModuleRecord,
    visited: *std.ArrayList(core.Atom),
) !bool {
    for (visited.items) |seen| {
        if (seen == record.module_name) return false;
    }
    try visited.append(runtime.memory.allocator, record.module_name);
    for (record.requested_modules) |request| {
        const request_name = runtime.atoms.name(request) orelse continue;
        for (continuations.items) |continuation| {
            if (!continuation.completed and std.mem.eql(u8, continuation.path, request_name)) return true;
        }
        const requested_record = runtime.modules.find(request) orelse continue;
        if (try recordHasActiveAsyncDependency(runtime, continuations, requested_record, visited)) return true;
    }
    return false;
}

fn drainOneModuleContinuation(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    allocator: std.mem.Allocator,
    continuations: *std.ArrayList(ModuleContinuation),
) !?core.JSValue {
    var current = continuations.orderedRemove(0);
    var current_roots_registered = true;
    errdefer if (current_roots_registered) unregisterSymbolRoots(runtime, &current);
    defer allocator.free(current.source);
    defer allocator.free(current.path);
    if (current.completed) {
        unregisterSymbolRoots(runtime, &current);
        current_roots_registered = false;
        if (current.keep_result) return current.awaited;
        current.awaited.free(runtime);
        return null;
    }
    const awaited_value = current.awaited;
    var awaited_owned = true;
    errdefer if (awaited_owned) awaited_value.free(runtime);
    const continuation = current.continuation;
    var continuation_owned = true;
    errdefer if (continuation_owned) continuation.free(runtime);
    const module_source = current.source;
    const path = current.path;
    const keep_result = current.keep_result;
    const global_object = try exec.zjs_vm.contextGlobal(context);
    try exec.zjs_vm.drainPendingPromiseJobs(context, null, global_object);
    continuation_owned = false;
    const step = try evalPreloadedFileModuleStep(runtime, context, module_source, path, continuation, awaited_value);
    awaited_value.free(runtime);
    awaited_owned = false;
    unregisterSymbolRoots(runtime, &current);
    current_roots_registered = false;
    var step_owned = true;
    errdefer if (step_owned) freeModuleEvalStep(runtime, step);
    try runJobsRaw(runtime, context);
    if (context.hasUnhandledRejection() or context.hasException()) return error.UnhandledPromiseRejection;
    step_owned = false;
    try handleModuleEvalStep(runtime, allocator, continuations, step, module_source, path, keep_result);
    return null;
}

fn handleModuleEvalStep(
    runtime: *core.JSRuntime,
    allocator: std.mem.Allocator,
    continuations: *std.ArrayList(ModuleContinuation),
    step: ModuleEvalStep,
    source_text: []const u8,
    filename: []const u8,
    keep_result: bool,
) !void {
    switch (step) {
        .completed => |value| {
            if (keep_result) {
                errdefer value.free(runtime);
                const source_copy = try allocator.dupe(u8, source_text);
                errdefer allocator.free(source_copy);
                const path_copy = try allocator.dupe(u8, filename);
                errdefer allocator.free(path_copy);
                var continuation = ModuleContinuation{
                    .source = source_copy,
                    .path = path_copy,
                    .continuation = core.JSValue.undefinedValue(),
                    .awaited = value,
                    .keep_result = true,
                    .completed = true,
                };
                try registerSymbolRoots(runtime, &continuation);
                errdefer unregisterSymbolRoots(runtime, &continuation);
                try continuations.append(allocator, continuation);
            } else {
                value.free(runtime);
            }
        },
        .suspended => |suspended| {
            errdefer suspended.continuation.free(runtime);
            errdefer suspended.awaited.free(runtime);
            const source_copy = try allocator.dupe(u8, source_text);
            errdefer allocator.free(source_copy);
            const path_copy = try allocator.dupe(u8, filename);
            errdefer allocator.free(path_copy);
            var continuation = ModuleContinuation{
                .source = source_copy,
                .path = path_copy,
                .continuation = suspended.continuation,
                .awaited = suspended.awaited,
                .keep_result = keep_result,
            };
            try registerSymbolRoots(runtime, &continuation);
            errdefer unregisterSymbolRoots(runtime, &continuation);
            try continuations.append(allocator, continuation);
        },
    }
}

fn drainModuleContinuations(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    allocator: std.mem.Allocator,
    continuations: *std.ArrayList(ModuleContinuation),
) !core.JSValue {
    var kept_result: core.JSValue = core.JSValue.undefinedValue();
    var has_kept_result = false;
    while (continuations.items.len != 0) {
        if (try drainOneModuleContinuation(runtime, context, allocator, continuations)) |value| {
            if (has_kept_result) kept_result.free(runtime);
            kept_result = value;
            has_kept_result = true;
        }
    }
    if (has_kept_result) return kept_result;
    return core.JSValue.undefinedValue();
}

fn registerSymbolRoots(runtime: *core.JSRuntime, self: *ModuleContinuation) !void {
    std.debug.assert(self.symbol_root_mask == 0);
    errdefer unregisterSymbolRoots(runtime, self);
    if (try runtime.registerExternalValueSymbolRoot(self.continuation)) self.symbol_root_mask |= 0b01;
    if (try runtime.registerExternalValueSymbolRoot(self.awaited)) self.symbol_root_mask |= 0b10;
}

fn unregisterSymbolRoots(runtime: *core.JSRuntime, self: *ModuleContinuation) void {
    if ((self.symbol_root_mask & 0b01) != 0) runtime.unregisterExternalValueSymbolRoot(self.continuation);
    if ((self.symbol_root_mask & 0b10) != 0) runtime.unregisterExternalValueSymbolRoot(self.awaited);
    self.symbol_root_mask = 0;
}

fn freeModuleContinuations(
    runtime: *core.JSRuntime,
    allocator: std.mem.Allocator,
    continuations: *std.ArrayList(ModuleContinuation),
) void {
    for (continuations.items) |*item| {
        allocator.free(item.source);
        allocator.free(item.path);
        unregisterSymbolRoots(runtime, item);
        item.continuation.free(runtime);
        item.awaited.free(runtime);
    }
    continuations.deinit(allocator);
}

fn freeModuleEvalStep(runtime: *core.JSRuntime, step: ModuleEvalStep) void {
    switch (step) {
        .completed => |value| value.free(runtime),
        .suspended => |suspended| {
            suspended.continuation.free(runtime);
            suspended.awaited.free(runtime);
        },
    }
}
