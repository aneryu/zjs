const bignum = @import("../libs/bignum.zig");

pub fn add(a: bignum.BigInt, b: bignum.BigInt) bignum.BigInt {
    return a.add(b);
}

pub fn parse(bytes: []const u8) !bignum.BigInt {
    return bignum.parseBase10(bytes);
}
