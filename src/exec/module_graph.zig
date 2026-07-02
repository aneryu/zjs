const std = @import("std");
const core = @import("../core/root.zig");
const parser = @import("../parser.zig");
const exec = @import("root.zig");

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

pub const ModuleEvalStep = union(enum) {
    completed: core.JSValue,
    suspended: struct {
        continuation: core.JSValue,
        awaited: core.JSValue,
    },
};

pub const ModuleContinuation = struct {
    source: []const u8,
    path: []const u8,
    continuation: core.JSValue,
    awaited: core.JSValue,
    keep_result: bool,
    track_module_status: bool,
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

pub const DynamicImportState = struct {
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    output: ?*std.Io.Writer,
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
        return evalDynamicImportModule(
            state.runtime,
            state.context,
            output,
            referrer_path,
            specifier,
            state.io,
            state.allocator,
            state.max_source_size,
        ) catch |err| {
            // Any pending JS exception must reach the import() promise as-is
            // (js_dynamic_import_job quickjs.c:31063: exception → reject).
            if (state.context.hasException()) return error.JSException;
            return err;
        };
    }
};

pub const DynamicImportHostState = struct {
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    output: ?*std.Io.Writer,
    host_hooks: HostHooks,
    allocator: std.mem.Allocator,

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
        const state: *DynamicImportHostState = @ptrCast(@alignCast(userdata orelse return error.ModuleNotFound));
        return evalDynamicImportModuleWithHostHooks(
            state.runtime,
            state.context,
            output orelse state.output,
            state.host_hooks,
            referrer_path,
            specifier,
            state.allocator,
        ) catch |err| {
            // Any pending JS exception must reach the import() promise as-is
            // (js_dynamic_import_job quickjs.c:31063: exception → reject).
            if (state.context.hasException()) return error.JSException;
            return dynamicImportHostError(err);
        };
    }
};

/// Identity marker for the shared dynamic-import job registration in the
/// runtime's external-host-function table (one registration per runtime,
/// found again by (ptr, call) identity).
var dynamic_import_job_marker: u8 = 0;

fn dynamicImportJobExternalId(rt: *core.JSRuntime) !u32 {
    const marker: *anyopaque = @ptrCast(&dynamic_import_job_marker);
    for (rt.external_host_functions, 0..) |record, index| {
        if (record.call == dynamicImportJobCall and record.ptr == marker) return @intCast(index + 1);
    }
    return rt.registerExternalHostFunction(.{ .ptr = marker, .call = dynamicImportJobCall });
}

/// Mirror of qjs js_dynamic_import (quickjs.c:31073): build a promise
/// capability, bind [resolve, reject, basename, specifier] onto a job
/// callable, and enqueue it on the promise-job queue (JS_EnqueueJob
/// quickjs.c:31155 — "cannot run JS_LoadModuleInternal synchronously because
/// it would cause an unexpected recursion in js_evaluate_module()"). The
/// returned pending promise is the value of the import() expression; the
/// module loads and evaluates only when the job runs.
pub fn enqueueDynamicImportJob(
    ctx: *core.JSContext,
    global: *core.Object,
    prototype: ?*core.Object,
    referrer_path: []const u8,
    specifier: core.JSValue,
) !core.JSValue {
    const rt = ctx.runtime;
    const resolvers_value = try core.promise.withResolvers(rt, prototype);
    defer resolvers_value.free(rt);
    const resolvers = try exec.property_ops.expectObject(resolvers_value);

    const promise_atom = try rt.internAtom("promise");
    defer rt.atoms.free(promise_atom);
    const resolve_atom = try rt.internAtom("resolve");
    defer rt.atoms.free(resolve_atom);
    const reject_atom = try rt.internAtom("reject");
    defer rt.atoms.free(reject_atom);
    const basename_atom = try rt.internAtom("basename");
    defer rt.atoms.free(basename_atom);
    const specifier_atom = try rt.internAtom("specifier");
    defer rt.atoms.free(specifier_atom);

    const promise_value = resolvers.getProperty(promise_atom);
    errdefer promise_value.free(rt);
    const resolve_value = resolvers.getProperty(resolve_atom);
    defer resolve_value.free(rt);
    const reject_value = resolvers.getProperty(reject_atom);
    defer reject_value.free(rt);

    const basename_value = try exec.value_ops.createStringValue(rt, referrer_path);
    defer basename_value.free(rt);

    const job_value = try core.function.nativeFunction(rt, "", 0);
    defer job_value.free(rt);
    const job_object = try exec.property_ops.expectObject(job_value);
    job_object.hostFunctionKindSlot().* = core.host_function.ids.external_host;
    job_object.externalHostFunctionIdSlot().* = try dynamicImportJobExternalId(rt);
    try job_object.setFunctionRealmGlobalPtr(rt, global);
    // Bound job data lives as ordinary (GC-traced) properties on the job
    // callable, mirroring JS_NewCFunctionData's func_data slots.
    try job_object.defineOwnProperty(rt, resolve_atom, core.Descriptor.data(resolve_value, false, false, false));
    try job_object.defineOwnProperty(rt, reject_atom, core.Descriptor.data(reject_value, false, false, false));
    try job_object.defineOwnProperty(rt, basename_atom, core.Descriptor.data(basename_value, false, false, false));
    try job_object.defineOwnProperty(rt, specifier_atom, core.Descriptor.data(specifier, false, false, false));

    try exec.promise_ops.enqueuePendingPromiseJob(ctx, job_value);
    return promise_value;
}

