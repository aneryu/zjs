const std = @import("std");

const limb_bits = 32;
const Limb = u32;
const DoubleLimb = u64;

pub const BigInt = struct {
    negative: bool = false,
    limbs: []Limb = &.{},
    allocator: std.mem.Allocator = std.heap.page_allocator,

    pub fn fromInt(value: i128) BigInt {
        return fromIntAlloc(std.heap.page_allocator, value) catch unreachable;
    }

    pub fn fromIntAlloc(allocator: std.mem.Allocator, value: i128) !BigInt {
        if (value == 0) return .{ .allocator = allocator };
        var magnitude: u128 = if (value < 0) @intCast(-value) else @intCast(value);
        var tmp: [4]Limb = undefined;
        var len: usize = 0;
        while (magnitude != 0) {
            tmp[len] = @truncate(magnitude);
            magnitude >>= limb_bits;
            len += 1;
        }
        const limbs = try allocator.alloc(Limb, len);
        @memcpy(limbs, tmp[0..len]);
        return .{ .negative = value < 0, .limbs = limbs, .allocator = allocator };
    }

    pub fn deinit(self: *BigInt) void {
        if (self.limbs.len != 0) self.allocator.free(self.limbs);
        self.* = .{ .allocator = self.allocator };
    }

    pub fn clone(self: BigInt) !BigInt {
        return self.cloneWithAllocator(self.allocator);
    }

    pub fn cloneWithAllocator(self: BigInt, allocator: std.mem.Allocator) !BigInt {
        if (self.limbs.len == 0) return .{ .allocator = allocator };
        const limbs = try allocator.alloc(Limb, self.limbs.len);
        @memcpy(limbs, self.limbs);
        return .{ .negative = self.negative, .limbs = limbs, .allocator = allocator };
    }

    pub fn isZero(self: BigInt) bool {
        return self.limbs.len == 0;
    }

    pub fn add(self: BigInt, other: BigInt) BigInt {
        return addAlloc(self.allocator, self, other) catch unreachable;
    }

    pub fn sub(self: BigInt, other: BigInt) BigInt {
        return subAlloc(self.allocator, self, other) catch unreachable;
    }

    pub fn mul(self: BigInt, other: BigInt) BigInt {
        return mulAlloc(self.allocator, self, other) catch unreachable;
    }

    pub fn div(self: BigInt, other: BigInt) !BigInt {
        if (other.isZero()) return error.DivisionByZero;
        const out = try divRemAlloc(self.allocator, self, other);
        var remainder = out[1];
        remainder.deinit();
        return out[0];
    }

    pub fn rem(self: BigInt, other: BigInt) !BigInt {
        if (other.isZero()) return error.DivisionByZero;
        const out = try divRemAlloc(self.allocator, self, other);
        var quotient = out[0];
        quotient.deinit();
        return out[1];
    }

    pub fn compare(self: BigInt, other: BigInt) std.math.Order {
        if (self.negative != other.negative) return if (self.negative) .lt else .gt;
        const abs_order = compareAbs(self, other);
        return if (self.negative) invertOrder(abs_order) else abs_order;
    }

    pub fn formatBase10Alloc(self: BigInt, allocator: std.mem.Allocator) ![]u8 {
        return self.formatBaseAlloc(allocator, 10);
    }

    pub fn formatBaseAlloc(self: BigInt, allocator: std.mem.Allocator, base: u8) ![]u8 {
        if (base < 2 or base > 36) return error.InvalidRadix;
        if (self.isZero()) {
            const out = try allocator.alloc(u8, 1);
            out[0] = '0';
            return out;
        }
        var work = try self.absCloneWithAllocator(allocator);
        defer work.deinit();
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        if (self.negative) try out.append(allocator, '-');
        if (base == 10) {
            var chunks = std.ArrayList(u32).empty;
            defer chunks.deinit(allocator);
            while (!work.isZero()) {
                const remainder = try work.divRemSmallInPlace(1_000_000_000);
                try chunks.append(allocator, remainder);
            }
            var index = chunks.items.len;
            while (index > 0) {
                index -= 1;
                var buf: [16]u8 = undefined;
                if (index == chunks.items.len - 1) {
                    const text = try std.fmt.bufPrint(&buf, "{d}", .{chunks.items[index]});
                    try out.appendSlice(allocator, text);
                } else {
                    const text = try std.fmt.bufPrint(&buf, "{d:0>9}", .{chunks.items[index]});
                    try out.appendSlice(allocator, text);
                }
            }
            return try out.toOwnedSlice(allocator);
        }
        var digits = std.ArrayList(u8).empty;
        defer digits.deinit(allocator);
        while (!work.isZero()) {
            const remainder = try work.divRemSmallInPlace(base);
            try digits.append(allocator, if (remainder < 10) @intCast('0' + remainder) else @intCast('a' + remainder - 10));
        }
        var index = digits.items.len;
        while (index > 0) {
            index -= 1;
            try out.append(allocator, digits.items[index]);
        }
        return try out.toOwnedSlice(allocator);
    }

    pub fn pow(self: BigInt, exponent: BigInt, allocator: std.mem.Allocator) !BigInt {
        if (exponent.negative) return error.NegativeExponent;
        const exp = exponent.toUsize() orelse return error.BigIntTooLarge;
        var result = try BigInt.fromIntAlloc(allocator, 1);
        errdefer result.deinit();
        var base_value = try self.cloneWithAllocator(allocator);
        defer base_value.deinit();
        var remaining = exp;
        while (remaining != 0) {
            if ((remaining & 1) != 0) {
                const next = try mulAlloc(allocator, result, base_value);
                result.deinit();
                result = next;
            }
            remaining >>= 1;
            if (remaining != 0) {
                const next = try mulAlloc(allocator, base_value, base_value);
                base_value.deinit();
                base_value = next;
            }
        }
        return result;
    }

    pub fn bitNot(self: BigInt, allocator: std.mem.Allocator) !BigInt {
        var one = try BigInt.fromIntAlloc(allocator, 1);
        defer one.deinit();
        var plus_one = try addAlloc(allocator, self, one);
        defer plus_one.deinit();
        const zero = BigInt{ .allocator = allocator };
        return subAlloc(allocator, zero, plus_one);
    }

    pub fn bitwise(self: BigInt, other: BigInt, allocator: std.mem.Allocator, op: enum { @"and", @"or", xor }) !BigInt {
        const width = @max(self.bitLengthAbs(), other.bitLengthAbs()) + 1;
        const limb_count = (width + limb_bits - 1) / limb_bits;
        const lhs = try self.toTwosComplement(allocator, limb_count);
        defer allocator.free(lhs);
        const rhs = try other.toTwosComplement(allocator, limb_count);
        defer allocator.free(rhs);
        for (lhs, 0..) |*limb, i| {
            limb.* = switch (op) {
                .@"and" => limb.* & rhs[i],
                .@"or" => limb.* | rhs[i],
                .xor => limb.* ^ rhs[i],
            };
        }
        return fromTwosComplement(allocator, lhs, width);
    }

    pub fn shl(self: BigInt, allocator: std.mem.Allocator, shift: usize) !BigInt {
        if (self.isZero()) return .{ .allocator = allocator };
        const limb_shift = shift / limb_bits;
        const bit_shift: u5 = @intCast(shift % limb_bits);
        const extra: usize = if (bit_shift == 0) 0 else 1;
        const limbs = try allocator.alloc(Limb, self.limbs.len + limb_shift + extra);
        @memset(limbs, 0);
        var carry: DoubleLimb = 0;
        for (self.limbs, 0..) |limb, i| {
            const shifted = (@as(DoubleLimb, limb) << bit_shift) | carry;
            limbs[i + limb_shift] = @truncate(shifted);
            carry = shifted >> limb_bits;
        }
        if (extra != 0) limbs[limbs.len - 1] = @intCast(carry);
        return normalize(.{ .negative = self.negative, .limbs = limbs, .allocator = allocator });
    }

    pub fn shr(self: BigInt, allocator: std.mem.Allocator, shift: usize) !BigInt {
        if (self.isZero()) return .{ .allocator = allocator };
        if (!self.negative) return self.shrAbs(allocator, shift);
        var abs_value = try self.absCloneWithAllocator(allocator);
        defer abs_value.deinit();
        var divisor = try pow2(allocator, shift);
        defer divisor.deinit();
        const div_rem = try divRemAbsAlloc(allocator, abs_value, divisor);
        var quotient = div_rem[0];
        var remainder = div_rem[1];
        defer remainder.deinit();
        if (!remainder.isZero()) {
            var one = try BigInt.fromIntAlloc(allocator, 1);
            defer one.deinit();
            const next = try addAlloc(allocator, quotient, one);
            quotient.deinit();
            quotient = next;
        }
        quotient.negative = !quotient.isZero();
        return quotient;
    }

    pub fn toUsize(self: BigInt) ?usize {
        if (self.negative) return null;
        var out: usize = 0;
        var i = self.limbs.len;
        while (i > 0) {
            i -= 1;
            if (out > (std.math.maxInt(usize) >> limb_bits)) return null;
            out = (out << limb_bits) | self.limbs[i];
        }
        return out;
    }

    pub fn bitLengthAbs(self: BigInt) usize {
        if (self.limbs.len == 0) return 0;
        const top = self.limbs[self.limbs.len - 1];
        return (self.limbs.len - 1) * limb_bits + (limb_bits - @clz(top));
    }

    pub fn modPowerOfTwo(self: BigInt, allocator: std.mem.Allocator, bits: usize) !BigInt {
        if (bits == 0 or self.isZero()) return .{ .allocator = allocator };
        var residue = try self.lowBits(allocator, bits);
        if (!self.negative or residue.isZero()) return residue;
        const modulus = try pow2(allocator, bits);
        defer {
            var m = modulus;
            m.deinit();
        }
        const out = try subAbsAlloc(allocator, modulus, residue);
        residue.deinit();
        return out;
    }

    pub fn testBit(self: BigInt, bit: usize) bool {
        const limb_index = bit / limb_bits;
        if (limb_index >= self.limbs.len) return false;
        const offset: u5 = @intCast(bit % limb_bits);
        return ((self.limbs[limb_index] >> offset) & 1) != 0;
    }

    pub fn lowBits(self: BigInt, allocator: std.mem.Allocator, bits: usize) !BigInt {
        if (bits == 0 or self.isZero()) return .{ .allocator = allocator };
        const needed = (bits + limb_bits - 1) / limb_bits;
        const count = @min(needed, self.limbs.len);
        if (count == 0) return .{ .allocator = allocator };
        const limbs = try allocator.alloc(Limb, count);
        @memcpy(limbs, self.limbs[0..count]);
        const remaining_bits = bits % limb_bits;
        if (remaining_bits != 0) {
            const mask: Limb = (@as(Limb, 1) << @intCast(remaining_bits)) - 1;
            limbs[count - 1] &= mask;
        }
        return normalize(.{ .negative = false, .limbs = limbs, .allocator = allocator });
    }

    fn absCloneWithAllocator(self: BigInt, allocator: std.mem.Allocator) !BigInt {
        var out = try self.cloneWithAllocator(allocator);
        out.negative = false;
        return out;
    }

    fn divRemSmallInPlace(self: *BigInt, divisor: Limb) !Limb {
        var remainder: DoubleLimb = 0;
        var index = self.limbs.len;
        while (index > 0) {
            index -= 1;
            const current = (remainder << limb_bits) | self.limbs[index];
            self.limbs[index] = @intCast(current / divisor);
            remainder = current % divisor;
        }
        self.* = normalize(self.*);
        return @intCast(remainder);
    }

    fn shrAbs(self: BigInt, allocator: std.mem.Allocator, shift: usize) !BigInt {
        const limb_shift = shift / limb_bits;
        if (limb_shift >= self.limbs.len) return .{ .allocator = allocator };
        const bit_shift: u5 = @intCast(shift % limb_bits);
        const out_len = self.limbs.len - limb_shift;
        const limbs = try allocator.alloc(Limb, out_len);
        if (bit_shift == 0) {
            @memcpy(limbs, self.limbs[limb_shift..]);
        } else {
            var i: usize = 0;
            while (i < out_len) : (i += 1) {
                const low = self.limbs[i + limb_shift] >> bit_shift;
                const high = if (i + limb_shift + 1 < self.limbs.len) self.limbs[i + limb_shift + 1] << @intCast(32 - @as(u6, bit_shift)) else 0;
                limbs[i] = low | high;
            }
        }
        return normalize(.{ .limbs = limbs, .allocator = allocator });
    }

    fn toTwosComplement(self: BigInt, allocator: std.mem.Allocator, limb_count: usize) ![]Limb {
        const out = try allocator.alloc(Limb, limb_count);
        @memset(out, 0);
        const count = @min(limb_count, self.limbs.len);
        @memcpy(out[0..count], self.limbs[0..count]);
        if (self.negative) {
            for (out) |*limb| limb.* = ~limb.*;
            var carry: DoubleLimb = 1;
            for (out) |*limb| {
                const sum = @as(DoubleLimb, limb.*) + carry;
                limb.* = @truncate(sum);
                carry = sum >> limb_bits;
                if (carry == 0) break;
            }
        }
        return out;
    }
};

