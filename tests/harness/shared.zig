//! Process-level shared TestEngine: one realm per test binary.
//!
//! Each `test "X" {}` block traditionally does:
//!
//!     var js = try helpers.TestEngine.init(std.testing.allocator);
//!     defer js.deinit();
//!
//! That pays ~195us (Debug) / ~50us (ReleaseSafe) per test for
//! `installHostGlobals`, which dominates the per-test wall time for
//! tests whose actual eval body is small. The shared-engine pattern
//! builds the Engine once per test BINARY (using a stable allocator
//! independent of `std.testing.allocator`, which is reset between
//! tests), and resets only the per-eval mutable state in between tests:
//!
//!     const js = helpers.sharedTestEngine();
//!     defer helpers.endSharedTest();
//!
//! `endSharedTest` clears the pending exception slot, drains the
//! job queue, nulls out `context.lexicals` (dropping the previous
//! test's let / const declarations), and then rebuilds the global's
//! property array and shape layout from the baseline snapshot taken
//! after `installHostGlobals`. Tests that mutate built-in objects
//! (e.g. `Promise.resolve = ...`) or rely on freshly built closures
//! referencing the previous test's eval scope still need a fresh
//! `TestEngine.init` per call.

const std = @import("std");
const zjs = @import("zjs");
const core = zjs.core;
const exec = zjs.exec;
const test_engine = @import("test_engine.zig");

const TestEngine = test_engine.TestEngine;

pub fn expectPrints(source: []const u8, expected: []const u8) !void {
    const js = sharedTestEngine();
    defer endSharedTest();

    var output_buffer: [8192]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(source, &output);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings(expected, output.buffered());
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

const test_runner_root = @import("root");

fn leakCensusEnabled() bool {
    return std.c.getenv("ZJS_LEAK_CENSUS") != null;
}

fn runnerPass() usize {
    if (@hasDecl(test_runner_root, "zjs_test_runner_current_pass")) return test_runner_root.zjs_test_runner_current_pass;
    return 0;
}

fn runnerTestName() []const u8 {
    if (@hasDecl(test_runner_root, "zjs_test_runner_current_name_ptr")) {
        return test_runner_root.zjs_test_runner_current_name_ptr[0..test_runner_root.zjs_test_runner_current_name_len];
    }
    return "";
}

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
        _ = eng.eval(";") catch unreachable;
        if (eng.context.hasException()) {
            _ = eng.context.takeException();
        }
        if (eng.context.hasUnhandledRejection()) {
            _ = eng.context.takeUnhandledRejection();
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
                shared_engine_baseline_properties.?[idx] = .{ .slot = entry.slot };
                if (g.propFlagsAt(idx).isVarRef()) {
                    const cell = entry.slot.var_ref;
                    shared_engine_baseline_var_refs.?[idx] = .{
                        .value = cell.varRefValue(),
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

/// Process-exit teardown for the shared engine. Frees the baseline snapshot's
/// page-allocator storage, then destroys only the host-owned main context.
/// Leftover createRealm cycles are collected by `JSRuntime.deinit`; extra
/// `JSContext.destroy` on those children is the undercount that trips
/// `visitRealm`.
pub fn deinitSharedTestEngine() void {
    const eng = if (shared_engine_storage) |*e| e else return;
    // Last `endSharedTest` already restored the baseline; the snapshot itself
    // is now only page-allocator storage (var refs, properties, shape props),
    // so releasing it just frees those arrays before the engine goes away.
    releaseSharedEngineBaselineSnapshot();
    var owned = eng.*;
    shared_engine_storage = null;
    owned.deinit();
}

fn releaseSharedEngineBaselineSnapshot() void {
    if (shared_engine_baseline_var_refs) |var_refs| {
        std.heap.page_allocator.free(var_refs);
        shared_engine_baseline_var_refs = null;
    }
    if (shared_engine_baseline_properties) |baselines| {
        std.heap.page_allocator.free(baselines);
        shared_engine_baseline_properties = null;
    }
    if (shared_engine_baseline_shape_props) |baseline_shape_props| {
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
    const test_name = runnerTestName();
    const current_pass = runnerPass();

    if (leakCensusEnabled()) {
        std.debug.print("leak-census: pass={} test=\"{s}\" count_delta={d} bytes_delta={d} module_count={} module_delta={d} count={} bytes={}\n", .{
            current_pass,
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
    if (current_pass != 0 and !module_count_grew) {
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
        _ = eng.context.takeException();
    }
    if (eng.context.hasUnhandledRejection()) {
        _ = eng.context.takeUnhandledRejection();
    }
    // Drain pending jobs so the next test starts with an empty queue;
    // tests that schedule a promise via `Promise.resolve(...)` and
    // return without awaiting would otherwise leak the job into the
    // next test.
    if (eng.context.global) |global| {
        while (true) switch (exec.promise_ops.drainOnePendingJob(eng.context, null, global) catch break) {
            .empty, .exception => break,
            .success => {},
        };
    }
    if (eng.context.hasException()) {
        _ = eng.context.takeException();
    }
    if (eng.context.hasUnhandledRejection()) {
        _ = eng.context.takeUnhandledRejection();
    }
    exec.zjs_vm.cleanupAtomicsWaitersForContext(eng.context);
    if (eng.context.global) |global| {
        // Reset global lexical bindings (let / const) so the next
        // test can re-declare any name without triggering a
        // redeclaration SyntaxError.
        eng.context.lexicals = null;
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
        // the global's value buffer. Restore capacity, then rebuild both
        // parallel arrays entirely from the snapshot.
        // This also removes user-added globals without assuming baseline indices
        // survived a compacting delete.
        const baseline = shared_engine_baseline_property_count;
        global.reserveOwnPropertyCapacity(eng.runtime, baseline) catch unreachable;

        // Restore baseline properties to their original states.
        if (shared_engine_baseline_properties) |baselines| {
            for (baselines, 0..) |base, idx| {
                if (shared_engine_baseline_var_refs.?[idx]) |state| {
                    // Restore the snapshot cell before publishing another ref
                    // to it in the rebuilt property array.
                    const cell = base.slot.var_ref;
                    cell.varRefValueSlot().* = state.value;
                    cell.is_lexical = state.is_lexical;
                    cell.varRefIsConstSlot().* = state.is_const;
                    cell.varRefIsDeletableSlot().* = state.is_deletable;
                }
                global.propertyEntry(idx).* = .{ .slot = base.slot };
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
