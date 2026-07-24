//! 8MB memory-cap OOM behaviour fixtures (engine production gate).
//!
//! Pins the catchable-OOM contract from eecf6c8 at the embedding surface:
//!   - under a hard 8MB runtime cap, unbounded JS growth OOMs into a JS
//!     `catch` as InternalError (QuickJS-aligned mapping), the process stays
//!     alive, and the same context keeps evaluating afterwards;
//!   - delivering the OOM exception to a JS catch handler while the heap is
//!     fully exhausted performs zero allocations (preallocated OOM error +
//!     `tryCatchInFrame` zero-allocation delivery), asserted with a counting
//!     backing allocator so even paths that bypass the MemoryAccount limit
//!     would be caught.
//!
//! Sub-second tests: they run inside the regular `zig build test` unified
//! suite (referenced from src/all_tests.zig) and as a focused binary wired
//! into the `engine-production-gate` step in build.zig.

const std = @import("std");
const zjs = @import("zjs");

const core = zjs.core;
const BindingContext = zjs.binding_root.JSContext;

const cap_bytes: usize = 8 * 1024 * 1024;

fn expectStringValue(value: core.JSValue, expected: []const u8) !void {
    if (!value.isString()) return error.TestUnexpectedResult;
    const string_value = value.asStringBody() orelse return error.TestUnexpectedResult;
    if (!string_value.eqlBytes(expected)) return error.TestUnexpectedResult;
}

test "engine production: 8MB cap OOM reaches JS catch as InternalError and the context stays usable" {
    const rt = try core.JSRuntime.createWithOptions(std.testing.allocator, .{
        .memory_limit = cap_bytes,
    });
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    var wrapper = BindingContext.borrowCore(ctx);

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
    defer caught.free(rt);
    try expectStringValue(caught, "caught:InternalError");

    // Same context must keep working after the OOM was caught and the
    // oversized value released.
    const followup = try wrapper.eval("6 * 7", .{ .filename = "<oom-cap>" });
    defer followup.free(rt);
    try std.testing.expectEqual(@as(?i32, 42), followup.asInt32());

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
    defer array_caught.free(rt);
    try expectStringValue(array_caught, "InternalError");

    const final = try wrapper.eval("\"alive\"", .{ .filename = "<oom-cap>" });
    defer final.free(rt);
    try expectStringValue(final, "alive");
}

/// Counts allocations that actually reach the backing allocator. Used to
/// prove the exhausted-heap OOM delivery window performs zero allocations:
/// the runtime limit rejects MemoryAccount-tracked allocations before they
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

    fn exhaust(ptr: *anyopaque, call: zjs.ExternalHostCall) anyerror!core.JSValue {
        _ = call;
        const self: *ExhaustState = @ptrCast(@alignCast(ptr));
        self.snapshot = self.counting.success_count;
        // Freeze the heap: every further accounted allocation fails.
        self.rt.memory.setLimit(self.rt.memory.allocated_bytes);
        return core.JSValue.undefinedValue();
    }

    fn report(ptr: *anyopaque, call: zjs.ExternalHostCall) anyerror!core.JSValue {
        _ = call;
        const self: *ExhaustState = @ptrCast(@alignCast(ptr));
        self.window_allocations = self.counting.success_count - self.snapshot;
        self.rt.memory.setLimit(null);
        return core.JSValue.undefinedValue();
    }
};

test "engine production: exhausted-heap OOM delivery to JS catch allocates nothing" {
    var counting = CountingAllocator{ .backing = std.testing.allocator };
    const rt = try core.JSRuntime.createWithOptions(counting.allocator(), .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    var wrapper = BindingContext.borrowCore(ctx);

    var state = ExhaustState{ .rt = rt, .counting = &counting };
    try wrapper.defineGlobalFunction("__exhaust", 0, &state, ExhaustState.exhaust, null);
    try wrapper.defineGlobalFunction("__report", 0, &state, ExhaustState.report, null);

    // Phase 1 (normal memory): compile the probe up front so phase 2 runs
    // without parsing.
    const setup = try wrapper.eval(
        \\function trigger() { return { grown: [1, 2, 3] }; }
        \\function probe() {
        \\  var name = "";
        \\  __exhaust();
        \\  try { trigger(); } catch (e) { name = e.name; }
        \\  __report();
        \\  return name;
        \\}
        \\"ready"
    , .{ .filename = "<oom-pin>" });
    defer setup.free(rt);
    try expectStringValue(setup, "ready");

    // Phase 2: inside one already-compiled call, exhaust the heap, force an
    // allocating operation to fail, and require (a) the catch handler sees
    // the preallocated InternalError and (b) zero allocations reached the
    // backing allocator inside the __exhaust..__report window.
    const result = try wrapper.eval("probe()", .{ .filename = "<oom-pin>" });
    defer result.free(rt);
    try expectStringValue(result, "InternalError");

    try std.testing.expect(state.window_allocations != null);
    try std.testing.expectEqual(@as(usize, 0), state.window_allocations.?);
}
