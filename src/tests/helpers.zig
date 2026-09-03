//! Shared test harness consumed by Class-B roots (roots that pull the engine
//! through the `zjs` module). Top-level declarations are the former
//! `exec.zig` `helpers` namespace so `helpers.foo` call sites stay unchanged.
//!
//! Rule D: this file `@import("zjs")` internally, so only Class-B roots may
//! consume it. `src/compiler/tests.zig` and in-tree runtime tests must
//! never import this file — those roots already span the engine subtree by
//! relative path, and pulling helpers in would be a file-exists-in-two-modules
//! error.

const std = @import("std");
const zjs = @import("zjs");
const engine = zjs;
const core = zjs.core;
const QjsLexer = zjs.parser.Lexer;
const parser_core = zjs.parser.Parser;
const ParseState = parser_core.ParseState;
const op = zjs.bytecode.opcode.op;

const helpers = @This();

/// Every TypeScript execution test goes through here.
pub fn evalTypeScriptChecked(engine_instance: *TestEngine, source: []const u8, options: EvalOptions) RuntimeError!core.JSValue {
    return engine_instance.evalWithOptions(source, options);
}

/// Install the standard + host globals on a bare `core.JSRuntime` global for
/// tests that build a runtime directly (bypassing the binding-layer context
/// create that wires the installer). The deep setup interface keeps the
/// installer callback and its capacity invariant together. Idempotent.
pub fn registerStandardGlobalsBare(rt: *core.JSRuntime) void {
    engine.exec.standard_globals.configureRuntime(rt);
}

pub fn installHostGlobalsBare(rt: *core.JSRuntime, global: *core.Object) !void {
    const exec_call = engine.exec.call;
    registerStandardGlobalsBare(rt);
    try exec_call.installHostGlobals(rt, global);
}

pub fn makeFunction(rt: *core.JSRuntime, code: []const u8) !engine.bytecode.Bytecode {
    const name = try rt.internAtom("exec");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    errdefer function.deinit(rt);
    try setCodeAndStackSize(&function, code);
    return function;
}

pub fn makeUncheckedFunction(rt: *core.JSRuntime, code: []const u8) !engine.bytecode.Bytecode {
    const name = try rt.internAtom("exec");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    errdefer function.deinit(rt);
    try function.setCode(code);
    return function;
}

pub fn setCodeAndStackSize(function: *engine.bytecode.Bytecode, code: []const u8) !void {
    try function.setCode(code);
    function.stack_size = try engine.bytecode.pipeline.stack_size.compute(function.code, .{});
}

pub fn runFunction(rt: *core.JSRuntime, ctx: *core.JSContext, function: *const engine.bytecode.Bytecode) !core.JSValue {
    registerStandardGlobalsBare(rt);
    var vm_instance = engine.exec.Vm.init(ctx);
    defer vm_instance.deinit();
    return runMutableVm(&vm_instance, function);
}

pub fn runMutableVm(vm: *engine.exec.Vm, function: *const engine.bytecode.Bytecode) !core.JSValue {
    // Fixture top-level Bytecode lives on the native stack (it is not a
    // registered gc object), and its malloc'd cpool array holds the only
    // strong refs to child FunctionBytecodes. Neither precise roots nor the
    // conservative stack scan can reach those children (the scan does not
    // chase malloc'd arrays), so a tracing collection during the run would
    // sweep them mid-execution (wide-fclosure autopsy, 2026-08-24). Root the
    // cpool window for the duration of the run; default `rc` erases this.
    const rt = vm.ctx.runtime;
    var cpool_roots = [_]core.runtime.ValueRootSlice{.{ .borrowed = function.cpoolSlice() }};
    var fixture_frame = core.runtime.ValueRootFrame{ .slices = &cpool_roots };
    fixture_frame.activate(rt);
    defer fixture_frame.deactivate(rt);
    var execution_adapter: engine.bytecode.LegacyExecutionAdapter = undefined;
    return vm.run(execution_adapter.init(function));
}

