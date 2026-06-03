pub const core = @import("core/root.zig");
pub const frontend = @import("frontend/root.zig");
pub const bytecode = @import("bytecode/root.zig");
pub const exec = @import("exec/root.zig");
pub const builtins = @import("builtins/root.zig");
pub const libs = @import("libs/root.zig");

pub const RuntimeError = exec.exceptions.RuntimeError;
pub const HostError = exec.exceptions.HostError;
pub const EngineError = RuntimeError;

pub const JSRuntime = core.JSRuntime;
pub const JSContext = core.JSContext;
pub const JSValue = core.JSValue;
pub const JSValueHandle = core.runtime.JSValueHandle;
pub const LocalHandle = core.LocalHandle;
pub const HandleScope = core.HandleScope;
pub const WeakPersistent = core.WeakPersistent;
pub const WeakPersistentValue = core.WeakPersistentValue;
pub const NativePin = core.NativePin;
pub const GCPolicy = core.GCPolicy;
pub const GCStats = core.GCStats;


pub const harness = struct {
    pub const Engine = HarnessEngine;
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

pub const EvalOptions = core.context.EvalOptions;
pub const EvalTiming = core.context.EvalTiming;
pub const ExternalHostCall = core.host_function.ExternalCall;
pub const ExternalHostCallFn = core.host_function.ExternalCallFn;
pub const ExternalHostFinalizer = core.host_function.ExternalFinalizer;

pub const ExceptionInfo = struct {
    value: JSValueHandle,

    pub fn deinit(self: *ExceptionInfo) void {
        self.value.deinit();
    }
};

pub const Engine = HarnessEngine;

const HarnessEngine = struct {
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    output: ?*std.Io.Writer = null,

    pub fn init(allocator: std.mem.Allocator) !HarnessEngine {
        return initWithOptions(.{ .allocator = allocator });
    }

    pub fn initWithOptions(options: EngineOptions) !HarnessEngine {
        const rt = try core.JSRuntime.createWithOptions(options.allocator, .{
            .trace_writer = options.trace_writer,
            .memory_limit = options.limits.memory_bytes,
            .gc_threshold = options.limits.gc_threshold_bytes orelse core.runtime.default_gc_threshold,
            .stack_size = options.limits.stack_bytes orelse core.runtime.default_stack_size,
        });
        errdefer rt.destroy();
        const ctx = try core.JSContext.create(rt);
        errdefer ctx.destroy();
        return .{
            .runtime = rt,
            .context = ctx,
            .output = null,
        };
    }

    pub fn initWithTrace(allocator: std.mem.Allocator, trace_writer: ?*std.Io.Writer) !HarnessEngine {
        return initWithOptions(.{
            .allocator = allocator,
            .trace_writer = trace_writer,
        });
    }

    pub fn deinit(self: *HarnessEngine) void {
        exec.zjs_vm.cleanupWorkersForRuntime(self.runtime);
        _ = exec.zjs_vm.cleanupTest262Agents();
        exec.zjs_vm.cleanupAtomicsWaitersForContext(self.context);
        self.context.destroy();
        self.runtime.destroy();
    }

    pub fn setLimits(self: *HarnessEngine, limits: Limits) void {
        self.runtime.setMemoryLimit(limits.memory_bytes);
        if (limits.stack_bytes) |stack_bytes| {
            self.runtime.setStackSize(stack_bytes);
            self.context.stack_limit = stack_bytes;
        }
        if (limits.gc_threshold_bytes) |gc_threshold_bytes| self.runtime.setGCThreshold(gc_threshold_bytes);
    }

    pub fn global(self: *HarnessEngine) !*core.Object {
        return exec.zjs_vm.contextGlobal(self.context);
    }

    pub fn eval(self: *HarnessEngine, source_text: []const u8) RuntimeError!core.JSValue {
        return self.evalMode(source_text, .script) catch |err| return @errorCast(moduleResolutionError(err));
    }

    pub fn evalHandle(self: *HarnessEngine, source_text: []const u8) RuntimeError!JSValueHandle {
        return self.evalHandleWithOptions(source_text, .{});
    }

    pub fn evalModule(self: *HarnessEngine, source_text: []const u8) RuntimeError!core.JSValue {
        return self.evalMode(source_text, .module) catch |err| return @errorCast(moduleResolutionError(err));
    }

    pub fn evalModuleHandle(self: *HarnessEngine, source_text: []const u8) RuntimeError!JSValueHandle {
        return self.evalHandleWithOptions(source_text, .{ .mode = .module });
    }

    pub fn evalMode(self: *HarnessEngine, source_text: []const u8, mode: frontend.parser.Mode) RuntimeError!core.JSValue {
        return self.evalModeWithOutput(source_text, null, mode) catch |err| return @errorCast(moduleResolutionError(err));
    }

    pub fn evalWithOptions(self: *HarnessEngine, source_text: []const u8, options: EvalOptions) RuntimeError!core.JSValue {
        return self.evalModeWithOutputNamedTimedOptions(
            source_text,
            options.output,
            options.mode,
            options.filename,
            options.source_kind,
            options.timing,
            options.parse_strict,
            options.runtime_strict,
        ) catch |err| return @errorCast(moduleResolutionError(err));
    }

    pub fn evalHandleWithOptions(self: *HarnessEngine, source_text: []const u8, options: EvalOptions) RuntimeError!JSValueHandle {
        const value = try self.evalWithOptions(source_text, options);
        return try JSValueHandle.init(self.runtime, value);
    }

    /// Create an owned persistent handle for a host-held value. The caller must
    /// destroy the returned handle before deinitializing the engine.
    pub fn createPersistentValue(self: *HarnessEngine, value: core.JSValue) !JSValueHandle {
        return self.runtime.createPersistentValue(value);
    }

    pub fn evalWithOutput(self: *HarnessEngine, source_text: []const u8, output: *std.Io.Writer) RuntimeError!core.JSValue {
        return self.evalWithOutputMode(source_text, output, .script) catch |err| return @errorCast(moduleResolutionError(err));
    }

    pub fn evalWithOutputMode(
        self: *HarnessEngine,
        source_text: []const u8,
        output: *std.Io.Writer,
        mode: frontend.parser.Mode,
    ) RuntimeError!core.JSValue {
        return self.evalModeWithOutputNamed(source_text, output, mode, "<eval>") catch |err| return @errorCast(moduleResolutionError(err));
    }

    pub fn evalFileWithOutputMode(
        self: *HarnessEngine,
        source_text: []const u8,
        output: *std.Io.Writer,
        mode: frontend.parser.Mode,
        filename: []const u8,
    ) RuntimeError!core.JSValue {
        return self.evalModeWithOutputNamed(source_text, output, mode, filename) catch |err| return @errorCast(moduleResolutionError(err));
    }

    pub fn evalFileWithOutputModeStrict(
        self: *HarnessEngine,
        source_text: []const u8,
        output: *std.Io.Writer,
        mode: frontend.parser.Mode,
        filename: []const u8,
        strict: bool,
    ) RuntimeError!core.JSValue {
        return self.evalModeWithOutputNamedTimedOptions(source_text, output, mode, filename, .auto, null, strict, strict) catch |err| return @errorCast(moduleResolutionError(err));
    }

    pub fn evalFileWithOutputModeRuntimeStrict(
        self: *HarnessEngine,
        source_text: []const u8,
        output: *std.Io.Writer,
        mode: frontend.parser.Mode,
        filename: []const u8,
        runtime_strict: bool,
    ) RuntimeError!core.JSValue {
        return self.evalModeWithOutputNamedTimedOptions(source_text, output, mode, filename, .auto, null, false, runtime_strict) catch |err| return @errorCast(moduleResolutionError(err));
    }

    pub fn evalFileWithOutputModeTimed(
        self: *HarnessEngine,
        source_text: []const u8,
        output: *std.Io.Writer,
        mode: frontend.parser.Mode,
        filename: []const u8,
        timing: *EvalTiming,
    ) RuntimeError!core.JSValue {
        return self.evalModeWithOutputNamedTimed(source_text, output, mode, filename, timing) catch |err| return @errorCast(moduleResolutionError(err));
    }

    pub fn evalFileWithOutputModeTimedStrict(
        self: *HarnessEngine,
        source_text: []const u8,
        output: *std.Io.Writer,
        mode: frontend.parser.Mode,
        filename: []const u8,
        timing: *EvalTiming,
        strict: bool,
    ) RuntimeError!core.JSValue {
        return self.evalModeWithOutputNamedTimedOptions(source_text, output, mode, filename, .auto, timing, strict, strict) catch |err| return @errorCast(moduleResolutionError(err));
    }

    pub fn evalFileWithOutputModeTimedRuntimeStrict(
        self: *HarnessEngine,
        source_text: []const u8,
        output: *std.Io.Writer,
        mode: frontend.parser.Mode,
        filename: []const u8,
        timing: *EvalTiming,
        runtime_strict: bool,
    ) RuntimeError!core.JSValue {
        return self.evalModeWithOutputNamedTimedOptions(source_text, output, mode, filename, .auto, timing, false, runtime_strict) catch |err| return @errorCast(moduleResolutionError(err));
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

    pub fn evalFileModuleGraphWithHostHooks(
        self: *HarnessEngine,
        source_text: []const u8,
        output: *std.Io.Writer,
        filename: []const u8,
        host_hooks: HostHooks,
        allocator: std.mem.Allocator,
    ) !core.JSValue {
        self.output = output;
        var module_postorder = std.ArrayList([]const u8).empty;
        defer {
            for (module_postorder.items) |path| allocator.free(path);
            module_postorder.deinit(allocator);
        }
        try preloadFileModuleGraphWithHostHooks(allocator, self.runtime, host_hooks, source_text, filename, &module_postorder);

        const root_module_name = try self.runtime.internAtom(filename);
        defer self.runtime.atoms.free(root_module_name);
        if (self.runtime.modules.find(root_module_name)) |record| record.import_meta_main = true;
        self.runtime.modules.linkModule(self.runtime, root_module_name) catch |err| return moduleResolutionError(err);
        const global_object = try exec.zjs_vm.contextGlobal(self.context);
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

            var compiled = try frontend.parser.parse(self.runtime, module_source, .{ .mode = .module, .filename = path });
            if (loaded_owned) allocator.free(raw_module_source);
            defer compiled.deinit();
            if (compiled.syntax_error) |err| {
                if (!@import("builtin").is_test) std.debug.print("SYNTAX ERROR in evalFileModuleGraphWithHostHooks {s}:{d}:{d} - {s}\n", .{ path, err.position.line, err.position.column, err.message });
                return error.SyntaxError;
            }
            const module_name = try self.runtime.internAtom(path);
            defer self.runtime.atoms.free(module_name);
            try exec.module.initializeModuleFunctionDeclarations(self.context, global_object, module_name, &compiled.function);
        }

        var continuations = std.ArrayList(ModuleContinuation).empty;
        defer freeModuleContinuations(self.runtime, allocator, &continuations);

        for (module_postorder.items) |path| {
            if (std.mem.eql(u8, path, filename)) continue;
            try self.drainModuleContinuationsForDependencies(output, allocator, &continuations, path);

            const resolved = try host_hooks.resolveModule(host_hooks.ptr, path, null, allocator);
            defer allocator.free(resolved.specifier);
            defer allocator.free(resolved.path);

            const loaded = try host_hooks.loadModule(host_hooks.ptr, resolved, allocator);
            defer if (loaded.owned) allocator.free(loaded.source);
            defer allocator.free(loaded.path);

            var module_source_allocated = false;
            const module_source = try wrapSourceByKind(allocator, loaded.kind, loaded.source, path, &module_source_allocated);
            defer if (module_source_allocated) allocator.free(module_source);

            const dep_step = try self.evalPreloadedFileModuleStep(module_source, output, path, null, null);
            try self.handleModuleEvalStep(allocator, &continuations, dep_step, module_source, path, false);
            try self.runJobs();
            if (self.context.hasUnhandledRejection() or self.context.hasException()) return error.UnhandledPromiseRejection;
        }

        try self.drainModuleContinuationsForDependencies(output, allocator, &continuations, filename);
        const root_step = try self.evalPreloadedFileModuleStep(source_text, output, filename, null, null);
        try self.handleModuleEvalStep(allocator, &continuations, root_step, source_text, filename, true);
        return self.drainModuleContinuations(output, allocator, &continuations);
    }

    fn preloadFileModuleGraphWithHostHooks(
        allocator: std.mem.Allocator,
        runtime: *core.JSRuntime,
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
        try preloadFileModuleGraphWithHostHooksInner(allocator, runtime, host_hooks, root_source, root_path, &seen, postorder);
    }

    fn preloadFileModuleGraphWithHostHooksInner(
        allocator: std.mem.Allocator,
        runtime: *core.JSRuntime,
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
            if (!@import("builtin").is_test) std.debug.print("SYNTAX ERROR in preloadFileModuleGraphWithHostHooksInner {s}:{d}:{d} - {s}\n", .{ path, err.position.line, err.position.column, err.message });
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
                    // 1. requested_modules
                    for (p_record.requested_modules) |*req| {
                        if (req.* == specifier_atom) {
                            runtime.atoms.free(req.*);
                            req.* = runtime.atoms.dup(resolved_atom);
                        }
                    }
                    // 2. imports
                    for (p_record.imports) |*imp| {
                        if (imp.module_name == specifier_atom) {
                            runtime.atoms.free(imp.module_name);
                            imp.module_name = runtime.atoms.dup(resolved_atom);
                        }
                    }
                    // 3. indirect_exports
                    for (p_record.indirect_exports) |*ind| {
                        if (ind.module_name == specifier_atom) {
                            runtime.atoms.free(ind.module_name);
                            ind.module_name = runtime.atoms.dup(resolved_atom);
                        }
                    }
                    // 4. star_exports
                    for (p_record.star_exports) |*star| {
                        if (star.module_name == specifier_atom) {
                            runtime.atoms.free(star.module_name);
                            star.module_name = runtime.atoms.dup(resolved_atom);
                        }
                    }
                    // 5. import_attributes
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

            try preloadFileModuleGraphWithHostHooksInner(allocator, runtime, host_hooks, module_source, loaded.path, seen, postorder);
        }

        const order_path = try allocator.dupe(u8, path);
        errdefer allocator.free(order_path);
        try postorder.append(allocator, order_path);
    }

    pub fn evalFileModuleGraphWithOutput(
        self: *HarnessEngine,
        source_text: []const u8,
        output: *std.Io.Writer,
        filename: []const u8,
        io: std.Io,
        allocator: std.mem.Allocator,
        max_source_size: usize,
    ) !core.JSValue {
        const normalized_filename = try std.fs.path.resolve(allocator, &.{filename});
        defer allocator.free(normalized_filename);

        var module_postorder = std.ArrayList([]const u8).empty;
        defer {
            for (module_postorder.items) |path| allocator.free(path);
            module_postorder.deinit(allocator);
        }
        try exec.module.preloadFileModuleGraphWithOrder(io, allocator, self.runtime, source_text, normalized_filename, max_source_size, &module_postorder);
        const root_module_name = try self.runtime.internAtom(normalized_filename);
        defer self.runtime.atoms.free(root_module_name);
        if (self.runtime.modules.find(root_module_name)) |record| record.import_meta_main = true;
        self.runtime.modules.linkModule(self.runtime, root_module_name) catch |err| return moduleResolutionError(err);
        try self.initializeSyntheticFileModules(io, allocator, max_source_size);
        try self.initializePreloadedModuleFunctionDeclarations(source_text, normalized_filename, io, allocator, max_source_size, module_postorder.items);
        var dynamic_import_state = DynamicImportState{
            .engine = self,
            .io = io,
            .allocator = allocator,
            .max_source_size = max_source_size,
        };
        const prev_dynamic_import_callback = self.context.dynamic_import_callback;
        const prev_dynamic_import_userdata = self.context.dynamic_import_userdata;
        self.context.dynamic_import_callback = DynamicImportState.load;
        self.context.dynamic_import_userdata = &dynamic_import_state;
        defer {
            self.context.dynamic_import_callback = prev_dynamic_import_callback;
            self.context.dynamic_import_userdata = prev_dynamic_import_userdata;
        }
        var continuations = std.ArrayList(ModuleContinuation).empty;
        defer freeModuleContinuations(self.runtime, allocator, &continuations);
        for (module_postorder.items) |path| {
            if (std.mem.eql(u8, path, normalized_filename)) continue;
            try self.drainModuleContinuationsForDependencies(output, allocator, &continuations, path);
            const dep_source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_source_size));
            defer allocator.free(dep_source);
            const dep_step = try self.evalPreloadedFileModuleStep(dep_source, output, path, null, null);
            try self.handleModuleEvalStep(allocator, &continuations, dep_step, dep_source, path, false);
            try self.runJobs();
            if (self.context.hasUnhandledRejection() or self.context.hasException()) return error.UnhandledPromiseRejection;
        }
        try self.drainModuleContinuationsForDependencies(output, allocator, &continuations, normalized_filename);
        const root_step = try self.evalPreloadedFileModuleStep(source_text, output, normalized_filename, null, null);
        try self.handleModuleEvalStep(allocator, &continuations, root_step, source_text, normalized_filename, true);
        return self.drainModuleContinuations(output, allocator, &continuations);
    }

    fn evalDynamicImportModule(
        self: *HarnessEngine,
        output: ?*std.Io.Writer,
        referrer_path: []const u8,
        specifier: []const u8,
        io: std.Io,
        allocator: std.mem.Allocator,
        max_source_size: usize,
    ) !core.JSValue {
        if (referrer_path.len == 0) return error.ModuleNotFound;
        const target_path = try exec.module.resolveModuleSpecifier(allocator, referrer_path, specifier);
        defer allocator.free(target_path);
        if (std.mem.eql(u8, target_path, "std") or std.mem.eql(u8, target_path, "os")) {
            const target_module_name = try self.runtime.internAtom(target_path);
            defer self.runtime.atoms.free(target_module_name);
            _ = try exec.module.preloadNativeModule(self.runtime, if (std.mem.eql(u8, target_path, "std")) .native_std else .native_os);
            self.runtime.modules.linkModule(self.runtime, target_module_name) catch |err| return moduleResolutionError(err);
            try self.initializeNativeSyntheticModules();
            return exec.module.moduleNamespaceValue(self.context, target_module_name);
        }
        const source_text = std.Io.Dir.cwd().readFileAlloc(io, target_path, allocator, .limited(max_source_size)) catch |err| switch (err) {
            error.FileNotFound => return error.ModuleNotFound,
            else => |e| return e,
        };
        defer allocator.free(source_text);

        var module_postorder = std.ArrayList([]const u8).empty;
        defer {
            for (module_postorder.items) |path| allocator.free(path);
            module_postorder.deinit(allocator);
        }
        try exec.module.preloadMissingFileModuleGraphWithOrder(io, allocator, self.runtime, source_text, target_path, max_source_size, &module_postorder);
        const target_module_name = try self.runtime.internAtom(target_path);
        defer self.runtime.atoms.free(target_module_name);
        self.runtime.modules.linkModule(self.runtime, target_module_name) catch |err| return moduleResolutionError(err);
        try self.initializeSyntheticFileModules(io, allocator, max_source_size);
        try self.initializePreloadedModuleFunctionDeclarations(source_text, target_path, io, allocator, max_source_size, module_postorder.items);

        for (module_postorder.items) |path| {
            const module_source = if (std.mem.eql(u8, path, target_path))
                source_text
            else
                try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_source_size));
            defer if (!std.mem.eql(u8, path, target_path)) allocator.free(module_source);
            const value = try self.evalPreloadedFileModuleWithOutput(module_source, output, path);
            defer value.free(self.runtime);
            try self.runJobs();
            if (self.context.hasUnhandledRejection() or self.context.hasException()) return error.UnhandledPromiseRejection;
        }

        return exec.module.moduleNamespaceValue(self.context, target_module_name);
    }

    fn initializePreloadedModuleFunctionDeclarations(
        self: *HarnessEngine,
        root_source: []const u8,
        root_path: []const u8,
        io: std.Io,
        allocator: std.mem.Allocator,
        max_source_size: usize,
        postorder: []const []const u8,
    ) !void {
        const global_object = try exec.zjs_vm.contextGlobal(self.context);
        for (postorder) |path| {
            const module_source = if (std.mem.eql(u8, path, root_path))
                root_source
            else
                try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_source_size));
            defer if (!std.mem.eql(u8, path, root_path)) allocator.free(module_source);

            var compiled = try frontend.parser.parse(self.runtime, module_source, .{ .mode = .module, .filename = path });
            defer compiled.deinit();
            if (compiled.syntax_error != null) return error.SyntaxError;
            const module_name = try self.runtime.internAtom(path);
            defer self.runtime.atoms.free(module_name);
            try exec.module.initializeModuleFunctionDeclarations(self.context, global_object, module_name, &compiled.function);
        }
    }

    fn initializeSyntheticFileModules(
        self: *HarnessEngine,
        io: std.Io,
        allocator: std.mem.Allocator,
        max_source_size: usize,
    ) !void {
        const global_object = try exec.zjs_vm.contextGlobal(self.context);
        for (self.runtime.modules.modules) |record| {
            if (record.synthetic_kind == .none) continue;
            if (record.synthetic_kind == .native_std or record.synthetic_kind == .native_os) {
                _ = try exec.module.initializeSyntheticFileModule(self.context, global_object, record.module_name, "");
                continue;
            }
            const path = self.runtime.atoms.name(record.module_name) orelse return error.InvalidAtom;
            const source_path = exec.module.syntheticModuleFilePath(path);
            const module_source = try std.Io.Dir.cwd().readFileAlloc(io, source_path, allocator, .limited(max_source_size));
            defer allocator.free(module_source);
            _ = try exec.module.initializeSyntheticFileModule(self.context, global_object, record.module_name, module_source);
        }
    }

    fn initializeNativeSyntheticModules(self: *HarnessEngine) !void {
        const global_object = try exec.zjs_vm.contextGlobal(self.context);
        for (self.runtime.modules.modules) |record| {
            if (record.synthetic_kind != .native_std and record.synthetic_kind != .native_os) continue;
            _ = try exec.module.initializeSyntheticFileModule(self.context, global_object, record.module_name, "");
        }
    }

    fn evalModeWithOutput(
        self: *HarnessEngine,
        source_text: []const u8,
        output: ?*std.Io.Writer,
        mode: frontend.parser.Mode,
    ) !core.JSValue {
        return self.evalModeWithOutputNamed(source_text, output, mode, "<eval>");
    }

    fn evalModeWithOutputNamed(
        self: *HarnessEngine,
        source_text: []const u8,
        output: ?*std.Io.Writer,
        mode: frontend.parser.Mode,
        filename: []const u8,
    ) !core.JSValue {
        return self.evalModeWithOutputNamedTimed(source_text, output, mode, filename, null);
    }

    fn evalModeWithOutputNamedTimed(
        self: *HarnessEngine,
        source_text: []const u8,
        output: ?*std.Io.Writer,
        mode: frontend.parser.Mode,
        filename: []const u8,
        timing: ?*EvalTiming,
    ) !core.JSValue {
        return self.evalModeWithOutputNamedTimedOptions(source_text, output, mode, filename, .auto, timing, false, false);
    }

    fn evalModeWithOutputNamedTimedOptions(
        self: *HarnessEngine,
        source_text: []const u8,
        output: ?*std.Io.Writer,
        mode: frontend.parser.Mode,
        filename: []const u8,
        source_kind: frontend.parser.SourceKind,
        timing: ?*EvalTiming,
        parse_strict: bool,
        runtime_strict: bool,
    ) !core.JSValue {
        self.output = output;
        return self.context.eval(source_text, .{
            .mode = mode,
            .filename = filename,
            .source_kind = source_kind,
            .output = output,
            .parse_strict = parse_strict,
            .runtime_strict = runtime_strict,
            .return_completion = mode == .script and std.mem.eql(u8, filename, "<repl>"),
            .discard_script_result = mode == .script and !std.mem.eql(u8, filename, "<repl>"),
            .timing = timing,
        });
    }

    fn runEvalModuleWithVarRefs(
        self: *HarnessEngine,
        function: *const bytecode.Bytecode,
        output: ?*std.Io.Writer,
        module_var_refs: []const core.JSValue,
        timing: ?*EvalTiming,
    ) !core.JSValue {
        var continuation_value = (try core.Object.create(self.runtime, core.class.ids.generator, null)).value();
        defer continuation_value.free(self.runtime);
        const continuation = try exec.property_ops.expectObject(continuation_value);
        var resume_value: ?core.JSValue = null;
        var resume_value_symbol_rooted = false;
        defer if (resume_value) |value| {
            if (resume_value_symbol_rooted) self.runtime.unregisterExternalValueSymbolRoot(value);
            value.free(self.runtime);
        };

        while (true) {
            var stack = exec.stack.Stack.init(&self.runtime.memory, self.context.stack_limit);
            defer stack.deinit(self.runtime);
            const vm_start = monotonicNanos();
            const result = exec.zjs_vm.runModuleWithOutputAndVarRefsState(
                self.context,
                &stack,
                function,
                output,
                module_var_refs,
                continuation,
                resume_value,
            ) catch |err| return moduleResolutionError(err);
            if (timing) |t| t.vm_run_ns += elapsedNanosSince(vm_start);
            if (resume_value) |value| {
                if (resume_value_symbol_rooted) {
                    self.runtime.unregisterExternalValueSymbolRoot(value);
                    resume_value_symbol_rooted = false;
                }
                value.free(self.runtime);
                resume_value = null;
            }

            if (continuation.generatorJustYielded() and !continuation.generatorDone()) {
                resume_value = result;
                resume_value_symbol_rooted = try self.runtime.registerExternalValueSymbolRoot(result);
                const global_object = try exec.zjs_vm.contextGlobal(self.context);
                const jobs_start = monotonicNanos();
                try exec.zjs_vm.drainPendingPromiseJobs(self.context, output, global_object);
                if (timing) |t| t.promise_jobs_ns += elapsedNanosSince(jobs_start);
                continue;
            }

            return result;
        }
    }

    fn evalPreloadedFileModuleWithOutput(
        self: *HarnessEngine,
        source_text: []const u8,
        output: ?*std.Io.Writer,
        filename: []const u8,
    ) !core.JSValue {
        var continuations = std.ArrayList(ModuleContinuation).empty;
        defer freeModuleContinuations(self.runtime, self.runtime.memory.allocator, &continuations);
        const step = try self.evalPreloadedFileModuleStep(source_text, output, filename, null, null);
        try self.handleModuleEvalStep(self.runtime.memory.allocator, &continuations, step, source_text, filename, true);
        return self.drainModuleContinuations(output, self.runtime.memory.allocator, &continuations);
    }

    fn evalPreloadedFileModuleStep(
        self: *HarnessEngine,
        source_text: []const u8,
        output: ?*std.Io.Writer,
        filename: []const u8,
        continuation_value: ?core.JSValue,
        resume_value: ?core.JSValue,
    ) !ModuleEvalStep {
        var input_continuation = continuation_value;
        errdefer if (input_continuation) |value| value.free(self.runtime);

        var compiled = try frontend.parser.parse(self.runtime, source_text, .{ .mode = .module, .filename = filename });
        defer compiled.deinit();
        if (compiled.syntax_error) |err| {
            if (!@import("builtin").is_test) std.debug.print("SYNTAX ERROR in evalPreloadedFileModuleStep {s}:{d}:{d} - {s}\n", .{ filename, err.position.line, err.position.column, err.message });
            return error.SyntaxError;
        }

        const module_name = try self.runtime.internAtom(filename);
        defer self.runtime.atoms.free(module_name);
        if (self.runtime.modules.find(module_name) == null) return error.ModuleNotFound;
        self.runtime.modules.linkModule(self.runtime, module_name) catch |err| {
            if (!@import("builtin").is_test) std.debug.print("LINK ERROR in evalPreloadedFileModuleStep for module {s}: {s}\n", .{ filename, @errorName(err) });
            return moduleResolutionError(err);
        };

        const module_var_refs = try exec.module.buildModuleVarRefs(self.context, module_name, &compiled.function);
        defer exec.module.freeModuleVarRefs(self.runtime, module_var_refs);
        var owned_continuation = if (input_continuation) |value| blk: {
            input_continuation = null;
            break :blk value;
        } else blk: {
            const object = try core.Object.create(self.runtime, core.class.ids.generator, null);
            break :blk object.value();
        };
        errdefer owned_continuation.free(self.runtime);
        const continuation = try exec.property_ops.expectObject(owned_continuation);
        var stack = exec.stack.Stack.init(&self.runtime.memory, self.context.stack_limit);
        defer stack.deinit(self.runtime);
        const result = exec.zjs_vm.runModuleWithOutputAndVarRefsState(self.context, &stack, &compiled.function, output, module_var_refs, continuation, resume_value) catch |err| return moduleResolutionError(err);
        if (continuation.generatorJustYielded() and !continuation.generatorDone()) {
            return .{ .suspended = .{
                .continuation = owned_continuation,
                .awaited = result,
            } };
        }
        owned_continuation.free(self.runtime);
        return .{ .completed = result };
    }

    fn handleModuleEvalStep(
        self: *HarnessEngine,
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
                    errdefer value.free(self.runtime);
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
                    try continuation.registerSymbolRoots(self.runtime);
                    errdefer continuation.unregisterSymbolRoots(self.runtime);
                    try continuations.append(allocator, continuation);
                } else {
                    value.free(self.runtime);
                }
            },
            .suspended => |suspended| {
                errdefer suspended.continuation.free(self.runtime);
                errdefer suspended.awaited.free(self.runtime);
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
                try continuation.registerSymbolRoots(self.runtime);
                errdefer continuation.unregisterSymbolRoots(self.runtime);
                try continuations.append(allocator, continuation);
            },
        }
    }

    fn drainModuleContinuations(
        self: *HarnessEngine,
        output: ?*std.Io.Writer,
        allocator: std.mem.Allocator,
        continuations: *std.ArrayList(ModuleContinuation),
    ) !core.JSValue {
        var kept_result: core.JSValue = core.JSValue.undefinedValue();
        var has_kept_result = false;
        while (continuations.items.len != 0) {
            if (try self.drainOneModuleContinuation(output, allocator, continuations)) |value| {
                if (has_kept_result) kept_result.free(self.runtime);
                kept_result = value;
                has_kept_result = true;
            }
        }
        if (has_kept_result) return kept_result;
        return core.JSValue.undefinedValue();
    }

    fn drainModuleContinuationsForDependencies(
        self: *HarnessEngine,
        output: ?*std.Io.Writer,
        allocator: std.mem.Allocator,
        continuations: *std.ArrayList(ModuleContinuation),
        filename: []const u8,
    ) !void {
        while (try self.hasActiveAsyncDependency(continuations, filename)) {
            if (try self.drainOneModuleContinuation(output, allocator, continuations)) |value| value.free(self.runtime);
        }
    }

    fn drainOneModuleContinuation(
        self: *HarnessEngine,
        output: ?*std.Io.Writer,
        allocator: std.mem.Allocator,
        continuations: *std.ArrayList(ModuleContinuation),
    ) !?core.JSValue {
        var current = continuations.orderedRemove(0);
        var current_roots_registered = true;
        errdefer if (current_roots_registered) current.unregisterSymbolRoots(self.runtime);
        defer allocator.free(current.source);
        defer allocator.free(current.path);
        if (current.completed) {
            current.unregisterSymbolRoots(self.runtime);
            current_roots_registered = false;
            if (current.keep_result) return current.awaited;
            current.awaited.free(self.runtime);
            return null;
        }
        const awaited_value = current.awaited;
        var awaited_owned = true;
        errdefer if (awaited_owned) awaited_value.free(self.runtime);
        const continuation = current.continuation;
        var continuation_owned = true;
        errdefer if (continuation_owned) continuation.free(self.runtime);
        const module_source = current.source;
        const path = current.path;
        const keep_result = current.keep_result;
        const global_object = try exec.zjs_vm.contextGlobal(self.context);
        try exec.zjs_vm.drainPendingPromiseJobs(self.context, output, global_object);
        continuation_owned = false;
        const step = try self.evalPreloadedFileModuleStep(module_source, output, path, continuation, awaited_value);
        awaited_value.free(self.runtime);
        awaited_owned = false;
        current.unregisterSymbolRoots(self.runtime);
        current_roots_registered = false;
        var step_owned = true;
        errdefer if (step_owned) freeModuleEvalStep(self.runtime, step);
        try self.runJobs();
        if (self.context.hasUnhandledRejection() or self.context.hasException()) return error.UnhandledPromiseRejection;
        step_owned = false;
        try self.handleModuleEvalStep(allocator, continuations, step, module_source, path, keep_result);
        return null;
    }

    fn hasActiveAsyncDependency(
        self: *HarnessEngine,
        continuations: *const std.ArrayList(ModuleContinuation),
        filename: []const u8,
    ) !bool {
        const module_name = try self.runtime.internAtom(filename);
        defer self.runtime.atoms.free(module_name);
        const record = self.runtime.modules.find(module_name) orelse return false;
        var visited = std.ArrayList(core.Atom).empty;
        defer visited.deinit(self.runtime.memory.allocator);
        return self.recordHasActiveAsyncDependency(continuations, record, &visited);
    }

    fn recordHasActiveAsyncDependency(
        self: *HarnessEngine,
        continuations: *const std.ArrayList(ModuleContinuation),
        record: *const core.module.ModuleRecord,
        visited: *std.ArrayList(core.Atom),
    ) !bool {
        for (visited.items) |seen| {
            if (seen == record.module_name) return false;
        }
        try visited.append(self.runtime.memory.allocator, record.module_name);
        for (record.requested_modules) |request| {
            const request_name = self.runtime.atoms.name(request) orelse continue;
            for (continuations.items) |continuation| {
                if (!continuation.completed and std.mem.eql(u8, continuation.path, request_name)) return true;
            }
            const requested_record = self.runtime.modules.find(request) orelse continue;
            if (try self.recordHasActiveAsyncDependency(continuations, requested_record, visited)) return true;
        }
        return false;
    }

    pub fn runJobs(self: *HarnessEngine) !void {
        self.runtime.job_queue.runAll();
        const global_object = try exec.zjs_vm.contextGlobal(self.context);
        exec.zjs_vm.drainPendingPromiseJobs(self.context, self.output, global_object) catch |err| {
            if (self.context.hasException() or self.context.hasUnhandledRejection()) return;
            return err;
        };
    }

    pub fn exposeStdOsGlobals(self: *HarnessEngine) !void {
        const global_object = try exec.zjs_vm.contextGlobal(self.context);
        try self.exposeNativeModuleGlobal(global_object, "std", .native_std);
        try self.exposeNativeModuleGlobal(global_object, "os", .native_os);
    }

    pub fn defineScriptArgs(self: *HarnessEngine, args: []const []const u8) !void {
        try self.defineStringArrayGlobal("scriptArgs", args);
    }

    pub fn createExternalHostFunctionValue(
        self: *HarnessEngine,
        name: []const u8,
        length: i32,
        ptr: *anyopaque,
        call: ExternalHostCallFn,
        finalizer: ?ExternalHostFinalizer,
    ) !core.JSValue {
        const id = try self.runtime.registerExternalHostFunction(.{
            .ptr = ptr,
            .call = call,
            .finalizer = finalizer,
        });
        const function_value = try builtins.function.nativeFunction(self.runtime, name, length);
        errdefer function_value.free(self.runtime);

        const function_object = try exec.property_ops.expectObject(function_value);
        function_object.hostFunctionKindSlot().* = core.host_function.ids.external_host;
        function_object.externalHostFunctionIdSlot().* = id;
        const global_object = try exec.zjs_vm.contextGlobal(self.context);
        try function_object.setFunctionRealmGlobalPtr(self.runtime, global_object);
        return function_value;
    }

    pub fn defineGlobalExternalHostFunction(
        self: *HarnessEngine,
        name: []const u8,
        length: i32,
        ptr: *anyopaque,
        call: ExternalHostCallFn,
        finalizer: ?ExternalHostFinalizer,
    ) !void {
        const global_object = try exec.zjs_vm.contextGlobal(self.context);
        const function_value = try self.createExternalHostFunctionValue(name, length, ptr, call, finalizer);
        defer function_value.free(self.runtime);

        const property_name = try self.runtime.internAtom(name);
        defer self.runtime.atoms.free(property_name);
        try global_object.defineOwnProperty(self.runtime, property_name, core.Descriptor.data(function_value, true, false, true));
    }

    pub fn defineArgvGlobals(self: *HarnessEngine, argv0: []const u8, exec_argv: []const []const u8) !void {
        const global_object = try exec.zjs_vm.contextGlobal(self.context);
        const argv0_value = try exec.value_ops.createStringValue(self.runtime, argv0);
        defer argv0_value.free(self.runtime);
        const argv0_key = try self.runtime.internAtom("argv0");
        defer self.runtime.atoms.free(argv0_key);
        try global_object.defineOwnProperty(self.runtime, argv0_key, core.Descriptor.data(argv0_value, true, true, true));
        try self.defineStringArrayGlobal("execArgv", exec_argv);
    }

    fn defineStringArrayGlobal(self: *HarnessEngine, name: []const u8, items: []const []const u8) !void {
        const global_object = try exec.zjs_vm.contextGlobal(self.context);
        const values = try self.runtime.memory.alloc(core.JSValue, items.len);
        defer self.runtime.memory.free(core.JSValue, values);
        var initialized: usize = 0;
        defer {
            for (values[0..initialized]) |value| value.free(self.runtime);
        }
        for (items, 0..) |item, index| {
            values[index] = try exec.value_ops.createStringValue(self.runtime, item);
            initialized += 1;
        }

        const array_prototype = try self.arrayPrototypeFromGlobal(global_object);
        const array = try core.Object.createArray(self.runtime, array_prototype);
        var array_raw_owned = true;
        errdefer if (array_raw_owned) core.Object.destroyFromHeader(self.runtime, &array.header);
        for (values, 0..) |value, index| {
            try array.defineOwnProperty(self.runtime, core.atom.atomFromUInt32(@intCast(index)), core.Descriptor.data(value, true, true, true));
        }
        array.length = @intCast(items.len);
        const property_name = try self.runtime.internAtom(name);
        defer self.runtime.atoms.free(property_name);
        const array_value = array.value();
        array_raw_owned = false;
        defer array_value.free(self.runtime);
        try global_object.defineOwnProperty(self.runtime, property_name, core.Descriptor.data(array_value, true, true, true));
    }

    pub fn defineCliArgvGlobalsLazy(self: *HarnessEngine, argv0: []const u8, exec_argv: []const []const u8) !void {
        self.runtime.cli_argv0 = argv0;
        self.runtime.cli_exec_argv = exec_argv;
        const global_object = try exec.zjs_vm.contextGlobal(self.context);
        const flags = core.property.Flags.data(true, true, true);
        try global_object.defineCliGlobalAutoInitProperty(self.runtime, core.atom.predefinedId("argv0", .string).?, "argv0", flags, global_object);
        try global_object.defineCliGlobalAutoInitProperty(self.runtime, core.atom.predefinedId("execArgv", .string).?, "execArgv", flags, global_object);
    }

    pub fn defineCliScriptArgsLazy(self: *HarnessEngine, args: []const []const u8) !void {
        self.runtime.cli_script_args = args;
        const global_object = try exec.zjs_vm.contextGlobal(self.context);
        try global_object.defineCliGlobalAutoInitProperty(
            self.runtime,
            core.atom.predefinedId("scriptArgs", .string).?,
            "scriptArgs",
            core.property.Flags.data(true, true, true),
            global_object,
        );
    }

    fn arrayPrototypeFromGlobal(self: *HarnessEngine, global_object: *core.Object) !*core.Object {
        const array_ctor_value = global_object.getProperty(core.atom.ids.Array);
        defer array_ctor_value.free(self.runtime);
        const array_ctor = try exec.property_ops.expectObject(array_ctor_value);
        const prototype_value = array_ctor.getProperty(core.atom.ids.prototype);
        defer prototype_value.free(self.runtime);
        return try exec.property_ops.expectObject(prototype_value);
    }

    fn exposeNativeModuleGlobal(
        self: *HarnessEngine,
        global_object: *core.Object,
        name: []const u8,
        kind: core.module.SyntheticKind,
    ) !void {
        _ = try exec.module.preloadNativeModule(self.runtime, kind);
        const module_name = try self.runtime.internAtom(name);
        defer self.runtime.atoms.free(module_name);
        self.runtime.modules.linkModule(self.runtime, module_name) catch |err| return moduleResolutionError(err);
        _ = try exec.module.initializeSyntheticFileModule(self.context, global_object, module_name, "");
        const namespace = try exec.module.moduleNamespaceValue(self.context, module_name);
        defer namespace.free(self.runtime);
        const property_name = try self.runtime.internAtom(name);
        defer self.runtime.atoms.free(property_name);
        try global_object.defineOwnProperty(self.runtime, property_name, core.Descriptor.data(namespace, true, false, true));
    }

    pub fn takeException(self: *HarnessEngine) core.JSValue {
        if (self.context.hasUnhandledRejection()) {
            const rejection = self.context.takeUnhandledRejection();
            if (self.context.hasException()) self.context.clearException();
            return rejection;
        }
        return self.context.takeException();
    }

    pub fn takeExceptionInfo(self: *HarnessEngine) !ExceptionInfo {
        return .{
            .value = try JSValueHandle.init(self.runtime, self.takeException()),
        };
    }
};

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

    fn registerSymbolRoots(self: *ModuleContinuation, runtime: *core.JSRuntime) !void {
        std.debug.assert(self.symbol_root_mask == 0);
        errdefer self.unregisterSymbolRoots(runtime);
        if (try runtime.registerExternalValueSymbolRoot(self.continuation)) self.symbol_root_mask |= 0b01;
        if (try runtime.registerExternalValueSymbolRoot(self.awaited)) self.symbol_root_mask |= 0b10;
    }

    fn unregisterSymbolRoots(self: *ModuleContinuation, runtime: *core.JSRuntime) void {
        if ((self.symbol_root_mask & 0b01) != 0) runtime.unregisterExternalValueSymbolRoot(self.continuation);
        if ((self.symbol_root_mask & 0b10) != 0) runtime.unregisterExternalValueSymbolRoot(self.awaited);
        self.symbol_root_mask = 0;
    }
};