/// Mirror of qjs js_dynamic_import_job (quickjs.c:31037): run the module
/// loader and settle the import() capability — any failure (including a
/// pending JS exception) rejects the promise instead of aborting evaluation.
fn dynamicImportJobCall(_: *anyopaque, call: core.host_function.ExternalCall) anyerror!core.JSValue {
    const ctx: *core.JSContext = @ptrCast(@alignCast(call.ctx));
    const rt = ctx.runtime;
    const job_object = call.func_obj;
    const global = call.global orelse job_object.functionRealmGlobalPtr() orelse return error.TypeError;

    const resolve_atom = try rt.internAtom("resolve");
    defer rt.atoms.free(resolve_atom);
    const reject_atom = try rt.internAtom("reject");
    defer rt.atoms.free(reject_atom);
    const basename_atom = try rt.internAtom("basename");
    defer rt.atoms.free(basename_atom);
    const specifier_atom = try rt.internAtom("specifier");
    defer rt.atoms.free(specifier_atom);

    const resolve_value = job_object.getProperty(resolve_atom);
    defer resolve_value.free(rt);
    const reject_value = job_object.getProperty(reject_atom);
    defer reject_value.free(rt);
    const basename_value = job_object.getProperty(basename_atom);
    defer basename_value.free(rt);
    const specifier_value = job_object.getProperty(specifier_atom);
    defer specifier_value.free(rt);

    var basename_bytes = std.ArrayList(u8).empty;
    defer basename_bytes.deinit(rt.memory.allocator);
    try exec.value_ops.appendRawString(rt, &basename_bytes, basename_value);
    var specifier_bytes = std.ArrayList(u8).empty;
    defer specifier_bytes.deinit(rt.memory.allocator);
    try exec.value_ops.appendRawString(rt, &specifier_bytes, specifier_value);

    const load_result: core.context.DynamicImportError!core.JSValue = blk: {
        const callback = ctx.dynamic_import_callback orelse break :blk error.OperationUnsupported;
        break :blk callback(ctx.dynamic_import_userdata, ctx, call.output, global, basename_bytes.items, specifier_bytes.items);
    };

    if (load_result) |namespace| {
        defer namespace.free(rt);
        const settle = try exec.call_runtime.callValueOrBytecode(ctx, call.output, global, core.JSValue.undefinedValue(), resolve_value, &.{namespace}, null, null);
        settle.free(rt);
    } else |err| {
        if (err == error.OutOfMemory or err == error.ProcessExit or err == error.StackOverflow) return err;
        const reason = try dynamicImportRejectionValue(ctx, global, err, specifier_bytes.items);
        defer reason.free(rt);
        const settle = try exec.call_runtime.callValueOrBytecode(ctx, call.output, global, core.JSValue.undefinedValue(), reject_value, &.{reason}, null, null);
        settle.free(rt);
    }
    return core.JSValue.undefinedValue();
}

/// Rejection reason for a failed dynamic import: the pending JS exception
/// verbatim when one exists (js_dynamic_import_job quickjs.c:31063
/// JS_GetException → reject), otherwise the loader's ReferenceError shape
/// (js_module_loader quickjs-libc.c:699) or a generic mapped error.
fn dynamicImportRejectionValue(
    ctx: *core.JSContext,
    global: *core.Object,
    err: anyerror,
    specifier: []const u8,
) !core.JSValue {
    if (ctx.hasException()) return ctx.takeException();
    switch (err) {
        error.OperationUnsupported => return exec.exception_ops.createNamedError(ctx, global, "TypeError", "dynamic import is not supported"),
        error.ModuleNotFound, error.FileNotFound => {
            var msg_buf = std.ArrayList(u8).empty;
            defer msg_buf.deinit(ctx.runtime.memory.allocator);
            try msg_buf.print(ctx.runtime.memory.allocator, "could not load module filename '{s}'", .{specifier});
            return exec.exception_ops.createNamedError(ctx, global, "ReferenceError", msg_buf.items);
        },
        else => {
            const info = exec.exception_ops.promiseErrorInfo(err);
            return exec.exception_ops.createNamedError(ctx, global, info.name, info.message);
        },
    }
}

/// Install the file-loader dynamic import callback on the state's context.
/// The state must outlive every job drain that may run an import job (the
/// CLI keeps one alive for the whole process; the module-graph runners
/// install a scoped one and drain before restoring).
pub fn installDynamicImport(state: *DynamicImportState) void {
    state.context.dynamic_import_callback = DynamicImportState.load;
    state.context.dynamic_import_userdata = state;
}

fn runJobs(runtime: *core.JSRuntime, context: *core.JSContext, output: ?*std.Io.Writer) !void {
    runtime.job_queue.runAll();
    const global_object = try @import("zjs_vm.zig").contextGlobal(context);
    @import("zjs_vm.zig").drainPendingPromiseJobs(context, output, global_object) catch |err| {
        if (context.hasException() or context.hasUnhandledRejection()) return;
        return err;
    };
}

