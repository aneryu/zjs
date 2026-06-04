const std = @import("std");
const engine = @import("quickjs_zig_engine");

const core = engine.core;

pub fn makeFunction(rt: *core.JSRuntime, code: []const u8) !engine.bytecode.Bytecode {
    const name = try rt.internAtom("exec");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    errdefer function.deinit(rt);
    try function.setCode(code);
    return function;
}

pub fn runFunction(rt: *core.JSRuntime, ctx: *core.JSContext, function: *const engine.bytecode.Bytecode) !core.JSValue {
    _ = rt;
    var vm_instance = engine.exec.Vm.init(ctx);
    defer vm_instance.deinit();
    return vm_instance.run(function);
}

pub fn objectFromValue(value: core.JSValue) *core.Object {
    const header = value.refHeader().?;
    return @fieldParentPtr("header", header);
}

pub fn expectActiveSetStrings(object: *core.Object, comptime expected: []const []const u8) !void {
    var active_index: usize = 0;
    for (object.collectionEntriesSlot().*) |entry| {
        if (!entry.active) continue;
        try std.testing.expect(active_index < expected.len);
        try expectStringValueBytes(entry.key, expected[active_index]);
        active_index += 1;
    }
    try std.testing.expectEqual(expected.len, active_index);
}

pub fn expectStringValueBytes(value: core.JSValue, expected: []const u8) !void {
    try std.testing.expect(value.isString());
    const header = value.refHeader().?;
    const string: *core.string.String = @fieldParentPtr("header", header);
    switch (string.resolveData()) {
        .latin1 => |bytes| try std.testing.expectEqualStrings(expected, bytes),
        .utf16 => |units| {
            try std.testing.expectEqual(expected.len, units.len);
            for (expected, units) |byte, unit| {
                try std.testing.expectEqual(@as(u16, byte), unit);
            }
        },
    }
}

pub var job_counter: usize = 0;

pub fn countJob(_: *core.JSContext, _: []const core.JSValue) core.JSValue {
    job_counter += 1;
    return core.JSValue.undefinedValue();
}

pub fn countJobArgs(ctx: *core.JSContext, args: []const core.JSValue) core.JSValue {
    _ = ctx;
    for (args) |arg| job_counter += @intCast(arg.asInt32().?);
    return core.JSValue.int32(@intCast(args.len));
}

// -----------------------------------------------------------------
// Shared test engine pattern
// -----------------------------------------------------------------
//
// Each `test "X" {}` block traditionally does:
//
//     var js = try engine.harness.Engine.init(std.testing.allocator);
//     defer js.deinit();
//     ...
//
// That pays ~195us (Debug) / ~50us (ReleaseSafe) per test for
// `installHostGlobals`, which dominates the per-test wall time for
// tests whose actual eval body is small. The shared-engine pattern
// below builds the Engine once per test BINARY (using a stable
// allocator independent of `std.testing.allocator`, which is reset
// between tests), and resets only the per-eval mutable state in
// between tests:
//
//     const js = helpers.sharedTestEngine();
//     defer helpers.endSharedTest();
//     ...
//
// `endSharedTest` clears the pending exception slot, drains the
// job queue, drops the global lexical environment (let / const
// declarations from the previous test), and marks any user-added
// global properties (`var x = ...`, `function f() {}`, ...) as
// deleted so the next test sees a clean global beyond
// `installHostGlobals`. Tests that mutate built-in objects (e.g.
// `Promise.resolve = ...`) or rely on freshly built closures
// referencing the previous test's eval scope still need a fresh
// `engine.harness.Engine.init` per call; the shared-engine pattern is
// safe for tests that only declare new locals / vars / functions
// and read the standard globals.
//
// The shared Engine uses `std.heap.page_allocator` so the Engine's
// internal allocations outlive any single test's
// `std.testing.allocator_instance` (which is freshly initialized for
// each test by the Zig test runner). Tests can still allocate their
// own stack buffers / `std.ArrayList` instances with
// `std.testing.allocator`; those are independent of the engine and
// continue to be leak-checked the usual way.

const cli_helpers = @import("../../cli/helpers.zig");

const EngineOptions = struct {
    allocator: std.mem.Allocator,
    trace_writer: ?*std.Io.Writer = null,
    limits: cli_helpers.Limits = .{},
};

const EvalOptions = core.context.ContextEvalOptions;

