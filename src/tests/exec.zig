const std = @import("std");
const engine = @import("quickjs_zig_engine");

const core = engine.core;
const QjsLexer = engine.frontend.zjs_lexer.Lexer;
const zjs_parser = engine.frontend.zjs_parser;
const ParseState = zjs_parser.ParseState;
const bytecode = engine.bytecode;
const function_def = engine.bytecode.function_def;
const op = engine.bytecode.opcode.op;
const property_ops = engine.exec.property_ops;

const makeFunction = helpers.makeFunction;
const runFunction = helpers.runFunction;
const countJob = helpers.countJob;
const countJobArgs = helpers.countJobArgs;

pub const helpers = struct {
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

const cli_helpers = @import("../cli/helpers.zig");

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
        const test262_helpers = @import("../cli/test262_helpers.zig");
        _ = test262_helpers.cleanupTest262Agents(self.runtime);
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

    pub fn ensureTest262GlobalsInstalled(self: *TestEngine) !void {
        if (self.context.global == null) {
            const global_obj = try engine.exec.zjs_vm.contextGlobal(self.context);
            try engine.exec.call.installTest262Globals(self.runtime, global_obj);
            const test262_helpers = @import("../cli/test262_helpers.zig");
            try test262_helpers.installTest262AgentGlobals(self.runtime, self.context, global_obj);
        }
    }

    pub fn evalWithOptions(self: *TestEngine, source_text: []const u8, options: EvalOptions) cli_helpers.RuntimeError!core.JSValue {
        const filename = options.filename;
        const mode = options.mode;
        self.ensureTest262GlobalsInstalled() catch |err| return @errorCast(err);
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
        try self.ensureTest262GlobalsInstalled();
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
        try self.ensureTest262GlobalsInstalled();
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

};

pub const vm_helpers = struct {
pub fn parseAndRun(rt: *core.JSRuntime, ctx: *core.JSContext, src: []const u8) !core.JSValue {
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    var lex = QjsLexer.init(std.testing.allocator, &rt.atoms, src);
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(rt);
    try zjs_parser.parseExpr(&state);

    // Run the FunctionDef-backed finalize pipeline so locals are lowered
    // to get_loc / put_loc instead of falling back to global get_var /
    // put_var.
    try engine.bytecode.pipeline.finalize.runWithFunctionDef(&function, &state.function_def);

    var vm = engine.exec.Vm.init(ctx);
    defer vm.deinit();
    return vm.run(&function);
}

pub fn parseAndRunWithTopLevelChildren(rt: *core.JSRuntime, ctx: *core.JSContext, src: []const u8) !core.JSValue {
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    var lex = QjsLexer.init(std.testing.allocator, &rt.atoms, src);
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(rt);
    state.top_level_functions_as_children = true;
    try zjs_parser.parseExpr(&state);

    try engine.bytecode.pipeline.finalize.runWithFunctionDefRuntime(&function, &state.function_def, rt);

    var vm = engine.exec.Vm.init(ctx);
    defer vm.deinit();
    return vm.run(&function);
}

pub fn expectStringBytes(value: core.JSValue, expected: []const u8) !void {
    try std.testing.expect(value.isString());
    const string_value: *core.string.String = @fieldParentPtr("header", value.refHeader().?);
    try std.testing.expect(string_value.eqlBytes(expected));
}

pub fn expectSingleCodeUnit(value: core.JSValue, expected: u16) !void {
    try std.testing.expect(value.isString());
    const string_value: *core.string.String = @fieldParentPtr("header", value.refHeader().?);
    try std.testing.expectEqual(@as(usize, 1), string_value.len());
    try std.testing.expectEqual(expected, string_value.codeUnitAt(0));
}

pub fn parseStmtAndRun(rt: *core.JSRuntime, ctx: *core.JSContext, src: []const u8) !core.JSValue {
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    var lex = QjsLexer.init(std.testing.allocator, &rt.atoms, src);
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(rt);

    try state.enableEvalReturn();
    while (state.token.val != engine.frontend.zjs_token.TOK_EOF) {
        try zjs_parser.parseStatementOrDecl(&state, zjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });
    }
    try state.finalizeEvalReturn();

    try engine.bytecode.pipeline.finalize.runWithFunctionDef(&function, &state.function_def);

    var vm = engine.exec.Vm.init(ctx);
    defer vm.deinit();
    return vm.run(&function);
}

pub fn parseStmtAndRunWithTopLevelChildren(rt: *core.JSRuntime, ctx: *core.JSContext, src: []const u8) !core.JSValue {
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    var lex = QjsLexer.init(std.testing.allocator, &rt.atoms, src);
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(rt);
    state.top_level_functions_as_children = true;

    try state.enableEvalReturn();
    while (state.token.val != engine.frontend.zjs_token.TOK_EOF) {
        try zjs_parser.parseStatementOrDecl(&state, zjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });
    }
    try state.finalizeEvalReturn();

    try engine.bytecode.pipeline.finalize.runWithFunctionDefRuntime(&function, &state.function_def, rt);

    var vm = engine.exec.Vm.init(ctx);
    defer vm.deinit();
    return vm.run(&function);
}

};


// ================== core_native.zig ==================




extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "vm executes push constants arithmetic comparisons and return" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    var function = try makeFunction(rt, &.{
        op.push_i32, 2,           0, 0, 0,
        op.push_i32, 3,           0, 0, 0,
        op.add,      op.push_i32, 6, 0, 0,
        0,           op.lt,
    });
    defer function.deinit(rt);

    const result = try runFunction(rt, ctx, &function);
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "vm executes stack constants source locations and return_undef" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    var function = try makeFunction(rt, &.{
        op.undefined, op.null, op.push_true, op.push_false, op.drop, op.return_undef,
    });
    defer function.deinit(rt);

    var vm_instance = engine.exec.Vm.init(ctx);
    defer vm_instance.deinit();
    const result = try vm_instance.run(&function);
    defer result.free(rt);
    try std.testing.expect(result.isUndefined());
    try std.testing.expect(result.isUndefined());
}

test "frame setLocal handles self-assignment without dropping object" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    defer function.deinit(rt);
    var frame = engine.exec.frame.Frame.init(&function);
    defer frame.deinit(&rt.memory, rt);

    const object = try core.Object.create(rt, core.class.ids.object, null);
    try frame.setLocal(&rt.memory, rt, 0, object.value());
    object.value().free(rt);

    try std.testing.expectEqual(@as(i32, 1), object.header.rc);
    const current = frame.locals[0];
    try frame.setLocal(&rt.memory, rt, 0, current);

    try std.testing.expectEqual(@as(i32, 1), object.header.rc);
    try std.testing.expectEqual(&object.header, frame.locals[0].refHeader().?);
}

test "VM roots frame this symbol before derived constructor var-ref allocation" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const global = try engine.exec.zjs_vm.contextGlobal(ctx);

    const this_name = try rt.internAtom("this");
    defer rt.atoms.free(this_name);

    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    defer function.deinit(rt);
    function.flags.is_derived_class_constructor = true;
    function.var_count = 1;
    function.stack_size = 1;
    function.var_names = try rt.memory.alloc(core.Atom, 1);
    function.var_names[0] = rt.atoms.dup(this_name);
    try function.setCode(&.{ op.get_loc0, op.drop, op.return_undef });

    const this_symbol = try rt.atoms.newValueSymbol("gc-vm-frame-this-before-roots");
    rt.setGCThreshold(0);

    var stack = engine.exec.stack.Stack.init(&rt.memory, rt.stackSize());
    defer stack.deinit(rt);

    const result = try engine.exec.zjs_vm.runWithArgsState(
        ctx,
        &stack,
        &function,
        core.JSValue.symbol(this_symbol),
        &.{},
        &.{},
        null,
        global,
        false,
        false,
        false,
        &.{},
        &.{},
        &.{},
        &.{},
        &.{},
        &.{},
        &.{},
        &.{},
        null,
        null,
        null,
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        false,
        false,
        core.JSValue.undefinedValue(),
        true,
        false,
    );
    defer result.free(rt);

    try std.testing.expectEqual(this_symbol, result.asSymbolAtom().?);
    try std.testing.expect(rt.atoms.name(this_symbol) != null);
}

test "bound function call skips zero-length combined args allocation" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const target = try engine.exec.closure.create(rt, 13, 0, 0, 0);
    defer target.free(rt);
    const bound = try core.Object.create(rt, core.class.ids.bound_function, null);
    defer bound.value().free(rt);
    bound.boundTargetSlot().* = target.dup();
    bound.boundThisSlot().* = core.JSValue.undefinedValue();

    const base_bytes = rt.memory.allocated_bytes;
    const base_allocations = rt.memory.allocation_count;

    const result = try engine.exec.call.callValue(ctx, null, bound.value(), &.{});
    defer result.free(rt);
    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqual(base_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(base_allocations, rt.memory.allocation_count);
}

test "os.exec PATH search keeps empty entries and continues after EACCES" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const root_dir = ".zig-cache/os-exec-path-search";
    const denied_dir = root_dir ++ "/denied";
    const ok_dir = root_dir ++ "/ok";
    const cwd_dir = root_dir ++ "/cwd";
    const root_path = root_dir ++ "/root.mjs";
    const eacces_cmd = "zjs-exec-path-eacces";
    const empty_cmd = "zjs-exec-path-empty";
    const denied_cmd_path = denied_dir ++ "/" ++ eacces_cmd;
    const ok_cmd_path = ok_dir ++ "/" ++ eacces_cmd;
    const empty_cmd_path = cwd_dir ++ "/" ++ empty_cmd;

    std.Io.Dir.cwd().deleteTree(std.testing.io, root_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, denied_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, ok_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, cwd_dir);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = denied_cmd_path, .data = "not executable\n" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = ok_cmd_path, .data =
        \\#!/bin/sh
        \\exit 0
        \\
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = empty_cmd_path, .data =
        \\#!/bin/sh
        \\exit 0
        \\
    });

    const denied_cmd_path_z = try std.testing.allocator.dupeZ(u8, denied_cmd_path);
    defer std.testing.allocator.free(denied_cmd_path_z);
    const ok_cmd_path_z = try std.testing.allocator.dupeZ(u8, ok_cmd_path);
    defer std.testing.allocator.free(ok_cmd_path_z);
    const empty_cmd_path_z = try std.testing.allocator.dupeZ(u8, empty_cmd_path);
    defer std.testing.allocator.free(empty_cmd_path_z);
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(denied_cmd_path_z.ptr, 0o644));
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(ok_cmd_path_z.ptr, 0o755));
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(empty_cmd_path_z.ptr, 0o755));

    const old_path = if (std.c.getenv("PATH")) |path|
        try std.testing.allocator.dupe(u8, std.mem.span(path))
    else
        null;
    defer if (old_path) |path| std.testing.allocator.free(path);
    const old_path_z = if (old_path) |path| try std.testing.allocator.dupeZ(u8, path) else null;
    defer if (old_path_z) |path| std.testing.allocator.free(path);
    const next_path_bytes = try std.fmt.allocPrint(std.testing.allocator, "{s}:{s}:", .{ denied_dir, ok_dir });
    defer std.testing.allocator.free(next_path_bytes);
    const next_path = try std.testing.allocator.dupeZ(u8, next_path_bytes);
    defer std.testing.allocator.free(next_path);
    try std.testing.expectEqual(@as(c_int, 0), setenv("PATH", next_path.ptr, 1));
    defer {
        if (old_path_z) |path| {
            _ = setenv("PATH", path.ptr, 1);
        } else {
            _ = unsetenv("PATH");
        }
    }

    const root_source =
        \\import { exec } from "os";
        \\print(exec(["zjs-exec-path-eacces"], { env: { ZJS_OS_EXEC_PATH_TEST: "1" } }));
        \\print(exec(["zjs-exec-path-empty"], { cwd: ".zig-cache/os-exec-path-search/cwd", env: { ZJS_OS_EXEC_PATH_TEST: "1" } }));
    ;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root_path, .data = root_source });

    var output_buffer: [32]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithOutput(root_source, &output, root_path, std.testing.io, std.testing.allocator, 4096);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("0\n0\n", output.buffered());
}

test "constant pool execution retains returned constants" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const name = try rt.internAtom("const-return");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    const str = try core.string.String.createAscii(rt, "hello");
    const value = str.value();
    _ = try function.addConstant(value);
    value.free(rt);
    try function.setCode(&.{ op.push_const, 0, 0, 0, 0 });

    const result = try runFunction(rt, ctx, &function);
    defer result.free(rt);
    try std.testing.expect(result.isString());
}

test "property ops use shared object semantics" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const obj = try core.Object.create(rt, core.class.ids.object, null);
    defer obj.value().free(rt);
    const key = try rt.internAtom("x");
    defer rt.atoms.free(key);

    try engine.exec.property_ops.defineDataProperty(rt, obj, key, core.JSValue.int32(9));
    try engine.exec.property_ops.setProperty(rt, obj, key, core.JSValue.int32(10));
    const value = engine.exec.property_ops.getProperty(obj, key);
    try std.testing.expectEqual(@as(?i32, 10), value.asInt32());

    const direct_value = try engine.exec.property_ops.getPropertyValue(rt, obj.value(), key);
    defer direct_value.free(rt);
    try std.testing.expectEqual(@as(?i32, 10), direct_value.asInt32());

    const key_string_obj = try core.string.String.createUtf8(rt, "x");
    const key_string = key_string_obj.value();
    defer key_string.free(rt);
    const in_result = try engine.exec.property_ops.propertyIn(rt, obj.value(), key_string);
    try std.testing.expectEqual(true, in_result.asBool().?);

    const optional_result = try engine.exec.property_ops.optionalGetPropertyValue(rt, core.JSValue.nullValue(), key);
    try std.testing.expect(optional_result.isUndefined());

    try std.testing.expect(engine.exec.property_ops.deleteProperty(rt, obj, key));
}

test "value ops own primitive VM semantics" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const sum = try engine.exec.value_ops.binary(rt, op.add, core.JSValue.int32(2), core.JSValue.int32(3));
    defer sum.free(rt);
    try std.testing.expectEqual(@as(?i32, 5), sum.asInt32());

    const suffix_obj = try core.string.String.createUtf8(rt, "px");
    const suffix = suffix_obj.value();
    defer suffix.free(rt);
    const joined = try engine.exec.value_ops.binary(rt, op.add, core.JSValue.int32(2), suffix);
    defer joined.free(rt);

    var joined_text = std.ArrayList(u8).empty;
    defer joined_text.deinit(rt.memory.allocator);
    try engine.exec.value_ops.appendRawString(rt, &joined_text, joined);
    try std.testing.expectEqualStrings("2px", joined_text.items);

    const int_string = try engine.exec.value_ops.toStringValue(rt, core.JSValue.int32(7));
    defer int_string.free(rt);
    var int_string_text = std.ArrayList(u8).empty;
    defer int_string_text.deinit(rt.memory.allocator);
    try engine.exec.value_ops.appendRawString(rt, &int_string_text, int_string);
    try std.testing.expectEqualStrings("7", int_string_text.items);

    const empty_obj = try core.string.String.createUtf8(rt, "");
    const empty = empty_obj.value();
    defer empty.free(rt);

    const empty_suffix = try engine.exec.value_ops.binary(rt, op.add, empty, core.JSValue.int32(7));
    defer empty_suffix.free(rt);
    var empty_suffix_text = std.ArrayList(u8).empty;
    defer empty_suffix_text.deinit(rt.memory.allocator);
    try engine.exec.value_ops.appendRawString(rt, &empty_suffix_text, empty_suffix);
    try std.testing.expectEqualStrings("7", empty_suffix_text.items);

    const empty_prefix = try engine.exec.value_ops.binary(rt, op.add, core.JSValue.int32(7), empty);
    defer empty_prefix.free(rt);
    var empty_prefix_text = std.ArrayList(u8).empty;
    defer empty_prefix_text.deinit(rt.memory.allocator);
    try engine.exec.value_ops.appendRawString(rt, &empty_prefix_text, empty_prefix);
    try std.testing.expectEqualStrings("7", empty_prefix_text.items);

    const one_obj = try core.string.String.createUtf8(rt, "1");
    const one_string = one_obj.value();
    defer one_string.free(rt);

    const same_string = try engine.exec.value_ops.toStringValue(rt, one_string);
    defer same_string.free(rt);
    try std.testing.expect(same_string.same(one_string));

    const boxed_one = try engine.builtins.string.constructWithPrototype(rt, &.{one_string}, null);
    defer boxed_one.free(rt);
    const boxed_one_object: *core.Object = @fieldParentPtr("header", boxed_one.refHeader().?);
    const boxed_one_data = boxed_one_object.objectData() orelse return error.TypeError;
    try std.testing.expect(boxed_one_data.same(one_string));

    const symbol_atom = try rt.atoms.newSymbol("boxed", .symbol);
    defer rt.atoms.free(symbol_atom);
    try std.testing.expectError(error.TypeError, engine.builtins.string.constructWithPrototype(rt, &.{core.JSValue.symbol(symbol_atom)}, null));

    const name = try rt.internAtom("loose-eq");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    _ = try function.addConstant(one_string);
    try function.setCode(&.{
        op.push_i32,   1, 0, 0, 0,
        op.push_const, 0, 0, 0, 0,
        op.eq,
    });
    const eq_result = try runFunction(rt, ctx, &function);
    defer eq_result.free(rt);
    try std.testing.expectEqual(true, eq_result.asBool().?);

    try std.testing.expectEqual(false, engine.exec.value_ops.toBooleanValue(core.JSValue.int32(0)).asBool().?);
}

test "closure helper stores closure state outside the VM" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const closure_value = try engine.exec.closure.create(rt, 2, 0, 0, 0);
    defer closure_value.free(rt);
    const first = try engine.exec.closure.call(rt, closure_value, &.{}, &.{});
    defer first.free(rt);
    const second = try engine.exec.closure.call(rt, closure_value, &.{}, &.{});
    defer second.free(rt);

    try std.testing.expectEqual(@as(?i32, 1), first.asInt32());
    try std.testing.expectEqual(@as(?i32, 2), second.asInt32());
}