pub fn evalFileModuleGraphWithOutput(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    source_text: []const u8,
    output: *std.Io.Writer,
    filename: []const u8,
    io: std.Io,
    allocator: std.mem.Allocator,
    max_source_size: usize,
) !core.JSValue {
    // Arm the native recursion guard at this outermost ES-module entry (analogue
    // of eval()'s JS_UpdateStackTop refresh) so module parse/exec on this thread
    // measures against a precise base. The construction-time baseline already
    // covers it; this tightens it for the running thread (test262 workers run on
    // a different C stack than where the runtime was constructed).
    if (context.call_depth == 0) runtime.updateNativeStackTop();
    const normalized_filename = try std.fs.path.resolve(allocator, &.{filename});
    defer allocator.free(normalized_filename);

    var module_postorder = std.ArrayList([]const u8).empty;
    defer {
        for (module_postorder.items) |path| allocator.free(path);
        module_postorder.deinit(allocator);
    }
    try exec.module.preloadFileModuleGraphWithOrder(io, allocator, runtime, context, source_text, normalized_filename, max_source_size, &module_postorder);
    const root_module_name = try runtime.internAtom(normalized_filename);
    defer runtime.atoms.free(root_module_name);
    if (runtime.modules.find(root_module_name)) |record| record.import_meta_main = true;
    runtime.modules.linkModule(runtime, root_module_name) catch |err| {
        try throwModuleLinkError(runtime, context, normalized_filename, err);
        return moduleResolutionError(err);
    };
    try initializeSyntheticFileModules(runtime, context, io, allocator, max_source_size);
    try initializePreloadedModuleFunctionDeclarations(runtime, context, source_text, normalized_filename, io, allocator, max_source_size, module_postorder.items);
    var dynamic_import_state = DynamicImportState{
        .runtime = runtime,
        .context = context,
        .output = output,
        .io = io,
        .allocator = allocator,
        .max_source_size = max_source_size,
    };
    const prev_dynamic_import_callback = context.dynamic_import_callback;
    const prev_dynamic_import_userdata = context.dynamic_import_userdata;
    context.dynamic_import_callback = DynamicImportState.load;
    context.dynamic_import_userdata = &dynamic_import_state;
    defer {
        context.dynamic_import_callback = prev_dynamic_import_callback;
        context.dynamic_import_userdata = prev_dynamic_import_userdata;
    }
    var continuations = std.ArrayList(ModuleContinuation).empty;
    defer freeModuleContinuations(runtime, allocator, &continuations);
    for (module_postorder.items) |path| {
        if (std.mem.eql(u8, path, normalized_filename)) continue;
        if (!preloadedModuleNeedsEvaluation(runtime, path)) continue;
        try drainModuleContinuationsForDependencies(runtime, context, output, allocator, &continuations, path);
        const dep_source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_source_size));
        defer allocator.free(dep_source);
        const dep_step = try evalPreloadedFileModuleStep(runtime, context, dep_source, output, path, null, null, true);
        try handleModuleEvalStep(runtime, allocator, &continuations, dep_step, dep_source, path, false, true);
        try runJobs(runtime, context, output);
        if (context.hasUnhandledRejection() or context.hasException()) return error.UnhandledPromiseRejection;
    }
    try drainModuleContinuationsForDependencies(runtime, context, output, allocator, &continuations, normalized_filename);
    var result = core.JSValue.undefinedValue();
    if (preloadedModuleNeedsEvaluation(runtime, normalized_filename)) {
        const root_step = try evalPreloadedFileModuleStep(runtime, context, source_text, output, normalized_filename, null, null, true);
        try handleModuleEvalStep(runtime, allocator, &continuations, root_step, source_text, normalized_filename, true, true);
        result = try drainModuleContinuations(runtime, context, output, allocator, &continuations);
    }
    // Drain jobs enqueued by a synchronously-completing root (dynamic-import
    // jobs in particular) while this runner's dynamic-import state is still
    // installed and alive.
    errdefer result.free(runtime);
    try runJobs(runtime, context, output);
    return result;
}

/// Status gate shared by the postorder evaluation loops: modules already
/// evaluated (e.g. by a dynamic import job that ran between steps) or
/// currently evaluating are never re-run (mirrors js_inner_module_evaluation
/// quickjs.c:31441).
fn preloadedModuleNeedsEvaluation(runtime: *core.JSRuntime, path: []const u8) bool {
    const module_name = runtime.internAtom(path) catch return true;
    defer runtime.atoms.free(module_name);
    const record = runtime.modules.find(module_name) orelse return true;
    return moduleNeedsEvaluation(record);
}