/// Reclaim whatever the test has just dropped its last reference to.
///
/// Under refcounting the drop itself destroys, so a test can assert on
/// `liveCount()`, heap stats or a finalizer having run the instant it releases.
/// Under the tracer nothing is reclaimed until a collection runs, and a test
/// that asserts the refcounting timing would only be asserting that RC is still
/// doing the work -- which is the thing being removed. Interposing a collection
/// keeps one test body meaningful in both builds.
///
/// The scan is `declared_only` (via `runObjectCycleRemoval`), so anything the
/// test still holds must be named in a `rootValues`/`rootObjects` frame. That
/// is deliberate: it is the precise-scan discipline that makes these tests
/// deterministic, and it is what turns a missing root into a test failure
/// rather than into a conservative-scan accident.
pub fn reclaimNow(rt: *core.JSRuntime) void {
    _ = rt.runObjectCycleRemoval();
}

/// Assert a refcount that is the ownership record under refcounting.
///
/// Under the tracer the count is not maintained at all for the kinds it owns
/// (`core.gc.refCountRemoved`), so there is no arithmetic left to check and the
/// assertion is skipped rather than deleted -- the refcounting build still
/// guards exactly what it always did. Kinds the tracer does not own (strings,
/// ropes, BigInt, and also shapes and realms, which keep their counts for
/// copy-on-write and host-handle reasons) are checked in both builds.
pub fn expectRefCount(expected: i32, header: anytype) !void {
    const h = core.gc.headerPtrConst(header);
    if (core.gc.refCountRemoved(h.metaConst().flags.kind)) return;
    try std.testing.expectEqual(expected, core.gc.headerRefCount(h));
}

/// Snapshot helper for tests whose expected arithmetic is asserted through
/// expectRefCount. Tracer-owned kinds deliberately have no count; return their
/// historical birth value only so the skipped arithmetic remains well-typed.
pub fn refCountSnapshot(header: anytype) i32 {
    const h = core.gc.headerPtrConst(header);
    if (core.gc.refCountRemoved(h.metaConst().flags.kind)) return 1;
    return core.gc.headerRefCount(h);
}