test "test262 helpers own SameValue assertions" {
    const test262_helpers = @import("../cli/test262_helpers.zig");
    const same_nan = try test262_helpers.assertSameValue(core.JSValue.float64(std.math.nan(f64)), core.JSValue.float64(std.math.nan(f64)));
    try std.testing.expect(same_nan.isUndefined());
    try std.testing.expectError(error.Test262Error, test262_helpers.assertSameValue(core.JSValue.int32(1), core.JSValue.int32(2)));
}

test "call subsystem installs and invokes host globals" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try engine.exec.call.installHostGlobals(rt, global);
    try engine.exec.call.installTest262Globals(rt, global);

    const print_key = try rt.internAtom("print");
    defer rt.atoms.free(print_key);
    const print = global.getProperty(print_key);
    defer print.free(rt);
    const print_object: *core.Object = @fieldParentPtr("header", print.refHeader().?);
    const host_function_key = try rt.internAtom("__host_function");
    defer rt.atoms.free(host_function_key);
    try std.testing.expect(print_object.getOwnProperty(host_function_key) == null);
    try std.testing.expect(print_object.hostFunctionKindSlot().* != 0);

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const args = [_]core.JSValue{ core.JSValue.int32(1), core.JSValue.boolean(true) };
    const result = try engine.exec.call.callValue(ctx, &stream, print, &args);
    defer result.free(rt);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1 true\n", stream.buffered());

    const assert_key = try rt.internAtom("assert");
    defer rt.atoms.free(assert_key);
    const same_value_key = try rt.internAtom("sameValue");
    defer rt.atoms.free(same_value_key);
    const assert_object_value = global.getProperty(assert_key);
    defer assert_object_value.free(rt);
    const assert_object_header = assert_object_value.refHeader().?;
    const assert_object: *core.Object = @fieldParentPtr("header", assert_object_header);
    const same_value = assert_object.getProperty(same_value_key);
    defer same_value.free(rt);

    const same_args = [_]core.JSValue{ core.JSValue.float64(std.math.nan(f64)), core.JSValue.float64(std.math.nan(f64)) };
    const same_result = try engine.exec.call.callValue(ctx, null, same_value, &same_args);
    defer same_result.free(rt);
    try std.testing.expect(same_result.isUndefined());
    const mismatch_args = [_]core.JSValue{ core.JSValue.int32(1), core.JSValue.int32(2) };
    try std.testing.expectError(error.Test262Error, engine.exec.call.callValue(ctx, null, same_value, &mismatch_args));

    const test262_key = try rt.internAtom("Test262Error");
    defer rt.atoms.free(test262_key);
    const test262_ctor = global.getProperty(test262_key);
    defer test262_ctor.free(rt);
    try std.testing.expectError(error.Test262Error, engine.exec.call.callValue(ctx, null, test262_ctor, &.{}));

    const map_value = try engine.builtins.collection.construct(rt, 1);
    defer map_value.free(rt);
    const map_object: *core.Object = @fieldParentPtr("header", map_value.refHeader().?);
    const set_key = try rt.internAtom("set");
    defer rt.atoms.free(set_key);
    const get_key = try rt.internAtom("get");
    defer rt.atoms.free(get_key);
    const map_set = map_object.getProperty(set_key);
    defer map_set.free(rt);
    const map_get = map_object.getProperty(get_key);
    defer map_get.free(rt);
    const stored_key_obj = try core.string.String.createUtf8(rt, "key");
    const stored_key = stored_key_obj.value();
    defer stored_key.free(rt);
    const stored_value_obj = try core.string.String.createUtf8(rt, "value");
    const stored_value = stored_value_obj.value();
    defer stored_value.free(rt);
    const set_args = [_]core.JSValue{ stored_key, stored_value };
    const set_result = try engine.exec.call.callValueWithThis(ctx, null, map_value, map_set, &set_args);
    defer set_result.free(rt);
    try std.testing.expect(set_result.same(map_value));
    try std.testing.expectError(error.TypeError, engine.exec.call.callValue(ctx, null, map_set, &set_args));
    const get_result = try engine.exec.call.callValueWithThis(ctx, null, map_value, map_get, &.{stored_key});
    defer get_result.free(rt);
    var get_text = std.ArrayList(u8).empty;
    defer get_text.deinit(std.testing.allocator);
    try engine.exec.value_ops.appendRawString(rt, &get_text, get_result);
    try std.testing.expectEqualStrings("value", get_text.items);
}

test "native builtin record dispatch is independent from dispatch-name strings" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try engine.exec.call.installHostGlobals(rt, global);

    const math_key = try rt.internAtom("Math");
    defer rt.atoms.free(math_key);
    const abs_key = try rt.internAtom("abs");
    defer rt.atoms.free(abs_key);
    const math_value = global.getProperty(math_key);
    defer math_value.free(rt);
    const math_object: *core.Object = @fieldParentPtr("header", math_value.refHeader().?);
    const abs_value = math_object.getProperty(abs_key);
    defer abs_value.free(rt);
    const abs_object: *core.Object = @fieldParentPtr("header", abs_value.refHeader().?);
    try std.testing.expect(abs_object.nativeFunctionIdSlot().* != 0);

    const fake = try engine.builtins.function.nativeFunction(rt, "notMathAbs", 1);
    defer fake.free(rt);
    const fake_object: *core.Object = @fieldParentPtr("header", fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = abs_object.nativeFunctionIdSlot().*;

    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notMathAbs", dispatch_name);

    const args = [_]core.JSValue{core.JSValue.int32(-8)};
    const result = try engine.exec.call.callValue(ctx, null, fake, &args);
    defer result.free(rt);
    try std.testing.expectEqual(@as(f64, 8.0), engine.exec.value_ops.numberValue(result).?);

    const fake_key = try rt.internAtom("fake");
    defer rt.atoms.free(fake_key);
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, true, false, true));

    var parsed = try engine.frontend.parser.parse(rt, "print(fake(-8));", .{ .mode = .script, .filename = "native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [16]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false, &.{}, &.{}, &.{}, &.{});
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("8\n", output.buffered());
}

test "native dispatch metadata is internal and ignores user properties" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var f = Object.prototype.isPrototypeOf;
        \\print("__zjs_native_name" in f);
        \\print(Object.getOwnPropertyDescriptor(f, "__zjs_native_name") === undefined);
        \\f.__zjs_native_name = "notIsPrototypeOf";
        \\print(f.call(Object.prototype, {}));
        \\print(delete f.__zjs_native_name);
        \\print(f.call(Object.prototype, {}));
        \\var a = [];
        \\Array.prototype.push.__zjs_native_name = "notPush";
        \\print(Array.prototype.push.call(a, 1));
        \\print(delete Array.prototype.push.__zjs_native_name);
        \\print(Array.prototype.push.call(a, 2));
        \\print(a.length);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false\ntrue\ntrue\ntrue\ntrue\n1\ntrue\n2\n2\n", stream.buffered());
}

test "__zjs-prefixed user properties are ordinary own properties" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var o = {};
        \\o.__zjs_user = 1;
        \\Object.defineProperty(o, "__zjs_non_enum", { value: 2, enumerable: false, configurable: true });
        \\print(Object.getOwnPropertyNames(o).join("|"));
        \\print(Object.getOwnPropertyDescriptors(o).__zjs_user.value);
        \\print(Object.getOwnPropertyDescriptor(o, "__zjs_non_enum").value);
        \\print(Reflect.ownKeys(o).join("|"));
        \\print(Object.keys(o).join("|"));
        \\print("__zjs_user" in o);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("__zjs_user|__zjs_non_enum\n1\n2\n__zjs_user|__zjs_non_enum\n__zjs_user\ntrue\n", stream.buffered());
}

test "array species fast path markers are internal" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var getter = Object.getOwnPropertyDescriptor(Array, Symbol.species).get;
        \\print("__zjs_array_constructor" in Array);
        \\print(Object.getOwnPropertyDescriptor(Array, "__zjs_array_constructor") === undefined);
        \\print("__zjs_array_species_getter" in getter);
        \\print(Object.getOwnPropertyDescriptor(getter, "__zjs_array_species_getter") === undefined);
        \\Array.__zjs_array_constructor = 0;
        \\getter.__zjs_array_species_getter = 0;
        \\var mapped = [1, 2].map(function(value) { return value + 1; });
        \\print(mapped instanceof Array);
        \\print(mapped.join(","));
        \\print(delete Array.__zjs_array_constructor);
        \\print(delete getter.__zjs_array_species_getter);
        \\print([3].filter(function() { return true; }).join(","));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false\ntrue\nfalse\ntrue\ntrue\n2,3\ntrue\ntrue\n3\n", stream.buffered());
}

test "auto-init builtin markers are internal and ignore user properties" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function check(fn, marker, run) {
        \\  print(marker in fn);
        \\  print(Object.getOwnPropertyDescriptor(fn, marker) === undefined);
        \\  fn[marker] = 0;
        \\  print(run());
        \\  print(delete fn[marker]);
        \\  print(run());
        \\}
        \\check(Object.assign, "__zjs_object_static", function() {
        \\  var target = {};
        \\  Object.assign(target, { x: 1 });
        \\  return target.x;
        \\});
        \\check(Object.defineProperty, "__zjs_define_property_kind", function() {
        \\  var object = {};
        \\  Object.defineProperty(object, "x", { value: 1 });
        \\  return object.x;
        \\});
        \\check(Object.prototype.hasOwnProperty, "__zjs_object_method", function() {
        \\  return Object.prototype.hasOwnProperty.call({ x: 1 }, "x");
        \\});
        \\check(String.prototype.includes, "__zjs_string_method", function() {
        \\  return "abc".includes("b");
        \\});
        \\check(Number.prototype.toFixed, "__zjs_number_method", function() {
        \\  return (7).toFixed(0);
        \\});
        \\check(RegExp.prototype.test, "__zjs_regexp_method", function() {
        \\  return /a/.test("a");
        \\});
        \\check(RegExp.escape, "__zjs_regexp_escape", function() {
        \\  return RegExp.escape("a+b") === "\\x61\\+b";
        \\});
        \\check(JSON.parse, "__zjs_json_static", function() {
        \\  return JSON.parse("{\"x\":1}").x;
        \\});
        \\check(JSON.stringify, "__zjs_json_static", function() {
        \\  return JSON.stringify({ x: 1 });
        \\});
        \\check(Reflect.apply, "__zjs_reflect_static", function() {
        \\  return Reflect.apply(function(x) { return x + 1; }, null, [2]);
        \\});
        \\check(Reflect.setPrototypeOf, "__zjs_reflect_set_prototype_of", function() {
        \\  var proto = { x: 1 };
        \\  var object = {};
        \\  return Reflect.setPrototypeOf(object, proto) && object.x;
        \\});
        \\check(Reflect.defineProperty, "__zjs_define_property_kind", function() {
        \\  var object = {};
        \\  return Reflect.defineProperty(object, "x", { value: 1 }) && object.x;
        \\});
        \\check(Atomics.isLockFree, "__zjs_atomics_static", function() {
        \\  return Atomics.isLockFree(4);
        \\});
        \\check(Array.prototype.concat, "__zjs_array_concat", function() {
        \\  return [1].concat([2]).join(",");
        \\});
        \\check(ArrayBuffer.prototype.slice, "__zjs_buffer_method_kind", function() {
        \\  return new ArrayBuffer(4).slice(1).byteLength;
        \\});
        \\check(SharedArrayBuffer.prototype.slice, "__zjs_buffer_method_kind", function() {
        \\  return new SharedArrayBuffer(4).slice(1).byteLength;
        \\});
        \\check(Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, "byteLength").get, "__zjs_buffer_accessor_kind", function() {
        \\  return new ArrayBuffer(4).byteLength;
        \\});
        \\check(Object.getOwnPropertyDescriptor(SharedArrayBuffer.prototype, "byteLength").get, "__zjs_buffer_accessor_kind", function() {
        \\  return new SharedArrayBuffer(4).byteLength;
        \\});
        \\check(Object.getOwnPropertyDescriptor(DataView.prototype, "byteLength").get, "__zjs_dataview_accessor", function() {
        \\  return new DataView(new ArrayBuffer(6), 1, 3).byteLength;
        \\});
        \\check(Object.getOwnPropertyDescriptor(Object.getPrototypeOf(Uint8Array.prototype), "length").get, "__zjs_typedarray_accessor", function() {
        \\  return new Uint8Array(5).length;
        \\});
        \\check(Uint8Array.prototype.slice, "__zjs_typedarray_method", function() {
        \\  return new Uint8Array([1, 2]).slice(1)[0];
        \\});
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "false\ntrue\n1\ntrue\n1\n" ++
            "false\ntrue\n1\ntrue\n1\n" ++
            "false\ntrue\ntrue\ntrue\ntrue\n" ++
            "false\ntrue\ntrue\ntrue\ntrue\n" ++
            "false\ntrue\n7\ntrue\n7\n" ++
            "false\ntrue\ntrue\ntrue\ntrue\n" ++
            "false\ntrue\ntrue\ntrue\ntrue\n" ++
            "false\ntrue\n1\ntrue\n1\n" ++
            "false\ntrue\n{\"x\":1}\ntrue\n{\"x\":1}\n" ++
            "false\ntrue\n3\ntrue\n3\n" ++
            "false\ntrue\n1\ntrue\n1\n" ++
            "false\ntrue\n1\ntrue\n1\n" ++
            "false\ntrue\ntrue\ntrue\ntrue\n" ++
            "false\ntrue\n1,2\ntrue\n1,2\n" ++
            "false\ntrue\n3\ntrue\n3\n" ++
            "false\ntrue\n3\ntrue\n3\n" ++
            "false\ntrue\n4\ntrue\n4\n" ++
            "false\ntrue\n4\ntrue\n4\n" ++
            "false\ntrue\n3\ntrue\n3\n" ++
            "false\ntrue\n5\ntrue\n5\n" ++
            "false\ntrue\n2\ntrue\n2\n",
        stream.buffered(),
    );
}

test "immutable prototype marker is internal" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print("__zjs_immutable_prototype" in Object.prototype);
        \\print(Object.getOwnPropertyDescriptor(Object.prototype, "__zjs_immutable_prototype") === undefined);
        \\Object.prototype.__zjs_immutable_prototype = false;
        \\print(Reflect.setPrototypeOf(Object.prototype, {}));
        \\try { Object.setPrototypeOf(Object.prototype, {}); print("no throw"); } catch (e) { print(e.name); }
        \\print(delete Object.prototype.__zjs_immutable_prototype);
        \\print(Reflect.setPrototypeOf(Object.prototype, null));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false\ntrue\nfalse\nTypeError\ntrue\ntrue\n", stream.buffered());
}

test "builtin dispatch function markers are internal" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function check(fn, marker, run) {
        \\  print(marker in fn);
        \\  print(Object.getOwnPropertyDescriptor(fn, marker) === undefined);
        \\  fn[marker] = 0;
        \\  print(run());
        \\  print(delete fn[marker]);
        \\  print(run());
        \\}
        \\check(Function.prototype.toString, "__zjs_function_to_string", function() {
        \\  return typeof Function.prototype.toString.call(Array.prototype.push);
        \\});
        \\check(Error.prototype.toString, "__zjs_error_to_string", function() {
        \\  return Error.prototype.toString.call({ name: "E", message: "m" });
        \\});
        \\var constructorDesc = Object.getOwnPropertyDescriptor(Iterator.prototype, "constructor");
        \\var tagDesc = Object.getOwnPropertyDescriptor(Iterator.prototype, Symbol.toStringTag);
        \\check(constructorDesc.get, "__zjs_iterator_accessor", function() {
        \\  return constructorDesc.get.call(Iterator.prototype) === Iterator;
        \\});
        \\check(tagDesc.get, "__zjs_iterator_accessor", function() {
        \\  return tagDesc.get.call(Iterator.prototype);
        \\});
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "false\ntrue\nstring\ntrue\nstring\n" ++
            "false\ntrue\nE: m\ntrue\nE: m\n" ++
            "false\ntrue\ntrue\ntrue\ntrue\n" ++
            "false\ntrue\nIterator\ntrue\nIterator\n",
        stream.buffered(),
    );
}

test "proxy revocation target is internal" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var r = Proxy.revocable({ x: 1 }, {});
        \\var revoke = r.revoke;
        \\print("__zjs_revoke_proxy" in revoke);
        \\print(Object.getOwnPropertyDescriptor(revoke, "__zjs_revoke_proxy") === undefined);
        \\revoke.__zjs_revoke_proxy = null;
        \\print(revoke.__zjs_revoke_proxy === null);
        \\revoke();
        \\var threw = false;
        \\try {
        \\  r.proxy.x;
        \\} catch (e) {
        \\  threw = e instanceof TypeError;
        \\}
        \\print(threw);
        \\print(delete revoke.__zjs_revoke_proxy);
        \\print("__zjs_revoke_proxy" in revoke);
        \\var r2 = Proxy.revocable({ y: 2 }, {});
        \\print(delete r2.revoke.__zjs_revoke_proxy);
        \\r2.revoke();
        \\var threw2 = false;
        \\try {
        \\  r2.proxy.y;
        \\} catch (e) {
        \\  threw2 = e instanceof TypeError;
        \\}
        \\print(threw2);
        \\r2.revoke();
        \\print("done");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false\ntrue\ntrue\ntrue\ntrue\nfalse\ntrue\ntrue\ndone\n", stream.buffered());
}

test "regexp accessor realm TypeError constructor is internal" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var getter = Object.getOwnPropertyDescriptor(RegExp.prototype, "source").get;
        \\print("__zjs_realm_TypeError" in getter);
        \\print(Object.getOwnPropertyDescriptor(getter, "__zjs_realm_TypeError") === undefined);
        \\function Fake(message) {
        \\  this.message = message;
        \\}
        \\Fake.prototype = Object.create(Error.prototype);
        \\Fake.prototype.constructor = Fake;
        \\getter.__zjs_realm_TypeError = Fake;
        \\try {
        \\  getter.call({});
        \\} catch (e) {
        \\  print(e.constructor === Fake);
        \\  print(e instanceof TypeError);
        \\}
        \\print(delete getter.__zjs_realm_TypeError);
        \\try {
        \\  getter.call({});
        \\} catch (e) {
        \\  print(e instanceof TypeError);
        \\}
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false\ntrue\nfalse\ntrue\ntrue\ntrue\n", stream.buffered());
}

