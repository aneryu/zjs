//! Growable native slices for the compiler's append-heavy buffers.
//!
//! A growable slice keeps `slice.*.len` as the used count and
//! `slice.*.ptr[0..capacity.*]` as the allocator-owned backing buffer.
const std = @import("std");

/// Geometric growth helper.
///
/// Maintains the contract that `slice.*.len` is the *used* count while the
/// allocator-owned backing buffer is `slice.*.ptr[0..capacity.*]`. Returns a
/// writable view of the freshly grown tail (length `n`).
///
/// Each append used to do `alloc(old + n) + memcpy + free(old)`, making
/// repeated appends O(n²). Geometric growth (capacity doubling, with an
/// 8-element floor) reduces total cost to amortised O(1) per item.
pub inline fn growSliceBy(
    comptime T: type,
    allocator: std.mem.Allocator,
    slice: *[]T,
    capacity: *usize,
    n: usize,
) ![]T {
    const used = slice.len;
    const new_used = used + n;
    if (new_used <= capacity.*) {
        slice.* = slice.ptr[0..new_used];
        return slice.ptr[used..new_used];
    }
    var new_cap: usize = if (capacity.* == 0) 8 else capacity.* * 2;
    if (new_cap < new_used) new_cap = new_used;
    const new_buf = try allocator.alloc(T, new_cap);
    if (used != 0) @memcpy(new_buf[0..used], slice.ptr[0..used]);
    var old_buf: []T = &.{};
    if (capacity.* != 0) old_buf = slice.ptr[0..capacity.*];
    slice.* = new_buf[0..new_used];
    capacity.* = new_cap;
    if (old_buf.len != 0) allocator.free(old_buf);
    return slice.ptr[used..new_used];
}

/// Free the full backing buffer of a growable slice and reset both the
/// visible slice and its capacity. Growth and install keep `capacity == 0`
/// only for an empty slice.
pub fn freeGrowableSlice(
    comptime T: type,
    allocator: std.mem.Allocator,
    slice: *[]T,
    capacity: *usize,
) void {
    std.debug.assert(capacity.* != 0 or slice.len == 0);
    var old_buf: []T = &.{};
    if (capacity.* != 0) old_buf = slice.ptr[0..capacity.*];
    slice.* = &.{};
    capacity.* = 0;
    if (old_buf.len != 0) allocator.free(old_buf);
}