pub const TestEngine = struct {
    runtime: *core.JSRuntime,
    context: *core.JSContext,

    pub const HostHooks = cli_helpers.HostHooks;

    pub fn init(allocator: std.mem.Allocator) !TestEngine {
        return initWithOptions(.{ .allocator = allocator });
    }

    pub fn initWithOptions(options: EngineOptions) !TestEngine {
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
        };
    }

    pub fn deinit(self: *TestEngine) void {
        cli_helpers.runJobs(self.runtime, self.context, null) catch {};
        engine.exec.zjs_vm.cleanupWorkersForRuntime(self.runtime);
        _ = engine.exec.zjs_vm.cleanupTest262Agents(self.runtime);
        engine.exec.zjs_vm.cleanupAtomicsWaitersForContext(self.context);
        self.context.destroy();
        self.runtime.destroy();
    }

    pub fn eval(self: *TestEngine, source_text: []const u8) cli_helpers.RuntimeError!core.JSValue {
        return self.evalMode(source_text, .script);
    }

    pub fn evalHandle(self: *TestEngine, source_text: []const u8) cli_helpers.RuntimeError!core.JSValueHandle {
        return self.evalHandleWithOptions(source_text, .{});
    }

    pub fn evalModule(self: *TestEngine, source_text: []const u8) cli_helpers.RuntimeError!core.JSValue {
        return self.evalMode(source_text, .module);
    }

    pub fn evalModuleHandle(self: *TestEngine, source_text: []const u8) cli_helpers.RuntimeError!core.JSValueHandle {
        return self.evalHandleWithOptions(source_text, .{ .mode = .module });
    }

    pub fn evalMode(self: *TestEngine, source_text: []const u8, mode: engine.frontend.parser.Mode) cli_helpers.RuntimeError!core.JSValue {
        return self.evalWithOptions(source_text, .{ .mode = mode });
    }

    pub fn evalWithOptions(self: *TestEngine, source_text: []const u8, options: EvalOptions) cli_helpers.RuntimeError!core.JSValue {
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

    pub fn evalHandleWithOptions(self: *TestEngine, source_text: []const u8, options: EvalOptions) cli_helpers.RuntimeError!core.JSValueHandle {
        const value = try self.evalWithOptions(source_text, options);
        return try core.JSValueHandle.init(self.runtime, value);
    }

    pub fn createPersistentValue(self: *TestEngine, value: core.JSValue) !core.JSValueHandle {
        return self.runtime.createPersistentValue(value);
    }

    pub fn evalWithOutput(self: *TestEngine, source_text: []const u8, output: *std.Io.Writer) cli_helpers.RuntimeError!core.JSValue {
        return self.evalWithOptions(source_text, .{ .output = output });
    }

    pub fn evalWithOutputMode(self: *TestEngine, source_text: []const u8, output: *std.Io.Writer, mode: engine.frontend.parser.Mode) cli_helpers.RuntimeError!core.JSValue {
        return self.evalWithOptions(source_text, .{ .output = output, .mode = mode, .filename = "<eval>" });
    }

    pub fn evalFileWithOutputMode(self: *TestEngine, source_text: []const u8, output: *std.Io.Writer, mode: engine.frontend.parser.Mode, filename: []const u8) cli_helpers.RuntimeError!core.JSValue {
        return self.evalWithOptions(source_text, .{ .output = output, .mode = mode, .filename = filename });
    }

    pub fn evalFileWithOutputModeStrict(self: *TestEngine, source_text: []const u8, output: *std.Io.Writer, mode: engine.frontend.parser.Mode, filename: []const u8, strict: bool) cli_helpers.RuntimeError!core.JSValue {
        return self.evalWithOptions(source_text, .{ .output = output, .mode = mode, .filename = filename, .parse_strict = strict, .runtime_strict = strict });
    }

    pub fn evalFileWithOutputModeRuntimeStrict(self: *TestEngine, source_text: []const u8, output: *std.Io.Writer, mode: engine.frontend.parser.Mode, filename: []const u8, runtime_strict: bool) cli_helpers.RuntimeError!core.JSValue {
        return self.evalWithOptions(source_text, .{ .output = output, .mode = mode, .filename = filename, .runtime_strict = runtime_strict });
    }

    pub fn evalFileModuleGraphWithHostHooks(
        self: *TestEngine,
        source_text: []const u8,
        output: *std.Io.Writer,
        filename: []const u8,
        host_hooks: cli_helpers.HostHooks,
        allocator: std.mem.Allocator,
    ) !core.JSValue {
        return cli_helpers.evalFileModuleGraphWithHostHooks(self.runtime, self.context, source_text, output, filename, host_hooks, allocator);
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
        return cli_helpers.evalFileModuleGraphWithOutput(self.runtime, self.context, source_text, output, filename, io, allocator, max_source_size);
    }

    pub fn runJobs(self: *TestEngine) !void {
        try cli_helpers.runJobs(self.runtime, self.context, null);
    }

    pub fn exposeStdOsGlobals(self: *TestEngine) !void {
        try cli_helpers.exposeStdOsGlobals(self.runtime, self.context);
    }

    pub fn defineScriptArgs(self: *TestEngine, args: []const []const u8) !void {
        try cli_helpers.defineScriptArgs(self.runtime, self.context, args);
    }

    pub fn createExternalHostFunctionValue(
        self: *TestEngine,
        name: []const u8,
        length: i32,
        ptr: *anyopaque,
        call: core.host_function.ExternalCallFn,
        finalizer: ?core.host_function.ExternalFinalizer,
    ) !core.JSValue {
        return cli_helpers.createExternalHostFunctionValue(self.runtime, self.context, name, length, ptr, call, finalizer);
    }

    pub fn defineGlobalExternalHostFunction(
        self: *TestEngine,
        name: []const u8,
        length: i32,
        ptr: *anyopaque,
        call: core.host_function.ExternalCallFn,
        finalizer: ?core.host_function.ExternalFinalizer,
    ) !void {
        try cli_helpers.defineGlobalExternalHostFunction(self.runtime, self.context, name, length, ptr, call, finalizer);
    }

    pub fn defineArgvGlobals(self: *TestEngine, argv0: []const u8, exec_argv: []const []const u8) !void {
        try cli_helpers.defineArgvGlobals(self.runtime, self.context, argv0, exec_argv);
    }

    pub fn defineCliArgvGlobalsLazy(self: *TestEngine, argv0: []const u8, exec_argv: []const []const u8) !void {
        try cli_helpers.defineCliArgvGlobalsLazy(self.runtime, self.context, argv0, exec_argv);
    }

    pub fn defineCliScriptArgsLazy(self: *TestEngine, args: []const []const u8) !void {
        try cli_helpers.defineCliScriptArgsLazy(self.runtime, self.context, args);
    }

    pub fn takeException(self: *TestEngine) core.JSValue {
        return cli_helpers.takeException(self.context);
    }

    pub fn takeExceptionInfo(self: *TestEngine) !cli_helpers.ExceptionInfo {
        return cli_helpers.takeExceptionInfo(self.runtime, self.context);
    }
};

