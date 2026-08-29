//! zjs engine test layer; governed by docs/README.md testing policy and zjs embedding contract.

const std = @import("std");
const zjs = @import("zjs");
const engine = zjs;
const bytecode = zjs.bytecode;
const core = zjs.core;

const Rng = std.Random.DefaultPrng;
const helpers = @import("helpers.zig");
const appendWeakCollectionEntry = helpers.appendWeakCollectionEntry;

fn dropGcPtr(ptr: anytype) void {
    @memset(std.mem.asBytes(ptr), 0);
}

fn bindObjectRoots(slots: []?*core.Object, roots: []core.runtime.ObjectRootValue) void {
    for (roots, slots) |*root, *slot| root.* = .{ .object = slot };
}

test "gc stress deterministic tiny heap preserves live roots" {
    var rt: core.JSRuntime = undefined;
    try rt.init(std.testing.allocator, .{ .gc_threshold = 1 });
    defer rt.deinit();

    const count = 32;
    var objects: [count]?*core.Object = @splat(null);
    var object_roots: [count]core.runtime.ObjectRootValue = undefined;
    bindObjectRoots(&objects, &object_roots);
    var frame = core.runtime.ValueRootFrame{ .objects = &object_roots };
    frame.activate(&rt);
    defer frame.deactivate(&rt);

    const edge_key = try rt.internAtom("tiny-heap-edge");
    defer rt.atoms.free(edge_key);

    for (&objects, 0..) |*slot, index| {
        slot.* = try core.Object.create(&rt, core.class.ids.object, null);
        if (index != 0) {
            try objects[index - 1].?.defineOwnProperty(
                &rt,
                edge_key,
                core.Descriptor.data(slot.*.?.value(), true, true, true),
            );
        }
    }
    try objects[count - 1].?.defineOwnProperty(
        &rt,
        edge_key,
        core.Descriptor.data(objects[0].?.value(), true, true, true),
    );
    const live_with_cycle = rt.gc.liveCount();
    try std.testing.expect(live_with_cycle >= count);

    // Keep objects[0] as the named external root and drop the other
    // construction retains. The cycle through objects[0] keeps the rest.
    for (objects[1..]) |*slot| {
        slot.*.?.value().free(&rt);
        slot.* = null;
    }
    _ = try rt.forceMajorGC(null);
    try std.testing.expectEqual(live_with_cycle, rt.gc.liveCount());

    objects[0].?.value().free(&rt);
    objects[0] = null;
    _ = try rt.forceMajorGC(null);
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
    try std.testing.expect(rt.gc.stats.cycle_gc_count > 1);
}

test "gc stress deterministic object cycles are reclaimed" {
    var prng = Rng.init(0x7a6a_6763_0001);
    const random = prng.random();

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const count = 128;
    var objects: [count]?*core.Object = @splat(null);
    var object_roots: [count]core.runtime.ObjectRootValue = undefined;
    bindObjectRoots(&objects, &object_roots);
    var frame = core.runtime.ValueRootFrame{ .objects = &object_roots };
    frame.activate(rt);
    defer frame.deactivate(rt);
    var external_alive: [count]bool = @splat(true);

    for (&objects) |*slot| {
        slot.* = try core.Object.create(rt, core.class.ids.object, null);
    }

    const edge_key = try rt.internAtom("stress-edge");
    defer rt.atoms.free(edge_key);

    for (objects) |obj| {
        const target_index = random.uintLessThan(usize, objects.len);
        const target = objects[target_index].?;
        try obj.?.defineOwnProperty(rt, edge_key, core.Descriptor.data(target.value(), true, true, true));
    }

    for (&objects, 0..) |*slot, index| {
        if ((index % 3) == 0) {
            slot.*.?.value().free(rt);
            slot.* = null;
            external_alive[index] = false;
        }
    }

    for (&objects, 0..) |*slot, index| {
        if (external_alive[index]) {
            slot.*.?.value().free(rt);
            slot.* = null;
        }
    }

    _ = try rt.tryRunObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
}