pub fn evalFileModuleGraphWithHostHooks(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    source_text: []const u8,
    output: *std.Io.Writer,
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
    runtime.modules.linkModule(runtime, root_module_name) catch |err| {
        try throwModuleLinkError(runtime, context, filename, err);
        return moduleResolutionError(err);
    };
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

        var compiled = try parser.compile(runtime, module_source, .{ .mode = .module, .filename = path });
        if (loaded_owned) allocator.free(raw_module_source);
        defer compiled.deinit();
        if (compiled.syntax_error) |err| {
            const exception_ops = exec.exception_ops;
            var msg_buf = std.ArrayList(u8).empty;
            defer msg_buf.deinit(runtime.memory.allocator);
            try msg_buf.print(runtime.memory.allocator, "SYNTAX ERROR in {s}:{d}:{d} - {s}", .{ path, err.position.line, err.position.column, err.message });
            const error_val = try exception_ops.createNamedError(context, global_object, "SyntaxError", msg_buf.items);
            _ = context.throwValue(error_val);
            return error.SyntaxError;
        }
        const module_name = try runtime.internAtom(path);
        defer runtime.atoms.free(module_name);
        try exec.module.initializeModuleFunctionDeclarations(context, global_object, module_name, &compiled.function);
    }

    var dynamic_import_state = DynamicImportHostState{
        .runtime = runtime,
        .context = context,
        .output = output,
        .host_hooks = host_hooks,
        .allocator = allocator,
    };
    const prev_dynamic_import_callback = context.dynamic_import_callback;
    const prev_dynamic_import_userdata = context.dynamic_import_userdata;
    context.dynamic_import_callback = DynamicImportHostState.load;
    context.dynamic_import_userdata = &dynamic_import_state;
    defer {
        context.dynamic_import_callback = prev_dynamic_import_callback;
        context.dynamic_import_userdata = prev_dynamic_import_userdata;
    }

    var continuations = std.ArrayList(ModuleContinuation).empty;
    defer freeModuleContinuations(runtime, allocator, &continuations);

    for (module_postorder.items) |path| {
        if (std.mem.eql(u8, path, filename)) continue;
        if (!preloadedModuleNeedsEvaluation(runtime, path)) continue;
        try drainModuleContinuationsForDependencies(runtime, context, output, allocator, &continuations, path);

        const resolved = try host_hooks.resolveModule(host_hooks.ptr, path, null, allocator);
        defer allocator.free(resolved.specifier);
        defer allocator.free(resolved.path);

        const loaded = try host_hooks.loadModule(host_hooks.ptr, resolved, allocator);
        defer if (loaded.owned) allocator.free(loaded.source);
        defer allocator.free(loaded.path);

        var module_source_allocated = false;
        const module_source = try wrapSourceByKind(allocator, loaded.kind, loaded.source, path, &module_source_allocated);
        defer if (module_source_allocated) allocator.free(module_source);

        const dep_step = try evalPreloadedFileModuleStep(runtime, context, module_source, output, path, null, null, true);
        try handleModuleEvalStep(runtime, allocator, &continuations, dep_step, module_source, path, false, true);
        try runJobs(runtime, context, output);
        if (context.hasUnhandledRejection() or context.hasException()) return error.UnhandledPromiseRejection;
    }

    try drainModuleContinuationsForDependencies(runtime, context, output, allocator, &continuations, filename);
    var result = core.JSValue.undefinedValue();
    if (preloadedModuleNeedsEvaluation(runtime, filename)) {
        const root_step = try evalPreloadedFileModuleStep(runtime, context, source_text, output, filename, null, null, true);
        try handleModuleEvalStep(runtime, allocator, &continuations, root_step, source_text, filename, true, true);
        result = try drainModuleContinuations(runtime, context, output, allocator, &continuations);
    }
    // Drain jobs enqueued by a synchronously-completing root (dynamic-import
    // jobs in particular) while this runner's dynamic-import state is still
    // installed and alive.
    errdefer result.free(runtime);
    try runJobs(runtime, context, output);
    return result;
}

fn initializeSyntheticFileModules(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    io: std.Io,
    allocator: std.mem.Allocator,
    max_source_size: usize,
) !void {
    const global_object = try exec.zjs_vm.contextGlobal(context);
    for (runtime.modules.modules) |record| {
        if (record.synthetic_kind == .none) continue;
        const path = runtime.atoms.name(record.module_name) orelse return error.InvalidAtom;
        const source_path = exec.module.syntheticModuleFilePath(path);
        const module_source = try std.Io.Dir.cwd().readFileAlloc(io, source_path, allocator, .limited(max_source_size));
        defer allocator.free(module_source);
        _ = try exec.module.initializeSyntheticFileModule(context, global_object, record.module_name, module_source);
    }
}

fn initializePreloadedModuleFunctionDeclarations(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    root_source: []const u8,
    root_path: []const u8,
    io: std.Io,
    allocator: std.mem.Allocator,
    max_source_size: usize,
    postorder_paths: []const []const u8,
) !void {
    const global_object = try exec.zjs_vm.contextGlobal(context);
    for (postorder_paths) |path| {
        const is_root = std.mem.eql(u8, path, root_path);
        const source = if (is_root)
            root_source
        else blk: {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_source_size));
            break :blk bytes;
        };
        defer if (!is_root) allocator.free(source);
        var compiled = try parser.compile(runtime, source, .{ .mode = .module, .filename = path });
        defer compiled.deinit();
        if (compiled.syntax_error != null) return error.SyntaxError;
        const module_name = try runtime.internAtom(path);
        defer runtime.atoms.free(module_name);
        try exec.module.initializeModuleFunctionDeclarations(context, global_object, module_name, &compiled.function);
    }
}