fn freeModuleContinuations(
    runtime: *core.JSRuntime,
    allocator: std.mem.Allocator,
    continuations: *std.ArrayList(ModuleContinuation),
) void {
    for (continuations.items) |*item| {
        allocator.free(item.source);
        allocator.free(item.path);
        item.unregisterSymbolRoots(runtime);
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

const DynamicImportState = struct {
    engine: *HarnessEngine,
    io: std.Io,
    allocator: std.mem.Allocator,
    max_source_size: usize,

    fn load(
        userdata: ?*anyopaque,
        ctx: *core.JSContext,
        output: ?*std.Io.Writer,
        global: *core.Object,
        referrer_path: []const u8,
        specifier: []const u8,
    ) core.context.DynamicImportError!core.JSValue {
        _ = ctx;
        _ = global;
        const state: *DynamicImportState = @ptrCast(@alignCast(userdata orelse return error.ModuleNotFound));
        return state.engine.evalDynamicImportModule(output, referrer_path, specifier, state.io, state.allocator, state.max_source_size);
    }
};

fn moduleResolutionError(err: anytype) (@TypeOf(err) || error{SyntaxError}) {
    return switch (err) {
        error.MissingExport, error.AmbiguousExport => error.SyntaxError,
        else => err,
    };
}

fn forceRuntimeStrict(function: *bytecode.Bytecode) void {
    function.flags.runtime_strict = true;
    for (function.constants.values) |value| forceFunctionBytecodeRuntimeStrict(value);
}

fn forceFunctionBytecodeRuntimeStrict(value: core.JSValue) void {
    if (!value.isFunctionBytecode()) return;
    const header = value.objectHeader() orelse return;
    const function_bytecode: *bytecode.FunctionBytecode = @fieldParentPtr("header", header);
    function_bytecode.runtime_strict_mode = true;
    for (function_bytecode.cpool) |child| forceFunctionBytecodeRuntimeStrict(child);
}

fn isWhitespaceSeparatedNumericScript(source_text: []const u8) bool {
    var saw_digit = false;
    var saw_space_after_digit = false;
    for (source_text) |ch| {
        if (std.ascii.isDigit(ch)) {
            if (saw_space_after_digit) return true;
            saw_digit = true;
        } else if (std.ascii.isWhitespace(ch)) {
            if (saw_digit) saw_space_after_digit = true;
        } else {
            return false;
        }
    }
    return false;
}

fn elapsedNanosSince(start: u64) u64 {
    const end = monotonicNanos();
    return if (end > start) end - start else 0;
}

fn monotonicNanos() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

test {
    _ = core;
    _ = frontend;
    _ = bytecode;
    _ = exec;
    _ = builtins;
    _ = libs;
}


const RealmCachedGeneratorPrototypeKind = enum {
    generator,
    async_generator,
    async_function_function,
    generator_function,
    async_generator_function,
};

fn expectRealmCachedGeneratorPrototypeOOMCleanup(kind: RealmCachedGeneratorPrototypeKind) !void {
    var saw_oom = false;
    var saw_success = false;

    var fail_offset: usize = 0;
    while (fail_offset < 280) : (fail_offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const rt = try core.JSRuntime.create(failing.allocator());
        const global = try core.Object.create(rt, core.class.ids.object, null);

        failing.fail_index = failing.alloc_index + fail_offset;
        const result = realmCachedPrototypeFromGlobal(rt, global, kind);
        failing.fail_index = std.math.maxInt(usize);

        if (result) |_| {
            saw_success = true;
        } else |err| switch (err) {
            error.OutOfMemory => saw_oom = true,
            else => |unexpected| {
                cleanupRealmCachedGeneratorPrototypeOOMIteration(rt, global);
                return unexpected;
            },
        }

        cleanupRealmCachedGeneratorPrototypeOOMIteration(rt, global);
    }

    try std.testing.expect(saw_oom);
    try std.testing.expect(saw_success);
}

fn realmCachedPrototypeFromGlobal(
    rt: *core.JSRuntime,
    global: *core.Object,
    kind: RealmCachedGeneratorPrototypeKind,
) !?*core.Object {
    return switch (kind) {
        .generator => try shared_vm.generatorPrototypeFromGlobal(rt, global),
        .async_generator => try shared_vm.asyncGeneratorPrototypeFromGlobal(rt, global),
        .async_function_function => try shared_vm.asyncFunctionPrototypeFromGlobal(rt, global),
        .generator_function => try shared_vm.generatorFunctionPrototypeFromGlobal(rt, global),
        .async_generator_function => try shared_vm.asyncGeneratorFunctionPrototypeFromGlobal(rt, global),
    };
}

fn cleanupRealmCachedGeneratorPrototypeOOMIteration(rt: *core.JSRuntime, global: *core.Object) void {
    global.value().free(rt);
    rt.destroy();
}

const std = @import("std");
const shared_vm = @import("exec/vm/shared.zig");