pub fn objectFromValue(value: core.JSValue) *core.Object {
    return core.value_semantics.objectFromValue(value).?;
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
    const string = value.asStringBody().?;
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

pub fn expectPrints(source: []const u8, expected: []const u8) !void {
    const js = sharedTestEngine();
    defer endSharedTest();

    var output_buffer: [8192]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(source, &output);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(expected, output.buffered());
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
//     var js = try helpers.TestEngine.init(std.testing.allocator);
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
// `helpers.TestEngine.init` per call; the shared-engine pattern is
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
//
// Process exit (atexit, registered on first `sharedTestEngine()`)
// restores the baseline, releases the snapshot's extra retains, then
// destroys only the host-owned main context and the runtime. Leftover
// `$262.createRealm()` children are cycle-collected there. Do not walk
// `context_head` and `JSContext.destroy` them.

const module_graph = engine.exec.module_graph;
const RuntimeError = engine.exec.exceptions.RuntimeError;

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
        if (value.isObject()) {
            const header = value.refHeader() orelse return error.InvalidEngineState;
            const object: *core.Object = core.Object.fromHeader(header);

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
        defer temp_list.deinit(rt.memory.allocator);
        try engine.exec.value_ops.appendValueString(rt, &temp_list, value);
        return try allocator.dupe(u8, temp_list.items);
    }

    pub fn getStack(self: ExceptionInfo, allocator: std.mem.Allocator) !?[]const u8 {
        const rt = self.value.runtime orelse return error.InvalidEngineState;
        const value = self.value.get();
        if (!value.isObject()) return null;
        const header = value.refHeader() orelse return null;
        const object: *core.Object = core.Object.fromHeader(header);
        return try getPropertyString(rt, object, "stack", allocator);
    }
};

fn getPropertyString(rt: *core.JSRuntime, obj: *core.Object, name: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    const val = try obj.getProperty(key);
    defer val.free(rt);
    if (!val.isString()) return null;

    var temp_list = std.ArrayList(u8).empty;
    defer temp_list.deinit(rt.memory.allocator);
    try engine.exec.value_ops.appendRawString(rt, &temp_list, val);
    return try allocator.dupe(u8, temp_list.items);
}

const EngineOptions = struct {
    allocator: std.mem.Allocator,
    trace_writer: ?*std.Io.Writer = null,
    limits: Limits = .{},
};

const EvalOptions = core.context.ContextEvalOptions;

pub const TestEngine = struct {
    allocator: std.mem.Allocator,
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    event_loop: *engine.runtime.EventLoop,

    pub const HostHooks = module_graph.HostHooks;

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
        registerStandardGlobalsBare(rt);
        rt.setNativeStackSize(core.runtime.default_native_stack_size * 4);
        const ctx = try core.JSContext.create(rt);
        errdefer ctx.destroy();
        const event_loop = try options.allocator.create(engine.runtime.EventLoop);
        errdefer options.allocator.destroy(event_loop);
        event_loop.* = engine.runtime.EventLoop.initCore(ctx, .{});
        event_loop.install();
        return .{
            .allocator = options.allocator,
            .runtime = rt,
            .context = ctx,
            .event_loop = event_loop,
        };
    }

    pub fn deinit(self: *TestEngine) void {
        var wrapper = zjs.JSContext.borrowCore(self.context);
        wrapper.runJobs(null) catch {};
        self.event_loop.deinit();
        self.allocator.destroy(self.event_loop);
        const run_test262 = @import("../cli/run_test262.zig");
        _ = run_test262.cleanupTest262Agents(self.runtime);
        engine.exec.zjs_vm.cleanupAtomicsWaitersForContext(self.context);
        self.context.destroy();
        self.runtime.destroy();
    }

    pub fn eval(self: *TestEngine, source_text: []const u8) RuntimeError!core.JSValue {
        return self.evalMode(source_text, .script);
    }

    pub fn evalHandle(self: *TestEngine, source_text: []const u8) RuntimeError!core.JSValueHandle {
        return self.evalHandleWithOptions(source_text, .{});
    }

    pub fn evalModule(self: *TestEngine, source_text: []const u8) RuntimeError!core.JSValue {
        return self.evalMode(source_text, .module);
    }

    pub fn evalModuleHandle(self: *TestEngine, source_text: []const u8) RuntimeError!core.JSValueHandle {
        return self.evalHandleWithOptions(source_text, .{ .mode = .module });
    }

    pub fn evalMode(self: *TestEngine, source_text: []const u8, mode: core.EvalMode) RuntimeError!core.JSValue {
        return self.evalWithOptions(source_text, .{ .mode = mode });
    }

    pub fn ensureTest262GlobalsInstalled(self: *TestEngine) !void {
        if (self.context.global == null) {
            const global_obj = try engine.exec.zjs_vm.contextGlobal(self.context);
            const run_test262 = @import("../cli/run_test262.zig");
            var wrapper = zjs.JSContext.borrowCore(self.context);
            try run_test262.installTest262Globals(self.runtime, &wrapper, global_obj);
        }
    }

    pub fn evalWithOptions(self: *TestEngine, source_text: []const u8, options: EvalOptions) RuntimeError!core.JSValue {
        const filename = options.filename;
        const mode = options.mode;
        self.ensureTest262GlobalsInstalled() catch |err| return @errorCast(err);
        var wrapper = zjs.JSContext.borrowCore(self.context);
        return wrapper.eval(source_text, .{
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

    pub fn evalHandleWithOptions(self: *TestEngine, source_text: []const u8, options: EvalOptions) RuntimeError!core.JSValueHandle {
        const value = try self.evalWithOptions(source_text, options);
        return try core.JSValueHandle.init(self.runtime, value);
    }

    pub fn createPersistentValue(self: *TestEngine, value: core.JSValue) !core.JSValueHandle {
        return self.runtime.createPersistentValue(value);
    }

    pub fn evalWithOutput(self: *TestEngine, source_text: []const u8, output: *std.Io.Writer) RuntimeError!core.JSValue {
        return self.evalWithOptions(source_text, .{ .output = output });
    }

    pub fn evalWithOutputMode(self: *TestEngine, source_text: []const u8, output: *std.Io.Writer, mode: core.EvalMode) RuntimeError!core.JSValue {
        return self.evalWithOptions(source_text, .{ .output = output, .mode = mode, .filename = "<eval>" });
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
        var wrapper = zjs.JSContext.borrowCore(self.context);
        try wrapper.runJobs(null);
    }

    pub fn createExternalHostFunctionValue(
        self: *TestEngine,
        name: []const u8,
        length: i32,
        ptr: *anyopaque,
        call: core.host_function.ExternalCallFn,
        finalizer: ?core.host_function.ExternalFinalizer,
    ) !core.JSValue {
        const id = try self.runtime.registerExternalHostFunction(.{
            .ptr = ptr,
            .call = call,
            .finalizer = finalizer,
        });
        const function_value = try engine.core.function.nativeFunction(self.context, name, length);
        errdefer function_value.free(self.runtime);

        const function_object = try engine.exec.property_ops.expectObject(function_value);
        function_object.hostFunctionKindSlot().* = core.host_function.ids.external_host;
        function_object.externalHostFunctionIdSlot().* = id;
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
        const global_object = try engine.exec.zjs_vm.contextGlobal(self.context);
        const function_value = try self.createExternalHostFunctionValue(name, length, ptr, call, finalizer);
        defer function_value.free(self.runtime);

        const property_name = try self.runtime.internAtom(name);
        defer self.runtime.atoms.free(property_name);
        try global_object.defineOwnProperty(self.runtime, property_name, core.Descriptor.data(function_value, true, false, true));
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

var shared_engine_storage: ?TestEngine = null;
var shared_engine_baseline_property_count: usize = 0;
var shared_engine_baseline_shape_prop_count: usize = 0;
var shared_engine_baseline_shape_hash: u32 = 0;
var shared_engine_baseline_shape_deleted_count: usize = 0;
var shared_engine_baseline_properties: ?[]core.property.Entry = null;
var shared_engine_baseline_shape_props: ?[]core.shape.Property = null;
// A Slot.dup of a VARREF retains the same mutable cell. Keep its original
// contents separately so deleting a baseline global cannot corrupt the
// snapshot by parking that shared cell at UNINITIALIZED.
const SharedBaselineVarRef = struct {
    value: core.JSValue,
    is_lexical: bool,
    is_const: bool,
    is_deletable: bool,
};
var shared_engine_baseline_var_refs: ?[]?SharedBaselineVarRef = null;
// Fresh three-pass census after Q4b: 814 warmed zero-module observations had
// allocation-count p95 0 and max 7. One extra allocation is the safety margin.
const shared_engine_allocation_tolerance: usize = 8;
var shared_engine_baseline_allocation_count: usize = 0;
var shared_engine_baseline_allocated_bytes: usize = 0;
var shared_engine_baseline_module_count: usize = 0;
var shared_engine_teardown_registered: bool = false;

extern var zjs_test_runner_current_name_ptr: [*]const u8;
extern var zjs_test_runner_current_name_len: usize;
extern var zjs_test_runner_current_pass: usize;
extern var zjs_test_runner_leak_census: bool;

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
            shared_engine_baseline_property_count = g.shape_ref.prop_count;
            shared_engine_baseline_shape_prop_count = g.shape_ref.prop_count;
            shared_engine_baseline_shape_hash = g.shape_ref.hash;
            shared_engine_baseline_shape_deleted_count = g.shape_ref.deletedPropCount();

            // Snapshot the baseline property entries (value slots only;
            // key atoms and flags are snapshotted with the shape props
            // below).
            shared_engine_baseline_properties = std.heap.page_allocator.alloc(core.property.Entry, g.shape_ref.prop_count) catch unreachable;
            shared_engine_baseline_var_refs = std.heap.page_allocator.alloc(?SharedBaselineVarRef, g.shape_ref.prop_count) catch unreachable;
            @memset(shared_engine_baseline_var_refs.?, null);
            for (g.propertyEntries(), 0..) |entry, idx| {
                // Dup the slot using its kind (read from the shape flags); the
                // value cell is untagged so dup/destroy need the flags.
                shared_engine_baseline_properties.?[idx] = .{ .slot = entry.slot.dup(g.propFlagsAt(idx)) };
                if (g.propFlagsAt(idx).isVarRef()) {
                    const cell = entry.slot.var_ref;
                    shared_engine_baseline_var_refs.?[idx] = .{
                        .value = cell.varRefValue().dup(),
                        .is_lexical = cell.is_lexical,
                        .is_const = cell.varRefIsConstSlot().*,
                        .is_deletable = cell.varRefIsDeletableSlot().*,
                    };
                }
            }

            shared_engine_baseline_shape_props = std.heap.page_allocator.alloc(core.shape.Property, g.shape_ref.prop_count) catch unreachable;
            for (g.shape_ref.props()[0..g.shape_ref.prop_count], 0..) |prop, idx| {
                shared_engine_baseline_shape_props.?[idx] = prop;
                shared_engine_baseline_shape_props.?[idx].hash_next = core.shape.no_property_index;
                if (prop.atom_id != core.atom.null_atom) {
                    _ = eng.runtime.atoms.dup(prop.atom_id);
                }
            }
        }
        _ = eng.runtime.runObjectCycleRemoval();
        shared_engine_baseline_allocation_count = eng.runtime.memory.allocation_count;
        shared_engine_baseline_allocated_bytes = eng.runtime.memory.allocated_bytes;
        shared_engine_baseline_module_count = eng.context.modules.count;
        registerSharedEngineProcessTeardown();
    }
    return &shared_engine_storage.?;
}

extern "c" fn atexit(function: *const fn () callconv(.c) void) c_int;

fn registerSharedEngineProcessTeardown() void {
    if (shared_engine_teardown_registered) return;
    shared_engine_teardown_registered = true;
    _ = atexit(&sharedEngineProcessTeardown);
}

fn sharedEngineProcessTeardown() callconv(.c) void {
    deinitSharedTestEngine();
}

/// Process-exit teardown for the shared engine. Restores the baseline so
/// extra globals drop, releases the snapshot's extra realm retains, then
/// destroys only the host-owned main context. Leftover createRealm cycles
/// are collected by `JSRuntime.deinit`; extra `JSContext.destroy` on those
/// children is the undercount that trips `visitRealm`.
pub fn deinitSharedTestEngine() void {
    const eng = if (shared_engine_storage) |*e| e else return;
    // Last `endSharedTest` already restored the baseline. Releasing the
    // snapshot drops its untraced extra retains (auto_init on the context,
    // data dups, var_ref value extras) so cycle GC can collect the host realm.
    releaseSharedEngineBaselineSnapshot(eng.runtime);
    var owned = eng.*;
    shared_engine_storage = null;
    owned.deinit();
}

fn releaseSharedEngineBaselineSnapshot(rt: *core.JSRuntime) void {
    if (shared_engine_baseline_var_refs) |var_refs| {
        for (var_refs) |maybe_state| {
            if (maybe_state) |state| state.value.free(rt);
        }
        std.heap.page_allocator.free(var_refs);
        shared_engine_baseline_var_refs = null;
    }
    if (shared_engine_baseline_properties) |baselines| {
        const baseline_shape_props = shared_engine_baseline_shape_props.?;
        for (baselines, 0..) |base, idx| {
            const base_flags = core.property.Flags.fromBits(baseline_shape_props[idx].flags);
            // VARREF snapshot slots alias the live global's cell. `slot.dup`
            // extra-retains that cell's value; drop the extra without
            // `slot.destroy`, which would free the live cell value twice.
            if (base_flags.isVarRef()) {
                if (!base_flags.deleted) base.slot.var_ref.valueRef().free(rt);
            } else {
                base.slot.destroy(base_flags, rt);
            }
        }
        std.heap.page_allocator.free(baselines);
        shared_engine_baseline_properties = null;
    }
    if (shared_engine_baseline_shape_props) |baseline_shape_props| {
        for (baseline_shape_props) |prop| {
            if (prop.atom_id != core.atom.null_atom) rt.atoms.free(prop.atom_id);
        }
        std.heap.page_allocator.free(baseline_shape_props);
        shared_engine_baseline_shape_props = null;
    }
    shared_engine_baseline_property_count = 0;
    shared_engine_baseline_shape_prop_count = 0;
    shared_engine_baseline_shape_hash = 0;
    shared_engine_baseline_shape_deleted_count = 0;
}

pub fn endSharedTest() void {
    const eng = if (shared_engine_storage) |*e| e else return;
    resetSharedEngineAfterTest(eng);

    const allocation_count = eng.runtime.memory.allocation_count;
    const allocated_bytes = eng.runtime.memory.allocated_bytes;
    const module_count = eng.context.modules.count;
    const count_delta = @as(i128, @intCast(allocation_count)) - @as(i128, @intCast(shared_engine_baseline_allocation_count));
    const bytes_delta = @as(i128, @intCast(allocated_bytes)) - @as(i128, @intCast(shared_engine_baseline_allocated_bytes));
    const module_delta = @as(i128, @intCast(module_count)) - @as(i128, @intCast(shared_engine_baseline_module_count));
    const test_name = zjs_test_runner_current_name_ptr[0..zjs_test_runner_current_name_len];

    if (zjs_test_runner_leak_census) {
        std.debug.print("leak-census: pass={} test=\"{s}\" count_delta={d} bytes_delta={d} module_count={} module_delta={d} count={} bytes={}\n", .{
            zjs_test_runner_current_pass,
            test_name,
            count_delta,
            bytes_delta,
            module_count,
            module_delta,
            allocation_count,
            allocated_bytes,
        });
    }

    // Pass 0 deliberately warms lazy shared-Realm state. From pass 1 onward,
    // module-registry growth is the sole unbounded owner and is accounted by
    // its own monotonic count; every other test must stay within the measured
    // bounded property-capacity noise floor.
    const module_count_grew = module_count > shared_engine_baseline_module_count;
    if (zjs_test_runner_current_pass != 0 and !module_count_grew) {
        const limit = std.math.add(usize, shared_engine_baseline_allocation_count, shared_engine_allocation_tolerance) catch std.math.maxInt(usize);
        if (allocation_count > limit) {
            std.debug.panic(
                "shared-test leak gate: test=\"{s}\" count_delta={d} bytes_delta={d} module_count={} module_delta={d} baseline_count={} observed_count={} tolerance={}",
                .{
                    test_name,
                    count_delta,
                    bytes_delta,
                    module_count,
                    module_delta,
                    shared_engine_baseline_allocation_count,
                    allocation_count,
                    shared_engine_allocation_tolerance,
                },
            );
        }
    }

    shared_engine_baseline_allocation_count = @max(shared_engine_baseline_allocation_count, allocation_count);
    shared_engine_baseline_allocated_bytes = @max(shared_engine_baseline_allocated_bytes, allocated_bytes);
    shared_engine_baseline_module_count = @max(shared_engine_baseline_module_count, module_count);
}

fn resetSharedEngineAfterTest(eng: *TestEngine) void {
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
    if (eng.context.global) |global| {
        while (true) switch (engine.exec.promise_ops.drainOnePendingJob(eng.context, null, global) catch break) {
            .empty, .exception => break,
            .success => {},
        };
    }
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
        // Suppress allocation-triggered GC for the whole property restore.
        // Restoring slots and shape flags is a multi-step swap that passes
        // through transient states where a slot's arm and the live shape's
        // `Flags.kind` disagree (e.g. a materialized `.data` slot while the
        // baseline flags being restored say `.auto_init`). Under
        // `-Dzjs_force_gc=true` the `restorePropertyLayout` storage alloc
        // would otherwise run the cycle collector against that half-applied
        // state and trace the wrong union arm. Making the restore atomic
        // w.r.t. GC keeps the slot/flag pair consistent throughout.
        const saved_trigger_fn = eng.runtime.memory.trigger_gc_fn;
        const saved_trigger_ctx = eng.runtime.memory.trigger_gc_ctx;
        eng.runtime.memory.trigger_gc_fn = null;
        eng.runtime.memory.trigger_gc_ctx = null;
        defer {
            eng.runtime.memory.trigger_gc_fn = saved_trigger_fn;
            eng.runtime.memory.trigger_gc_ctx = saved_trigger_ctx;
        }

        // Property compaction may have shifted live baseline entries and shrunk
        // the global's value buffer. Restore capacity before destroying current
        // entries, then rebuild both parallel arrays entirely from the snapshot.
        // This also removes user-added globals without assuming baseline indices
        // survived a compacting delete.
        const baseline = shared_engine_baseline_property_count;
        global.reserveOwnPropertyCapacity(eng.runtime, baseline) catch unreachable;

        // Destroy every current slot using the CURRENT shape flags before the
        // baseline layout replaces them.
        for (global.propertyEntries(), 0..) |entry, idx| {
            entry.slot.destroy(global.propFlagsAt(idx), eng.runtime);
        }

        // Restore baseline properties to their original states.
        if (shared_engine_baseline_properties) |baselines| {
            // Restore baseline values, dupping with the BASELINE
            // flags snapshotted alongside the baseline slots (1:1 by index).
            const baseline_shape_props = shared_engine_baseline_shape_props.?;
            for (baselines, 0..) |base, idx| {
                const base_flags = core.property.Flags.fromBits(baseline_shape_props[idx].flags);
                if (shared_engine_baseline_var_refs.?[idx]) |state| {
                    // Restore the snapshot cell before publishing another ref
                    // to it in the rebuilt property array.
                    const cell = base.slot.var_ref;
                    const old_value = cell.varRefValueSlot().*;
                    cell.varRefValueSlot().* = state.value.dup();
                    cell.is_lexical = state.is_lexical;
                    cell.varRefIsConstSlot().* = state.is_const;
                    cell.varRefIsDeletableSlot().* = state.is_deletable;
                    old_value.free(eng.runtime);
                }
                global.propertyEntry(idx).* = .{ .slot = base.slot.dup(base_flags) };
            }
        }

        if (shared_engine_baseline_shape_props) |baseline_shape_props| {
            eng.runtime.shapes.restorePropertyLayout(
                &global.shape_ref,
                baseline_shape_props[0..shared_engine_baseline_shape_prop_count],
                shared_engine_baseline_shape_hash,
                shared_engine_baseline_shape_deleted_count,
            ) catch unreachable;
        }
    }
    _ = eng.runtime.runObjectCycleRemoval();
}

pub const vm_helpers = struct {
    pub fn parseAndRun(rt: *core.JSRuntime, ctx: *core.JSContext, src: []const u8) !core.JSValue {
        const name = try rt.internAtom("test");
        defer rt.atoms.free(name);
        var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer function.deinit(rt);

        var lex = QjsLexer.init(std.testing.allocator, &rt.atoms, src);
        var state = try ParseState.initWithRuntime(rt, &lex, &function);
        defer state.deinit(rt);
        try parser_core.parseExpr(&state);
        try state.builderEmitOp(op.@"return");

        // Run the FunctionDef-backed finalize pipeline so locals are lowered
        // to get_loc / put_loc instead of falling back to global get_var /
        // put_var.
        try engine.bytecode.pipeline.finalize.runWithFunctionDef(&function, &state.function_def);

        helpers.registerStandardGlobalsBare(rt);
        var vm = engine.exec.Vm.init(ctx);
        defer vm.deinit();
        return helpers.runMutableVm(&vm, &function);
    }

    pub fn parseAndRunWithTopLevelChildren(rt: *core.JSRuntime, ctx: *core.JSContext, src: []const u8) !core.JSValue {
        const name = try rt.internAtom("test");
        defer rt.atoms.free(name);
        var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer function.deinit(rt);

        var lex = QjsLexer.init(std.testing.allocator, &rt.atoms, src);
        var state = try ParseState.initWithRuntime(rt, &lex, &function);
        defer state.deinit(rt);
        state.top_level_functions_as_children = true;
        try parser_core.parseExpr(&state);
        try state.builderEmitOp(op.@"return");

        try engine.bytecode.pipeline.finalize.runWithFunctionDefRuntime(&function, &state.function_def, .{ .realm = ctx });

        helpers.registerStandardGlobalsBare(rt);
        var vm = engine.exec.Vm.init(ctx);
        defer vm.deinit();
        return helpers.runMutableVm(&vm, &function);
    }

    pub fn expectStringBytes(value: core.JSValue, expected: []const u8) !void {
        try std.testing.expect(value.isString());
        const string_value = value.asStringBody().?;
        try std.testing.expect(string_value.eqlBytes(expected));
    }

    pub fn expectSingleCodeUnit(value: core.JSValue, expected: u16) !void {
        try std.testing.expect(value.isString());
        const string_value = value.asStringBody().?;
        try std.testing.expectEqual(@as(usize, 1), string_value.len());
        try std.testing.expectEqual(expected, string_value.codeUnitAt(0));
    }

    pub fn parseStmtAndRun(rt: *core.JSRuntime, ctx: *core.JSContext, src: []const u8) !core.JSValue {
        const name = try rt.internAtom("test");
        defer rt.atoms.free(name);
        var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer function.deinit(rt);

        var lex = QjsLexer.init(std.testing.allocator, &rt.atoms, src);
        var state = try ParseState.initWithRuntime(rt, &lex, &function);
        defer state.deinit(rt);

        try state.enableEvalReturn();
        while (state.token.val != engine.parser.token.TOK_EOF) {
            try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });
        }
        try state.finalizeEvalReturn();

        try engine.bytecode.pipeline.finalize.runWithFunctionDef(&function, &state.function_def);

        helpers.registerStandardGlobalsBare(rt);
        var vm = engine.exec.Vm.init(ctx);
        defer vm.deinit();
        return helpers.runMutableVm(&vm, &function);
    }

    pub fn parseStmtAndRunWithTopLevelChildren(rt: *core.JSRuntime, ctx: *core.JSContext, src: []const u8) !core.JSValue {
        const name = try rt.internAtom("test");
        defer rt.atoms.free(name);
        var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer function.deinit(rt);

        var lex = QjsLexer.init(std.testing.allocator, &rt.atoms, src);
        var state = try ParseState.initWithRuntime(rt, &lex, &function);
        defer state.deinit(rt);
        state.top_level_functions_as_children = true;
        state.top_level_lexical_as_global_ref = true;
        state.function_def.is_eval = true;
        state.function_def.is_global_var = true;

        // This helper executes global script code and only needs completion
        // capture; enableEvalReturn would incorrectly switch declarations to
        // direct-eval placement. Mirror compileQjsProgram's script setup.
        try state.beginProgramEmission();
        try state.enableReturnCompletion();
        while (state.token.val != engine.parser.token.TOK_EOF) {
            try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });
        }
        try state.finalizeEvalReturn();

        try engine.bytecode.pipeline.finalize.runWithFunctionDefRuntime(&function, &state.function_def, .{ .realm = ctx });

        helpers.registerStandardGlobalsBare(rt);
        var vm = engine.exec.Vm.init(ctx);
        defer vm.deinit();
        return helpers.runMutableVm(&vm, &function);
    }
};