fn moduleResolutionError(err: anytype) (@TypeOf(err) || error{SyntaxError}) {
    return switch (err) {
        error.MissingExport, error.AmbiguousExport => error.SyntaxError,
        else => err,
    };
}

var shared_engine_storage: ?TestEngine = null;
var shared_engine_baseline_property_count: usize = 0;
var shared_engine_baseline_shape_prop_count: usize = 0;
var shared_engine_baseline_shape_hash: u32 = 0;
var shared_engine_baseline_shape_deleted_count: usize = 0;
var shared_engine_baseline_properties: ?[]core.property.Entry = null;

pub fn sharedTestEngine() *TestEngine {
    if (shared_engine_storage == null) {
        shared_engine_storage = TestEngine.init(std.heap.page_allocator) catch unreachable;
        const eng = &shared_engine_storage.?;
        // Force the global object build (`installHostGlobals`) by
        // running an empty eval. This lets us snapshot the post-install
        // property count so subsequent `endSharedTest()` calls can
        // remove user-added globals (`var x = ...`, `function f() {}`,
        // ...) without rebuilding the entire standard-globals
        // namespace.
        const sentinel = eng.eval(";") catch unreachable;
        sentinel.free(eng.runtime);
        if (eng.context.hasException()) {
            const thrown = eng.context.takeException();
            thrown.free(eng.runtime);
        }
        if (eng.context.hasUnhandledRejection()) {
            const thrown = eng.context.takeUnhandledRejection();
            thrown.free(eng.runtime);
        }
        if (eng.context.global) |g| {
            shared_engine_baseline_property_count = g.properties.len;
            shared_engine_baseline_shape_prop_count = g.shape_ref.prop_count;
            shared_engine_baseline_shape_hash = g.shape_ref.hash;
            shared_engine_baseline_shape_deleted_count = g.shape_ref.deleted_prop_count;

            // Snapshot the baseline property entries
            shared_engine_baseline_properties = std.heap.page_allocator.alloc(core.property.Entry, g.properties.len) catch unreachable;
            for (g.properties, 0..) |entry, idx| {
                shared_engine_baseline_properties.?[idx] = entry;
                shared_engine_baseline_properties.?[idx].slot = entry.slot.dup();
                if (entry.atom_id != core.atom.null_atom) {
                    _ = eng.runtime.atoms.dup(entry.atom_id);
                }
            }
        }
    }
    return &shared_engine_storage.?;
}