test "gc stress weak map preserved key keeps value alive" {
    var prng = Rng.init(0x7a6a_6763_0002);
    const random = prng.random();

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const weakmap = try core.Object.create(rt, core.class.ids.weakmap, null);
    const count = 16;
    const preserved_index = random.uintLessThan(usize, count);
    var keys: [count]?*core.Object = @splat(null);
    var values: [count]?*core.Object = @splat(null);
    var key_roots: [count]core.runtime.ObjectRootValue = undefined;
    var value_roots: [count]core.runtime.ObjectRootValue = undefined;
    bindObjectRoots(&keys, &key_roots);
    bindObjectRoots(&values, &value_roots);
    var weakmap_slot: ?*core.Object = weakmap;
    var live_roots = core.runtime.rootObjects(.{&weakmap_slot});
    live_roots.activate(rt);
    defer live_roots.deactivate(rt);
    var key_frame = core.runtime.ValueRootFrame{ .objects = &key_roots };
    key_frame.activate(rt);
    defer key_frame.deactivate(rt);
    var value_frame = core.runtime.ValueRootFrame{ .objects = &value_roots };
    value_frame.activate(rt);
    defer value_frame.deactivate(rt);

    for (&keys, &values) |*key_slot, *value_slot| {
        key_slot.* = try core.Object.create(rt, core.class.ids.object, null);
        value_slot.* = try core.Object.create(rt, core.class.ids.object, null);
    }

    for (keys, values) |key, value| {
        try appendWeakCollectionEntry(rt, weakmap, key.?, value.?.value());
        value.?.value().free(rt);
    }
    for (&values) |*slot| slot.* = null;

    for (&keys, 0..) |*slot, index| {
        if (index != preserved_index) {
            slot.*.?.value().free(rt);
            slot.* = null;
        }
    }

    _ = try rt.tryRunObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 1), weakmap.weakCollectionEntries().len);
    // Shapes are GC objects now: weakmap + preserved key + value share
    // one live empty root shape.
    try std.testing.expectEqual(@as(usize, 4), rt.gc.liveCount());

    weakmap.value().free(rt);
    weakmap_slot = null;
    keys[preserved_index].?.value().free(rt);
    keys[preserved_index] = null;
    _ = try rt.tryRunObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
}

test "gc stress weak map dead cyclic keys clear values" {
    var prng = Rng.init(0x7a6a_6763_0003);
    const random = prng.random();

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const weakmap = try core.Object.create(rt, core.class.ids.weakmap, null);
    const count = 24;
    var keys: [count]?*core.Object = @splat(null);
    var values: [count]?*core.Object = @splat(null);
    var key_roots: [count]core.runtime.ObjectRootValue = undefined;
    var value_roots: [count]core.runtime.ObjectRootValue = undefined;
    bindObjectRoots(&keys, &key_roots);
    bindObjectRoots(&values, &value_roots);
    var weakmap_slot: ?*core.Object = weakmap;
    var live_roots = core.runtime.rootObjects(.{&weakmap_slot});
    live_roots.activate(rt);
    defer live_roots.deactivate(rt);
    var key_frame = core.runtime.ValueRootFrame{ .objects = &key_roots };
    key_frame.activate(rt);
    defer key_frame.deactivate(rt);
    var value_frame = core.runtime.ValueRootFrame{ .objects = &value_roots };
    value_frame.activate(rt);
    defer value_frame.deactivate(rt);

    for (&keys, &values) |*key_slot, *value_slot| {
        key_slot.* = try core.Object.create(rt, core.class.ids.object, null);
        value_slot.* = try core.Object.create(rt, core.class.ids.object, null);
    }

    const self_key = try rt.internAtom("stress-weak-dead-self");
    defer rt.atoms.free(self_key);
    const peer_key = try rt.internAtom("stress-weak-dead-peer");
    defer rt.atoms.free(peer_key);

    for (keys, values) |key, value| {
        try key.?.defineOwnProperty(rt, self_key, core.Descriptor.data(key.?.value(), true, true, true));
        const peer = keys[random.uintLessThan(usize, keys.len)].?;
        try key.?.defineOwnProperty(rt, peer_key, core.Descriptor.data(peer.value(), true, true, true));
        try appendWeakCollectionEntry(rt, weakmap, key.?, value.?.value());
        value.?.value().free(rt);
    }
    for (&values) |*slot| slot.* = null;

    for (&keys) |*slot| {
        slot.*.?.value().free(rt);
        slot.* = null;
    }
    try std.testing.expectEqual(@as(usize, count), weakmap.weakCollectionEntries().len);

    _ = try rt.tryRunObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 0), weakmap.weakCollectionEntries().len);
    // The live weakmap keeps its empty root shape alive.
    try std.testing.expectEqual(@as(usize, 2), rt.gc.liveCount());

    weakmap.value().free(rt);
    weakmap_slot = null;
    _ = try rt.tryRunObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
}