pub fn divRemAlloc(allocator: std.mem.Allocator, lhs: BigInt, rhs: BigInt) !struct { BigInt, BigInt } {
    if (rhs.isZero()) return error.DivisionByZero;
    var lhs_abs = try lhs.absCloneWithAllocator(allocator);
    defer lhs_abs.deinit();
    var rhs_abs = try rhs.absCloneWithAllocator(allocator);
    defer rhs_abs.deinit();
    const div_rem = try divRemAbsAlloc(allocator, lhs_abs, rhs_abs);
    var quotient = div_rem[0];
    var remainder = div_rem[1];
    quotient.negative = (lhs.negative != rhs.negative) and !quotient.isZero();
    remainder.negative = lhs.negative and !remainder.isZero();
    return .{ quotient, remainder };
}

pub fn parseBase10(bytes: []const u8) !BigInt {
    return parseBase10Alloc(std.heap.page_allocator, bytes);
}

pub fn parseBase10Alloc(allocator: std.mem.Allocator, bytes: []const u8) !BigInt {
    return parseBaseAlloc(allocator, bytes, 10);
}

pub fn parseAutoAlloc(allocator: std.mem.Allocator, bytes: []const u8) !BigInt {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len >= 2 and trimmed[0] == '0' and (trimmed[1] == 'x' or trimmed[1] == 'X')) {
        return parseBaseAlloc(allocator, trimmed[2..], 16);
    }
    return parseBaseAlloc(allocator, trimmed, 10);
}