test "throw type error intrinsic marker is internal" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\"use strict";
        \\print("__zjs_throw_type_error_intrinsic" in globalThis);
        \\print(Object.getOwnPropertyDescriptor(globalThis, "__zjs_throw_type_error_intrinsic") === undefined);
        \\globalThis.__zjs_throw_type_error_intrinsic = function() { return 1; };
        \\print("__zjs_throw_type_error_intrinsic" in globalThis);
        \\print(delete globalThis.__zjs_throw_type_error_intrinsic);
        \\print("__zjs_throw_type_error_intrinsic" in globalThis);
        \\var thrower = Object.getOwnPropertyDescriptor(Function.prototype, "arguments").get;
        \\print(typeof thrower);
        \\print("__zjs_throw_type_error_function_proto" in thrower);
        \\print(Object.getOwnPropertyDescriptor(thrower, "__zjs_throw_type_error_function_proto") === undefined);
        \\var assignType = "none";
        \\try {
        \\  thrower.__zjs_throw_type_error_function_proto = false;
        \\} catch (e) {
        \\  assignType = e.name;
        \\}
        \\print(assignType);
        \\print("__zjs_throw_type_error_function_proto" in thrower);
        \\print(delete thrower.__zjs_throw_type_error_function_proto);
        \\var threw = false;
        \\try {
        \\  thrower();
        \\} catch (e) {
        \\  threw = e instanceof TypeError;
        \\}
        \\print(threw);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false\ntrue\ntrue\ntrue\nfalse\nfunction\nfalse\ntrue\nTypeError\nfalse\ntrue\ntrue\n", stream.buffered());

    const probe_result = try js.eval("globalThis.__thrower_probe = Object.getOwnPropertyDescriptor(Function.prototype, \"arguments\").get;");
    defer probe_result.free(js.runtime);
    try std.testing.expect(js.context.global != null);
    const global = js.context.global.?;
    const probe_key = try js.runtime.internAtom("__thrower_probe");
    defer js.runtime.atoms.free(probe_key);
    const thrower_value = global.getProperty(probe_key);
    defer thrower_value.free(js.runtime);
    const thrower_object = try property_ops.expectObject(thrower_value);
    const dispatch_atom = thrower_object.nativeDispatchName();
    try std.testing.expect(dispatch_atom != core.atom.null_atom);
    const dispatch_name = js.runtime.atoms.name(dispatch_atom);
    try std.testing.expect(dispatch_name != null);
    try std.testing.expectEqualStrings("", dispatch_name.?);
}

test "async generator prototype method marker is internal" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\async function* g() {}
        \\var AsyncGeneratorPrototype = Object.getPrototypeOf(g.prototype);
        \\var next = AsyncGeneratorPrototype.next;
        \\print("__zjs_async_generator_method" in next);
        \\print(Object.getOwnPropertyDescriptor(next, "__zjs_async_generator_method") === undefined);
        \\next.__zjs_async_generator_method = 0;
        \\print("__zjs_async_generator_method" in next);
        \\print(delete next.__zjs_async_generator_method);
        \\print("__zjs_async_generator_method" in next);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false\ntrue\ntrue\ntrue\nfalse\n", stream.buffered());
}

test "iterator helper method marker is internal" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function printLayout(label, helper) {
        \\  var proto = Object.getPrototypeOf(helper);
        \\  print(label);
        \\  print(Object.prototype.toString.call(helper));
        \\  print("own:" + Object.getOwnPropertyNames(helper).join(","));
        \\  print("proto:" + Object.getOwnPropertyNames(proto).join(","));
        \\  print(helper.hasOwnProperty("next"));
        \\  print(typeof proto.next);
        \\  print(helper.next === proto.next);
        \\}
        \\function check(fn, marker, run) {
        \\  print(marker in fn);
        \\  print(Object.getOwnPropertyDescriptor(fn, marker) === undefined);
        \\  fn[marker] = 0;
        \\  print(marker in fn);
        \\  print(run());
        \\  print(delete fn[marker]);
        \\  print(marker in fn);
        \\  print(run());
        \\}
        \\var helper = Iterator.from([1]).map(function(x) { return x + 1; });
        \\printLayout("map", helper);
        \\printLayout("concat", Iterator.concat([1]));
        \\printLayout("zip", Iterator.zip([[1], [2]]));
        \\var next = helper.next;
        \\check(next, "__zjs_iterator_helper_method", function() {
        \\  var h = Iterator.from([1]).map(function(x) { return x + 1; });
        \\  return next.call(h).value;
        \\});
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "map\n[object Iterator Helper]\nown:\nproto:next,return\nfalse\nfunction\ntrue\n" ++
            "concat\n[object Iterator Concat]\nown:\nproto:next,return\nfalse\nfunction\ntrue\n" ++
            "zip\n[object Iterator Helper]\nown:next,return\nproto:next,return\ntrue\nfunction\nfalse\n" ++
            "false\ntrue\ntrue\n2\ntrue\nfalse\n2\n",
        stream.buffered(),
    );
}

test "Iterator.from follows QuickJS wrapper selection" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var count = 0;
        \\var iterable = {
        \\  [Symbol.iterator]: function() { return this; },
        \\  get next() {
        \\    count++;
        \\    return function() { return { done: true, value: 1 }; };
        \\  },
        \\};
        \\var fromIterable = Iterator.from(iterable);
        \\print(fromIterable === iterable);
        \\print(count);
        \\fromIterable.next();
        \\print(count);
        \\print(typeof fromIterable.map);
        \\var sealed = Object.preventExtensions({
        \\  next: function() { return { done: true }; },
        \\});
        \\var wrapped = Iterator.from(sealed);
        \\print(wrapped === sealed);
        \\var wrapProto = Object.getPrototypeOf(wrapped);
        \\print("__zjs_iterator_wrap_method" in wrapProto.next);
        \\print(Object.getOwnPropertyDescriptor(wrapProto.next, "__zjs_iterator_wrap_method") === undefined);
        \\print("__zjs_iterator_wrap_method" in wrapProto.return);
        \\print(Object.getOwnPropertyDescriptor(wrapProto.return, "__zjs_iterator_wrap_method") === undefined);
        \\wrapProto.next.__zjs_iterator_wrap_method = 2;
        \\print(wrapped.next().done);
        \\print(wrapped.next().value);
        \\print(delete wrapProto.next.__zjs_iterator_wrap_method);
        \\print(wrapped.next().value);
        \\wrapProto.return.__zjs_iterator_wrap_method = 1;
        \\print(wrapped.return().done);
        \\print(delete wrapProto.return.__zjs_iterator_wrap_method);
        \\print(wrapped.return().done);
        \\print("__zjs_iterator_next" in wrapped);
        \\print(Object.getOwnPropertyDescriptor(wrapped, "__zjs_iterator_next") === undefined);
        \\wrapped.__zjs_iterator_next = function() { return { done: false, value: 99 }; };
        \\print(wrapped.next().value);
        \\print(delete wrapped.__zjs_iterator_next);
        \\print("__zjs_iterator_next" in wrapped);
        \\var bad = Iterator.from({ next: 1 });
        \\print(typeof bad);
        \\try {
        \\  bad.next();
        \\} catch (e) {
        \\  print(e.name);
        \\}
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\n0\n1\nundefined\nfalse\nfalse\ntrue\nfalse\ntrue\ntrue\nundefined\ntrue\nundefined\ntrue\ntrue\ntrue\nfalse\ntrue\nundefined\ntrue\nfalse\nobject\nTypeError\n", stream.buffered());
}

test "number native builtin records cover static and prototype dispatch" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try engine.exec.call.installHostGlobals(rt, global);

    const number_key = try rt.internAtom("Number");
    defer rt.atoms.free(number_key);
    const is_integer_key = try rt.internAtom("isInteger");
    defer rt.atoms.free(is_integer_key);
    const prototype_key = core.atom.ids.prototype;
    const to_fixed_key = try rt.internAtom("toFixed");
    defer rt.atoms.free(to_fixed_key);

    const number_value = global.getProperty(number_key);
    defer number_value.free(rt);
    const number_object: *core.Object = @fieldParentPtr("header", number_value.refHeader().?);

    const is_integer_value = number_object.getProperty(is_integer_key);
    defer is_integer_value.free(rt);
    const is_integer_object: *core.Object = @fieldParentPtr("header", is_integer_value.refHeader().?);
    try std.testing.expect(is_integer_object.nativeFunctionIdSlot().* != 0);

    const fake_static = try engine.builtins.function.nativeFunction(rt, "notNumberIsInteger", 1);
    defer fake_static.free(rt);
    const fake_static_object: *core.Object = @fieldParentPtr("header", fake_static.refHeader().?);
    fake_static_object.nativeFunctionIdSlot().* = is_integer_object.nativeFunctionIdSlot().*;
    const static_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_static_object);
    defer rt.memory.allocator.free(static_dispatch_name);
    try std.testing.expectEqualStrings("notNumberIsInteger", static_dispatch_name);
    const static_args = [_]core.JSValue{core.JSValue.float64(3.5)};
    const static_result = try engine.exec.call.callValue(ctx, null, fake_static, &static_args);
    defer static_result.free(rt);
    try std.testing.expectEqual(false, static_result.asBool().?);

    const prototype_value = number_object.getProperty(prototype_key);
    defer prototype_value.free(rt);
    const prototype_object: *core.Object = @fieldParentPtr("header", prototype_value.refHeader().?);
    const to_fixed_value = prototype_object.getProperty(to_fixed_key);
    defer to_fixed_value.free(rt);
    const to_fixed_object: *core.Object = @fieldParentPtr("header", to_fixed_value.refHeader().?);
    try std.testing.expect(to_fixed_object.nativeFunctionIdSlot().* != 0);

    const fake_proto = try engine.builtins.function.nativeFunction(rt, "notNumberToFixed", 1);
    defer fake_proto.free(rt);
    const fake_proto_object: *core.Object = @fieldParentPtr("header", fake_proto.refHeader().?);
    fake_proto_object.nativeFunctionIdSlot().* = to_fixed_object.nativeFunctionIdSlot().*;
    const proto_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_proto_object);
    defer rt.memory.allocator.free(proto_dispatch_name);
    try std.testing.expectEqualStrings("notNumberToFixed", proto_dispatch_name);
    const fixed_args = [_]core.JSValue{core.JSValue.int32(2)};
    const proto_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, core.JSValue.float64(1.25), fake_proto, &fixed_args);
    defer proto_result.free(rt);
    const proto_string: *core.string.String = @fieldParentPtr("header", proto_result.refHeader().?);
    try std.testing.expect(proto_string.eqlBytes("1.25"));

    const fake_static_key = try rt.internAtom("fakeStatic");
    defer rt.atoms.free(fake_static_key);
    try global.defineOwnProperty(rt, fake_static_key, core.Descriptor.data(fake_static, true, false, true));
    const fake_proto_key = try rt.internAtom("fakeProto");
    defer rt.atoms.free(fake_proto_key);
    try global.defineOwnProperty(rt, fake_proto_key, core.Descriptor.data(fake_proto, true, false, true));

    var parsed = try engine.frontend.parser.parse(rt, "print(fakeStatic(3.5)); print(fakeProto.call(1.25, 2));", .{ .mode = .script, .filename = "number-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [32]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false, &.{}, &.{}, &.{}, &.{});
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("false\n1.25\n", output.buffered());
}

test "string static native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try engine.exec.call.installHostGlobals(rt, global);

    const string_key = try rt.internAtom("String");
    defer rt.atoms.free(string_key);
    const from_code_point_key = try rt.internAtom("fromCodePoint");
    defer rt.atoms.free(from_code_point_key);
    const string_value = global.getProperty(string_key);
    defer string_value.free(rt);
    const string_object: *core.Object = @fieldParentPtr("header", string_value.refHeader().?);
    const from_code_point_value = string_object.getProperty(from_code_point_key);
    defer from_code_point_value.free(rt);
    const from_code_point_object: *core.Object = @fieldParentPtr("header", from_code_point_value.refHeader().?);
    try std.testing.expect(from_code_point_object.nativeFunctionIdSlot().* != 0);

    const fake = try engine.builtins.function.nativeFunction(rt, "notStringFromCodePoint", 1);
    defer fake.free(rt);
    const fake_object: *core.Object = @fieldParentPtr("header", fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = from_code_point_object.nativeFunctionIdSlot().*;
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notStringFromCodePoint", dispatch_name);

    const args = [_]core.JSValue{core.JSValue.int32(0x41)};
    const result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, core.JSValue.undefinedValue(), fake, &args);
    defer result.free(rt);
    const result_string: *core.string.String = @fieldParentPtr("header", result.refHeader().?);
    try std.testing.expect(result_string.eqlBytes("A"));

    const fake_key = try rt.internAtom("fakeStringStatic");
    defer rt.atoms.free(fake_key);
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, true, false, true));

    var parsed = try engine.frontend.parser.parse(rt, "print(fakeStringStatic({ valueOf: function(){ return 0x42; } }));", .{ .mode = .script, .filename = "string-static-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [8]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false, &.{}, &.{}, &.{}, &.{});
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("B\n", output.buffered());
}

test "string prototype native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try engine.exec.call.installHostGlobals(rt, global);

    const string_key = try rt.internAtom("String");
    defer rt.atoms.free(string_key);
    const index_of_key = try rt.internAtom("indexOf");
    defer rt.atoms.free(index_of_key);
    const string_value = global.getProperty(string_key);
    defer string_value.free(rt);
    const string_object: *core.Object = @fieldParentPtr("header", string_value.refHeader().?);
    const prototype_value = string_object.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    const prototype_object: *core.Object = @fieldParentPtr("header", prototype_value.refHeader().?);
    const index_of_value = prototype_object.getProperty(index_of_key);
    defer index_of_value.free(rt);
    const index_of_object: *core.Object = @fieldParentPtr("header", index_of_value.refHeader().?);
    try std.testing.expect(index_of_object.nativeFunctionIdSlot().* != 0);

    const fake = try engine.builtins.function.nativeFunction(rt, "notStringIndexOf", 1);
    defer fake.free(rt);
    const fake_object: *core.Object = @fieldParentPtr("header", fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = index_of_object.nativeFunctionIdSlot().*;
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notStringIndexOf", dispatch_name);

    const needle_string = try core.string.String.createUtf8(rt, "n");
    defer needle_string.value().free(rt);
    const receiver_string = try core.string.String.createUtf8(rt, "banana");
    defer receiver_string.value().free(rt);
    const direct_args = [_]core.JSValue{ needle_string.value(), core.JSValue.int32(3) };
    const direct_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver_string.value(), fake, &direct_args);
    defer direct_result.free(rt);
    try std.testing.expectEqual(@as(i32, 4), direct_result.asInt32().?);

    const fake_key = try rt.internAtom("fakeStringIndexOf");
    defer rt.atoms.free(fake_key);
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, true, false, true));

    var parsed = try engine.frontend.parser.parse(rt, "print(fakeStringIndexOf.call('banana', 'n', { valueOf: function(){ return 3; } }));", .{ .mode = .script, .filename = "string-prototype-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [8]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false, &.{}, &.{}, &.{}, &.{});
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("4\n", output.buffered());
}

test "date static native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try engine.exec.call.installHostGlobals(rt, global);

    const date_key = try rt.internAtom("Date");
    defer rt.atoms.free(date_key);
    const utc_key = try rt.internAtom("UTC");
    defer rt.atoms.free(utc_key);
    const date_value = global.getProperty(date_key);
    defer date_value.free(rt);
    const date_object: *core.Object = @fieldParentPtr("header", date_value.refHeader().?);
    const utc_value = date_object.getProperty(utc_key);
    defer utc_value.free(rt);
    const utc_object: *core.Object = @fieldParentPtr("header", utc_value.refHeader().?);
    try std.testing.expect(utc_object.nativeFunctionIdSlot().* != 0);

    const fake = try engine.builtins.function.nativeFunction(rt, "notDateUTC", 7);
    defer fake.free(rt);
    const fake_object: *core.Object = @fieldParentPtr("header", fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = utc_object.nativeFunctionIdSlot().*;
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notDateUTC", dispatch_name);

    const args = [_]core.JSValue{ core.JSValue.int32(2024), core.JSValue.int32(0), core.JSValue.int32(1) };
    const result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, core.JSValue.undefinedValue(), fake, &args);
    defer result.free(rt);
    try std.testing.expectEqual(@as(f64, 1704067200000), engine.exec.value_ops.numberValue(result).?);

    const fake_key = try rt.internAtom("fakeDateUTC");
    defer rt.atoms.free(fake_key);
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, true, false, true));

    var parsed = try engine.frontend.parser.parse(rt, "print(fakeDateUTC({ valueOf: function(){ return 2024; } }, 0, 1));", .{ .mode = .script, .filename = "date-static-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [24]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false, &.{}, &.{}, &.{}, &.{});
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("1704067200000\n", output.buffered());
}

test "date constructor native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try engine.exec.call.installHostGlobals(rt, global);

    const date_key = try rt.internAtom("Date");
    defer rt.atoms.free(date_key);
    const date_value = global.getProperty(date_key);
    defer date_value.free(rt);
    const date_object: *core.Object = @fieldParentPtr("header", date_value.refHeader().?);
    try std.testing.expect(date_object.nativeFunctionIdSlot().* != 0);

    const fake = try engine.builtins.function.nativeFunction(rt, "notDateConstructor", 7);
    defer fake.free(rt);
    const fake_object: *core.Object = @fieldParentPtr("header", fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = date_object.nativeFunctionIdSlot().*;
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notDateConstructor", dispatch_name);

    const prototype_value = date_object.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    try fake_object.defineOwnProperty(rt, core.atom.ids.prototype, core.Descriptor.data(prototype_value, true, false, true));

    const call_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, core.JSValue.undefinedValue(), fake, &.{});
    defer call_result.free(rt);
    var call_buffer = std.ArrayList(u8).empty;
    defer call_buffer.deinit(rt.memory.allocator);
    try engine.exec.value_ops.appendRawString(rt, &call_buffer, call_result);
    try std.testing.expect(std.mem.indexOf(u8, call_buffer.items, "GMT+0000") != null);

    const construct_result = try engine.exec.construct.constructValue(rt, fake, &.{core.JSValue.int32(1)}, &.{});
    defer construct_result.free(rt);
    const construct_ms = try engine.builtins.date.methodCall(rt, construct_result, 1);
    defer construct_ms.free(rt);
    try std.testing.expectEqual(@as(f64, 1), engine.exec.value_ops.numberValue(construct_ms).?);

    const fake_key = try rt.internAtom("fakeDateConstructor");
    defer rt.atoms.free(fake_key);
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, true, false, true));

    var parsed = try engine.frontend.parser.parse(rt,
        \\const d = new fakeDateConstructor({ valueOf: function(){ return 2; } });
        \\print(d instanceof Date);
        \\print(d.getTime());
        \\print(fakeDateConstructor().indexOf('GMT+0000') >= 0);
        \\print(Reflect.construct(fakeDateConstructor, [3], Date).getTime());
    , .{ .mode = .script, .filename = "date-constructor-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false, &.{}, &.{}, &.{}, &.{});
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("true\n2\ntrue\n3\n", output.buffered());
}

test "constructValue AggregateError releases copied errors array owner" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("AggregateError");
    defer rt.atoms.free(name);
    const constructor = try engine.exec.construct.functionObject(rt, name);
    defer constructor.free(rt);

    const source = try core.Object.createArray(rt, null);
    defer source.value().free(rt);
    try source.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(core.JSValue.int32(1), true, true, true));
    try source.defineOwnProperty(rt, core.atom.atomFromUInt32(1), core.Descriptor.data(core.JSValue.int32(2), true, true, true));
    source.length = 2;
    try source.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(2), true, false, false));

    const baseline_objects = rt.gc.liveCount();
    const result = try engine.exec.construct.constructValue(rt, constructor, &.{source.value()}, &.{});
    result.free(rt);
    _ = rt.runObjectCycleRemoval();

    try std.testing.expectEqual(baseline_objects, rt.gc.liveCount());
}

