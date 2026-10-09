//! Core integration tests: oom_cap.
const std = @import("std");
const zjs = @import("zjs");
const core = zjs.core;
const helpers = @import("../harness.zig");

// --- oom cap ---

// 8MB memory-cap OOM behaviour fixtures (engine production gate).
// Catchable-OOM contract: unbounded JS growth under an 8MB cap becomes a JS
// InternalError, the process stays alive, and delivering the preallocated OOM
// exception allocates nothing.

const cap_bytes: usize = 8 * 1024 * 1024;

test "engine production: 8MB cap OOM reaches JS catch as InternalError and the context stays usable" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{
        .memory_limit = cap_bytes,
    });
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    var wrapper = zjs.borrowContext(ctx);

    // Unbounded eager string growth must hit the cap, surface as a
    // catchable InternalError inside JS, and leave the engine alive.
    // (`"x".repeat(n)` materializes n bytes per round; plain `s = s + s`
    // would build O(1) rope links and overflow usize before ever touching
    // an 8MB cap.)
    const caught = try wrapper.eval(
        \\var oomName = "";
        \\var oomCaught = false;
        \\var n = 65536;
        \\var s = "";
        \\try {
        \\  for (;;) { n *= 2; s = "x".repeat(n); }
        \\} catch (e) {
        \\  // zjs maps OOM to the QuickJS-aligned InternalError *name*. There is
        \\  // no global InternalError constructor and the preallocated error's
        \\  // prototype is not chained under Error.prototype today, so pin the
        \\  // contract as: a catchable error object whose name is InternalError.
        \\  oomCaught = typeof e === "object" && e !== null && e.name === "InternalError";
        \\  oomName = e.name;
        \\  s = null;
        \\}
        \\oomCaught ? "caught:" + oomName : "uncaught"
    , .{ .filename = "<oom-cap>" });
    try helpers.expectStringValueBytes(caught, "caught:InternalError");

    // Same context must keep working after the OOM was caught and the
    // oversized value released.
    const followup = try wrapper.eval("6 * 7", .{ .filename = "<oom-cap>" });
    try std.testing.expectEqual(@as(?i32, 42), followup.as(.int));

    // Array growth variant: same cap, same catchable shape. Chunky
    // elements keep the loop short (sub-second tier).
    const array_caught = try wrapper.eval(
        \\var arrName = "";
        \\try {
        \\  var a = [];
        \\  for (;;) { a.push("y".repeat(65536)); }
        \\} catch (e) {
        \\  arrName = e.name;
        \\  a = null;
        \\}
        \\arrName
    , .{ .filename = "<oom-cap>" });
    try helpers.expectStringValueBytes(array_caught, "InternalError");

    const final = try wrapper.eval("\"alive\"", .{ .filename = "<oom-cap>" });
    try helpers.expectStringValueBytes(final, "alive");
}

/// Counts allocations that actually reach the backing allocator. Used to
/// prove the exhausted-heap OOM delivery window performs zero allocations:
/// the runtime limit rejects runtime-tracked allocations before they
/// reach this wrapper, and any path that bypassed the account (or released
/// the limit) would be counted here and fail the pin.
const CountingAllocator = struct {
    backing: std.mem.Allocator,
    success_count: usize = 0,
    attempt_count: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
        };
    }

    fn alloc(c: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(c));
        self.attempt_count += 1;
        const result = self.backing.rawAlloc(len, alignment, ra) orelse return null;
        self.success_count += 1;
        return result;
    }

    fn resize(c: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(c));
        return self.backing.rawResize(m, a, n, ra);
    }

    fn remap(c: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(c));
        return self.backing.rawRemap(m, a, n, ra);
    }

    fn free(c: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(c));
        self.backing.rawFree(m, a, ra);
    }
};

const ExhaustState = struct {
    rt: *core.JSRuntime,
    counting: *CountingAllocator,
    snapshot: usize = 0,
    window_allocations: ?usize = null,

    fn exhaust(call: *zjs.native.Call) core.JSValue {
        const self = call.state(ExhaustState);
        self.snapshot = self.counting.success_count;
        // Freeze the heap: every further accounted allocation fails.
        self.rt.setNativeBytesLimitForTest(self.rt.allocation_diagnostics.allocated_bytes);
        return core.JSValue.undefinedValue();
    }

    fn report(call: *zjs.native.Call) core.JSValue {
        const self = call.state(ExhaustState);
        self.window_allocations = self.counting.success_count - self.snapshot;
        self.rt.setNativeBytesLimitForTest(null);
        return core.JSValue.undefinedValue();
    }
};

test "engine production: exhausted-heap OOM delivery to JS catch allocates nothing" {
    var counting = CountingAllocator{ .backing = std.testing.allocator };
    const rt = try core.JSRuntime.create(counting.allocator(), .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    var wrapper = zjs.borrowContext(ctx);

    var state = ExhaustState{ .rt = rt, .counting = &counting };
    _ = try wrapper.defineFunction("__exhaust", zjs.native.managed(ExhaustState.exhaust), .{ .state = @ptrCast(&state) });
    _ = try wrapper.defineFunction("__report", zjs.native.managed(ExhaustState.report), .{ .state = @ptrCast(&state) });

    // Phase 1 (normal memory): compile the probe up front so phase 2 runs
    // without parsing.
    const setup = try wrapper.eval(
        \\function trigger() { return "x".repeat(65536); }
        \\function probe() {
        \\  var name = "";
        \\  __exhaust();
        \\  try { trigger(); } catch (e) { name = e.name; }
        \\  __report();
        \\  return name;
        \\}
        \\"ready"
    , .{ .filename = "<oom-pin>" });
    try helpers.expectStringValueBytes(setup, "ready");

    // Phase 2: inside one already-compiled call, exhaust the heap, force an
    // allocating operation to fail, and require (a) the catch handler sees
    // the preallocated InternalError and (b) zero allocations reached the
    // backing allocator inside the __exhaust..__report window.
    const result = try wrapper.eval("probe()", .{ .filename = "<oom-pin>" });
    try helpers.expectStringValueBytes(result, "InternalError");

    try std.testing.expect(state.window_allocations != null);
    try std.testing.expectEqual(@as(usize, 0), state.window_allocations.?);
}