pub fn appendWeakCollectionEntry(rt: *core.JSRuntime, collection: *core.Object, key: *core.Object, value: core.JSValue) !void {
    const key_identity = (try core.Object.weakIdentityFromValue(rt, key.value())) orelse unreachable;
    rt.retainWeakIdentity(key_identity);
    errdefer rt.releaseWeakIdentity(key_identity);
    const entries_slot = collection.weakCollectionEntriesSlot();
    const index = entries_slot.*.len;
    const inserted_holder = !rt.borrowedReferenceHolderRegistered(collection);
    try rt.registerBorrowedReferenceHolder(collection);
    errdefer if (inserted_holder) rt.unregisterBorrowedReferenceHolder(collection);
    try collection.ensureWeakCollectionEntryCapacity(rt, index + 1);
    const refreshed_entries = collection.weakCollectionEntriesSlot();
    refreshed_entries.* = refreshed_entries.*.ptr[0 .. index + 1];
    errdefer refreshed_entries.* = refreshed_entries.*[0..index];
    refreshed_entries.*[index] = .{
        .key_identity = key_identity,
        .value = value.dup(),
    };
    try rt.registerBorrowedReferenceHolder(collection);
}

/// Drive an open incremental major cycle to completion. Threshold-triggered
/// collections under the tracer begin a cycle and finish it at a later poll;
/// tests that assert on freed counts after a crossing call this to reach the
/// poll where the result lands.
pub fn finishGcCycles(rt: anytype) void {
    var polls: usize = 0;
    while (rt.gc.concurrent.markingActive() or rt.gc.doomed_pending) : (polls += 1) {
        std.debug.assert(polls < 100_000);
        _ = rt.pollGC(null, .safepoint) catch return;
    }
}
