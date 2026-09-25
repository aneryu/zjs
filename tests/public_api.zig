//! Public Runtime/Context/Value contract and host-facing eval behavior.
const std = @import("std");
const zjs = @import("zjs");

const DiagnosticTestClock = struct {
    now: u64 = 100,
    calls: usize = 0,

    fn read(ptr: ?*anyopaque) u64 {
        const self: *@This() = @ptrCast(@alignCast(ptr.?));
        self.calls += 1;
        const result = self.now;
        self.now += 10;
        return result;
    }
};

test "diagnostic clock is opt in and isolated per Runtime" {
    // Stress collects at safepoints regardless of threshold, and each
    // collection times itself through the diagnostic clock.
    if (zjs.core.gc.forensics.stressing()) return error.SkipZigTest;
    var clock: DiagnosticTestClock = .{};
    const rt = try zjs.Runtime.create(std.testing.allocator, .{
        .diagnostic_clock = .{ .context = &clock, .nowNanos = DiagnosticTestClock.read },
        .gc_threshold = std.math.maxInt(usize),
    });
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{ .math_random_seed = 42 });
    defer ctx.destroy();
    _ = try ctx.eval("21 * 2", .{});
    try std.testing.expectEqual(@as(usize, 0), clock.calls);

    var timing: zjs.Context.EvalTiming = .{};
    _ = try ctx.eval("21 * 2", .{ .timing = &timing });
    try std.testing.expect(timing.compile_frontend_ns > 0);
    try std.testing.expect(timing.compile_finalize_ns > 0);
    try std.testing.expect(timing.vm_run_ns > 0);
    const calls = clock.calls;

    const other = try zjs.Runtime.create(std.testing.allocator, .{});
    defer other.destroy();
    const other_ctx = try zjs.Context.create(other, .{ .math_random_seed = 42 });
    defer other_ctx.destroy();
    timing = .{};
    _ = try other_ctx.eval("21 * 2", .{ .timing = &timing });
    try std.testing.expectEqualDeep(zjs.Context.EvalTiming{}, timing);
    try std.testing.expectEqual(calls, clock.calls);
    try std.testing.expectEqual(@as(u64, 0), other.diagnosticNanos());

    // Explicit Realm seeds are independent of either diagnostic clock.
    const a = try ctx.eval("Math.random()", .{});
    const b = try other_ctx.eval("Math.random()", .{});
    try std.testing.expect(a.as(.float64) != null);
    try std.testing.expectEqual(a.as(.float64), b.as(.float64));
    clock.now = 5;
    try std.testing.expectEqual(@as(u64, 0), rt.diagnosticElapsedSince(100));
    const no_timing_gc = try other.forceGC(null);
    try std.testing.expectEqual(@as(u64, 0), no_timing_gc.duration_ns);
    // Turning diagnostics off must not freeze the collector's page-age clock.
    try std.testing.expect(other.gc.block_heap.clock_ns > 0);
}

test "diagnostic clock measures construction and GC through Runtime hook" {
    var clock: DiagnosticTestClock = .{};
    const rt = try zjs.Runtime.create(std.testing.allocator, .{
        .diagnostic_clock = .{ .context = &clock, .nowNanos = DiagnosticTestClock.read },
    });
    defer rt.destroy();
    const context_mod = @import("../src/js_context.zig");
    var timing: context_mod.ContextCreateTiming = .{};
    const ctx = try context_mod.createMeasured(rt, .{}, &timing);
    defer ctx.destroy();
    try std.testing.expect(timing.raw_create_ns > 0);
    try std.testing.expect(timing.bootstrap_ns > 0);
    const result = try rt.forceGC(null);
    try std.testing.expect(result.duration_ns > 0);
}