pub fn pow2(allocator: std.mem.Allocator, bits: usize) !BigInt {
    const limb_index = bits / limb_bits;
    const offset: u5 = @intCast(bits % limb_bits);
    const limbs = try allocator.alloc(Limb, limb_index + 1);
    @memset(limbs, 0);
    limbs[limb_index] = @as(Limb, 1) << offset;
    return .{ .limbs = limbs, .allocator = allocator };
}

fn divRemAbsAlloc(allocator: std.mem.Allocator, lhs: BigInt, rhs: BigInt) !struct { BigInt, BigInt } {
    if (rhs.isZero()) return error.DivisionByZero;
    if (compareAbs(lhs, rhs) == .lt) {
        return .{ .{ .allocator = allocator }, try lhs.cloneWithAllocator(allocator) };
    }
    var quotient = BigInt{ .allocator = allocator };
    errdefer quotient.deinit();
    var remainder = BigInt{ .allocator = allocator };
    errdefer remainder.deinit();
    var bit = lhs.bitLengthAbs();
    while (bit > 0) {
        bit -= 1;
        const shifted = try remainder.shl(allocator, 1);
        remainder.deinit();
        remainder = shifted;
        if (lhs.testBit(bit)) try addSmallInPlace(&remainder, 1);
        if (compareAbs(remainder, rhs) != .lt) {
            const next_remainder = try subAbsAlloc(allocator, remainder, rhs);
            remainder.deinit();
            remainder = next_remainder;
            try setBit(&quotient, bit);
        }
    }
    return .{ normalize(quotient), normalize(remainder) };
}