fn evalPreloadedFileModuleStep(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    source_text: []const u8,
    output: ?*std.Io.Writer,
    filename: []const u8,
    continuation_value: ?core.JSValue,
    resume_value: ?core.JSValue,
    track_module_status: bool,
) !ModuleEvalStep {
    var input_continuation = continuation_value;
    errdefer if (input_continuation) |value| value.free(runtime);

    var compiled = try parser.compile(runtime, source_text, .{ .mode = .module, .filename = filename });
    defer compiled.deinit();
    if (compiled.syntax_error) |err| {
        const exception_ops = exec.exception_ops;
        const global_object = try exec.zjs_vm.contextGlobal(context);
        var msg_buf = std.ArrayList(u8).empty;
        defer msg_buf.deinit(runtime.memory.allocator);
        try msg_buf.print(runtime.memory.allocator, "SYNTAX ERROR in {s}:{d}:{d} - {s}", .{ filename, err.position.line, err.position.column, err.message });
        const error_val = try exception_ops.createNamedError(context, global_object, "SyntaxError", msg_buf.items);
        _ = context.throwValue(error_val);
        return error.SyntaxError;
    }

    const module_name = try runtime.internAtom(filename);
    defer runtime.atoms.free(module_name);
    if (runtime.modules.find(module_name) == null) return error.ModuleNotFound;
    runtime.modules.linkModule(runtime, module_name) catch |err| {
        try throwModuleLinkError(runtime, context, filename, err);
        return moduleResolutionError(err);
    };
    if (track_module_status) {
        if (runtime.modules.find(module_name)) |record| {
            record.status = .evaluating;
        }
    }
    errdefer {
        if (track_module_status) {
            if (runtime.modules.find(module_name)) |record| {
                if (record.status == .evaluating) {
                    // Cache the evaluation exception on the record so later
                    // imports rethrow it instead of re-running the body
                    // (mirrors qjs setting m->eval_exception,
                    // quickjs.c:31279/31563).
                    record.status = .errored;
                    if (context.hasException()) {
                        record.setEvalException(runtime, context.exception_slot.value.dup());
                    }
                }
            }
        }
    }

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
    const result = exec.zjs_vm.runModuleWithOutputAndVarRefsState(context, &stack, &compiled.function, output, module_var_refs, continuation, resume_value) catch |err| return moduleResolutionError(err);
    if (continuation.generatorJustYielded() and !continuation.generatorDone()) {
        return .{ .suspended = .{
            .continuation = owned_continuation,
            .awaited = result,
        } };
    }
    owned_continuation.free(runtime);
    if (track_module_status) {
        if (runtime.modules.find(module_name)) |record| {
            record.status = .evaluated;
        }
    }
    return .{ .completed = result };
}

fn handleModuleEvalStep(
    runtime: *core.JSRuntime,
    allocator: std.mem.Allocator,
    continuations: *std.ArrayList(ModuleContinuation),
    step: ModuleEvalStep,
    source_text: []const u8,
    filename: []const u8,
    keep_result: bool,
    track_module_status: bool,
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
                    .track_module_status = track_module_status,
                    .completed = true,
                };
                try continuation.registerSymbolRoots(runtime);
                errdefer continuation.unregisterSymbolRoots(runtime);
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
                .track_module_status = track_module_status,
            };
            try continuation.registerSymbolRoots(runtime);
            errdefer continuation.unregisterSymbolRoots(runtime);
            try continuations.append(allocator, continuation);
        },
    }
}

fn drainModuleContinuations(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    output: ?*std.Io.Writer,
    allocator: std.mem.Allocator,
    continuations: *std.ArrayList(ModuleContinuation),
) !core.JSValue {
    var kept_result: core.JSValue = core.JSValue.undefinedValue();
    var has_kept_result = false;
    while (continuations.items.len != 0) {
        if (try drainOneModuleContinuation(runtime, context, output, allocator, continuations)) |value| {
            if (has_kept_result) kept_result.free(runtime);
            kept_result = value;
            has_kept_result = true;
        }
    }
    if (has_kept_result) return kept_result;
    return core.JSValue.undefinedValue();
}

fn drainModuleContinuationsForDependencies(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    output: ?*std.Io.Writer,
    allocator: std.mem.Allocator,
    continuations: *std.ArrayList(ModuleContinuation),
    filename: []const u8,
) !void {
    while (try hasActiveAsyncDependency(runtime, continuations, filename)) {
        if (try drainOneModuleContinuation(runtime, context, output, allocator, continuations)) |value| value.free(runtime);
    }
}

