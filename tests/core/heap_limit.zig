//! Core integration tests: heap_limit.
const std = @import("std");
const zjs = @import("zjs");
const core = zjs.core;

test "heap budget caps published cells without capping native alloc or external bytes" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    rt.forcePreciseRootScanForTest();
    rt.suppressLimitCollectionForTest(true);
    rt.setGCThreshold(std.math.maxInt(usize));

    const other = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer other.destroy();
    other.suppressLimitCollectionForTest(true);
    other.setGCThreshold(std.math.maxInt(usize));

    const before = rt.gc.heap_budget.bytes;
    var object: ?*core.Object = try core.Object.create(rt, core.class.ids.object, null);
    const with_object = rt.gc.heap_budget.bytes;
    try std.testing.expect(with_object > before);
    object = null;
    _ = try rt.collectForTest();
    const after_collect = rt.gc.heap_budget.bytes;
    try std.testing.expect(after_collect < with_object);
    const charge = with_object - after_collect;

    const retries_before = rt.gc.heap_budget.limit_retries;
    rt.setMemoryLimit(after_collect + charge - 1);
    try std.testing.expectError(error.OutOfMemory, core.Object.create(rt, core.class.ids.object, null));
    try std.testing.expectEqual(after_collect, rt.gc.heap_budget.bytes);
    try std.testing.expectEqual(retries_before, rt.gc.heap_budget.limit_retries);

    rt.setMemoryLimit(after_collect + charge);
    object = try core.Object.create(rt, core.class.ids.object, null);
    try std.testing.expectEqual(after_collect + charge, rt.gc.heap_budget.bytes);
    object = null;
    _ = try rt.collectForTest();
    try std.testing.expectEqual(after_collect, rt.gc.heap_budget.bytes);

    rt.setMemoryLimit(0);
    const native = try rt.allocNative(u8, 32);
    const heap_before_remap = rt.gc.heap_budget.bytes;
    rt.setNativeBytesLimitForTest(rt.allocation_diagnostics.allocated_bytes);
    try std.testing.expectError(error.OutOfMemory, rt.remapNative(u8, native, 128));
    try std.testing.expectEqual(heap_before_remap, rt.gc.heap_budget.bytes);
    rt.setNativeBytesLimitForTest(null);
    rt.freeNative(u8, native);

    const external_before = rt.gc.heap_budget.bytes;
    var token = try rt.gc.reportExternalAlloc(128);
    defer token.release();
    try std.testing.expectEqual(external_before, rt.gc.heap_budget.bytes);
    try std.testing.expect(rt.gcStats().external_bytes >= 128);

    const other_before = other.gc.heap_budget.bytes;
    const other_object = try core.Object.create(other, core.class.ids.object, null);
    try std.testing.expect(other.gc.heap_budget.bytes > other_before);
    core.Object.destroyFromHeader(other, other_object.gcHeader());
    try std.testing.expectEqual(other_before, other.gc.heap_budget.bytes);
    try std.testing.expectEqual(after_collect, rt.gc.heap_budget.bytes);
}

test "heap limit collects once and then admits another object" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    rt.forcePreciseRootScanForTest();
    rt.setGCThreshold(std.math.maxInt(usize));
    _ = try rt.collectForTest();

    const kept_object = try core.Object.create(rt, core.class.ids.object, null);
    var kept = kept_object.value();
    var kept_roots = core.runtime.rootValues(.{&kept});
    kept_roots.activate(rt);
    defer kept_roots.deactivate(rt);
    const with_kept = rt.gc.heap_budget.bytes;

    const charge = blk: {
        const dropped = try core.Object.create(rt, core.class.ids.object, null);
        const with_dropped = rt.gc.heap_budget.bytes;
        try std.testing.expect(with_dropped > with_kept);
        std.mem.doNotOptimizeAway(dropped);
        break :blk with_dropped - with_kept;
    };

    rt.setMemoryLimit(with_kept + charge);
    const retries = rt.gc.heap_budget.limit_retries;
    const majors = rt.gc.stats.collections;
    const created = try core.Object.create(rt, core.class.ids.object, null);
    try std.testing.expectEqual(retries + 1, rt.gc.heap_budget.limit_retries);
    try std.testing.expectEqual(majors + 1, rt.gc.stats.collections);
    try std.testing.expectEqual(with_kept + charge, rt.gc.heap_budget.bytes);
    try std.testing.expectEqual(core.class.ids.object, kept_object.class_id);
    try std.testing.expect(created != kept_object);
}

test "heap limit retry keeps a local object the precise root set cannot name" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    rt.setGCThreshold(std.math.maxInt(usize));
    _ = try rt.collectForTest();

    var live = try core.Object.create(rt, core.class.ids.object, null);
    std.mem.doNotOptimizeAway(&live);
    const with_live = rt.gc.heap_budget.bytes;
    rt.setMemoryLimit(with_live);
    const retries = rt.gc.heap_budget.limit_retries;
    try std.testing.expectError(error.OutOfMemory, core.Object.create(rt, core.class.ids.object, null));
    try std.testing.expectEqual(retries + 1, rt.gc.heap_budget.limit_retries);
    try std.testing.expectEqual(with_live, rt.gc.heap_budget.bytes);
    try std.testing.expectEqual(core.class.ids.object, live.class_id);
}

test "heap limit of zero collects once and still rejects" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    rt.setGCThreshold(std.math.maxInt(usize));
    const seeded = try core.Object.create(rt, core.class.ids.object, null);
    std.mem.doNotOptimizeAway(seeded);
    try std.testing.expect(rt.gc.heap_budget.bytes > 0);
    rt.setMemoryLimit(0);
    const retries = rt.gc.heap_budget.limit_retries;
    try std.testing.expectError(error.OutOfMemory, core.Object.create(rt, core.class.ids.object, null));
    try std.testing.expectEqual(retries + 1, rt.gc.heap_budget.limit_retries);
    try std.testing.expect(rt.gc.heap_budget.bytes > 0);
}

test "native byte cap does not retry the heap limit" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    rt.setGCThreshold(std.math.maxInt(usize));
    const retries = rt.gc.heap_budget.limit_retries;
    const majors = rt.gc.stats.collections;
    rt.setNativeBytesLimitForTest(rt.allocation_diagnostics.allocated_bytes);
    defer rt.setNativeBytesLimitForTest(null);
    try std.testing.expectError(error.OutOfMemory, rt.allocNative(u8, 64));
    try std.testing.expectEqual(retries, rt.gc.heap_budget.limit_retries);
    try std.testing.expectEqual(majors, rt.gc.stats.collections);
}

test "heap limit retry does not nest while a collection is running" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    rt.setGCThreshold(std.math.maxInt(usize));
    rt.setMemoryLimit(rt.gc.heap_budget.bytes);
    rt.gc.hot.collecting = true;
    defer rt.gc.hot.collecting = false;
    const retries = rt.gc.heap_budget.limit_retries;
    const majors = rt.gc.stats.collections;
    try std.testing.expectError(error.OutOfMemory, core.Object.create(rt, core.class.ids.object, null));
    try std.testing.expect(rt.gc.heap_budget.limit_retries > retries);
    try std.testing.expectEqual(majors, rt.gc.stats.collections);
}