test "date prototype native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try engine.exec.call.installHostGlobals(rt, global);

    const date_key = try rt.internAtom("Date");
    defer rt.atoms.free(date_key);
    const set_time_key = try rt.internAtom("setTime");
    defer rt.atoms.free(set_time_key);
    const date_value = global.getProperty(date_key);
    defer date_value.free(rt);
    const date_object: *core.Object = @fieldParentPtr("header", date_value.refHeader().?);
    const prototype_value = date_object.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    const prototype_object: *core.Object = @fieldParentPtr("header", prototype_value.refHeader().?);
    const set_time_value = prototype_object.getProperty(set_time_key);
    defer set_time_value.free(rt);
    const set_time_object: *core.Object = @fieldParentPtr("header", set_time_value.refHeader().?);
    try std.testing.expect(set_time_object.nativeFunctionIdSlot().* != 0);

    const fake = try engine.builtins.function.nativeFunction(rt, "notDateSetTime", 1);
    defer fake.free(rt);
    const fake_object: *core.Object = @fieldParentPtr("header", fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = set_time_object.nativeFunctionIdSlot().*;
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notDateSetTime", dispatch_name);

    const direct_receiver = try engine.builtins.date.construct(rt, &.{core.JSValue.int32(0)});
    defer direct_receiver.free(rt);
    const direct_args = [_]core.JSValue{core.JSValue.int32(1)};
    const direct_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, direct_receiver, fake, &direct_args);
    defer direct_result.free(rt);
    try std.testing.expectEqual(@as(f64, 1), engine.exec.value_ops.numberValue(direct_result).?);

    const fake_key = try rt.internAtom("fakeDateSetTime");
    defer rt.atoms.free(fake_key);
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, true, false, true));

    var parsed = try engine.frontend.parser.parse(rt, "const d = new Date(0); print(fakeDateSetTime.call(d, { valueOf: function(){ return 1704067200000; } })); print(d.getTime());", .{ .mode = .script, .filename = "date-prototype-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [48]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false, &.{}, &.{}, &.{}, &.{});
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("1704067200000\n1704067200000\n", output.buffered());
}

test "array static native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try engine.exec.call.installHostGlobals(rt, global);

    const array_key = try rt.internAtom("Array");
    defer rt.atoms.free(array_key);
    const is_array_key = try rt.internAtom("isArray");
    defer rt.atoms.free(is_array_key);
    const from_key = try rt.internAtom("from");
    defer rt.atoms.free(from_key);
    const array_value = global.getProperty(array_key);
    defer array_value.free(rt);
    const array_object: *core.Object = @fieldParentPtr("header", array_value.refHeader().?);
    const is_array_value = array_object.getProperty(is_array_key);
    defer is_array_value.free(rt);
    const is_array_object: *core.Object = @fieldParentPtr("header", is_array_value.refHeader().?);
    try std.testing.expect(is_array_object.nativeFunctionIdSlot().* != 0);
    const from_value = array_object.getProperty(from_key);
    defer from_value.free(rt);
    const from_object: *core.Object = @fieldParentPtr("header", from_value.refHeader().?);
    try std.testing.expect(from_object.nativeFunctionIdSlot().* != 0);

    const fake_is_array = try engine.builtins.function.nativeFunction(rt, "notArrayIsArray", 1);
    defer fake_is_array.free(rt);
    const fake_is_array_object: *core.Object = @fieldParentPtr("header", fake_is_array.refHeader().?);
    fake_is_array_object.nativeFunctionIdSlot().* = is_array_object.nativeFunctionIdSlot().*;
    const is_array_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_is_array_object);
    defer rt.memory.allocator.free(is_array_dispatch_name);
    try std.testing.expectEqualStrings("notArrayIsArray", is_array_dispatch_name);

    const direct_array = try engine.builtins.array.construct(rt, &.{core.JSValue.int32(1)});
    defer direct_array.free(rt);
    const direct_is_array_args = [_]core.JSValue{direct_array};
    const is_array_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, core.JSValue.undefinedValue(), fake_is_array, &direct_is_array_args);
    defer is_array_result.free(rt);
    try std.testing.expectEqual(true, is_array_result.asBool().?);

    const fake_from = try engine.builtins.function.nativeFunction(rt, "notArrayFrom", 1);
    defer fake_from.free(rt);
    const fake_from_object: *core.Object = @fieldParentPtr("header", fake_from.refHeader().?);
    fake_from_object.nativeFunctionIdSlot().* = from_object.nativeFunctionIdSlot().*;
    const from_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_from_object);
    defer rt.memory.allocator.free(from_dispatch_name);
    try std.testing.expectEqualStrings("notArrayFrom", from_dispatch_name);

    const direct_from_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, array_value, fake_from, &direct_is_array_args);
    defer direct_from_result.free(rt);
    const direct_from_array: *core.Object = @fieldParentPtr("header", direct_from_result.refHeader().?);
    try std.testing.expect(direct_from_array.is_array);
    try std.testing.expectEqual(@as(u32, 1), direct_from_array.length);

    const fake_is_array_key = try rt.internAtom("fakeArrayIsArray");
    defer rt.atoms.free(fake_is_array_key);
    try global.defineOwnProperty(rt, fake_is_array_key, core.Descriptor.data(fake_is_array, true, false, true));
    const fake_from_key = try rt.internAtom("fakeArrayFrom");
    defer rt.atoms.free(fake_from_key);
    try global.defineOwnProperty(rt, fake_from_key, core.Descriptor.data(fake_from, true, false, true));

    var parsed = try engine.frontend.parser.parse(rt, "print(fakeArrayIsArray([])); print(fakeArrayFrom.call(Array, [7, 8]).join(','));", .{ .mode = .script, .filename = "array-static-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [24]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false, &.{}, &.{}, &.{}, &.{});
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("true\n7,8\n", output.buffered());
}

test "array prototype native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try engine.exec.call.installHostGlobals(rt, global);

    const array_key = try rt.internAtom("Array");
    defer rt.atoms.free(array_key);
    const prototype_key = try rt.internAtom("prototype");
    defer rt.atoms.free(prototype_key);
    const to_string_key = try rt.internAtom("toString");
    defer rt.atoms.free(to_string_key);
    const join_key = try rt.internAtom("join");
    defer rt.atoms.free(join_key);
    const map_key = try rt.internAtom("map");
    defer rt.atoms.free(map_key);
    const values_key = try rt.internAtom("values");
    defer rt.atoms.free(values_key);
    const array_value = global.getProperty(array_key);
    defer array_value.free(rt);
    const array_object: *core.Object = @fieldParentPtr("header", array_value.refHeader().?);
    const prototype_value = array_object.getProperty(prototype_key);
    defer prototype_value.free(rt);
    const prototype_object: *core.Object = @fieldParentPtr("header", prototype_value.refHeader().?);

    const to_string_value = prototype_object.getProperty(to_string_key);
    defer to_string_value.free(rt);
    const to_string_object: *core.Object = @fieldParentPtr("header", to_string_value.refHeader().?);
    try std.testing.expect(to_string_object.nativeFunctionIdSlot().* != 0);
    const join_value = prototype_object.getProperty(join_key);
    defer join_value.free(rt);
    const join_object: *core.Object = @fieldParentPtr("header", join_value.refHeader().?);
    try std.testing.expect(join_object.nativeFunctionIdSlot().* != 0);
    const map_value = prototype_object.getProperty(map_key);
    defer map_value.free(rt);
    const map_object: *core.Object = @fieldParentPtr("header", map_value.refHeader().?);
    try std.testing.expect(map_object.nativeFunctionIdSlot().* != 0);
    const values_value = prototype_object.getProperty(values_key);
    defer values_value.free(rt);
    const values_object: *core.Object = @fieldParentPtr("header", values_value.refHeader().?);
    try std.testing.expect(values_object.nativeFunctionIdSlot().* != 0);

    const fake_join = try engine.builtins.function.nativeFunction(rt, "notArrayJoin", 1);
    defer fake_join.free(rt);
    const fake_join_object: *core.Object = @fieldParentPtr("header", fake_join.refHeader().?);
    fake_join_object.nativeFunctionIdSlot().* = join_object.nativeFunctionIdSlot().*;
    const join_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_join_object);
    defer rt.memory.allocator.free(join_dispatch_name);
    try std.testing.expectEqualStrings("notArrayJoin", join_dispatch_name);

    const direct_array = try engine.builtins.array.constructWithPrototype(rt, &.{ core.JSValue.int32(1), core.JSValue.int32(2) }, prototype_object);
    defer direct_array.free(rt);
    const separator = (try core.string.String.createUtf8(rt, ":")).value();
    defer separator.free(rt);
    const join_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, direct_array, fake_join, &.{separator});
    defer join_result.free(rt);
    var join_text = std.ArrayList(u8).empty;
    defer join_text.deinit(rt.memory.allocator);
    try engine.exec.value_ops.appendRawString(rt, &join_text, join_result);
    try std.testing.expectEqualStrings("1:2", join_text.items);

    const fake_to_string = try engine.builtins.function.nativeFunction(rt, "notArrayToString", 0);
    defer fake_to_string.free(rt);
    const fake_to_string_object: *core.Object = @fieldParentPtr("header", fake_to_string.refHeader().?);
    fake_to_string_object.nativeFunctionIdSlot().* = to_string_object.nativeFunctionIdSlot().*;
    const to_string_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, direct_array, fake_to_string, &.{});
    defer to_string_result.free(rt);
    var to_string_text = std.ArrayList(u8).empty;
    defer to_string_text.deinit(rt.memory.allocator);
    try engine.exec.value_ops.appendRawString(rt, &to_string_text, to_string_result);
    try std.testing.expectEqualStrings("1,2", to_string_text.items);

    const fake_map = try engine.builtins.function.nativeFunction(rt, "notArrayMap", 1);
    defer fake_map.free(rt);
    const fake_map_object: *core.Object = @fieldParentPtr("header", fake_map.refHeader().?);
    fake_map_object.nativeFunctionIdSlot().* = map_object.nativeFunctionIdSlot().*;
    const fake_values = try engine.builtins.function.nativeFunction(rt, "notArrayValues", 0);
    defer fake_values.free(rt);
    const fake_values_object: *core.Object = @fieldParentPtr("header", fake_values.refHeader().?);
    fake_values_object.nativeFunctionIdSlot().* = values_object.nativeFunctionIdSlot().*;

    const fake_map_key = try rt.internAtom("fakeArrayMap");
    defer rt.atoms.free(fake_map_key);
    try global.defineOwnProperty(rt, fake_map_key, core.Descriptor.data(fake_map, true, false, true));
    const fake_values_key = try rt.internAtom("fakeArrayValues");
    defer rt.atoms.free(fake_values_key);
    try global.defineOwnProperty(rt, fake_values_key, core.Descriptor.data(fake_values, true, false, true));

    var parsed = try engine.frontend.parser.parse(rt, "print(fakeArrayMap.call([1,2], function(v){ return v + 1; }).join(',')); const it = fakeArrayValues.call([9]); print(it.next().value);", .{ .mode = .script, .filename = "array-prototype-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [24]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false, &.{}, &.{}, &.{}, &.{});
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("2,3\n9\n", output.buffered());
}

test "collection native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try engine.exec.call.installHostGlobals(rt, global);

    const map_key = try rt.internAtom("Map");
    defer rt.atoms.free(map_key);
    const set_key = try rt.internAtom("Set");
    defer rt.atoms.free(set_key);
    const prototype_key = try rt.internAtom("prototype");
    defer rt.atoms.free(prototype_key);
    const group_by_key = try rt.internAtom("groupBy");
    defer rt.atoms.free(group_by_key);
    const map_set_key = try rt.internAtom("set");
    defer rt.atoms.free(map_set_key);
    const map_for_each_key = try rt.internAtom("forEach");
    defer rt.atoms.free(map_for_each_key);
    const set_union_key = try rt.internAtom("union");
    defer rt.atoms.free(set_union_key);
    const set_values_key = try rt.internAtom("values");
    defer rt.atoms.free(set_values_key);

    const map_value = global.getProperty(map_key);
    defer map_value.free(rt);
    const map_object: *core.Object = @fieldParentPtr("header", map_value.refHeader().?);
    const group_by_value = map_object.getProperty(group_by_key);
    defer group_by_value.free(rt);
    const group_by_object: *core.Object = @fieldParentPtr("header", group_by_value.refHeader().?);
    try std.testing.expect(group_by_object.nativeFunctionIdSlot().* != 0);
    const map_prototype_value = map_object.getProperty(prototype_key);
    defer map_prototype_value.free(rt);
    const map_prototype_object: *core.Object = @fieldParentPtr("header", map_prototype_value.refHeader().?);
    const map_set_value = map_prototype_object.getProperty(map_set_key);
    defer map_set_value.free(rt);
    const map_set_object: *core.Object = @fieldParentPtr("header", map_set_value.refHeader().?);
    try std.testing.expect(map_set_object.nativeFunctionIdSlot().* != 0);
    const map_for_each_value = map_prototype_object.getProperty(map_for_each_key);
    defer map_for_each_value.free(rt);
    const map_for_each_object: *core.Object = @fieldParentPtr("header", map_for_each_value.refHeader().?);
    try std.testing.expect(map_for_each_object.nativeFunctionIdSlot().* != 0);

    const set_value = global.getProperty(set_key);
    defer set_value.free(rt);
    const set_object: *core.Object = @fieldParentPtr("header", set_value.refHeader().?);
    const set_prototype_value = set_object.getProperty(prototype_key);
    defer set_prototype_value.free(rt);
    const set_prototype_object: *core.Object = @fieldParentPtr("header", set_prototype_value.refHeader().?);
    const set_union_value = set_prototype_object.getProperty(set_union_key);
    defer set_union_value.free(rt);
    const set_union_object: *core.Object = @fieldParentPtr("header", set_union_value.refHeader().?);
    try std.testing.expect(set_union_object.nativeFunctionIdSlot().* != 0);
    const set_values_value = set_prototype_object.getProperty(set_values_key);
    defer set_values_value.free(rt);
    const set_values_object: *core.Object = @fieldParentPtr("header", set_values_value.refHeader().?);
    try std.testing.expect(set_values_object.nativeFunctionIdSlot().* != 0);

    const fake_map_set = try engine.builtins.function.nativeFunction(rt, "notMapSet", 2);
    defer fake_map_set.free(rt);
    const fake_map_set_object: *core.Object = @fieldParentPtr("header", fake_map_set.refHeader().?);
    fake_map_set_object.nativeFunctionIdSlot().* = map_set_object.nativeFunctionIdSlot().*;
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_map_set_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notMapSet", dispatch_name);

    const direct_map = try engine.builtins.collection.constructWithPrototype(rt, 1, map_prototype_object);
    defer direct_map.free(rt);
    const direct_key = (try core.string.String.createUtf8(rt, "direct")).value();
    defer direct_key.free(rt);
    const direct_args = [_]core.JSValue{ direct_key, core.JSValue.int32(7) };
    const direct_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, direct_map, fake_map_set, &direct_args);
    defer direct_result.free(rt);
    try std.testing.expect(direct_result.same(direct_map));
    const direct_get_result = try engine.builtins.collection.methodCall(rt, direct_map, 2, &.{direct_key});
    defer direct_get_result.free(rt);
    try std.testing.expectEqual(@as(?i32, 7), direct_get_result.asInt32());

    const fake_group_by = try engine.builtins.function.nativeFunction(rt, "notMapGroupBy", 2);
    defer fake_group_by.free(rt);
    const fake_group_by_object: *core.Object = @fieldParentPtr("header", fake_group_by.refHeader().?);
    fake_group_by_object.nativeFunctionIdSlot().* = group_by_object.nativeFunctionIdSlot().*;
    const fake_map_for_each = try engine.builtins.function.nativeFunction(rt, "notMapForEach", 1);
    defer fake_map_for_each.free(rt);
    const fake_map_for_each_object: *core.Object = @fieldParentPtr("header", fake_map_for_each.refHeader().?);
    fake_map_for_each_object.nativeFunctionIdSlot().* = map_for_each_object.nativeFunctionIdSlot().*;
    const fake_set_union = try engine.builtins.function.nativeFunction(rt, "notSetUnion", 1);
    defer fake_set_union.free(rt);
    const fake_set_union_object: *core.Object = @fieldParentPtr("header", fake_set_union.refHeader().?);
    fake_set_union_object.nativeFunctionIdSlot().* = set_union_object.nativeFunctionIdSlot().*;
    const fake_set_values = try engine.builtins.function.nativeFunction(rt, "notSetValues", 0);
    defer fake_set_values.free(rt);
    const fake_set_values_object: *core.Object = @fieldParentPtr("header", fake_set_values.refHeader().?);
    fake_set_values_object.nativeFunctionIdSlot().* = set_values_object.nativeFunctionIdSlot().*;

    const fake_map_set_key = try rt.internAtom("fakeMapSet");
    defer rt.atoms.free(fake_map_set_key);
    try global.defineOwnProperty(rt, fake_map_set_key, core.Descriptor.data(fake_map_set, true, false, true));
    const fake_group_by_key = try rt.internAtom("fakeMapGroupBy");
    defer rt.atoms.free(fake_group_by_key);
    try global.defineOwnProperty(rt, fake_group_by_key, core.Descriptor.data(fake_group_by, true, false, true));
    const fake_map_for_each_key = try rt.internAtom("fakeMapForEach");
    defer rt.atoms.free(fake_map_for_each_key);
    try global.defineOwnProperty(rt, fake_map_for_each_key, core.Descriptor.data(fake_map_for_each, true, false, true));
    const fake_set_union_key = try rt.internAtom("fakeSetUnion");
    defer rt.atoms.free(fake_set_union_key);
    try global.defineOwnProperty(rt, fake_set_union_key, core.Descriptor.data(fake_set_union, true, false, true));
    const fake_set_values_key = try rt.internAtom("fakeSetValues");
    defer rt.atoms.free(fake_set_values_key);
    try global.defineOwnProperty(rt, fake_set_values_key, core.Descriptor.data(fake_set_values, true, false, true));

    var parsed = try engine.frontend.parser.parse(rt, "const grouped = fakeMapGroupBy.call(Map, ['aa', 'b'], function(v) { return v.length; }); print(grouped.get(2)[0]); const m = new Map(); fakeMapSet.call(m, 'a', 1); print(m.get('a')); fakeMapForEach.call(m, function(value, key) { print(key + ':' + value); }); const left = new Set(); left.add(1); const right = new Set(); right.add(2); const union = fakeSetUnion.call(left, right); print(Array.from(fakeSetValues.call(union)).join(','));", .{ .mode = .script, .filename = "collection-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [32]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false, &.{}, &.{}, &.{}, &.{});
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("aa\n1\na:1\n1,2\n", output.buffered());
}

test "buffer native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try engine.exec.call.installHostGlobals(rt, global);

    const array_buffer_key = try rt.internAtom("ArrayBuffer");
    defer rt.atoms.free(array_buffer_key);
    const shared_array_buffer_key = try rt.internAtom("SharedArrayBuffer");
    defer rt.atoms.free(shared_array_buffer_key);
    const data_view_key = try rt.internAtom("DataView");
    defer rt.atoms.free(data_view_key);
    const prototype_key = try rt.internAtom("prototype");
    defer rt.atoms.free(prototype_key);
    const is_view_key = try rt.internAtom("isView");
    defer rt.atoms.free(is_view_key);
    const slice_key = try rt.internAtom("slice");
    defer rt.atoms.free(slice_key);
    const byte_length_key = try rt.internAtom("byteLength");
    defer rt.atoms.free(byte_length_key);
    const get_uint8_key = try rt.internAtom("getUint8");
    defer rt.atoms.free(get_uint8_key);
    const set_uint8_key = try rt.internAtom("setUint8");
    defer rt.atoms.free(set_uint8_key);

    const array_buffer_value = global.getProperty(array_buffer_key);
    defer array_buffer_value.free(rt);
    const array_buffer_object: *core.Object = @fieldParentPtr("header", array_buffer_value.refHeader().?);
    const is_view_value = array_buffer_object.getProperty(is_view_key);
    defer is_view_value.free(rt);
    const is_view_object: *core.Object = @fieldParentPtr("header", is_view_value.refHeader().?);
    try std.testing.expect(is_view_object.nativeFunctionIdSlot().* != 0);
    const array_buffer_prototype_value = array_buffer_object.getProperty(prototype_key);
    defer array_buffer_prototype_value.free(rt);
    const array_buffer_prototype_object: *core.Object = @fieldParentPtr("header", array_buffer_prototype_value.refHeader().?);
    const array_buffer_slice_value = array_buffer_prototype_object.getProperty(slice_key);
    defer array_buffer_slice_value.free(rt);
    const array_buffer_slice_object: *core.Object = @fieldParentPtr("header", array_buffer_slice_value.refHeader().?);
    try std.testing.expect(array_buffer_slice_object.nativeFunctionIdSlot().* != 0);
    const array_buffer_byte_length_desc = array_buffer_prototype_object.getOwnProperty(byte_length_key).?;
    defer array_buffer_byte_length_desc.destroy(rt);
    const array_buffer_byte_length_getter: *core.Object = @fieldParentPtr("header", array_buffer_byte_length_desc.getter.refHeader().?);
    try std.testing.expect(array_buffer_byte_length_getter.nativeFunctionIdSlot().* != 0);

    const shared_array_buffer_value = global.getProperty(shared_array_buffer_key);
    defer shared_array_buffer_value.free(rt);
    const shared_array_buffer_object: *core.Object = @fieldParentPtr("header", shared_array_buffer_value.refHeader().?);
    const shared_array_buffer_prototype_value = shared_array_buffer_object.getProperty(prototype_key);
    defer shared_array_buffer_prototype_value.free(rt);
    const shared_array_buffer_prototype_object: *core.Object = @fieldParentPtr("header", shared_array_buffer_prototype_value.refHeader().?);
    const shared_array_buffer_slice_value = shared_array_buffer_prototype_object.getProperty(slice_key);
    defer shared_array_buffer_slice_value.free(rt);
    const shared_array_buffer_slice_object: *core.Object = @fieldParentPtr("header", shared_array_buffer_slice_value.refHeader().?);
    try std.testing.expect(shared_array_buffer_slice_object.nativeFunctionIdSlot().* != 0);

    const data_view_value = global.getProperty(data_view_key);
    defer data_view_value.free(rt);
    const data_view_object: *core.Object = @fieldParentPtr("header", data_view_value.refHeader().?);
    const data_view_prototype_value = data_view_object.getProperty(prototype_key);
    defer data_view_prototype_value.free(rt);
    const data_view_prototype_object: *core.Object = @fieldParentPtr("header", data_view_prototype_value.refHeader().?);
    const get_uint8_value = data_view_prototype_object.getProperty(get_uint8_key);
    defer get_uint8_value.free(rt);
    const get_uint8_object: *core.Object = @fieldParentPtr("header", get_uint8_value.refHeader().?);
    try std.testing.expect(get_uint8_object.nativeFunctionIdSlot().* != 0);
    const set_uint8_value = data_view_prototype_object.getProperty(set_uint8_key);
    defer set_uint8_value.free(rt);
    const set_uint8_object: *core.Object = @fieldParentPtr("header", set_uint8_value.refHeader().?);
    try std.testing.expect(set_uint8_object.nativeFunctionIdSlot().* != 0);
    const data_view_byte_length_desc = data_view_prototype_object.getOwnProperty(byte_length_key).?;
    defer data_view_byte_length_desc.destroy(rt);
    const data_view_byte_length_getter: *core.Object = @fieldParentPtr("header", data_view_byte_length_desc.getter.refHeader().?);
    try std.testing.expect(data_view_byte_length_getter.nativeFunctionIdSlot().* != 0);

    const fake_is_view = try engine.builtins.function.nativeFunction(rt, "notArrayBufferIsView", 1);
    defer fake_is_view.free(rt);
    const fake_is_view_object: *core.Object = @fieldParentPtr("header", fake_is_view.refHeader().?);
    fake_is_view_object.nativeFunctionIdSlot().* = is_view_object.nativeFunctionIdSlot().*;
    const fake_array_buffer_slice = try engine.builtins.function.nativeFunction(rt, "notArrayBufferSlice", 2);
    defer fake_array_buffer_slice.free(rt);
    const fake_array_buffer_slice_object: *core.Object = @fieldParentPtr("header", fake_array_buffer_slice.refHeader().?);
    fake_array_buffer_slice_object.nativeFunctionIdSlot().* = array_buffer_slice_object.nativeFunctionIdSlot().*;
    const fake_array_buffer_byte_length = try engine.builtins.function.nativeFunction(rt, "notArrayBufferByteLength", 0);
    defer fake_array_buffer_byte_length.free(rt);
    const fake_array_buffer_byte_length_object: *core.Object = @fieldParentPtr("header", fake_array_buffer_byte_length.refHeader().?);
    fake_array_buffer_byte_length_object.nativeFunctionIdSlot().* = array_buffer_byte_length_getter.nativeFunctionIdSlot().*;
    const fake_shared_array_buffer_slice = try engine.builtins.function.nativeFunction(rt, "notSharedArrayBufferSlice", 2);
    defer fake_shared_array_buffer_slice.free(rt);
    const fake_shared_array_buffer_slice_object: *core.Object = @fieldParentPtr("header", fake_shared_array_buffer_slice.refHeader().?);
    fake_shared_array_buffer_slice_object.nativeFunctionIdSlot().* = shared_array_buffer_slice_object.nativeFunctionIdSlot().*;
    const fake_data_view_get_uint8 = try engine.builtins.function.nativeFunction(rt, "notDataViewGetUint8", 1);
    defer fake_data_view_get_uint8.free(rt);
    const fake_data_view_get_uint8_object: *core.Object = @fieldParentPtr("header", fake_data_view_get_uint8.refHeader().?);
    fake_data_view_get_uint8_object.nativeFunctionIdSlot().* = get_uint8_object.nativeFunctionIdSlot().*;
    const fake_data_view_set_uint8 = try engine.builtins.function.nativeFunction(rt, "notDataViewSetUint8", 2);
    defer fake_data_view_set_uint8.free(rt);
    const fake_data_view_set_uint8_object: *core.Object = @fieldParentPtr("header", fake_data_view_set_uint8.refHeader().?);
    fake_data_view_set_uint8_object.nativeFunctionIdSlot().* = set_uint8_object.nativeFunctionIdSlot().*;
    const fake_data_view_byte_length = try engine.builtins.function.nativeFunction(rt, "notDataViewByteLength", 0);
    defer fake_data_view_byte_length.free(rt);
    const fake_data_view_byte_length_object: *core.Object = @fieldParentPtr("header", fake_data_view_byte_length.refHeader().?);
    fake_data_view_byte_length_object.nativeFunctionIdSlot().* = data_view_byte_length_getter.nativeFunctionIdSlot().*;

    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_array_buffer_slice_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notArrayBufferSlice", dispatch_name);

    const direct_buffer = try engine.builtins.buffer.arrayBufferConstructArgs(rt, &.{core.JSValue.int32(6)}, array_buffer_prototype_object);
    defer direct_buffer.free(rt);
    const direct_slice_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, direct_buffer, fake_array_buffer_slice, &.{ core.JSValue.int32(1), core.JSValue.int32(4) });
    defer direct_slice_result.free(rt);
    const direct_slice_object: *core.Object = @fieldParentPtr("header", direct_slice_result.refHeader().?);
    try std.testing.expectEqual(@as(usize, 3), direct_slice_object.byteStorage().len);
    const direct_length_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, direct_buffer, fake_array_buffer_byte_length, &.{});
    defer direct_length_result.free(rt);
    try std.testing.expectEqual(@as(?i32, 6), direct_length_result.asInt32());

    const fake_is_view_key = try rt.internAtom("fakeArrayBufferIsView");
    defer rt.atoms.free(fake_is_view_key);
    try global.defineOwnProperty(rt, fake_is_view_key, core.Descriptor.data(fake_is_view, true, false, true));
    const fake_array_buffer_slice_key = try rt.internAtom("fakeArrayBufferSlice");
    defer rt.atoms.free(fake_array_buffer_slice_key);
    try global.defineOwnProperty(rt, fake_array_buffer_slice_key, core.Descriptor.data(fake_array_buffer_slice, true, false, true));
    const fake_array_buffer_byte_length_key = try rt.internAtom("fakeArrayBufferByteLength");
    defer rt.atoms.free(fake_array_buffer_byte_length_key);
    try global.defineOwnProperty(rt, fake_array_buffer_byte_length_key, core.Descriptor.data(fake_array_buffer_byte_length, true, false, true));
    const fake_shared_array_buffer_slice_key = try rt.internAtom("fakeSharedArrayBufferSlice");
    defer rt.atoms.free(fake_shared_array_buffer_slice_key);
    try global.defineOwnProperty(rt, fake_shared_array_buffer_slice_key, core.Descriptor.data(fake_shared_array_buffer_slice, true, false, true));
    const fake_data_view_get_uint8_key = try rt.internAtom("fakeDataViewGetUint8");
    defer rt.atoms.free(fake_data_view_get_uint8_key);
    try global.defineOwnProperty(rt, fake_data_view_get_uint8_key, core.Descriptor.data(fake_data_view_get_uint8, true, false, true));
    const fake_data_view_set_uint8_key = try rt.internAtom("fakeDataViewSetUint8");
    defer rt.atoms.free(fake_data_view_set_uint8_key);
    try global.defineOwnProperty(rt, fake_data_view_set_uint8_key, core.Descriptor.data(fake_data_view_set_uint8, true, false, true));
    const fake_data_view_byte_length_key = try rt.internAtom("fakeDataViewByteLength");
    defer rt.atoms.free(fake_data_view_byte_length_key);
    try global.defineOwnProperty(rt, fake_data_view_byte_length_key, core.Descriptor.data(fake_data_view_byte_length, true, false, true));

    var parsed = try engine.frontend.parser.parse(rt,
        \\const b = new ArrayBuffer(6);
        \\print(fakeArrayBufferIsView(new DataView(b)));
        \\print(fakeArrayBufferSlice.call(b, 1, 4).byteLength);
        \\print(fakeArrayBufferByteLength.call(b));
        \\const s = new SharedArrayBuffer(5);
        \\print(fakeSharedArrayBufferSlice.call(s, 1, 3).byteLength);
        \\const v = new DataView(b);
        \\fakeDataViewSetUint8.call(v, 0, 77);
        \\print(fakeDataViewGetUint8.call(v, 0));
        \\print(fakeDataViewByteLength.call(v));
    , .{ .mode = .script, .filename = "buffer-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [40]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false, &.{}, &.{}, &.{}, &.{});
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("true\n3\n6\n2\n77\n6\n", output.buffered());
}

test "typed array accessor native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try engine.exec.call.installHostGlobals(rt, global);

    const typed_array_key = try rt.internAtom("TypedArray");
    defer rt.atoms.free(typed_array_key);
    const prototype_key = try rt.internAtom("prototype");
    defer rt.atoms.free(prototype_key);
    const byte_length_key = try rt.internAtom("byteLength");
    defer rt.atoms.free(byte_length_key);
    const length_key = try rt.internAtom("length");
    defer rt.atoms.free(length_key);

    const typed_array_value = global.getProperty(typed_array_key);
    defer typed_array_value.free(rt);
    const typed_array_object: *core.Object = @fieldParentPtr("header", typed_array_value.refHeader().?);
    const prototype_value = typed_array_object.getProperty(prototype_key);
    defer prototype_value.free(rt);
    const prototype_object: *core.Object = @fieldParentPtr("header", prototype_value.refHeader().?);

    const byte_length_desc = prototype_object.getOwnProperty(byte_length_key).?;
    defer byte_length_desc.destroy(rt);
    const byte_length_getter: *core.Object = @fieldParentPtr("header", byte_length_desc.getter.refHeader().?);
    try std.testing.expect(byte_length_getter.nativeFunctionIdSlot().* != 0);
    const length_desc = prototype_object.getOwnProperty(length_key).?;
    defer length_desc.destroy(rt);
    const length_getter: *core.Object = @fieldParentPtr("header", length_desc.getter.refHeader().?);
    try std.testing.expect(length_getter.nativeFunctionIdSlot().* != 0);
    const tag_desc = prototype_object.getOwnProperty(core.atom.predefinedId("Symbol.toStringTag", .symbol).?).?;
    defer tag_desc.destroy(rt);
    const tag_getter: *core.Object = @fieldParentPtr("header", tag_desc.getter.refHeader().?);
    try std.testing.expect(tag_getter.nativeFunctionIdSlot().* != 0);

    const fake_byte_length = try engine.builtins.function.nativeFunction(rt, "notTypedArrayByteLength", 0);
    defer fake_byte_length.free(rt);
    const fake_byte_length_object: *core.Object = @fieldParentPtr("header", fake_byte_length.refHeader().?);
    fake_byte_length_object.nativeFunctionIdSlot().* = byte_length_getter.nativeFunctionIdSlot().*;
    const fake_length = try engine.builtins.function.nativeFunction(rt, "notTypedArrayLength", 0);
    defer fake_length.free(rt);
    const fake_length_object: *core.Object = @fieldParentPtr("header", fake_length.refHeader().?);
    fake_length_object.nativeFunctionIdSlot().* = length_getter.nativeFunctionIdSlot().*;
    const fake_tag = try engine.builtins.function.nativeFunction(rt, "notTypedArrayTag", 0);
    defer fake_tag.free(rt);
    const fake_tag_object: *core.Object = @fieldParentPtr("header", fake_tag.refHeader().?);
    fake_tag_object.nativeFunctionIdSlot().* = tag_getter.nativeFunctionIdSlot().*;

    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_byte_length_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notTypedArrayByteLength", dispatch_name);

    const direct_buffer = try engine.builtins.buffer.arrayBufferConstructArgs(rt, &.{core.JSValue.int32(8)}, null);
    defer direct_buffer.free(rt);
    const direct_typed_array = try engine.builtins.buffer.typedArrayConstructWithOptions(rt, 1, 2, direct_buffer, &.{direct_buffer}, prototype_object);
    defer direct_typed_array.free(rt);
    const direct_byte_length = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, direct_typed_array, fake_byte_length, &.{});
    defer direct_byte_length.free(rt);
    try std.testing.expectEqual(@as(?i32, 8), direct_byte_length.asInt32());
    const direct_length = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, direct_typed_array, fake_length, &.{});
    defer direct_length.free(rt);
    try std.testing.expectEqual(@as(?i32, 8), direct_length.asInt32());

    const fake_byte_length_key = try rt.internAtom("fakeTypedArrayByteLength");
    defer rt.atoms.free(fake_byte_length_key);
    try global.defineOwnProperty(rt, fake_byte_length_key, core.Descriptor.data(fake_byte_length, true, false, true));
    const fake_length_key = try rt.internAtom("fakeTypedArrayLength");
    defer rt.atoms.free(fake_length_key);
    try global.defineOwnProperty(rt, fake_length_key, core.Descriptor.data(fake_length, true, false, true));
    const fake_tag_key = try rt.internAtom("fakeTypedArrayTag");
    defer rt.atoms.free(fake_tag_key);
    try global.defineOwnProperty(rt, fake_tag_key, core.Descriptor.data(fake_tag, true, false, true));

    var parsed = try engine.frontend.parser.parse(rt,
        \\const ta = new Uint8Array([1, 2, 3, 4]);
        \\print(fakeTypedArrayByteLength.call(ta));
        \\print(fakeTypedArrayLength.call(ta));
        \\print(fakeTypedArrayTag.call(ta));
        \\print(fakeTypedArrayTag.call({}));
    , .{ .mode = .script, .filename = "typed-array-accessor-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [32]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false, &.{}, &.{}, &.{}, &.{});
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("4\n4\nUint8Array\nundefined\n", output.buffered());
}

test "regexp static native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try engine.exec.call.installHostGlobals(rt, global);

    const regexp_key = try rt.internAtom("RegExp");
    defer rt.atoms.free(regexp_key);
    const escape_key = try rt.internAtom("escape");
    defer rt.atoms.free(escape_key);
    const regexp_value = global.getProperty(regexp_key);
    defer regexp_value.free(rt);
    const regexp_object: *core.Object = @fieldParentPtr("header", regexp_value.refHeader().?);
    const escape_value = regexp_object.getProperty(escape_key);
    defer escape_value.free(rt);
    const escape_object: *core.Object = @fieldParentPtr("header", escape_value.refHeader().?);
    try std.testing.expect(escape_object.nativeFunctionIdSlot().* != 0);

    const fake = try engine.builtins.function.nativeFunction(rt, "notRegExpEscape", 1);
    defer fake.free(rt);
    const fake_object: *core.Object = @fieldParentPtr("header", fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = escape_object.nativeFunctionIdSlot().*;
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notRegExpEscape", dispatch_name);

    const dot = try core.string.String.createUtf8(rt, ".");
    defer dot.value().free(rt);
    const direct_args = [_]core.JSValue{dot.value()};
    const direct_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, core.JSValue.undefinedValue(), fake, &direct_args);
    defer direct_result.free(rt);
    try std.testing.expect(direct_result.isString());
    const direct_result_string: *core.string.String = @fieldParentPtr("header", direct_result.refHeader().?);
    try std.testing.expect(direct_result_string.eqlBytes("\\."));

    const fake_key = try rt.internAtom("fakeRegExpEscape");
    defer rt.atoms.free(fake_key);
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, true, false, true));

    var parsed = try engine.frontend.parser.parse(rt, "print(fakeRegExpEscape('.')); print(fakeRegExpEscape('a+b'));", .{ .mode = .script, .filename = "regexp-static-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [24]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false, &.{}, &.{}, &.{}, &.{});
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("\\.\n\\x61\\+b\n", output.buffered());
}

test "regexp prototype native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try engine.exec.call.installHostGlobals(rt, global);

    const regexp_key = try rt.internAtom("RegExp");
    defer rt.atoms.free(regexp_key);
    const exec_key = try rt.internAtom("exec");
    defer rt.atoms.free(exec_key);
    const test_key = try rt.internAtom("test");
    defer rt.atoms.free(test_key);
    const to_string_key = try rt.internAtom("toString");
    defer rt.atoms.free(to_string_key);
    const regexp_value = global.getProperty(regexp_key);
    defer regexp_value.free(rt);
    const regexp_object: *core.Object = @fieldParentPtr("header", regexp_value.refHeader().?);
    const prototype_value = regexp_object.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    const prototype_object: *core.Object = @fieldParentPtr("header", prototype_value.refHeader().?);
    const exec_value = prototype_object.getProperty(exec_key);
    defer exec_value.free(rt);
    const exec_object: *core.Object = @fieldParentPtr("header", exec_value.refHeader().?);
    try std.testing.expect(exec_object.nativeFunctionIdSlot().* != 0);
    const test_value = prototype_object.getProperty(test_key);
    defer test_value.free(rt);
    const test_object: *core.Object = @fieldParentPtr("header", test_value.refHeader().?);
    try std.testing.expect(test_object.nativeFunctionIdSlot().* != 0);
    const to_string_value = prototype_object.getProperty(to_string_key);
    defer to_string_value.free(rt);
    const to_string_object: *core.Object = @fieldParentPtr("header", to_string_value.refHeader().?);
    try std.testing.expect(to_string_object.nativeFunctionIdSlot().* != 0);

    const fake_exec = try engine.builtins.function.nativeFunction(rt, "notRegExpExec", 1);
    defer fake_exec.free(rt);
    const fake_exec_object: *core.Object = @fieldParentPtr("header", fake_exec.refHeader().?);
    fake_exec_object.nativeFunctionIdSlot().* = exec_object.nativeFunctionIdSlot().*;
    const exec_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_exec_object);
    defer rt.memory.allocator.free(exec_dispatch_name);
    try std.testing.expectEqualStrings("notRegExpExec", exec_dispatch_name);

    const fake_test = try engine.builtins.function.nativeFunction(rt, "notRegExpTest", 1);
    defer fake_test.free(rt);
    const fake_test_object: *core.Object = @fieldParentPtr("header", fake_test.refHeader().?);
    fake_test_object.nativeFunctionIdSlot().* = test_object.nativeFunctionIdSlot().*;
    const test_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_test_object);
    defer rt.memory.allocator.free(test_dispatch_name);
    try std.testing.expectEqualStrings("notRegExpTest", test_dispatch_name);

    const fake_to_string = try engine.builtins.function.nativeFunction(rt, "notRegExpToString", 0);
    defer fake_to_string.free(rt);
    const fake_to_string_object: *core.Object = @fieldParentPtr("header", fake_to_string.refHeader().?);
    fake_to_string_object.nativeFunctionIdSlot().* = to_string_object.nativeFunctionIdSlot().*;
    const to_string_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_to_string_object);
    defer rt.memory.allocator.free(to_string_dispatch_name);
    try std.testing.expectEqualStrings("notRegExpToString", to_string_dispatch_name);

    const pattern_string = try core.string.String.createUtf8(rt, "a");
    defer pattern_string.value().free(rt);
    const flags_string = try core.string.String.createUtf8(rt, "");
    defer flags_string.value().free(rt);
    const receiver = try engine.builtins.regexp.constructWithPrototype(rt, pattern_string.value(), flags_string.value(), prototype_object);
    defer receiver.free(rt);
    const input_string = try core.string.String.createUtf8(rt, "cat");
    defer input_string.value().free(rt);
    const direct_args = [_]core.JSValue{input_string.value()};
    const exec_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_exec, &direct_args);
    defer exec_result.free(rt);
    const exec_array: *core.Object = @fieldParentPtr("header", exec_result.refHeader().?);
    try std.testing.expect(exec_array.is_array);
    const first_match = exec_array.getProperty(core.atom.atomFromUInt32(0));
    defer first_match.free(rt);
    try std.testing.expect(first_match.isString());
    const first_match_string: *core.string.String = @fieldParentPtr("header", first_match.refHeader().?);
    try std.testing.expect(first_match_string.eqlBytes("a"));
    const index_key = try rt.internAtom("index");
    defer rt.atoms.free(index_key);
    const index_value = exec_array.getProperty(index_key);
    defer index_value.free(rt);
    try std.testing.expectEqual(@as(i32, 1), index_value.asInt32().?);

    const test_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_test, &direct_args);
    defer test_result.free(rt);
    try std.testing.expectEqual(true, test_result.asBool().?);

    const to_string_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_to_string, &.{});
    defer to_string_result.free(rt);
    try std.testing.expect(to_string_result.isString());
    const to_string_result_string: *core.string.String = @fieldParentPtr("header", to_string_result.refHeader().?);
    try std.testing.expect(to_string_result_string.eqlBytes("/a/"));

    const fake_exec_key = try rt.internAtom("fakeRegExpExec");
    defer rt.atoms.free(fake_exec_key);
    try global.defineOwnProperty(rt, fake_exec_key, core.Descriptor.data(fake_exec, true, false, true));
    const fake_test_key = try rt.internAtom("fakeRegExpTest");
    defer rt.atoms.free(fake_test_key);
    try global.defineOwnProperty(rt, fake_test_key, core.Descriptor.data(fake_test, true, false, true));
    const fake_to_string_key = try rt.internAtom("fakeRegExpToString");
    defer rt.atoms.free(fake_to_string_key);
    try global.defineOwnProperty(rt, fake_to_string_key, core.Descriptor.data(fake_to_string, true, false, true));

    var parsed = try engine.frontend.parser.parse(rt, "const r = /a/; const m = fakeRegExpExec.call(r, 'cat'); print(m[0] + ':' + m.index); print(fakeRegExpTest.call(r, 'cat')); print(fakeRegExpToString.call(r));", .{ .mode = .script, .filename = "regexp-prototype-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [32]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false, &.{}, &.{}, &.{}, &.{});
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("a:1\ntrue\n/a/\n", output.buffered());
}

test "regexp symbol native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try engine.exec.call.installHostGlobals(rt, global);

    const regexp_key = try rt.internAtom("RegExp");
    defer rt.atoms.free(regexp_key);
    const regexp_value = global.getProperty(regexp_key);
    defer regexp_value.free(rt);
    const regexp_object: *core.Object = @fieldParentPtr("header", regexp_value.refHeader().?);
    const prototype_value = regexp_object.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    const prototype_object: *core.Object = @fieldParentPtr("header", prototype_value.refHeader().?);

    const search_value = prototype_object.getProperty(core.atom.predefinedId("Symbol.search", .symbol).?);
    defer search_value.free(rt);
    const search_object: *core.Object = @fieldParentPtr("header", search_value.refHeader().?);
    try std.testing.expect(search_object.nativeFunctionIdSlot().* != 0);
    const match_value = prototype_object.getProperty(core.atom.predefinedId("Symbol.match", .symbol).?);
    defer match_value.free(rt);
    const match_object: *core.Object = @fieldParentPtr("header", match_value.refHeader().?);
    try std.testing.expect(match_object.nativeFunctionIdSlot().* != 0);
    const match_all_value = prototype_object.getProperty(core.atom.predefinedId("Symbol.matchAll", .symbol).?);
    defer match_all_value.free(rt);
    const match_all_object: *core.Object = @fieldParentPtr("header", match_all_value.refHeader().?);
    try std.testing.expect(match_all_object.nativeFunctionIdSlot().* != 0);
    const replace_value = prototype_object.getProperty(core.atom.predefinedId("Symbol.replace", .symbol).?);
    defer replace_value.free(rt);
    const replace_object: *core.Object = @fieldParentPtr("header", replace_value.refHeader().?);
    try std.testing.expect(replace_object.nativeFunctionIdSlot().* != 0);
    const split_value = prototype_object.getProperty(core.atom.predefinedId("Symbol.split", .symbol).?);
    defer split_value.free(rt);
    const split_object: *core.Object = @fieldParentPtr("header", split_value.refHeader().?);
    try std.testing.expect(split_object.nativeFunctionIdSlot().* != 0);

    const fake_search = try engine.builtins.function.nativeFunction(rt, "notRegExpSearch", 1);
    defer fake_search.free(rt);
    const fake_search_object: *core.Object = @fieldParentPtr("header", fake_search.refHeader().?);
    fake_search_object.nativeFunctionIdSlot().* = search_object.nativeFunctionIdSlot().*;
    const search_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_search_object);
    defer rt.memory.allocator.free(search_dispatch_name);
    try std.testing.expectEqualStrings("notRegExpSearch", search_dispatch_name);

    const fake_match = try engine.builtins.function.nativeFunction(rt, "notRegExpMatch", 1);
    defer fake_match.free(rt);
    const fake_match_object: *core.Object = @fieldParentPtr("header", fake_match.refHeader().?);
    fake_match_object.nativeFunctionIdSlot().* = match_object.nativeFunctionIdSlot().*;
    const fake_match_all = try engine.builtins.function.nativeFunction(rt, "notRegExpMatchAll", 1);
    defer fake_match_all.free(rt);
    const fake_match_all_object: *core.Object = @fieldParentPtr("header", fake_match_all.refHeader().?);
    fake_match_all_object.nativeFunctionIdSlot().* = match_all_object.nativeFunctionIdSlot().*;
    const fake_replace = try engine.builtins.function.nativeFunction(rt, "notRegExpReplace", 2);
    defer fake_replace.free(rt);
    const fake_replace_object: *core.Object = @fieldParentPtr("header", fake_replace.refHeader().?);
    fake_replace_object.nativeFunctionIdSlot().* = replace_object.nativeFunctionIdSlot().*;
    const fake_split = try engine.builtins.function.nativeFunction(rt, "notRegExpSplit", 2);
    defer fake_split.free(rt);
    const fake_split_object: *core.Object = @fieldParentPtr("header", fake_split.refHeader().?);
    fake_split_object.nativeFunctionIdSlot().* = split_object.nativeFunctionIdSlot().*;

    const pattern_string = try core.string.String.createUtf8(rt, "a");
    defer pattern_string.value().free(rt);
    const flags_string = try core.string.String.createUtf8(rt, "");
    defer flags_string.value().free(rt);
    const receiver = try engine.builtins.regexp.constructWithPrototype(rt, pattern_string.value(), flags_string.value(), prototype_object);
    defer receiver.free(rt);
    const input_string = try core.string.String.createUtf8(rt, "cat");
    defer input_string.value().free(rt);
    const replacement_string = try core.string.String.createUtf8(rt, "o");
    defer replacement_string.value().free(rt);

    const one_arg = [_]core.JSValue{input_string.value()};
    const search_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_search, &one_arg);
    defer search_result.free(rt);
    try std.testing.expectEqual(@as(i32, 1), search_result.asInt32().?);

    const match_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_match, &one_arg);
    defer match_result.free(rt);
    const match_array: *core.Object = @fieldParentPtr("header", match_result.refHeader().?);
    const match_zero = match_array.getProperty(core.atom.atomFromUInt32(0));
    defer match_zero.free(rt);
    try std.testing.expect(match_zero.isString());
    const match_zero_string: *core.string.String = @fieldParentPtr("header", match_zero.refHeader().?);
    try std.testing.expect(match_zero_string.eqlBytes("a"));

    const match_all_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_match_all, &one_arg);
    defer match_all_result.free(rt);
    const match_all_iterator: *core.Object = @fieldParentPtr("header", match_all_result.refHeader().?);
    try std.testing.expectEqual(core.class.ids.regexp_string_iterator, match_all_iterator.class_id);

    const replace_args = [_]core.JSValue{ input_string.value(), replacement_string.value() };
    const replace_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_replace, &replace_args);
    defer replace_result.free(rt);
    try std.testing.expect(replace_result.isString());
    const replace_result_string: *core.string.String = @fieldParentPtr("header", replace_result.refHeader().?);
    try std.testing.expect(replace_result_string.eqlBytes("cot"));

    const split_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_split, &one_arg);
    defer split_result.free(rt);
    const split_array: *core.Object = @fieldParentPtr("header", split_result.refHeader().?);
    try std.testing.expect(split_array.is_array);
    try std.testing.expectEqual(@as(u32, 2), split_array.length);

    const fake_search_key = try rt.internAtom("fakeRegExpSearch");
    defer rt.atoms.free(fake_search_key);
    try global.defineOwnProperty(rt, fake_search_key, core.Descriptor.data(fake_search, true, false, true));
    const fake_match_key = try rt.internAtom("fakeRegExpMatch");
    defer rt.atoms.free(fake_match_key);
    try global.defineOwnProperty(rt, fake_match_key, core.Descriptor.data(fake_match, true, false, true));
    const fake_match_all_key = try rt.internAtom("fakeRegExpMatchAll");
    defer rt.atoms.free(fake_match_all_key);
    try global.defineOwnProperty(rt, fake_match_all_key, core.Descriptor.data(fake_match_all, true, false, true));
    const fake_replace_key = try rt.internAtom("fakeRegExpReplace");
    defer rt.atoms.free(fake_replace_key);
    try global.defineOwnProperty(rt, fake_replace_key, core.Descriptor.data(fake_replace, true, false, true));
    const fake_split_key = try rt.internAtom("fakeRegExpSplit");
    defer rt.atoms.free(fake_split_key);
    try global.defineOwnProperty(rt, fake_split_key, core.Descriptor.data(fake_split, true, false, true));

    var parsed = try engine.frontend.parser.parse(rt,
        \\const r = /a/;
        \\print(fakeRegExpSearch.call(r, 'cat'));
        \\print(fakeRegExpMatch.call(r, 'cat')[0]);
        \\print(fakeRegExpMatchAll.call(r, 'cat').next().value[0]);
        \\print(fakeRegExpReplace.call(r, 'cat', 'o'));
        \\print(fakeRegExpSplit.call(r, 'cat').join('|'));
    , .{ .mode = .script, .filename = "regexp-symbol-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [48]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false, &.{}, &.{}, &.{}, &.{});
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("1\na\na\ncot\nc|t\n", output.buffered());
}

test "regexp accessor native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try engine.exec.call.installHostGlobals(rt, global);

    const regexp_key = try rt.internAtom("RegExp");
    defer rt.atoms.free(regexp_key);
    const regexp_value = global.getProperty(regexp_key);
    defer regexp_value.free(rt);
    const regexp_object: *core.Object = @fieldParentPtr("header", regexp_value.refHeader().?);
    const prototype_value = regexp_object.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    const prototype_object: *core.Object = @fieldParentPtr("header", prototype_value.refHeader().?);

    const source_key = try rt.internAtom("source");
    defer rt.atoms.free(source_key);
    const source_desc = prototype_object.getOwnProperty(source_key).?;
    defer source_desc.destroy(rt);
    const source_getter: *core.Object = @fieldParentPtr("header", source_desc.getter.refHeader().?);
    try std.testing.expect(source_getter.nativeFunctionIdSlot().* != 0);
    const global_key = try rt.internAtom("global");
    defer rt.atoms.free(global_key);
    const global_desc = prototype_object.getOwnProperty(global_key).?;
    defer global_desc.destroy(rt);
    const global_getter: *core.Object = @fieldParentPtr("header", global_desc.getter.refHeader().?);
    try std.testing.expect(global_getter.nativeFunctionIdSlot().* != 0);

    const fake_source = try engine.builtins.function.nativeFunction(rt, "notRegExpSourceGetter", 0);
    defer fake_source.free(rt);
    const fake_source_object: *core.Object = @fieldParentPtr("header", fake_source.refHeader().?);
    fake_source_object.nativeFunctionIdSlot().* = source_getter.nativeFunctionIdSlot().*;
    const source_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_source_object);
    defer rt.memory.allocator.free(source_dispatch_name);
    try std.testing.expectEqualStrings("notRegExpSourceGetter", source_dispatch_name);

    const fake_global = try engine.builtins.function.nativeFunction(rt, "notRegExpGlobalGetter", 0);
    defer fake_global.free(rt);
    const fake_global_object: *core.Object = @fieldParentPtr("header", fake_global.refHeader().?);
    fake_global_object.nativeFunctionIdSlot().* = global_getter.nativeFunctionIdSlot().*;

    const pattern_string = try core.string.String.createUtf8(rt, "a/b");
    defer pattern_string.value().free(rt);
    const flags_string = try core.string.String.createUtf8(rt, "g");
    defer flags_string.value().free(rt);
    const receiver = try engine.builtins.regexp.constructWithPrototype(rt, pattern_string.value(), flags_string.value(), prototype_object);
    defer receiver.free(rt);

    const source_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_source, &.{});
    defer source_result.free(rt);
    try std.testing.expect(source_result.isString());
    const source_string: *core.string.String = @fieldParentPtr("header", source_result.refHeader().?);
    try std.testing.expect(source_string.eqlBytes("a\\/b"));

    const global_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_global, &.{});
    defer global_result.free(rt);
    try std.testing.expectEqual(true, global_result.asBool().?);

    const fake_source_key = try rt.internAtom("fakeRegExpSourceGetter");
    defer rt.atoms.free(fake_source_key);
    try global.defineOwnProperty(rt, fake_source_key, core.Descriptor.data(fake_source, true, false, true));
    const fake_global_key = try rt.internAtom("fakeRegExpGlobalGetter");
    defer rt.atoms.free(fake_global_key);
    try global.defineOwnProperty(rt, fake_global_key, core.Descriptor.data(fake_global, true, false, true));

    var parsed = try engine.frontend.parser.parse(rt,
        \\const r = /a\/b/g;
        \\print(fakeRegExpSourceGetter.call(r));
        \\print(fakeRegExpGlobalGetter.call(r));
    , .{ .mode = .script, .filename = "regexp-accessor-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [24]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false, &.{}, &.{}, &.{}, &.{});
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("a\\/b\ntrue\n", output.buffered());
}

test "vm collection constructors use registered prototype methods" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const name = try rt.internAtom("collection-prototype");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    const map_atom = try rt.internAtom("Map");
    defer rt.atoms.free(map_atom);
    var bytes: [8]u8 = undefined;
    bytes[0] = op.get_var;
    std.mem.writeInt(u32, bytes[1..5], map_atom, .little);
    bytes[5] = op.call_constructor;
    std.mem.writeInt(u16, bytes[6..8], 0, .little);
    try function.setCode(&bytes);

    var vm_instance = engine.exec.Vm.init(ctx);
    defer vm_instance.deinit();
    const result = try vm_instance.run(&function);
    defer result.free(rt);

    const object: *core.Object = @fieldParentPtr("header", result.refHeader().?);
    const set_key = try rt.internAtom("set");
    defer rt.atoms.free(set_key);
    try std.testing.expect(object.getPrototype() != null);
    try std.testing.expect(!object.hasOwnProperty(set_key));
    try std.testing.expect(object.hasProperty(set_key));
    try std.testing.expect(object.getPrototype().?.hasOwnProperty(set_key));
}

