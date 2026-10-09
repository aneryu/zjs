//! Core integration tests: value_root_buffer.
const std = @import("std");
const zjs = @import("zjs");
const core = zjs.core;

const BufferCollectionProbe = struct {
    runtime: *core.JSRuntime,
    source_to_clear: []core.JSValue = &.{},
    calls: usize = 0,
    failure: ?core.gc.CollectionError = null,

    fn trigger(raw: ?*anyopaque, _: usize) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        // The copy is complete when provider growth allocates. Its source
        // may now change through a reentrant owner, without changing the copy.
        if (self.calls == 2) @memset(self.source_to_clear, core.JSValue.undefinedValue());
        _ = self.runtime.collectForTest() catch |err| {
            self.failure = err;
        };
    }
};

fn traceEmptyBufferTestProvider(_: *anyopaque, _: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {}

test "ValueRootBuffer protects copy and provider growth then owns liveness" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    // Occupy the inline provider slot so registration must allocate too.
    const dummy = core.runtime.RootProvider{ .context = rt, .trace = traceEmptyBufferTestProvider };
    try rt.registerRootProvider(dummy);
    defer rt.unregisterRootProvider(dummy);
    try std.testing.expectEqual(rt.roots.providerCapacity(), rt.roots.providers().len);
    const source = try std.testing.allocator.alloc(core.JSValue, 1);
    defer std.testing.allocator.free(source);
    const first_id = try rt.atoms.newValueSymbol("root-buffer-first");
    source[0] = try rt.symbolValue(first_id);
    var probe = BufferCollectionProbe{ .runtime = rt, .source_to_clear = source };
    const epoch = rt.gc.collection_epoch;
    _ = rt.gc.heap_budget.installProbe(.{ .run = BufferCollectionProbe.trigger, .context = &probe });
    defer rt.gc.heap_budget.restoreProbe(null);
    var first = try core.runtime.ValueRootBuffer.initCopy(rt, source);
    defer first.deinit();
    rt.gc.heap_budget.restoreProbe(null);
    if (probe.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try std.testing.expectEqual(epoch + 2, rt.gc.collection_epoch);
    try std.testing.expect(rt.atoms.name(first_id) != null);
    try std.testing.expect(rt.active_value_roots == null);
    source[0] = core.JSValue.undefinedValue();
    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(first_id) != null);
    try std.testing.expect(!first.values()[0].is(.undefined_value));

    const second_id = try rt.atoms.newValueSymbol("root-buffer-second");
    source[0] = try rt.symbolValue(second_id);
    var second = try core.runtime.ValueRootBuffer.initCopy(rt, source);
    defer second.deinit();
    source[0] = core.JSValue.undefinedValue();
    // Non-LIFO removal must leave the other provider intact.
    first.deinit();
    first.deinit();
    try std.testing.expectEqual(@as(usize, 0), first.values().len);
    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(first_id) == null);
    try std.testing.expect(rt.atoms.name(second_id) != null);
    second.deinit();
    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(second_id) == null);
    try std.testing.expectEqual(@as(usize, 0), rt.roots.value_root_buffers);
}

test "ValueRootBuffer allocation failures restore roots and storage" {
    for (0..2) |fail_offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const rt = try core.JSRuntime.create(failing.allocator(), .{});
        defer rt.destroy();
        const dummy = core.runtime.RootProvider{ .context = rt, .trace = traceEmptyBufferTestProvider };
        try rt.registerRootProvider(dummy);
        defer rt.unregisterRootProvider(dummy);
        const slices = [_]core.runtime.ValueRootSlice{.{ .borrowed = &.{} }};
        var outer = core.runtime.ValueRootFrame{ .slices = &slices };
        outer.activate(rt);
        defer outer.deactivate(rt);
        const live_bytes = failing.allocated_bytes - failing.freed_bytes;
        failing.fail_index = failing.alloc_index + fail_offset;
        try std.testing.expectError(error.OutOfMemory, core.runtime.ValueRootBuffer.initCopy(rt, &.{core.JSValue.int32(42)}));
        failing.fail_index = std.math.maxInt(usize);
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(live_bytes, failing.allocated_bytes - failing.freed_bytes);
        try std.testing.expectEqual(@as(usize, 1), rt.roots.providers().len);
        try std.testing.expectEqual(@as(usize, 0), rt.roots.value_root_buffers);
        try std.testing.expect(rt.active_value_roots == &outer);
        var retry = try core.runtime.ValueRootBuffer.initCopy(rt, &.{core.JSValue.int32(42)});
        defer retry.deinit();
        try std.testing.expect(retry.values()[0].same(core.JSValue.int32(42)));
    }
}

test "ValueRootBuffer empty needs no allocation or registration" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const rt = try core.JSRuntime.create(failing.allocator(), .{});
    defer rt.destroy();
    failing.fail_index = failing.alloc_index;
    var buffer = try core.runtime.ValueRootBuffer.initCopy(rt, &.{});
    buffer.deinit();
    buffer.deinit();
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), buffer.values().len);
    try std.testing.expectEqual(@as(usize, 0), rt.roots.value_root_buffers);
    failing.fail_index = std.math.maxInt(usize);
}

test "ValueRootBuffer teardown guard" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var buffer = try core.runtime.ValueRootBuffer.initCopy(rt, &.{core.JSValue.int32(1)});
    defer buffer.deinit();
    // Run through zig build test with this filter to exercise the real
    // Runtime.destroy guard, rather than a test-only copy of its predicate.
    if (std.c.getenv("ZJS_VALUE_ROOT_BUFFER_INJECT")) |raw| {
        if (std.mem.eql(u8, std.mem.span(raw), "1")) rt.destroy();
    }
}

test "ValueRootBuffer registration survives allocation probe reentry" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const dummy = core.runtime.RootProvider{ .context = rt, .trace = traceEmptyBufferTestProvider };
    try rt.registerRootProvider(dummy);
    defer rt.unregisterRootProvider(dummy);
    const Probe = struct {
        runtime: *core.JSRuntime,
        calls: usize = 0,
        nested: [3]core.runtime.ValueRootBuffer = @splat(.{}),
        failure: ?std.mem.Allocator.Error = null,

        fn trigger(raw: ?*anyopaque, _: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            // Reenter specifically while the outer provider table is growing.
            if (self.calls != 2) return;
            for (&self.nested) |*buffer| {
                buffer.* = core.runtime.ValueRootBuffer.initCopy(self.runtime, &.{core.JSValue.int32(7)}) catch |err| {
                    self.failure = err;
                    return;
                };
            }
        }
    };
    var probe = Probe{ .runtime = rt };
    defer for (&probe.nested) |*buffer| buffer.deinit();
    _ = rt.gc.heap_budget.installProbe(.{ .run = Probe.trigger, .context = &probe });
    defer rt.gc.heap_budget.restoreProbe(null);
    var outer = try core.runtime.ValueRootBuffer.initCopy(rt, &.{core.JSValue.int32(9)});
    defer outer.deinit();
    if (probe.failure) |err| return err;
    try std.testing.expect(probe.calls >= 2);
    try std.testing.expectEqual(@as(usize, 4), rt.roots.value_root_buffers);
    try std.testing.expectEqual(@as(usize, 5), rt.roots.providers().len);
    _ = try rt.collectForTest();
}