pub fn addAlloc(allocator: std.mem.Allocator, lhs: BigInt, rhs: BigInt) !BigInt {
    if (lhs.negative == rhs.negative) {
        var out = try addAbsAlloc(allocator, lhs, rhs);
        out.negative = lhs.negative and !out.isZero();
        return out;
    }
    return switch (compareAbs(lhs, rhs)) {
        .eq => .{ .allocator = allocator },
        .gt => blk: {
            var out = try subAbsAlloc(allocator, lhs, rhs);
            out.negative = lhs.negative;
            break :blk out;
        },
        .lt => blk: {
            var out = try subAbsAlloc(allocator, rhs, lhs);
            out.negative = rhs.negative;
            break :blk out;
        },
    };
}

pub fn subAlloc(allocator: std.mem.Allocator, lhs: BigInt, rhs: BigInt) !BigInt {
    var neg_rhs = rhs;
    neg_rhs.negative = !rhs.negative;
    return addAlloc(allocator, lhs, neg_rhs);
}

pub fn mulAlloc(allocator: std.mem.Allocator, lhs: BigInt, rhs: BigInt) !BigInt {
    if (lhs.isZero() or rhs.isZero()) return .{ .allocator = allocator };
    const limbs = try allocator.alloc(Limb, lhs.limbs.len + rhs.limbs.len);
    @memset(limbs, 0);
    for (lhs.limbs, 0..) |a, i| {
        var carry: DoubleLimb = 0;
        for (rhs.limbs, 0..) |b, j| {
            const index = i + j;
            const current: DoubleLimb = @as(DoubleLimb, a) * b + limbs[index] + carry;
            limbs[index] = @truncate(current);
            carry = current >> limb_bits;
        }
        limbs[i + rhs.limbs.len] = @intCast(carry);
    }
    return normalize(.{ .negative = lhs.negative != rhs.negative, .limbs = limbs, .allocator = allocator });
}