test "finite number formatting keeps simple decimal fast path semantics" {
    var buffer: [64]u8 = undefined;

    try std.testing.expectEqualStrings("12.5", try engine.exec.value_ops.formatFiniteNumber(&buffer, 12.5));
    try std.testing.expectEqualStrings("-12.5", try engine.exec.value_ops.formatFiniteNumber(&buffer, -12.5));
    try std.testing.expectEqualStrings("1", try engine.exec.value_ops.formatFiniteNumber(&buffer, 1.0));
    try std.testing.expectEqualStrings("0.1", try engine.exec.value_ops.formatFiniteNumber(&buffer, 0.1));
    try std.testing.expectEqualStrings("1e+21", try engine.exec.value_ops.formatFiniteNumber(&buffer, 1e21));
}

// ================== engine_smoke.zig ==================



test "Engine eval executes test262 helpers through generic call paths" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval("assert.sameValue(1 + 1, 2, 'sum');");
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
    try std.testing.expectError(error.Test262Error, js.eval("assert.sameValue(1, 2);"));
    try std.testing.expectError(error.Test262Error, js.eval("throw new Test262Error('boom');"));
}

test "Engine eval strips TypeScript source kind before execution" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalWithOptions(
        \\type Label = string;
        \\interface Box { value: number }
        \\const value: number = 41;
        \\function add(input: number): number { return input + 1; }
        \\assert.sameValue(add(value), 42 as number);
    , .{ .source_kind = .typescript });
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine eval strips TypeScript method annotations" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalWithOptions(
        \\class C { m(x: number): number { return x; } }
        \\const object = { m(x: number): number { return x + 1; } };
        \\assert.sameValue(new C().m(41), 41);
        \\assert.sameValue(object.m(41), 42);
    , .{ .source_kind = .typescript });
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine eval preserves as and satisfies runtime property names in TypeScript files" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalWithOptions(
        \\const obj = { as: 1, satisfies: 2 };
        \\assert.sameValue(obj.as + obj.satisfies, 3);
    , .{ .source_kind = .typescript });
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine eval supports TypeScript parameter properties" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var result = try js.evalWithOptions(
        \\class Box {
        \\    constructor(public value: number) {}
        \\}
        \\const b = new Box(42);
        \\b.value === 42 ? 42 : 0
    , .{ .source_kind = .typescript, .mode = .eval_indirect });
    defer result.free(js.runtime);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32());
}