fn drainOneModuleContinuation(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    output: ?*std.Io.Writer,
    allocator: std.mem.Allocator,
    continuations: *std.ArrayList(ModuleContinuation),
) !?core.JSValue {
    var current = continuations.orderedRemove(0);
    var current_roots_registered = true;
    errdefer if (current_roots_registered) current.unregisterSymbolRoots(runtime);
    defer allocator.free(current.source);
    defer allocator.free(current.path);
    if (current.completed) {
        current.unregisterSymbolRoots(runtime);
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
    const track_module_status = current.track_module_status;
    const global_object = try exec.zjs_vm.contextGlobal(context);
    try exec.zjs_vm.drainPendingPromiseJobs(context, output, global_object);
    continuation_owned = false;
    const step = try evalPreloadedFileModuleStep(runtime, context, module_source, output, path, continuation, awaited_value, track_module_status);
    awaited_value.free(runtime);
    awaited_owned = false;
    current.unregisterSymbolRoots(runtime);
    current_roots_registered = false;
    var step_owned = true;
    errdefer if (step_owned) freeModuleEvalStep(runtime, step);
    try runJobs(runtime, context, output);
    if (context.hasUnhandledRejection() or context.hasException()) return error.UnhandledPromiseRejection;
    step_owned = false;
    try handleModuleEvalStep(runtime, allocator, continuations, step, module_source, path, keep_result, track_module_status);
    return null;
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

fn moduleResolutionError(err: anytype) (@TypeOf(err) || error{SyntaxError}) {
    return switch (err) {
        error.MissingExport, error.AmbiguousExport => error.SyntaxError,
        else => err,
    };
}

fn evalDynamicImportModule(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    output: ?*std.Io.Writer,
    referrer_path: []const u8,
    specifier: []const u8,
    io: std.Io,
    allocator: std.mem.Allocator,
    max_source_size: usize,
) !core.JSValue {
    if (referrer_path.len == 0) {
        try exec.module.throwCouldNotLoadModule(context, specifier);
        return error.JSException;
    }
    // An unresolvable specifier rejects the import() promise with the
    // loader's ReferenceError (mirrors js_module_loader quickjs-libc.c:699)
    // instead of aborting the evaluation with a host error.
    const target_path_base = exec.module.resolveModuleSpecifier(allocator, referrer_path, specifier) catch |err| switch (err) {
        error.ModuleNotFound => {
            try exec.module.throwCouldNotLoadModule(context, specifier);
            return error.JSException;
        },
        else => |e| return e,
    };
    defer allocator.free(target_path_base);

    // A `.json` target loads as a JSON module even without import
    // attributes, mirroring js_module_loader's extension check
    // (`has_suffix(module_name, ".json") || res > 0`, quickjs-libc.c:704).
    // The synthetic registry name is shared with attribute-tagged static
    // imports so both resolve to one module record.
    const is_json = std.mem.endsWith(u8, target_path_base, ".json");
    const target_path = if (is_json)
        try exec.module.syntheticModuleRegistryName(allocator, target_path_base, .json)
    else
        try allocator.dupe(u8, target_path_base);
    defer allocator.free(target_path);

    const module_name = try runtime.internAtom(target_path);
    defer runtime.atoms.free(module_name);

    var did_preload_graph = false;
    if (runtime.modules.find(module_name) == null) {
        if (!is_json) {
            const source = std.Io.Dir.cwd().readFileAlloc(io, target_path, allocator, .limited(max_source_size)) catch |err| switch (err) {
                error.FileNotFound => {
                    try exec.module.throwCouldNotLoadModule(context, target_path);
                    return error.JSException;
                },
                else => |e| return e,
            };
            defer allocator.free(source);
            var preload_postorder = std.ArrayList([]const u8).empty;
            defer {
                for (preload_postorder.items) |item| allocator.free(item);
                preload_postorder.deinit(allocator);
            }
            // skip-existing preload: records already in the registry keep
            // their live bindings and status (re-instantiating them would
            // reset already-evaluated modules).
            try exec.module.preloadMissingFileModuleGraphWithOrder(io, allocator, runtime, context, source, target_path, max_source_size, &preload_postorder);
            did_preload_graph = true;
        } else {
            _ = try exec.module.preloadSyntheticFileModule(runtime, target_path, .json);
        }
    }

    // Evaluate-once via the module status machine (mirrors
    // js_inner_module_evaluation quickjs.c:31441): an errored module
    // rethrows its cached exception (before relinking — linking artifacts of
    // an errored record must stay untouched); evaluating/evaluated modules
    // never re-run their body.
    if (runtime.modules.find(module_name)) |record| {
        if (record.status == .errored) return throwCachedModuleEvalException(runtime, context, record);
    } else return error.ModuleNotFound;

    runtime.modules.linkModule(runtime, module_name) catch |err| {
        try throwModuleLinkError(runtime, context, target_path_base, err);
        return error.JSException;
    };

    // Synthetic bindings are installed after linking: linkModule resets a
    // fresh record's link artifacts (clearLinkArtifacts), so initializing
    // before it would drop the binding cells (same order as the static
    // graph runner: link first, then initializeSyntheticFileModules).
    if (is_json) {
        const source_path = exec.module.syntheticModuleFilePath(target_path);
        const module_source = std.Io.Dir.cwd().readFileAlloc(io, source_path, allocator, .limited(max_source_size)) catch |err| switch (err) {
            error.FileNotFound => {
                try exec.module.throwCouldNotLoadModule(context, target_path_base);
                return error.JSException;
            },
            else => |e| return e,
        };
        defer allocator.free(module_source);
        const global_object = try exec.zjs_vm.contextGlobal(context);
        _ = try exec.module.initializeSyntheticFileModule(context, global_object, module_name, module_source);
    } else if (did_preload_graph) {
        try initializeSyntheticFileModules(runtime, context, io, allocator, max_source_size);
    }

    var postorder = std.ArrayList([]const u8).empty;
    defer {
        for (postorder.items) |path| allocator.free(path);
        postorder.deinit(allocator);
    }
    var seen = std.ArrayList(core.Atom).empty;
    defer seen.deinit(allocator);
    try appendPendingModuleEvalPostorder(runtime, allocator, module_name, &seen, &postorder);

    var continuations = std.ArrayList(ModuleContinuation).empty;
    defer freeModuleContinuations(runtime, allocator, &continuations);

    for (postorder.items) |path| {
        const module_atom = try runtime.internAtom(path);
        defer runtime.atoms.free(module_atom);
        const record = runtime.modules.find(module_atom) orelse return error.ModuleNotFound;
        if (record.synthetic_kind != .none) {
            // Synthetic (JSON) module records carry no code; their default
            // binding was initialized at preload.
            record.status = .evaluated;
            continue;
        }
        if (!moduleNeedsEvaluation(record)) continue;

        try drainModuleContinuationsForDependencies(runtime, context, output, allocator, &continuations, path);

        const dep_source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_source_size)) catch |err| switch (err) {
            error.FileNotFound => {
                try exec.module.throwCouldNotLoadModule(context, path);
                return error.JSException;
            },
            else => |e| return e,
        };
        defer allocator.free(dep_source);
        const step = try evalPreloadedFileModuleStep(runtime, context, dep_source, output, path, null, null, true);
        try handleModuleEvalStep(runtime, allocator, &continuations, step, dep_source, path, false, true);
        try runJobs(runtime, context, output);
        if (context.hasException()) return error.JSException;
    }

    _ = try drainModuleContinuations(runtime, context, output, allocator, &continuations);

    if (runtime.modules.find(module_name)) |record| {
        if (record.status == .errored) return throwCachedModuleEvalException(runtime, context, record);
    }
    return exec.module.moduleNamespaceValue(context, module_name);
}