test "defineScriptArgs materializes empty array on first read" {
    const rt = try zjs.Runtime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();

    try ctx.defineScriptArgs(&.{"stale"});
    try ctx.defineScriptArgs(&.{});
    try ctx.defineScriptArgs(&.{});
    const result = try ctx.eval(
        \\var desc = Object.getOwnPropertyDescriptor(globalThis, "scriptArgs");
        \\desc.writable === true &&
        \\desc.enumerable === true &&
        \\desc.configurable === true &&
        \\Array.isArray(desc.value) &&
        \\desc.value.length === 0 &&
        \\Object.getPrototypeOf(scriptArgs) === Array.prototype &&
        \\(scriptArgs.push("ok"), scriptArgs.length === 1 && scriptArgs[0] === "ok") &&
        \\delete globalThis.scriptArgs &&
        \\!("scriptArgs" in globalThis);
    , .{});
    try std.testing.expectEqual(true, result.as(.boolean).?);
}

test "defineScriptArgs installs string items" {
    const rt = try zjs.Runtime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();

    try ctx.defineScriptArgs(&.{ "a.js", "--flag" });
    const result = try ctx.eval(
        \\Array.isArray(scriptArgs) &&
        \\scriptArgs.length === 2 &&
        \\scriptArgs[0] === "a.js" &&
        \\scriptArgs[1] === "--flag" &&
        \\Object.getPrototypeOf(scriptArgs) === Array.prototype;
    , .{});
    try std.testing.expectEqual(true, result.as(.boolean).?);
}

test "Context.toString performs ECMAScript ToString instead of tag assertion" {
    const rt = try zjs.Runtime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();

    const object = try ctx.eval("({ toString() { return 'semantic-string'; } })", .{});
    try std.testing.expect(object.asString() == null);

    const converted = try ctx.toString(object);
    try std.testing.expectEqualStrings("semantic-string", converted.asString().?.units().latin1);
}

test "Context owned string conversion roots source across allocator GC" {
    const CollectingAllocator = struct {
        rt: *zjs.Runtime,
        collected: bool = false,

        fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.rt.forcePreciseRootScanForTest();
            defer self.rt.restoreDefaultRootScanForTest();
            _ = self.rt.forceGC(null) catch return null;
            self.collected = true;
            return std.testing.allocator.rawAlloc(len, alignment, ra);
        }
        fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
            return false;
        }
        fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
            return null;
        }
        fn free(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            std.testing.allocator.rawFree(bytes, alignment, ra);
        }
    };
    const rt = try zjs.Runtime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    for ([_]bool{ false, true }) |rope_input| {
        const left = try zjs.core.string.String.createUtf16(rt, &.{ 'a', 0xd83d });
        const input = if (rope_input) blk: {
            const right = try zjs.core.string.String.createUtf16(rt, &.{ 0xde00, 'z' });
            break :blk (try zjs.core.string.String.createRope(rt, left.value(), right.value())).value();
        } else left.value();
        var state = CollectingAllocator{ .rt = rt };
        const allocator = std.mem.Allocator{ .ptr = &state, .vtable = &.{
            .alloc = CollectingAllocator.alloc,
            .resize = CollectingAllocator.resize,
            .remap = CollectingAllocator.remap,
            .free = CollectingAllocator.free,
        } };
        const epoch = rt.gc.collection_epoch;
        const bytes = try ctx.toOwnedUtf8(input, allocator);
        defer allocator.free(bytes);
        try std.testing.expect(state.collected);
        try std.testing.expect(rt.gc.collection_epoch > epoch);
        try std.testing.expectEqualStrings(if (rope_input) "a\xf0\x9f\x98\x80z" else "a\xed\xa0\xbd", bytes);
        if (input.ropeBody()) |rope| try std.testing.expect(!rope.isLinearized());
    }
}

test "Runtime create requires an explicit host allocator" {
    try std.testing.expect(!@hasField(zjs.Runtime.Options, "allocator"));
    const allocator = std.testing.allocator;
    const rt = try zjs.Runtime.create(allocator, .{});
    defer rt.destroy();
    try std.testing.expectEqual(allocator.ptr, rt.allocator.ptr);
    try std.testing.expectEqual(allocator.vtable, rt.allocator.vtable);
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    try std.testing.expectEqual(@as(?i32, 42), (try ctx.eval("21 * 2", .{})).as(.int));
    try rt.runMicrotasks();
    try std.testing.expect(rt.memoryUsage().heap_bytes > 0);
}
