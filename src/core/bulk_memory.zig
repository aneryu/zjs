//! Bulk byte fill for the compiler's medium and large temporary buffers.
//!
//! QuickJS reaches the platform `memset` backend for the corresponding
//! `js_mallocz` and `compute_stack_size` fills. Zig's compiler-rt fallback on
//! the production target uses byte stores, so keep the same bulk-store shape
//! explicitly and leave only the sub-vector tail to the compiler.

pub noinline fn fillByte(bytes: []u8, value: u8) void {
    const Vector = @Vector(16, u8);
    const wide: Vector = @splat(value);
    var offset: usize = 0;
    while (bytes.len - offset >= @sizeOf(Vector)) : (offset += @sizeOf(Vector)) {
        const target: *align(1) Vector = @ptrCast(bytes.ptr + offset);
        target.* = wide;
    }
    while (offset < bytes.len) : (offset += 1) bytes[offset] = value;
}

test "fillByte writes the complete slice" {
    const std = @import("std");
    var bytes = [_]u8{0} ** 17;
    fillByte(&bytes, 0xa5);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** bytes.len), &bytes);
}
