const bignum = @import("../libs/bignum.zig");
const std = @import("std");

pub fn staticUnsignedMode(name: []const u8) ?bool {
    if (std.mem.eql(u8, name, "asIntN")) return false;
    if (std.mem.eql(u8, name, "asUintN")) return true;
    return null;
}

pub fn add(a: bignum.BigInt, b: bignum.BigInt) !bignum.BigInt {
    return a.add(b);
}

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !bignum.BigInt {
    return bignum.parseBase10(allocator, bytes);
}