fn parseBaseAlloc(allocator: std.mem.Allocator, bytes: []const u8, base: u32) !BigInt {
    var text = std.mem.trim(u8, bytes, " \t\r\n");
    var negative = false;
    if (text.len != 0 and (text[0] == '-' or text[0] == '+')) {
        negative = text[0] == '-';
        text = text[1..];
    }
    if (text.len == 0) return error.InvalidBigInt;
    var out = BigInt{ .allocator = allocator };
    errdefer out.deinit();
    for (text) |ch| {
        const digit = std.fmt.charToDigit(ch, @intCast(base)) catch return error.InvalidBigInt;
        try mulSmallInPlace(&out, base);
        try addSmallInPlace(&out, digit);
    }
    out.negative = negative and !out.isZero();
    return out;
}

fn addAbsAlloc(allocator: std.mem.Allocator, lhs: BigInt, rhs: BigInt) !BigInt {
    const max_len = @max(lhs.limbs.len, rhs.limbs.len);
    const limbs = try allocator.alloc(Limb, max_len + 1);
    var carry: DoubleLimb = 0;
    var i: usize = 0;
    while (i < max_len) : (i += 1) {
        const a: DoubleLimb = if (i < lhs.limbs.len) lhs.limbs[i] else 0;
        const b: DoubleLimb = if (i < rhs.limbs.len) rhs.limbs[i] else 0;
        const sum = a + b + carry;
        limbs[i] = @truncate(sum);
        carry = sum >> limb_bits;
    }
    limbs[max_len] = @intCast(carry);
    return normalize(.{ .limbs = limbs, .allocator = allocator });
}

fn subAbsAlloc(allocator: std.mem.Allocator, lhs: BigInt, rhs: BigInt) !BigInt {
    const limbs = try allocator.alloc(Limb, lhs.limbs.len);
    var borrow: i64 = 0;
    for (lhs.limbs, 0..) |a, i| {
        const b: i64 = if (i < rhs.limbs.len) rhs.limbs[i] else 0;
        var diff: i64 = @as(i64, a) - b - borrow;
        if (diff < 0) {
            diff += @as(i64, 1) << limb_bits;
            borrow = 1;
        } else {
            borrow = 0;
        }
        limbs[i] = @intCast(diff);
    }
    return normalize(.{ .limbs = limbs, .allocator = allocator });
}

fn mulSmallInPlace(value: *BigInt, multiplier: Limb) !void {
    if (value.isZero() or multiplier == 1) return;
    if (multiplier == 0) {
        value.deinit();
        return;
    }
    var carry: DoubleLimb = 0;
    for (value.limbs) |*limb| {
        const product = @as(DoubleLimb, limb.*) * multiplier + carry;
        limb.* = @truncate(product);
        carry = product >> limb_bits;
    }
    if (carry != 0) {
        const next = try value.allocator.realloc(value.limbs, value.limbs.len + 1);
        next[next.len - 1] = @intCast(carry);
        value.limbs = next;
    }
}

