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

var shared_engine_storage: ?engine.harness.Engine = null;
var shared_engine_baseline_property_count: usize = 0;
var shared_engine_baseline_shape_prop_count: usize = 0;
var shared_engine_baseline_shape_hash: u32 = 0;
var shared_engine_baseline_shape_deleted_count: usize = 0;

pub fn sharedTestEngine() *engine.harness.Engine {
    if (shared_engine_storage == null) {
        shared_engine_storage = engine.harness.Engine.init(std.heap.page_allocator) catch unreachable;
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