/// Rethrow a module's cached evaluation exception (mirrors
/// js_inner_module_evaluation quickjs.c:31442: `JS_DupValue(ctx,
/// m->eval_exception)` for an evaluated module with eval_has_exception).
fn throwCachedModuleEvalException(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    record: *core.module.ModuleRecord,
) error{JSException} {
    _ = runtime;
    if (record.eval_exception) |exception| {
        _ = context.throwValue(exception.dup());
    }
    return error.JSException;
}

/// Throw the qjs-shaped SyntaxError for a module link failure (mirrors
/// js_resolve_export_throw_error quickjs.c:30232).
pub fn throwModuleLinkError(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    filename: []const u8,
    err: anyerror,
) !void {
    const exception_ops = exec.exception_ops;
    const global_object = try exec.zjs_vm.contextGlobal(context);
    var msg_buf = std.ArrayList(u8).empty;
    defer msg_buf.deinit(runtime.memory.allocator);
    if (runtime.modules.link_error) |info| {
        const export_name = runtime.atoms.name(info.export_name) orelse "";
        const in_module = runtime.atoms.name(info.module_name) orelse "";
        switch (info.kind) {
            .missing_export => try msg_buf.print(runtime.memory.allocator, "Could not find export '{s}' in module '{s}'", .{ export_name, in_module }),
            .ambiguous_export => try msg_buf.print(runtime.memory.allocator, "export '{s}' in module '{s}' is ambiguous", .{ export_name, in_module }),
        }
        runtime.modules.clearLinkError();
    } else {
        try msg_buf.print(runtime.memory.allocator, "could not link module '{s}': {s}", .{ filename, @errorName(err) });
    }
    const error_val = try exception_ops.createNamedError(context, global_object, "SyntaxError", msg_buf.items);
    _ = context.throwValue(error_val);
}

fn evalDynamicImportModuleWithHostHooks(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    output: ?*std.Io.Writer,
    host_hooks: HostHooks,
    referrer_path: []const u8,
    specifier: []const u8,
    allocator: std.mem.Allocator,
) !core.JSValue {
    if (referrer_path.len == 0) return error.ModuleNotFound;

    const resolved = try host_hooks.resolveModule(host_hooks.ptr, specifier, referrer_path, allocator);
    defer allocator.free(resolved.specifier);
    defer allocator.free(resolved.path);

    const resolved_atom = try runtime.internAtom(resolved.path);
    defer runtime.atoms.free(resolved_atom);

    if (runtime.modules.find(resolved_atom) == null) {
        const loaded = try host_hooks.loadModule(host_hooks.ptr, resolved, allocator);
        defer if (loaded.owned) allocator.free(loaded.source);
        defer allocator.free(loaded.path);

        var module_source_allocated = false;
        const module_source = try wrapSourceByKind(allocator, loaded.kind, loaded.source, resolved.path, &module_source_allocated);
        defer if (module_source_allocated) allocator.free(module_source);

        var preload_postorder = std.ArrayList([]const u8).empty;
        defer {
            for (preload_postorder.items) |path| allocator.free(path);
            preload_postorder.deinit(allocator);
        }
        try preloadFileModuleGraphWithHostHooksMode(allocator, runtime, context, host_hooks, module_source, resolved.path, &preload_postorder, true);
    }

    runtime.modules.linkModule(runtime, resolved_atom) catch |err| return moduleResolutionError(err);

    var postorder = std.ArrayList([]const u8).empty;
    defer {
        for (postorder.items) |path| allocator.free(path);
        postorder.deinit(allocator);
    }
    var seen = std.ArrayList(core.Atom).empty;
    defer seen.deinit(allocator);
    try appendPendingModuleEvalPostorder(runtime, allocator, resolved_atom, &seen, &postorder);

    var continuations = std.ArrayList(ModuleContinuation).empty;
    defer freeModuleContinuations(runtime, allocator, &continuations);

    for (postorder.items) |path| {
        const module_atom = try runtime.internAtom(path);
        defer runtime.atoms.free(module_atom);
        const record = runtime.modules.find(module_atom) orelse return error.ModuleNotFound;
        if (!moduleNeedsEvaluation(record)) continue;

        try drainModuleContinuationsForDependencies(runtime, context, output, allocator, &continuations, path);

        const eval_resolved = try host_hooks.resolveModule(host_hooks.ptr, path, null, allocator);
        defer allocator.free(eval_resolved.specifier);
        defer allocator.free(eval_resolved.path);

        const loaded = try host_hooks.loadModule(host_hooks.ptr, eval_resolved, allocator);
        defer if (loaded.owned) allocator.free(loaded.source);
        defer allocator.free(loaded.path);

        var module_source_allocated = false;
        const module_source = try wrapSourceByKind(allocator, loaded.kind, loaded.source, path, &module_source_allocated);
        defer if (module_source_allocated) allocator.free(module_source);

        const step = try evalPreloadedFileModuleStep(runtime, context, module_source, output, path, null, null, true);
        try handleModuleEvalStep(runtime, allocator, &continuations, step, module_source, path, false, true);
        try runJobs(runtime, context, output);
        if (context.hasUnhandledRejection() or context.hasException()) return error.UnhandledPromiseRejection;
    }

    _ = try drainModuleContinuations(runtime, context, output, allocator, &continuations);
    return exec.module.moduleNamespaceValue(context, resolved_atom);
}