test "Engine eval strips TypeScript automatically for ts filenames" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalWithOptions(
        \\const value: number = 42;
        \\assert.sameValue(value, 42);
    , .{ .filename = "sample.ts" });
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "CallSite metadata is internal" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\Error.prepareStackTrace = function(err, sites) {
        \\    var site = sites[0];
        \\    assert.sameValue("__zjs_callsite" in site, false);
        \\    assert.sameValue("__zjs_callsite_line" in site, false);
        \\    assert.sameValue(typeof site.getFunction, "function");
        \\    assert.sameValue(typeof site.getThis, "undefined");
        \\    assert.sameValue(site.hasOwnProperty("getFunction"), false);
        \\    assert.sameValue(site.toString(), "[object CallSite]");
        \\    assert.sameValue(Object.prototype.toString.call(site), "[object CallSite]");
        \\    assert.sameValue(site[Symbol.toStringTag], "CallSite");
        \\    var name = site.getFunctionName();
        \\    var file = site.getFileName();
        \\    var line = site.getLineNumber();
        \\    var column = site.getColumnNumber();
        \\    site.__zjs_callsite_function = "fakeFn";
        \\    site.__zjs_callsite_file = "fake.js";
        \\    site.__zjs_callsite_line = 999;
        \\    site.__zjs_callsite_column = 777;
        \\    assert.sameValue(site.getFunctionName(), name);
        \\    assert.sameValue(site.getFileName(), file);
        \\    assert.sameValue(site.getLineNumber(), line);
        \\    assert.sameValue(site.getColumnNumber(), column);
        \\    assert.sameValue(site.toString().indexOf("fake"), -1);
        \\    return "ok";
        \\};
        \\function inner() {
        \\    return new Error("x").stack;
        \\}
        \\assert.sameValue(inner(), "ok");
        \\Error.prepareStackTrace = undefined;
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Error stack uses object method runtime names" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var object = {
        \\    return() {
        \\        return new Error("x").stack;
        \\    }
        \\};
        \\var stack = object.return();
        \\assert.sameValue(stack.indexOf("at return") >= 0, true);
        \\assert.sameValue(stack.indexOf("    at return"), 0);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Error stack preserves construction frames across delayed access" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function makeError() {
        \\    return new Error("x");
        \\}
        \\var err = makeError();
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(err, "stack"), false);
        \\function readStack(error) {
        \\    return error.stack;
        \\}
        \\var stack = readStack(err);
        \\assert.sameValue(typeof stack, "string");
        \\assert.sameValue(stack.indexOf("at makeError") >= 0, true);
        \\assert.sameValue(stack.indexOf("at readStack") < 0, true);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Error prepareStackTrace formats captured frames lazily" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var calls = 0;
        \\Error.prepareStackTrace = function() {
        \\    calls++;
        \\    return "early";
        \\};
        \\function makeError() {
        \\    return new Error("x");
        \\}
        \\var err = makeError();
        \\assert.sameValue(calls, 0);
        \\Error.prepareStackTrace = function(error, sites) {
        \\    calls++;
        \\    assert.sameValue(error, err);
        \\    assert.sameValue(sites[0].getFunctionName(), "makeError");
        \\    return "late:" + sites[0].getFunctionName();
        \\};
        \\assert.sameValue(err.stack, "late:makeError");
        \\assert.sameValue(calls, 1);
        \\assert.sameValue(err.stack, "late:makeError");
        \\assert.sameValue(calls, 1);
        \\Error.prepareStackTrace = undefined;
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Error stack setter rejects non-string stack values" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var err = new Error("x");
        \\assert.throws(TypeError, function() {
        \\    err.stack = 123;
        \\});
        \\assert.throws(TypeError, function() {
        \\    Object.getOwnPropertyDescriptor(Error.prototype, "stack").set.call(err);
        \\});
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(err, "stack"), false);
        \\assert.sameValue(typeof err.stack, "string");
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Error stack copied accessor setter writes without recursion" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var err = new Error("x");
        \\Object.defineProperty(err, "stack", Object.getOwnPropertyDescriptor(Error.prototype, "stack"));
        \\assert.throws(TypeError, function() {
        \\    err.stack = 123;
        \\});
        \\err.stack = "updated";
        \\var desc = Object.getOwnPropertyDescriptor(err, "stack");
        \\assert.sameValue(desc.value, "updated");
        \\assert.sameValue(desc.writable, true);
        \\assert.sameValue(err.stack, "updated");
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Error stack copied accessor setter writes through proxy without recursion" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var proxy = new Proxy(new Error("x"), {});
        \\Object.defineProperty(proxy, "stack", Object.getOwnPropertyDescriptor(Error.prototype, "stack"));
        \\proxy.stack = "updated";
        \\var desc = Object.getOwnPropertyDescriptor(proxy, "stack");
        \\assert.sameValue(desc.value, "updated");
        \\assert.sameValue(desc.writable, true);
        \\assert.sameValue(proxy.stack, "updated");
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Error stack reentrant formatting is capped to captured frames" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var previousLimit = Error.stackTraceLimit;
        \\Error.stackTraceLimit = 1;
        \\var calls = 0;
        \\Error.prepareStackTrace = function(error, sites) {
        \\    calls++;
        \\    sites.length = 3;
        \\    sites[2] = sites[0];
        \\    return error.stack;
        \\};
        \\var stack = new Error("x").stack;
        \\Error.prepareStackTrace = undefined;
        \\Error.stackTraceLimit = previousLimit;
        \\var frames = String(stack).split("\n").filter(function(line) {
        \\    return line.indexOf("    at ") === 0;
        \\});
        \\assert.sameValue(calls, 1);
        \\assert.sameValue(frames.length, 1);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Array fill respects proxy prototypes" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var calls = [];
        \\var array = new Array(3);
        \\Object.setPrototypeOf(array, new Proxy(Array.prototype, {
        \\    set: function(target, key, value, receiver) {
        \\        calls.push(String(key) + ":" + value);
        \\        return Reflect.set(target, key, value, receiver);
        \\    }
        \\}));
        \\Array.prototype.fill.call(array, 7);
        \\assert.sameValue(calls.join(","), "0:7,1:7,2:7");
        \\assert.sameValue(array.join(","), "7,7,7");
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Error.prepareStackTrace exceptions produce null stack" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\Error.prepareStackTrace = function() {
        \\    throw new TypeError("prep");
        \\};
        \\assert.sameValue(new Error("x").stack, null);
        \\Error.prepareStackTrace = undefined;
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine runtime-strict file eval matches QuickJS CLI script surface" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileWithOutputModeRuntimeStrict(
        \\function strictThis() { return this === undefined; }
        \\function cliLocalFunction() {}
        \\print(this === undefined);
        \\print(strictThis());
        \\var desc = Object.getOwnPropertyDescriptor(globalThis, "cliLocalFunction");
        \\print(desc === undefined);
        \\print(cliLocalFunction.name);
        \\var roProto = {};
        \\Object.defineProperty(roProto, "locked", { value: 1, writable: false, configurable: true });
        \\var roObj = Object.create(roProto);
        \\try { roObj.locked = 2; print(false); } catch (e) { print(e instanceof TypeError); }
        \\try { missingQuickJsCliStrict = 1; print(false); } catch (e) { print(e instanceof ReferenceError); }
        \\var capture;
        \\eval("var evalCreated = 5; capture = function(){ return evalCreated; };");
        \\print(evalCreated);
        \\print(delete evalCreated);
        \\try { print(capture()); } catch (e) { print(e instanceof ReferenceError); }
    , &stream, .script, "runtime-strict-file.js", true);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\ntrue\ntrue\ncliLocalFunction\ntrue\ntrue\n5\ntrue\ntrue\n", stream.buffered());
}

