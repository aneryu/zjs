const bignum = @import("../libs/bignum.zig");
const std = @import("std");
const core = @import("../core/root.zig");

// `staticUnsignedMode` relocated to engine core
// (`core/host_function.zig`, `builtin_method_id_lookup.bigint`) in Phase 6b-3
// STEP 2; re-exported here unchanged.
pub const staticUnsignedMode = core.host_function.builtin_method_id_lookup.bigint.staticUnsignedMode;

pub fn add(a: bignum.BigInt, b: bignum.BigInt) !bignum.BigInt {
    return a.add(b);
}

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !bignum.BigInt {
    return bignum.parseBase10(allocator, bytes);
}