pub fn endSharedTest() void {
    const eng = if (shared_engine_storage) |*e| e else return;
    // Clear any exception still sitting on the context from a test
    // that returned via `try` without explicitly taking it.
    if (eng.context.hasException()) {
        const thrown = eng.context.takeException();
        thrown.free(eng.runtime);
    }
    if (eng.context.hasUnhandledRejection()) {
        const thrown = eng.context.takeUnhandledRejection();
        thrown.free(eng.runtime);
    }
    // Drain pending jobs so the next test starts with an empty queue;
    // tests that schedule a promise via `Promise.resolve(...)` and
    // return without awaiting would otherwise leak the job into the
    // next test.
    eng.runtime.job_queue.runAll();
    if (eng.context.hasException()) {
        const thrown = eng.context.takeException();
        thrown.free(eng.runtime);
    }
    if (eng.context.hasUnhandledRejection()) {
        const thrown = eng.context.takeUnhandledRejection();
        thrown.free(eng.runtime);
    }
    engine.exec.zjs_vm.cleanupAtomicsWaitersForContext(eng.context);
    if (eng.context.global) |global| {
        // Reset global lexical bindings (let / const) so the next
        // test can re-declare any name without triggering a
        // redeclaration SyntaxError.
        if (eng.context.lexicals) |env| {
            eng.context.lexicals = null;
            env.value().free(eng.runtime);
        }
        // Remove any user-added properties (`var x = ...`,
        // `function f()`, ...) so the next test sees a clean global.
        // Standard globals (`Object`, `Array`, ...) and host helpers
        // (`print`, ...) installed by `installHostGlobals` live at
        // indices below `shared_engine_baseline_property_count` and
        // are kept.
        const baseline = shared_engine_baseline_property_count;
        if (global.properties.len > baseline) {
            for (global.properties[baseline..]) |*entry| {
                if (entry.flags.deleted) continue;
                entry.slot.destroy(eng.runtime);
                if (entry.atom_id != core.atom.null_atom) eng.runtime.atoms.free(entry.atom_id);
                entry.atom_id = core.atom.null_atom;
                entry.slot = .deleted;
                entry.flags.deleted = true;
            }
            global.properties = global.properties.ptr[0..baseline];
        }

        // Restore baseline properties below baseline to their original states
        if (shared_engine_baseline_properties) |baselines| {
            // First, destroy current values below baseline
            for (global.properties[0..baseline]) |entry| {
                entry.slot.destroy(eng.runtime);
                if (entry.atom_id != core.atom.null_atom) eng.runtime.atoms.free(entry.atom_id);
            }
            // Second, restore baseline values (and dup them so they can be modified/freed again)
            for (baselines, 0..) |base, idx| {
                global.properties[idx] = base;
                global.properties[idx].slot = base.slot.dup();
                if (base.atom_id != core.atom.null_atom) {
                    _ = eng.runtime.atoms.dup(base.atom_id);
                }
            }
        }

        const shape_baseline = shared_engine_baseline_shape_prop_count;
        if (global.shape_ref.prop_count > shape_baseline) {
            for (global.shape_ref.props[shape_baseline..global.shape_ref.prop_count]) |*prop| {
                if (prop.atom_id != core.atom.null_atom) eng.runtime.atoms.free(prop.atom_id);
                prop.* = .{};
            }
            global.shape_ref.prop_count = shape_baseline;
            global.shape_ref.hash = shared_engine_baseline_shape_hash;
            global.shape_ref.deleted_prop_count = shared_engine_baseline_shape_deleted_count;
        }
    }
}