test "Engine strict script top-level this remains the global object" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\"use strict";
        \\print(this === globalThis);
        \\function strictThis() { return this === undefined; }
        \\print(strictThis());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\ntrue\n", stream.buffered());
}

test "Engine direct eval publishes Annex B block functions" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\eval("{ function annexBEvalGlobalFn() { return 'global'; } }");
        \\assert.sameValue(annexBEvalGlobalFn(), "global");
        \\delete globalThis.annexBEvalGlobalFn;
        \\
        \\var init, changed, localAfter, functionAfter;
        \\(function() {
        \\  eval("init = annexBEvalLocalFn; annexBEvalLocalFn = 123; changed = annexBEvalLocalFn; { function annexBEvalLocalFn() { return 'local'; } } localAfter = annexBEvalLocalFn();");
        \\  functionAfter = annexBEvalLocalFn();
        \\}());
        \\assert.sameValue(init, undefined);
        \\assert.sameValue(changed, 123);
        \\assert.sameValue(localAfter, "local");
        \\assert.sameValue(functionAfter, "local");
        \\assert.throws(ReferenceError, function() { annexBEvalLocalFn; });
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine direct eval Annex B block function updates same-name parameter" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var init, after;
        \\(function(f) {
        \\  eval("init = f; { function f() {} } after = f;");
        \\}(123));
        \\print(init);
        \\print(typeof after);
        \\print(after());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("123\nfunction\nundefined\n", stream.buffered());
}

test "Engine eval supports Annex B escape and unescape code-unit semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(escape('\u0100\u0101\u0102'), '%u0100%u0101%u0102');
        \\assert.sameValue(escape('\ufffd\ufffe\uffff'), '%uFFFD%uFFFE%uFFFF');
        \\assert.sameValue(escape('\ud834\udf06'), '%uD834%uDF06');
        \\assert.sameValue(escape('{|}~\x7f\x80'), '%7B%7C%7D%7E%7F%80');
        \\assert.sameValue(unescape('%0%FE00'), '%0\xfe00');
        \\assert.sameValue(escape(unescape('%u0100')), '%u0100');
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine eval supports Annex B Date setYear ordering" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var dt = new Date(0);
        \\var called = 0;
        \\var value = { valueOf: function() { called++; dt.setTime(NaN); return 1; } };
        \\var result = dt.setYear(value);
        \\assert.sameValue(called, 1);
        \\assert.notSameValue(result, NaN);
        \\assert.sameValue(result, dt.getTime());
        \\assert.sameValue(dt.getYear(), 1);
        \\assert.throws(TypeError, function() { dt.setYear(Symbol("x")); });
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine eval supports Annex B String HTML wrappers and trim aliases" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue("_".big(), "<big>_</big>");
        \\assert.sameValue(String.prototype.big.call(0x2A), "<big>42</big>");
        \\assert.sameValue("x".anchor('a"b'), '<a name="a&quot;b">x</a>');
        \\assert.sameValue(String.prototype.trimLeft, String.prototype.trimStart);
        \\assert.sameValue(String.prototype.trimLeft.name, "trimStart");
        \\assert.sameValue(Number.isNaN("x"), false);
        \\assert.sameValue(Number.isFinite(1), true);
        \\assert.sameValue(Number.isFinite("1"), false);
        \\assert.sameValue(isFinite("1"), true);
        \\assert.sameValue(isFinite(Infinity), false);
        \\assert.sameValue(Math.trunc(-1.9), -1);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine eval TypeError with evaluated arguments does not double free constants" {
    {
        var js = try engine.harness.Engine.init(std.testing.allocator);
        defer js.deinit();
        try std.testing.expectError(error.TypeError, js.eval("const obj = {}; obj.missing(\"a\", \"a\");"));
    }
    {
        var js = try engine.harness.Engine.init(std.testing.allocator);
        defer js.deinit();
        try std.testing.expectError(error.TypeError, js.eval("RegExp.test(\"a\", \"a\");"));
    }
}

test "vm call handler accepts allocator-backed argument lists" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const name = try rt.internAtom("wide-call");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    const print_key = try rt.internAtom("print");
    defer rt.atoms.free(print_key);
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try bytes.append(rt.memory.allocator, op.get_var);
    try bytes.appendSlice(rt.memory.allocator, std.mem.asBytes(&print_key));
    var arg: i32 = 1;
    while (arg <= 40) : (arg += 1) {
        try bytes.append(rt.memory.allocator, op.push_i32);
        try bytes.appendSlice(rt.memory.allocator, std.mem.asBytes(&arg));
    }
    try bytes.append(rt.memory.allocator, op.call);
    const argc: u16 = 40;
    try bytes.appendSlice(rt.memory.allocator, std.mem.asBytes(&argc));
    try function.setCode(bytes.items);

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    var vm_instance = engine.exec.Vm.initWithOutput(ctx, &stream);
    defer vm_instance.deinit();
    const result = try vm_instance.run(&function);
    defer result.free(rt);

    var expected = std.ArrayList(u8).empty;
    defer expected.deinit(std.testing.allocator);
    var expected_arg: i32 = 1;
    while (expected_arg <= 40) : (expected_arg += 1) {
        if (expected_arg != 1) try expected.append(std.testing.allocator, ' ');
        var int_buf: [16]u8 = undefined;
        const printed = try std.fmt.bufPrint(&int_buf, "{d}", .{expected_arg});
        try expected.appendSlice(std.testing.allocator, printed);
    }
    try expected.append(std.testing.allocator, '\n');

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(expected.items, stream.buffered());
}