test "gc stress finalization registry dead target queues pending job" {
    var prng = Rng.init(0x7a6a_6763_0004);
    const random = prng.random();

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    var ctx = try core.JSContext.create(rt);
    var ctx_alive = true;
    defer if (ctx_alive) ctx.destroy();

    const cleanup = try core.Object.create(rt, core.class.ids.object, null);
    const registry = try core.Object.createFinalizationRegistry(rt, ctx, null);
    var cleanup_slot: ?*core.Object = cleanup;
    var registry_slot: ?*core.Object = registry;
    var live_roots = core.runtime.rootObjects(.{ &registry_slot, &cleanup_slot });
    live_roots.activate(rt);
    defer live_roots.deactivate(rt);
    registry.finalizationRegistryCleanupCallbackSlot().* = cleanup.value().dup();

    var target = try core.Object.create(rt, core.class.ids.object, null);
    var target_value = target.value();
    const self_key = try rt.internAtom("stress-finalization-target-self");
    defer rt.atoms.free(self_key);
    try target.defineOwnProperty(rt, self_key, core.Descriptor.data(target_value, true, true, true));

    var held = try core.Object.create(rt, core.class.ids.object, null);
    const held_key = try rt.internAtom("stress-finalization-held");
    defer rt.atoms.free(held_key);
    try held.defineOwnProperty(rt, held_key, core.Descriptor.data(core.JSValue.int32(@intCast(random.intRangeLessThan(i16, 1, 2048))), true, true, true));

    try registry.appendFinalizationRegistryCell(
        rt,
        target_value,
        held.value(),
        core.JSValue.undefinedValue(),
    );
    held.value().free(rt);
    dropGcPtr(&held);
    target_value.free(rt);
    target_value = core.JSValue.undefinedValue();
    dropGcPtr(&target);

    const collected = try rt.tryRunObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 2), collected.freed_objects);
    // `processWeak` enqueues the cleanup in the same collection that unreaches
    // the target.
    try std.testing.expectEqual(@as(usize, 1), rt.pendingFinalizationJobCountForTest());
    try std.testing.expectEqual(@as(usize, 0), registry.finalizationRegistryCells().len);
    // cleanup + registry + held object + construction realm, plus the shared root shape and the
    // held object's one-property transition shape.
    try std.testing.expectEqual(@as(usize, 6), rt.gc.liveCount());

    rt.clearPendingFinalizationJobs();
    registry.value().free(rt);
    registry_slot = null;
    cleanup.value().free(rt);
    cleanup_slot = null;
    ctx.destroy();
    ctx_alive = false;
    dropGcPtr(&ctx);
    _ = try rt.tryRunObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
}

test "gc stress function bytecode constant pool object cycles are reclaimed" {
    var prng = Rng.init(0x7a6a_6763_0006);
    const random = prng.random();

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const count = 17;
    const step = 1 + random.uintLessThan(usize, count - 1);
    var functions: [count]?*core.Object = @splat(null);
    var captured: [count]?*core.Object = @splat(null);
    var function_roots: [count]core.runtime.ObjectRootValue = undefined;
    var captured_roots: [count]core.runtime.ObjectRootValue = undefined;
    bindObjectRoots(&functions, &function_roots);
    bindObjectRoots(&captured, &captured_roots);
    var function_frame = core.runtime.ValueRootFrame{ .objects = &function_roots };
    function_frame.activate(rt);
    defer function_frame.deactivate(rt);
    var captured_frame = core.runtime.ValueRootFrame{ .objects = &captured_roots };
    captured_frame.activate(rt);
    defer captured_frame.deactivate(rt);

    for (&functions, &captured) |*function_slot, *captured_slot| {
        const function = try core.Object.create(rt, core.class.ids.bytecode_function, null);
        const captured_obj = try core.Object.create(rt, core.class.ids.object, null);
        const fb = try bytecode.FunctionBytecode.createFixture(rt, .{ .cpool_count = 1 });
        fb.cpoolSlice()[0] = captured_obj.value().dup();
        fb.publishFixtureNoFail(rt);

        try function.setFunctionBytecodeValue(rt, core.JSValue.functionBytecode(&fb.header));
        function_slot.* = function;
        captured_slot.* = captured_obj;
    }

    const function_key = try rt.internAtom("stress-bytecode-function");
    defer rt.atoms.free(function_key);
    for (captured, 0..) |captured_obj, index| {
        const target_index = (index + step) % count;
        try captured_obj.?.defineOwnProperty(rt, function_key, core.Descriptor.data(functions[target_index].?.value(), true, true, true));
    }

    for (&functions) |*slot| {
        slot.*.?.value().free(rt);
        slot.* = null;
    }
    for (&captured) |*slot| {
        slot.*.?.value().free(rt);
        slot.* = null;
    }

    _ = try rt.tryRunObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
}

pub const dummy = {};
