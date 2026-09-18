//! Type-erased `std.sort.heap` matching Zig 0.16 `heapContext` / `siftDown`.
//!
//! Leftover outlined `sort.siftDown` copies share one noinline walk. The
//! compare and swap arms stay typed trampolines. GC `u64` pause-sample and
//! registry-diagnostic heaps stay on std.

const std = @import("std");

const Ctx = struct {
    payload: *anyopaque,
    lessThan: *const fn (payload: *anyopaque, a: usize, b: usize) bool,
    swap: *const fn (payload: *anyopaque, a: usize, b: usize) void,
};

/// Same contract as `std.sort.heap`: in-place unstable heap sort.
pub inline fn heap(
    comptime T: type,
    items: []T,
    context: anytype,
    comptime lessThanFn: fn (@TypeOf(context), lhs: T, rhs: T) bool,
) void {
    const Wrapper = struct {
        items: []T,
        sub_ctx: @TypeOf(context),

        fn lessThan(payload: *anyopaque, a: usize, b: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(payload));
            return lessThanFn(self.sub_ctx, self.items[a], self.items[b]);
        }

        fn swap(payload: *anyopaque, a: usize, b: usize) void {
            const self: *@This() = @ptrCast(@alignCast(payload));
            const tmp = self.items[a];
            self.items[a] = self.items[b];
            self.items[b] = tmp;
        }
    };

    var wrapper = Wrapper{ .items = items, .sub_ctx = context };
    heapContext(items.len, .{
        .payload = &wrapper,
        .lessThan = Wrapper.lessThan,
        .swap = Wrapper.swap,
    });
}

noinline fn heapContext(len: usize, ctx: Ctx) void {
    var i = len / 2;
    while (i > 0) {
        i -= 1;
        siftDown(i, len, ctx);
    }

    i = len;
    while (i > 0) {
        i -= 1;
        ctx.swap(ctx.payload, 0, i);
        siftDown(0, i, ctx);
    }
}

/// Zig 0.16 `siftDown` with `a == 0` (the `heap` entry always uses that).
noinline fn siftDown(target: usize, bound: usize, ctx: Ctx) void {
    var cur = target;
    while (true) {
        var child = (std.math.mul(usize, cur, 2) catch break) + 1;
        if (!(child < bound)) break;

        const next_child = child + 1;
        if (next_child < bound and ctx.lessThan(ctx.payload, child, next_child)) {
            child = next_child;
        }
        if (ctx.lessThan(ctx.payload, child, cur)) break;
        ctx.swap(ctx.payload, child, cur);
        cur = child;
    }
}
test "sort_erased heap matches std.sort.heap" {
    const Sample = struct { key: u32, order: u32 };

    var empty: [0]u32 = .{};
    heap(u32, &empty, {}, std.sort.asc(u32));

    var std_nums = [_]u32{ 7, 1, 4, 1, 9, 0, 3 };
    var erased_nums = std_nums;
    std.sort.heap(u32, &std_nums, {}, std.sort.asc(u32));
    heap(u32, &erased_nums, {}, std.sort.asc(u32));
    try std.testing.expectEqualSlices(u32, &std_nums, &erased_nums);

    var std_desc = [_]u32{ 3, 8, 2, 8, 1 };
    var erased_desc = std_desc;
    std.sort.heap(u32, &std_desc, {}, std.sort.desc(u32));
    heap(u32, &erased_desc, {}, std.sort.desc(u32));
    try std.testing.expectEqualSlices(u32, &std_desc, &erased_desc);

    var std_samples = [_]Sample{
        .{ .key = 2, .order = 0 },
        .{ .key = 1, .order = 1 },
        .{ .key = 2, .order = 2 },
        .{ .key = 0, .order = 3 },
    };
    var erased_samples = std_samples;
    const lessThan = struct {
        fn lessThan(_: void, a: Sample, b: Sample) bool {
            return a.key < b.key or (a.key == b.key and a.order < b.order);
        }
    }.lessThan;
    std.sort.heap(Sample, &std_samples, {}, lessThan);
    heap(Sample, &erased_samples, {}, lessThan);
    try std.testing.expectEqualSlices(Sample, &std_samples, &erased_samples);
}
