//! A JS realm for one test: Runtime + Context + EventLoop, plus host probes.
//!
//! Tests that only add locals / vars / functions should prefer the process-
//! level shared engine in `shared.zig`. Use `TestEngine.init` when the test
//! mutates builtins or needs a fresh closure scope.

const std = @import("std");
const zjs = @import("zjs");
const core = zjs.core;
const exec = zjs.exec;
const event_loop = @import("zjs_host");
const test262_host = @import("test262_host");

const module_graph = exec.module_graph;
const RuntimeError = exec.exceptions.RuntimeError;
const EvalOptions = core.context.ContextEvalOptions;

/// Every TypeScript execution test goes through here.
pub fn evalTypeScriptChecked(engine_instance: *TestEngine, source: []const u8, options: EvalOptions) RuntimeError!core.JSValue {
    return engine_instance.evalWithOptions(source, options);
}

pub fn installHostGlobalsBare(ctx: *core.JSContext, global: *core.Object) !void {
    try exec.call.installEngineGlobals(ctx, global);
    try event_loop.globals.install(ctx, global);
}

pub var job_counter: usize = 0;

pub fn countJob(_: *core.JSContext, _: []const core.JSValue) core.JSValue {
    job_counter += 1;
    return core.JSValue.undefinedValue();
}

pub fn countJobArgs(ctx: *core.JSContext, args: []const core.JSValue) core.JSValue {
    _ = ctx;
    for (args) |arg| job_counter += @intCast(arg.as(.int).?);
    return core.JSValue.int32(@intCast(args.len));
}

const Limits = struct {
    memory_bytes: ?usize = null,
    stack_bytes: ?usize = null,
    gc_threshold_bytes: ?usize = null,
};