fn moduleNeedsEvaluation(record: *const core.module.ModuleRecord) bool {
    return switch (record.status) {
        .unlinked, .linked => true,
        .linking, .evaluating, .evaluated, .errored => false,
    };
}

fn dynamicImportHostError(err: anyerror) core.context.DynamicImportError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.AccessDenied => error.AccessDenied,
        error.PermissionDenied => error.PermissionDenied,
        error.ProcessExit => error.ProcessExit,
        error.SyntaxError => error.SyntaxError,
        error.ReferenceError => error.ReferenceError,
        error.TypeError => error.TypeError,
        error.UnhandledPromiseRejection => error.UnhandledPromiseRejection,
        error.ModuleNotFound, error.FileNotFound, error.Unsupported, error.UnsupportedBarePackage, error.PackageSubpathNotFound => error.ModuleNotFound,
        else => error.Unexpected,
    };
}

fn appendPendingModuleEvalPostorder(
    runtime: *core.JSRuntime,
    allocator: std.mem.Allocator,
    module_name: core.Atom,
    seen: *std.ArrayList(core.Atom),
    postorder: *std.ArrayList([]const u8),
) !void {
    for (seen.items) |existing| {
        if (existing == module_name) return;
    }
    try seen.append(allocator, module_name);

    const record = runtime.modules.find(module_name) orelse return error.ModuleNotFound;
    for (record.requested_modules) |request| {
        try appendPendingModuleEvalPostorder(runtime, allocator, request, seen, postorder);
    }

    const refreshed = runtime.modules.find(module_name) orelse return error.ModuleNotFound;
    if (!moduleNeedsEvaluation(refreshed)) return;

    const path = runtime.atoms.name(module_name) orelse return error.InvalidAtom;
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    try postorder.append(allocator, owned_path);
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
    try preloadFileModuleGraphWithHostHooksMode(allocator, runtime, context, host_hooks, root_source, root_path, postorder, false);
}

fn preloadFileModuleGraphWithHostHooksMode(
    allocator: std.mem.Allocator,
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    host_hooks: HostHooks,
    root_source: []const u8,
    root_path: []const u8,
    postorder: *std.ArrayList([]const u8),
    skip_existing: bool,
) !void {
    var seen = std.ArrayList([]const u8).empty;
    defer {
        for (seen.items) |path| allocator.free(path);
        seen.deinit(allocator);
    }
    try preloadFileModuleGraphWithHostHooksInner(allocator, runtime, context, host_hooks, root_source, root_path, &seen, postorder, skip_existing);
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
    skip_existing: bool,
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
    if (skip_existing and runtime.modules.find(module_name) != null) return;

    var parsed = try parser.compile(runtime, source_text, .{ .mode = .module, .filename = path });
    defer parsed.deinit();
    if (parsed.syntax_error) |err| {
        const exception_ops = exec.exception_ops;
        const global_object = try exec.zjs_vm.contextGlobal(context);
        var msg_buf = std.ArrayList(u8).empty;
        defer msg_buf.deinit(runtime.memory.allocator);
        try msg_buf.print(runtime.memory.allocator, "SYNTAX ERROR in {s}:{d}:{d} - {s}", .{ path, err.position.line, err.position.column, err.message });
        const error_val = try exception_ops.createNamedError(context, global_object, "SyntaxError", msg_buf.items);
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

        try preloadFileModuleGraphWithHostHooksInner(allocator, runtime, context, host_hooks, module_source, loaded.path, seen, postorder, skip_existing);
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

fn monotonicNanos() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
