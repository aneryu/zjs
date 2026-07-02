//! zjs engine test layer; governed by docs/README.md testing policy and zjs embedding contract.

const std = @import("std");
const zjs = @import("zjs");
const engine = zjs;
const bytecode = zjs.bytecode;
const core = zjs.core;

const Rng = std.Random.DefaultPrng;

fn appendWeakCollectionEntry(rt: *core.JSRuntime, collection: *core.Object, key: *core.Object, value: core.JSValue) !void {
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

test "gc stress deterministic object cycles are reclaimed" {
    var prng = Rng.init(0x7a6a_6763_0001);
    const random = prng.random();

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const count = 128;
    var objects: [count]*core.Object = undefined;
    var external_alive: [count]bool = @splat(true);

    for (&objects) |*slot| {
        slot.* = try core.Object.create(rt, core.class.ids.object, null);
    }

    const edge_key = try rt.internAtom("stress-edge");
    defer rt.atoms.free(edge_key);

    for (objects) |obj| {
        const target_index = random.uintLessThan(usize, objects.len);
        const target = objects[target_index];
        try obj.defineOwnProperty(rt, edge_key, core.Descriptor.data(target.value(), true, true, true));
    }

    for (objects, 0..) |obj, index| {
        if ((index % 3) == 0) {
            obj.value().free(rt);
            external_alive[index] = false;
        }
    }

    for (objects, 0..) |obj, index| {
        if (external_alive[index]) obj.value().free(rt);
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
    var keys: [count]*core.Object = undefined;
    var values: [count]*core.Object = undefined;

    for (&keys, &values) |*key_slot, *value_slot| {
        key_slot.* = try core.Object.create(rt, core.class.ids.object, null);
        value_slot.* = try core.Object.create(rt, core.class.ids.object, null);
    }

    for (keys, values) |key, value| {
        try appendWeakCollectionEntry(rt, weakmap, key, value.value());
        value.value().free(rt);
    }

    for (keys, 0..) |key, index| {
        if (index != preserved_index) key.value().free(rt);
    }

    _ = try rt.tryRunObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 1), weakmap.weakCollectionEntries().len);
    if (!core.memory.force_gc_on_allocation_enabled) {
        // Shapes are GC objects now: weakmap + preserved key + value share
        // one live empty root shape.
        try std.testing.expectEqual(@as(usize, 4), rt.gc.liveCount());
    } else {
        // TODO(S3): weak-collection liveness under forced GC.
    }

    weakmap.value().free(rt);
    keys[preserved_index].value().free(rt);
    _ = try rt.tryRunObjectCycleRemoval();
    if (!core.memory.force_gc_on_allocation_enabled) {
        try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
    } else {
        // TODO(S3): weak-collection liveness under forced GC.
    }
}

test "gc stress weak map dead cyclic keys clear values" {
    var prng = Rng.init(0x7a6a_6763_0003);
    const random = prng.random();

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const weakmap = try core.Object.create(rt, core.class.ids.weakmap, null);
    const count = 24;
    var keys: [count]*core.Object = undefined;
    var values: [count]*core.Object = undefined;

    for (&keys, &values) |*key_slot, *value_slot| {
        key_slot.* = try core.Object.create(rt, core.class.ids.object, null);
        value_slot.* = try core.Object.create(rt, core.class.ids.object, null);
    }

    const self_key = try rt.internAtom("stress-weak-dead-self");
    defer rt.atoms.free(self_key);
    const peer_key = try rt.internAtom("stress-weak-dead-peer");
    defer rt.atoms.free(peer_key);

    for (keys, values) |key, value| {
        try key.defineOwnProperty(rt, self_key, core.Descriptor.data(key.value(), true, true, true));
        const peer = keys[random.uintLessThan(usize, keys.len)];
        try key.defineOwnProperty(rt, peer_key, core.Descriptor.data(peer.value(), true, true, true));
        try appendWeakCollectionEntry(rt, weakmap, key, value.value());
        value.value().free(rt);
    }

    for (keys) |key| key.value().free(rt);
    try std.testing.expectEqual(@as(usize, count), weakmap.weakCollectionEntries().len);

    _ = try rt.tryRunObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 0), weakmap.weakCollectionEntries().len);
    // The live weakmap keeps its empty root shape alive.
    try std.testing.expectEqual(@as(usize, 2), rt.gc.liveCount());

    weakmap.value().free(rt);
    _ = try rt.tryRunObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
}

test "gc stress finalization registry dead target queues pending job" {
    var prng = Rng.init(0x7a6a_6763_0004);
    const random = prng.random();

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const cleanup = try core.Object.create(rt, core.class.ids.object, null);
    const registry = try core.Object.create(rt, core.class.ids.finalization_registry, null);
    registry.finalizationRegistryCleanupCallbackSlot().* = cleanup.value().dup();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    var target_value = target.value();
    const self_key = try rt.internAtom("stress-finalization-target-self");
    defer rt.atoms.free(self_key);
    try target.defineOwnProperty(rt, self_key, core.Descriptor.data(target_value, true, true, true));

    const held = try core.Object.create(rt, core.class.ids.object, null);
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
    target_value.free(rt);
    target_value = core.JSValue.undefinedValue();

    const collected = try rt.tryRunObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 2), collected.freed_objects);
    try std.testing.expectEqual(@as(usize, 0), rt.pendingFinalizationJobCountForTest());

    _ = try rt.tryRunObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 1), rt.pendingFinalizationJobCountForTest());
    try std.testing.expectEqual(@as(usize, 0), registry.finalizationRegistryCells().len);
    // cleanup + registry + held object, plus the shared root shape and the
    // held object's one-property transition shape.
    try std.testing.expectEqual(@as(usize, 5), rt.gc.liveCount());

    rt.clearPendingFinalizationJobs();
    registry.value().free(rt);
    cleanup.value().free(rt);
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
    var functions: [count]*core.Object = undefined;
    var captured: [count]*core.Object = undefined;

    for (&functions, &captured) |*function_slot, *captured_slot| {
        const function = try core.Object.create(rt, core.class.ids.bytecode_function, null);
        const captured_obj = try core.Object.create(rt, core.class.ids.object, null);
        const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
        const fb = &fb_slice[0];
        fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
        try rt.gc.add(&fb.header);
        {
            const __cp = try rt.memory.alloc(core.JSValue, 1);
            fb.cpool = __cp.ptr;
            fb.cpool_count = @intCast(__cp.len);
        }
        fb.cpool[0] = captured_obj.value().dup();
        fb.cpool_count = 1;

        function.functionBytecodeSlot().* = core.JSValue.functionBytecode(&fb.header);
        function_slot.* = function;
        captured_slot.* = captured_obj;
    }

    const function_key = try rt.internAtom("stress-bytecode-function");
    defer rt.atoms.free(function_key);
    for (captured, 0..) |captured_obj, index| {
        const target_index = (index + step) % count;
        try captured_obj.defineOwnProperty(rt, function_key, core.Descriptor.data(functions[target_index].value(), true, true, true));
    }

    for (functions) |function| function.value().free(rt);
    for (captured) |captured_obj| captured_obj.value().free(rt);

    _ = try rt.tryRunObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
}

pub const dummy = {};