const ExceptionInfo = struct {
    value: core.JSValueHandle,

    pub fn deinit(self: *ExceptionInfo) void {
        self.value.deinit();
    }

    pub fn getMessage(self: ExceptionInfo, allocator: std.mem.Allocator) ![]const u8 {
        const rt = self.value.runtime orelse return error.InvalidEngineState;
        const value = self.value.get();
        if (value.is(.object)) {
            const header = value.refHeader() orelse return error.InvalidEngineState;
            const object = core.Object.fromHeader(header);

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

        var temp_list = std.ArrayList(u8).empty;
        defer temp_list.deinit(rt.nativeAllocator());
        try exec.value_ops.appendValueString(rt, &temp_list, value);
        return try allocator.dupe(u8, temp_list.items);
    }
};

fn getPropertyString(rt: *core.JSRuntime, obj: *core.Object, name: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    const key = try rt.internAtom(name);
    const val = try obj.getProperty(key);
    if (!val.isString()) return null;

    var temp_list = std.ArrayList(u8).empty;
    defer temp_list.deinit(rt.nativeAllocator());
    try exec.value_ops.appendRawString(rt, &temp_list, val);
    return try allocator.dupe(u8, temp_list.items);
}

const EngineOptions = struct {
    allocator: std.mem.Allocator,
    limits: Limits = .{},
};

pub const TestEngine = struct {
    allocator: std.mem.Allocator,
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    event_loop: *event_loop.EventLoop,
    host_globals_installed: bool = false,

    pub const HostHooks = module_graph.HostHooks;

    pub fn init(allocator: std.mem.Allocator) !TestEngine {
        return initWithOptions(.{ .allocator = allocator });
    }

    pub fn initWithOptions(options: EngineOptions) !TestEngine {
        const rt = try core.JSRuntime.create(options.allocator, .{
            .memory_limit = options.limits.memory_bytes,
            .gc_threshold = options.limits.gc_threshold_bytes orelse core.runtime.default_gc_threshold,
            .stack_size = options.limits.stack_bytes orelse core.runtime.default_stack_size,
        });
        errdefer rt.destroy();
        rt.setNativeStackSize(core.runtime.default_native_stack_size * 4);
        const ctx = try core.JSContext.create(rt, .{});
        errdefer ctx.destroy();
        event_loop.file_modules.install(ctx);
        const loop = try options.allocator.create(event_loop.EventLoop);
        errdefer options.allocator.destroy(loop);
        loop.* = event_loop.EventLoop.initCore(ctx, .{});
        loop.install();
        return .{
            .allocator = options.allocator,
            .runtime = rt,
            .context = ctx,
            .event_loop = loop,
        };
    }

    pub fn deinit(self: *TestEngine) void {
        var wrapper = zjs.borrowContext(self.context);
        wrapper.runJobs(null) catch {};
        self.event_loop.deinit();
        self.allocator.destroy(self.event_loop);
        _ = test262_host.cleanupTest262Agents(self.runtime);
        exec.zjs_vm.cleanupAtomicsWaitersForContext(self.context);
        self.context.destroy();
        self.runtime.destroy();
    }

    pub fn eval(self: *TestEngine, source_text: []const u8) RuntimeError!core.JSValue {
        return self.evalMode(source_text, .script);
    }

    pub fn evalModule(self: *TestEngine, source_text: []const u8) RuntimeError!core.JSValue {
        return self.evalMode(source_text, .module);
    }

    pub fn evalMode(self: *TestEngine, source_text: []const u8, mode: core.EvalMode) RuntimeError!core.JSValue {
        return self.evalWithOptions(source_text, .{ .mode = mode });
    }

    pub fn ensureTest262GlobalsInstalled(self: *TestEngine) !void {
        if (!self.host_globals_installed) {
            const global_obj = try exec.zjs_vm.contextGlobal(self.context);
            var wrapper = zjs.borrowContext(self.context);
            try test262_host.installTest262Globals(self.runtime, &wrapper, global_obj);
            self.host_globals_installed = true;
        }
    }

    pub fn evalWithOptions(self: *TestEngine, source_text: []const u8, options: EvalOptions) RuntimeError!core.JSValue {
        const filename = options.filename;
        const mode = options.mode;
        self.ensureTest262GlobalsInstalled() catch |err| return @errorCast(err);
        var wrapper = zjs.borrowContext(self.context);
        return wrapper.eval(source_text, .{
            .mode = mode,
            .filename = filename,
            .output = options.output,
            .parse_strict = options.parse_strict,
            .runtime_strict = options.runtime_strict,
            .return_completion = mode == .script and std.mem.eql(u8, filename, "<repl>"),
            .discard_script_result = mode == .script and !std.mem.eql(u8, filename, "<repl>"),
            .timing = options.timing,
        }) catch |err| return @errorCast(moduleResolutionError(err));
    }

    pub fn createPersistentValue(self: *TestEngine, value: core.JSValue) !core.JSValueHandle {
        return self.runtime.createPersistentValue(value);
    }

    pub fn evalWithOutput(self: *TestEngine, source_text: []const u8, output: *std.Io.Writer) RuntimeError!core.JSValue {
        return self.evalWithOptions(source_text, .{ .output = output });
    }

    pub fn evalFileWithOutputMode(self: *TestEngine, source_text: []const u8, output: *std.Io.Writer, mode: core.EvalMode, filename: []const u8) RuntimeError!core.JSValue {
        return self.evalWithOptions(source_text, .{ .output = output, .mode = mode, .filename = filename });
    }

    pub fn evalFileWithOutputModeStrict(self: *TestEngine, source_text: []const u8, output: *std.Io.Writer, mode: core.EvalMode, filename: []const u8, strict: bool) RuntimeError!core.JSValue {
        return self.evalWithOptions(source_text, .{ .output = output, .mode = mode, .filename = filename, .parse_strict = strict, .runtime_strict = strict });
    }

    pub fn evalFileWithOutputModeRuntimeStrict(self: *TestEngine, source_text: []const u8, output: *std.Io.Writer, mode: core.EvalMode, filename: []const u8, runtime_strict: bool) RuntimeError!core.JSValue {
        return self.evalWithOptions(source_text, .{ .output = output, .mode = mode, .filename = filename, .runtime_strict = runtime_strict });
    }

    pub fn evalFileModuleGraphWithHostHooks(
        self: *TestEngine,
        source_text: []const u8,
        output: *std.Io.Writer,
        filename: []const u8,
        host_hooks: module_graph.HostHooks,
        allocator: std.mem.Allocator,
    ) !core.JSValue {
        try self.ensureTest262GlobalsInstalled();
        return module_graph.evalFileModuleGraphWithHostHooks(self.runtime, self.context, source_text, output, filename, host_hooks, allocator);
    }

    pub fn evalFileModuleGraphWithOutput(
        self: *TestEngine,
        source_text: []const u8,
        output: *std.Io.Writer,
        filename: []const u8,
        io: std.Io,
        allocator: std.mem.Allocator,
        max_source_size: usize,
    ) !core.JSValue {
        try self.ensureTest262GlobalsInstalled();
        return module_graph.evalFileModuleGraphWithOutput(self.runtime, self.context, source_text, output, filename, io, allocator, max_source_size);
    }

    pub fn runJobs(self: *TestEngine) !void {
        var wrapper = zjs.borrowContext(self.context);
        try wrapper.runJobs(null);
    }

    pub fn installLegacyProbeEntry(rt: *core.JSRuntime, function_object: *core.Object, ptr: *anyopaque, call: core.host_function.ExternalCallFn) !void {
        const state = try rt.nativeAllocator().create(LegacyProbeState);
        errdefer rt.nativeAllocator().destroy(state);
        state.* = .{ .runtime = rt, .ptr = ptr, .call = call, .finalizer = null };
        try rt.registerNativeEntryFinalizer(@ptrCast(state), LegacyProbeState.finalize);
        const entry = try rt.allocNativeEntry(.{
            .target = core.NativeEntry.code(&LegacyProbeState.thunk),
            .kind = .managed,
            .state = @ptrCast(state),
        });
        function_object.installNativeEntry(entry);
    }

    /// Test-probe adapter: the legacy `(ptr, ExternalCall)` probe shape is
    /// kept for the existing tests, but the function is an ordinary NB2
    /// `NativeEntry` (managed thunk + heap state), not a registry record.
    pub fn createExternalHostFunctionValue(
        self: *TestEngine,
        name: []const u8,
        length: i32,
        ptr: *anyopaque,
        call: core.host_function.ExternalCallFn,
        finalizer: ?core.host_function.ExternalFinalizer,
    ) !core.JSValue {
        const state = try self.runtime.nativeAllocator().create(LegacyProbeState);
        errdefer self.runtime.nativeAllocator().destroy(state);
        state.* = .{ .runtime = self.runtime, .ptr = ptr, .call = call, .finalizer = finalizer };
        try self.runtime.registerNativeEntryFinalizer(@ptrCast(state), LegacyProbeState.finalize);
        const entry = try self.runtime.allocNativeEntry(.{
            .target = core.NativeEntry.code(&LegacyProbeState.thunk),
            .kind = .managed,
            .state = @ptrCast(state),
            .arity = @intCast(@max(length, 0)),
        });
        const function_value = try core.function.nativeFunction(self.context, name, length);
        const function_object = try exec.property_ops.expectObject(function_value);
        function_object.installNativeEntry(entry);
        return function_value;
    }

    pub fn defineGlobalExternalHostFunction(
        self: *TestEngine,
        name: []const u8,
        length: i32,
        ptr: *anyopaque,
        call: core.host_function.ExternalCallFn,
        finalizer: ?core.host_function.ExternalFinalizer,
    ) !void {
        const global_object = try exec.zjs_vm.contextGlobal(self.context);
        const function_value = try self.createExternalHostFunctionValue(name, length, ptr, call, finalizer);

        const property_name = try self.runtime.internAtom(name);
        try global_object.defineOwnProperty(self.runtime, property_name, core.Descriptor.data(function_value, .method));
    }

    pub fn takeException(self: *TestEngine) core.JSValue {
        return self.context.takePendingException();
    }

    pub fn takeExceptionInfo(self: *TestEngine) !ExceptionInfo {
        return .{
            .value = try core.JSValueHandle.init(self.runtime, self.takeException()),
        };
    }
};

fn moduleResolutionError(err: anytype) (@TypeOf(err) || error{SyntaxError}) {
    return switch (err) {
        error.MissingExport, error.AmbiguousExport => error.SyntaxError,
        else => err,
    };
}

/// Heap state behind `createExternalHostFunctionValue`: runs the legacy probe
/// and maps its error exactly as the old external-host seam did.
pub const LegacyProbeState = struct {
    runtime: *core.JSRuntime,
    ptr: *anyopaque,
    call: core.host_function.ExternalCallFn,
    finalizer: ?core.host_function.ExternalFinalizer,

    pub fn finalize(raw: *anyopaque) void {
        const self: *LegacyProbeState = @ptrCast(@alignCast(raw));
        if (self.finalizer) |f| f(self.ptr);
        self.runtime.nativeAllocator().destroy(self);
    }

    pub fn thunk(
        ctx: *core.JSContext,
        this_value: core.JSValue,
        argv: [*]const core.JSValue,
        argc: u32,
        entry: *const core.NativeEntry,
        func_obj: ?*core.Object,
    ) callconv(.c) core.JSValue {
        const self: *LegacyProbeState = @ptrCast(@alignCast(entry.state.?));
        const function_object = func_obj orelse return exec.builtin_dispatch.hostErrorToValue(ctx, ctx.global, error.TypeError);
        const result = self.call(self.ptr, .{
            .realm = ctx,
            .output = exec.builtin_dispatch.vmCallerView(ctx).output,
            .func_obj = function_object,
            .this_value = this_value,
            .args = argv[0..argc],
        }) catch |err| return exec.builtin_dispatch.embedderErrorToValue(ctx, err);
        return result;
    }
};

/// A scratch directory name unique to this test process: the merge gate
/// runs the Debug and gc-stress shards concurrently, and two processes
/// deleting/creating one fixed directory race each other.
pub fn scratchDirForProcess(comptime base: []const u8) []const u8 {
    const S = struct {
        var buf: [256]u8 = undefined;
    };
    return std.fmt.bufPrint(&S.buf, "{s}-{d}", .{ base, std.c.getpid() }) catch base;
}