test "Engine API eval and job queue are wired" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval("1 2");
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());

    helpers.job_counter = 0;
    try js.runtime.job_queue.enqueueFunc(js.context, countJob, &.{});
    try js.runtime.job_queue.enqueueFunc(js.context, countJob, &.{});
    try js.runJobs();
    try std.testing.expectEqual(@as(usize, 2), helpers.job_counter);

    helpers.job_counter = 0;
    var i: usize = 0;
    while (i < 16) : (i += 1) try js.runtime.job_queue.enqueueFunc(js.context, countJob, &.{});
    try js.runJobs();
    try std.testing.expectEqual(@as(usize, 16), helpers.job_counter);

    helpers.job_counter = 0;
    try js.runtime.job_queue.enqueueFunc(js.context, countJobArgs, &.{ core.JSValue.int32(2), core.JSValue.int32(3) });
    try js.runJobs();
    try std.testing.expectEqual(@as(usize, 5), helpers.job_counter);

    helpers.job_counter = 0;
    try js.runtime.job_queue.enqueueFunc(js.context, countJobArgs, &.{
        core.JSValue.int32(1),
        core.JSValue.int32(2),
        core.JSValue.int32(3),
        core.JSValue.int32(4),
        core.JSValue.int32(5),
    });
    try js.runJobs();
    try std.testing.expectEqual(@as(usize, 15), helpers.job_counter);

    try std.testing.expectError(error.TooManyJobArgs, js.runtime.job_queue.enqueueFunc(js.context, countJobArgs, &.{
        core.JSValue.int32(1),
        core.JSValue.int32(2),
        core.JSValue.int32(3),
        core.JSValue.int32(4),
        core.JSValue.int32(5),
        core.JSValue.int32(6),
    }));
    try std.testing.expectEqual(@as(usize, 0), js.runtime.job_queue.jobs.len);
}

test "job queue enqueue propagates allocator failure" {
    var buffer: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    var account = core.memory.MemoryAccount.init(fixed.allocator());
    var queue = engine.exec.jobs.Queue.init(&account);
    defer queue.deinit();

    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    try std.testing.expectError(error.OutOfMemory, queue.enqueueFunc(js.context, countJob, &.{}));
    try std.testing.expectEqual(@as(usize, 0), queue.jobs.len);
}

test "job queue keeps symbol arguments rooted until release" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    var queue = engine.exec.jobs.Queue.init(&rt.memory);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-job-queue-symbol");
    try queue.enqueueFunc(ctx, countJob, &.{core.JSValue.symbol(symbol_atom)});

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);

    queue.deinit();
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "job queue symbol roots preserve weak map values" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    var queue = engine.exec.jobs.Queue.init(&rt.memory);

    const weak_map = try core.Object.create(rt, core.class.ids.weakmap, null);
    defer weak_map.value().free(rt);

    const value = try core.Object.create(rt, core.class.ids.object, null);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-job-queue-weak-key");
    try engine.builtins.collection.setWeakMapEntry(rt, weak_map, core.JSValue.symbol(symbol_atom), value.value());
    value.value().free(rt);

    try queue.enqueueFunc(ctx, countJob, &.{core.JSValue.symbol(symbol_atom)});
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    try std.testing.expectEqual(@as(usize, 1), weak_map.weakCollectionEntries().len);
    try std.testing.expectEqual(&value.header, weak_map.weakCollectionEntries()[0].value.refHeader().?);

    queue.deinit();
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
    try std.testing.expectEqual(@as(usize, 0), weak_map.weakCollectionEntries().len);
}

test "Engine eval executes simple variable assignment and print" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("let value = 5; value = value + 7; print(value);", &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("12\n", stream.buffered());
}

test "Engine eval assigns contextual await bindings in sloppy scripts" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [16]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var await = 0;
        \\await = 1;
        \\print(await);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\n", stream.buffered());
}

test "Engine eval creates non-configurable enumerable global var bindings" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(delete __globalVar);
        \\var __globalVar = "defined";
        \\print(__globalVar);
        \\print(delete __globalVar, delete this["__globalVar"]);
        \\var seen = false;
        \\for (var key in this) { if (key === "__globalVar") seen = true; }
        \\print(seen);
        \\var first = 1, second = first + 1, third;
        \\print(first, second, third);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false\ndefined\nfalse false\ntrue\n1 2 undefined\n", stream.buffered());
}

test "Engine eval executes object property assignment through quick parser" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("const obj = { x: 1 }; obj.x = obj.x + 2; print(obj.x);", &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3\n", stream.buffered());
}

test "Engine eval executes parenthesized literal postfix through quick parser" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("const obj = { x: 1 }; print(({ y: obj.x + 2 }).y); print(([3, 4])[1]);", &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3\n4\n", stream.buffered());
}

test "Engine eval executes compound assignment and update statements through quick parser" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("let x = 10; x += 5; x -= 3; x *= 2; x /= 4; x %= 5; x++; x--; print(x);", &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\n", stream.buffered());
}

test "Engine eval executes console.log with many arguments" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("console.log(1,2,3,4,5,6,7,8,9,10);", &stream);
    defer result.free(js.runtime);
    const output = stream.buffered();
    try std.testing.expectEqualStrings("1 2 3 4 5 6 7 8 9 10\n", output);
}

test "Engine eval routes host output through global function calls" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(1);
        \\console.log("x");
        \\const out = print;
        \\out(2 + 3, typeof out);
        \\const logger = console.log;
        \\logger("ok");
        \\const c = console;
        \\c.log("alias");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\nx\n5 function\nok\nalias\n", stream.buffered());
}

test "Engine eval preserves one-shot array literal host output semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function lengthOnly() {
        \\  let tab = [1, 2];
        \\  print(tab.length);
        \\}
        \\print(lengthOnly() === undefined);
        \\function valueAndLength() {
        \\  let tab = [2];
        \\  print(tab[0]);
        \\  print(tab.length);
        \\}
        \\print(valueAndLength() === undefined);
        \\let oldPrint = print;
        \\print = function(x) { globalThis.seen = (globalThis.seen || "") + "[" + x + "]"; };
        \\let tab = [2];
        \\print(tab[0]);
        \\print(tab.length);
        \\oldPrint(globalThis.seen);
        \\print = oldPrint;
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("2\ntrue\n2\n1\ntrue\n[2][1]\n", stream.buffered());
}

test "Engine eval preserves one-shot array named property host output semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let tab = [1];
        \\tab.a = 9;
        \\print(tab.a);
        \\let oldPrint = print;
        \\print = function(x) { oldPrint("custom:" + x); };
        \\let tab2 = [1];
        \\tab2.a = 8;
        \\print(tab2.a);
        \\print = oldPrint;
        \\let seen = 0;
        \\Object.defineProperty(Array.prototype, "guarded", {
        \\  set: function(v) { seen = v + 1; },
        \\  get: function() { return seen; },
        \\  configurable: true
        \\});
        \\let tab3 = [1];
        \\tab3.guarded = 7;
        \\print(tab3.guarded);
        \\delete Array.prototype.guarded;
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("9\ncustom:8\n8\n", stream.buffered());
}

test "Engine eval preserves typed array constructor length host output semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function lengthOnly() {
        \\  let tab = new Int32Array(new ArrayBuffer(16));
        \\  print(tab.length);
        \\}
        \\print(lengthOnly() === undefined);
        \\let oldPrint = print;
        \\print = function(x) { globalThis.seen = "print:" + x; };
        \\let tab = new Int32Array(new ArrayBuffer(16));
        \\print(tab.length);
        \\oldPrint(globalThis.seen);
        \\print = oldPrint;
        \\let OldTA = Int32Array;
        \\Int32Array = function(buffer) { this.length = 99; };
        \\let fake = new Int32Array(new ArrayBuffer(16));
        \\print(fake.length);
        \\Int32Array = OldTA;
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("4\ntrue\nprint:4\n99\n", stream.buffered());
}

test "Engine eval executes simple template interpolation" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("const x = 10; const y = 20; print(`${x} + ${y} = ${x + y}`);", &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("10 + 20 = 30\n", stream.buffered());
}

test "Engine eval template interpolation calls object toString" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        "const x = { toString(){ return 'custom'; } }; print(`${x}`);",
        &stream,
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("custom\n", stream.buffered());
}

test "Engine eval executes simple arrays and map" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("const arr = [1, 2, 3]; print(arr); print(arr.length); print(arr[0]); print(arr.map(x => x * 2));", &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1,2,3\n3\n1\n2,4,6\n", stream.buffered());
}

test "Engine eval executes simple functions and arrows" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [160]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function add(a, b) { return a + b; }
        \\print(add(2, 3));
        \\const double = x => x * 2;
        \\print(double(21));
        \\function fact(n) { return n <= 1 ? 1 : n * fact(n - 1); }
        \\print(fact(6));
        \\const mul = (a, b) => { return a * b; };
        \\print(mul(3, 4));
        \\function varArguments() { return typeof arguments; var arguments = 1; }
        \\print(varArguments(42));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("5\n42\n720\n12\nobject\n", stream.buffered());
}

test "Engine eval Function.prototype.toString returns source or native text" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [768]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function f(x) { return x; }
        \\print(f.toString());
        \\function /* a */ g /* b */ ( /* c */ y /* d */ ) /* e */ { /* f */ return y; /* g */ }
        \\print(g.toString());
        \\const arrow = y => y + 1;
        \\print(arrow.toString());
        \\print(print.toString());
        \\try { Function.prototype.toString.call({}); } catch (e) { print(e.name); }
        \\try { String({ toString: Function.prototype.toString }); } catch (e) { print(e.name); }
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "function f(x) { return x; }\n" ++
            "function /* a */ g /* b */ ( /* c */ y /* d */ ) /* e */ { /* f */ return y; /* g */ }\n" ++
            "y => y + 1\n" ++
            "function print() {\n    [native code]\n}\n" ++
            "TypeError\n" ++
            "TypeError\n",
        stream.buffered(),
    );
}

test "Engine eval Function.prototype.toString emits syntactic native names" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var native = " {\n    [native code]\n}";
        \\var invalid = Object.getOwnPropertyDescriptor(RegExp, "$&").get.toString();
        \\assert.sameValue(invalid, "function get()" + native);
        \\assert.sameValue(invalid.indexOf("get $&"), -1);
        \\var valid = Object.getOwnPropertyDescriptor(RegExp, "input").get.toString();
        \\assert.sameValue(valid, "function get input()" + native);
        \\var computed = Object.getOwnPropertyDescriptor(Array, Symbol.species).get.toString();
        \\assert.sameValue(computed, "function get [Symbol.species]()" + native);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Engine eval Function.prototype.toString returns method and class source" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [1280]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const method = { /* before */ f /* a */ ( /* b */ ) /* c */ { /* d */ } /* after */ }.f;
        \\print(method.toString());
        \\const asyncComputed = { async /* a */ [ /* b */ "g" /* c */ ] /* d */ ( /* e */ ) /* f */ { /* g */ } }.g;
        \\print(asyncComputed.toString());
        \\const asyncGeneratorComputed = { async /* a */ * /* b */ [ /* c */ "h" /* d */ ] /* e */ ( /* f */ ) /* g */ { /* h */ } }.h;
        \\print(asyncGeneratorComputed.toString());
        \\function B() {}
        \\const C = class /* a */ A /* b */ extends /* c */ B /* d */ { /* e */ constructor /* f */ ( /* g */ ) /* h */ { /* i */ } /* j */ };
        \\print(C.toString());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "f /* a */ ( /* b */ ) /* c */ { /* d */ }\n" ++
            "async /* a */ [ /* b */ \"g\" /* c */ ] /* d */ ( /* e */ ) /* f */ { /* g */ }\n" ++
            "async /* a */ * /* b */ [ /* c */ \"h\" /* d */ ] /* e */ ( /* f */ ) /* g */ { /* h */ }\n" ++
            "class /* a */ A /* b */ extends /* c */ B /* d */ { /* e */ constructor /* f */ ( /* g */ ) /* h */ { /* i */ } /* j */ }\n",
        stream.buffered(),
    );
}

test "Engine eval releases arrow destructuring iterator closures cleanly" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var doneCallCount = 0;
        \\var iter = {};
        \\iter[Symbol.iterator] = function() {
        \\  return {
        \\    next: function() { return { value: null, done: false }; },
        \\    return: function() { doneCallCount = doneCallCount + 1; return {}; }
        \\  };
        \\};
        \\var f = ([x]) => { print(doneCallCount); };
        \\f(iter);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\n", stream.buffered());
}

test "Engine eval preserves one-shot object missing field host output semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let obj = { a: 1 };
        \\print(obj.b === undefined);
        \\let obj2 = { a: 1 };
        \\print(obj2.a === undefined);
        \\let oldPrint = print;
        \\print = function(x) { oldPrint("custom:" + x); };
        \\let obj3 = { a: 1 };
        \\print(obj3.b === undefined);
        \\print = oldPrint;
        \\{
        \\  let undefined = 1;
        \\  let obj4 = { a: 1 };
        \\  print(obj4.b === undefined);
        \\}
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\nfalse\ncustom:true\nfalse\n", stream.buffered());
}

test "Engine runJobs preserves pending JS exceptions for callers" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();
    js.context.preserve_uncaught_exception = true;

    const setup = try js.eval("var __zjs_timer_throw = function() { throw new Error('timer boom'); };");
    defer setup.free(js.runtime);
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const callback_key = try js.runtime.internAtom("__zjs_timer_throw");
    defer js.runtime.atoms.free(callback_key);
    const callback = global.getProperty(callback_key);
    defer callback.free(js.runtime);

    try js.context.ensureOsTimerCapacity(1);
    const timer_index = js.context.os_timers.len;
    js.context.os_timers = js.context.os_timers.ptr[0 .. timer_index + 1];
    js.context.os_timers[timer_index] = try core.OsTimer.init(js.context, 1, callback, 0, 0, false);

    try js.runJobs();
    try std.testing.expect(js.context.hasException());

    var exception = try js.takeExceptionInfo();
    defer exception.deinit();
}

test "host module graph syntax diagnostics do not write to program output" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const modules = [_]HostFixtureModule{
        .{
            .specifier = "./bad.js",
            .path = "/fixture/bad.js",
            .source = "export const = ;",
            .kind = .esm,
        },
    };
    const host = HostFixture{ .modules = &modules };
    const hooks = hostHooks(&host);

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    try std.testing.expectError(
        error.SyntaxError,
        js.evalFileModuleGraphWithHostHooks(
            "import './bad.js';",
            &stream,
            "/fixture/main.mjs",
            hooks,
            std.testing.allocator,
        ),
    );
    try std.testing.expectEqualStrings("", stream.buffered());
}

test "host commonjs wrapper passes directory dirname" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const modules = [_]HostFixtureModule{
        .{
            .specifier = "./lib/dep.cjs",
            .path = "/fixture/lib/dep.cjs",
            .source =
            \\module.exports = {
            \\  filename: __filename,
            \\  dirname: __dirname,
            \\};
            ,
            .kind = .commonjs,
        },
    };
    const host = HostFixture{ .modules = &modules };
    const hooks = hostHooks(&host);

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithHostHooks(
        \\import info from './lib/dep.cjs';
        \\assert.sameValue(info.filename, '/fixture/lib/dep.cjs');
        \\assert.sameValue(info.dirname, '/fixture/lib');
    ,
        &stream,
        "/fixture/main.mjs",
        hooks,
        std.testing.allocator,
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("", stream.buffered());
}

const HostFixtureModule = struct {
    specifier: []const u8,
    path: []const u8,
    source: []const u8,
    kind: engine.harness.Engine.HostHooks.ModuleKind,
};

const HostFixture = struct {
    modules: []const HostFixtureModule,

    fn findBySpecifierOrPath(self: HostFixture, specifier: []const u8) ?HostFixtureModule {
        for (self.modules) |module| {
            if (std.mem.eql(u8, module.specifier, specifier) or std.mem.eql(u8, module.path, specifier)) return module;
        }
        return null;
    }

    fn findByPath(self: HostFixture, path: []const u8) ?HostFixtureModule {
        for (self.modules) |module| {
            if (std.mem.eql(u8, module.path, path)) return module;
        }
        return null;
    }
};

fn hostHooks(host: *const HostFixture) engine.harness.Engine.HostHooks {
    return .{
        .ptr = @constCast(host),
        .resolveModule = resolveFixtureModule,
        .loadModule = loadFixtureModule,
    };
}

fn resolveFixtureModule(
    ptr: *anyopaque,
    specifier: []const u8,
    referrer: ?[]const u8,
    allocator: std.mem.Allocator,
) anyerror!engine.harness.Engine.HostHooks.ResolvedModule {
    _ = referrer;
    const host: *const HostFixture = @ptrCast(@alignCast(ptr));
    const module = host.findBySpecifierOrPath(specifier) orelse return error.ModuleNotFound;
    return .{
        .specifier = try allocator.dupe(u8, specifier),
        .path = try allocator.dupe(u8, module.path),
        .kind = module.kind,
    };
}

fn loadFixtureModule(
    ptr: *anyopaque,
    resolved: engine.harness.Engine.HostHooks.ResolvedModule,
    allocator: std.mem.Allocator,
) anyerror!engine.harness.Engine.HostHooks.LoadedModule {
    const host: *const HostFixture = @ptrCast(@alignCast(ptr));
    const module = host.findByPath(resolved.path) orelse return error.ModuleNotFound;
    return .{
        .source = module.source,
        .path = try allocator.dupe(u8, module.path),
        .kind = module.kind,
        .owned = false,
    };
}