fn addSmallInPlace(value: *BigInt, addend: Limb) !void {
    if (addend == 0) return;
    if (value.isZero()) {
        value.limbs = try value.allocator.alloc(Limb, 1);
        value.limbs[0] = addend;
        return;
    }
    var carry: DoubleLimb = addend;
    for (value.limbs) |*limb| {
        const sum = @as(DoubleLimb, limb.*) + carry;
        limb.* = @truncate(sum);
        carry = sum >> limb_bits;
        if (carry == 0) return;
    }
    const next = try value.allocator.realloc(value.limbs, value.limbs.len + 1);
    next[next.len - 1] = @intCast(carry);
    value.limbs = next;
}

fn setBit(value: *BigInt, bit: usize) !void {
    const limb_index = bit / limb_bits;
    if (value.limbs.len <= limb_index) {
        const old_len = value.limbs.len;
        value.limbs = try value.allocator.realloc(value.limbs, limb_index + 1);
        @memset(value.limbs[old_len..], 0);
    }
    const offset: u5 = @intCast(bit % limb_bits);
    value.limbs[limb_index] |= @as(Limb, 1) << offset;
}

fn fromTwosComplement(allocator: std.mem.Allocator, limbs: []const Limb, width: usize) !BigInt {
    if (limbs.len == 0) return .{ .allocator = allocator };
    const sign_limb = (width - 1) / limb_bits;
    const sign_offset: u5 = @intCast((width - 1) % limb_bits);
    const negative = ((limbs[sign_limb] >> sign_offset) & 1) != 0;
    const out_limbs = try allocator.alloc(Limb, limbs.len);
    @memcpy(out_limbs, limbs);
    const unused = limbs.len * limb_bits - width;
    if (unused != 0) out_limbs[out_limbs.len - 1] &= (@as(Limb, 1) << @intCast(limb_bits - unused)) - 1;
    if (!negative) return normalize(.{ .limbs = out_limbs, .allocator = allocator });
    for (out_limbs) |*limb| limb.* = ~limb.*;
    if (unused != 0) out_limbs[out_limbs.len - 1] &= (@as(Limb, 1) << @intCast(limb_bits - unused)) - 1;
    var carry: DoubleLimb = 1;
    for (out_limbs) |*limb| {
        const sum = @as(DoubleLimb, limb.*) + carry;
        limb.* = @truncate(sum);
        carry = sum >> limb_bits;
        if (carry == 0) break;
    }
    var out = normalize(.{ .negative = true, .limbs = out_limbs, .allocator = allocator });
    out.negative = !out.isZero();
    return out;
}

fn compareAbs(lhs: BigInt, rhs: BigInt) std.math.Order {
    if (lhs.limbs.len != rhs.limbs.len) return std.math.order(lhs.limbs.len, rhs.limbs.len);
    var i = lhs.limbs.len;
    while (i > 0) {
        i -= 1;
        if (lhs.limbs[i] != rhs.limbs[i]) return std.math.order(lhs.limbs[i], rhs.limbs[i]);
    }
    return .eq;
}

fn normalize(value: BigInt) BigInt {
    var len = value.limbs.len;
    while (len > 0 and value.limbs[len - 1] == 0) : (len -= 1) {}
    if (len == 0) {
        if (value.limbs.len != 0) value.allocator.free(value.limbs);
        return .{ .allocator = value.allocator };
    }
    if (len != value.limbs.len) {
        return .{ .negative = value.negative, .limbs = value.allocator.realloc(value.limbs, len) catch unreachable, .allocator = value.allocator };
    }
    return .{ .negative = value.negative, .limbs = value.limbs, .allocator = value.allocator };
}

fn invertOrder(order: std.math.Order) std.math.Order {
    return switch (order) {
        .lt => .gt,
        .eq => .eq,
        .gt => .lt,
    };
}

fn fitsI128(value: BigInt) bool {
    if (value.limbs.len > 4) return false;
    if (value.limbs.len < 4) return true;
    const limit: u128 = if (value.negative) (@as(u128, 1) << 127) else ((@as(u128, 1) << 127) - 1);
    var out: u128 = 0;
    var i = value.limbs.len;
    while (i > 0) {
        i -= 1;
        out = (out << limb_bits) | value.limbs[i];
    }
    return out <= limit;
}

fn toI128(value: BigInt) i128 {
    var out: u128 = 0;
    var i = value.limbs.len;
    while (i > 0) {
        i -= 1;
        out = (out << limb_bits) | value.limbs[i];
    }
    const signed: i128 = @intCast(out);
    return if (value.negative) -signed else signed;
}
