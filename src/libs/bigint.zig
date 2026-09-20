//! Allocator-owned sign-magnitude 64-bit-limb arithmetic, capped at QuickJS's `JS_BIGINT_MAX_SIZE`; operations borrow inputs and return deinitialized owned results.
const std = @import("std");
const builtin = @import("builtin");
const limb_bits = 64;
pub const Limb = u64;
const DoubleLimb = u128;

/// qjs JS_BIGINT_MAX_SIZE: `(1024*1024)/JS_LIMB_BITS` limbs —
/// a 1M-bit cap enforced at every fresh bigint allocation by js_bigint_new
/// (quickjs.c, RangeError "BigInt is too large to allocate").
pub const max_bits: usize = 1024 * 1024;
pub const max_limbs: usize = max_bits / limb_bits;

const TestDigits = if (builtin.is_test) struct {
    threadlocal var count: u64 = 0;
} else struct {};

pub const test_only = if (builtin.is_test) struct {
    pub fn resetDigitIterations() void {
        TestDigits.count = 0;
    }
    pub fn digitIterations() u64 {
        return TestDigits.count;
    }
} else struct {};

/// Mirror of the js_bigint_new length check, applied at
/// the zjs result-allocation choke points.
fn checkLimbCount(len: usize) error{BigIntTooLarge}!void {
    if (len > max_limbs) return error.BigIntTooLarge;
}

pub const BigInt = struct {
    negative: bool = false,
    limbs: []Limb = &.{},
    allocator: std.mem.Allocator,

    pub fn fromInt(allocator: std.mem.Allocator, value: i128) !BigInt {
        return fromIntAlloc(allocator, value);
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

    pub fn add(self: BigInt, other: BigInt) !BigInt {
        return addAlloc(self.allocator, self, other);
    }

    pub fn sub(self: BigInt, other: BigInt) !BigInt {
        return subAlloc(self.allocator, self, other);
    }

    pub fn mul(self: BigInt, other: BigInt) !BigInt {
        return mulAlloc(self.allocator, self, other);
    }

    pub fn div(self: BigInt, other: BigInt) !BigInt {
        if (other.isZero()) return error.DivisionByZero;
        const out = try divRemAllocOutput(self.allocator, self, other, .quotient);
        // Empty unless the single-limb path produced one anyway; deinit on an
        // empty value is a no-op.
        var remainder = out[1];
        remainder.deinit();
        return out[0];
    }

    pub fn rem(self: BigInt, other: BigInt) !BigInt {
        if (other.isZero()) return error.DivisionByZero;
        const out = try divRemAllocOutput(self.allocator, self, other, .remainder);
        var quotient = out[0];
        quotient.deinit();
        return out[1];
    }

    pub fn compare(self: BigInt, other: BigInt) std.math.Order {
        return compareParts(self.negative, self.limbs, other.negative, other.limbs);
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
            var chunks = std.ArrayList(u64).empty;
            defer chunks.deinit(allocator);
            while (!work.isZero()) {
                const remainder = try work.divRemSmallInPlace(10_000_000_000_000_000_000);
                try chunks.append(allocator, remainder);
            }
            var index = chunks.items.len;
            while (index > 0) {
                index -= 1;
                var buf: [24]u8 = undefined;
                if (index == chunks.items.len - 1) {
                    // A u64 needs at most 20 decimal bytes; this buffer cannot
                    // exhaust, so NoSpaceLeft must not escape the formatter.
                    const text = std.fmt.bufPrint(&buf, "{d}", .{chunks.items[index]}) catch unreachable;
                    try out.appendSlice(allocator, text);
                } else {
                    const text = std.fmt.bufPrint(&buf, "{d:0>19}", .{chunks.items[index]}) catch unreachable;
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
        // qjs js_bigint_pow small shortcuts: a^0 = 1,
        // 0^e = 0, (±1)^e = ±1 by exponent parity — all valid for arbitrarily
        // wide exponents and computed before any exponent-width check.
        if (exponent.isZero()) return BigInt.fromIntAlloc(allocator, 1);
        if (self.isZero()) return .{ .allocator = allocator };
        if (self.bitLengthAbs() == 1) {
            const negative = self.negative and exponent.testBit(0);
            return BigInt.fromIntAlloc(allocator, if (negative) -1 else 1);
        }
        const exp = exponent.toUsize() orelse return error.BigIntTooLarge;
        // qjs js_bigint_pow power-of-two base shortcut:
        // |a| = 2^n builds ±2^(e*n) directly, with the exponent capped at
        // JS_BIGINT_MAX_SIZE bits instead of walking the
        // repeated-squaring ladder whose intermediates would hit the mul cap.
        if (self.isPowerOfTwoAbs()) {
            const n = self.bitLengthAbs() - 1;
            const e1 = std.math.mul(usize, exp, n) catch return error.BigIntTooLarge;
            if (e1 > max_bits) return error.BigIntTooLarge;
            var out = try pow2(allocator, e1);
            out.negative = self.negative and (exp & 1) == 1;
            return out;
        }
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
        // qjs js_bigint_logic allocates the operand-width result through
        // js_bigint_new's cap.
        try checkLimbCount(limb_count);
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
        // qjs js_bigint_shl allocates a->len + d limbs through js_bigint_new's
        // cap and extends by the carry limb: the result
        // value may use at most JS_BIGINT_MAX_SIZE bits. Enforce the cap on the
        // result's bit length. The `shift >= max_bits` pre-test keeps the sum
        // from overflowing usize for huge shifts.
        if (shift >= max_bits or self.bitLengthAbs() + shift > max_bits) return error.BigIntTooLarge;
        const limb_shift = shift / limb_bits;
        const bit_shift: u6 = @intCast(shift % limb_bits);
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
        // qjs js_bigint_shr: when d >= a->len the result
        // saturates to -sign (0 for positive, -1 for negative) before any
        // allocation — the guard that keeps huge right-shifts allocation-free.
        if (shift / limb_bits >= self.limbs.len) {
            return BigInt.fromIntAlloc(allocator, if (self.negative) -1 else 0);
        }
        if (!self.negative) return self.shrAbs(allocator, shift);
        var abs_value = try self.absCloneWithAllocator(allocator);
        defer abs_value.deinit();
        var divisor = try pow2(allocator, shift);
        defer divisor.deinit();
        const div_rem = try divRemAbsAlloc(allocator, abs_value, divisor, .both);
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
        if (self.negative or self.limbs.len > 1) return null;
        if (self.limbs.len == 0) return 0;
        return self.limbs[0];
    }

    pub fn toI64(self: BigInt) ?i64 {
        if (self.isZero()) return 0;
        if (self.limbs.len > 1) return null;
        const magnitude = self.limbs[0];
        if (self.negative) {
            if (magnitude > (@as(u64, 1) << 63)) return null;
            if (magnitude == (@as(u64, 1) << 63)) return std.math.minInt(i64);
            return -@as(i64, @intCast(magnitude));
        } else {
            if (magnitude >= (@as(u64, 1) << 63)) return null;
            return @intCast(magnitude);
        }
    }

    pub fn toU64(self: BigInt) ?u64 {
        if (self.isZero()) return 0;
        // Any non-zero negative value is out of range for u64.
        if (self.negative) return null;
        // More than one limb means the magnitude exceeds 2^64-1.
        if (self.limbs.len > 1) return null;
        return self.limbs[0];
    }

    /// Round to nearest, ties to even, ±Infinity when too large. Mirrors qjs
    /// `js_bigint_to_float64` on sign-magnitude limbs: the
    /// top 64 bits carry a sticky bit for everything below, then one
    /// rounding to 53 bits. No decimal detour, so exact for every size.
    pub fn toFloat64(self: BigInt) f64 {
        const n = self.limbs.len;
        if (n == 0) return 0;
        if (n == 1) {
            const v: f64 = @floatFromInt(self.limbs[0]);
            return if (self.negative) -v else v;
        }
        var sticky: Limb = 0;
        for (self.limbs[0 .. n - 2]) |limb| sticky |= limb;
        const a1 = self.limbs[n - 1];
        const a0 = self.limbs[n - 2] | @intFromBool(sticky != 0);
        const shift: u6 = @intCast(@clz(a1));
        var mant: u64 = if (shift == 0) a1 else (a1 << shift) | (a0 >> @intCast(64 - @as(u7, shift)));
        const low: u64 = if (shift == 0) a0 else a0 << shift;
        mant |= @intFromBool(low != 0);
        var e: i32 = @intCast(self.bitLengthAbs() - 1);
        const sign: u64 = @intFromBool(self.negative);
        if (e > 1023) return @bitCast((sign << 63) | (@as(u64, 0x7ff) << 52));
        // 63 bits with sticky, then shr_rndn by 10 -> 53 bits (ties to even).
        mant = (mant >> 1) | (mant & 1);
        const addend: u64 = ((mant >> 10) & 1) + ((1 << 9) - 1);
        mant = (mant + addend) >> 10;
        if (mant >= (@as(u64, 1) << 53)) {
            mant >>= 1;
            e += 1;
        }
        mant &= (@as(u64, 1) << 52) - 1;
        return @bitCast((sign << 63) | (@as(u64, @intCast(e + 1023)) << 52) | mant);
    }

    pub fn bitLengthAbs(self: BigInt) usize {
        if (self.limbs.len == 0) return 0;
        const top = self.limbs[self.limbs.len - 1];
        return (self.limbs.len - 1) * limb_bits + (limb_bits - @clz(top));
    }

    /// True when |self| is a power of two (exactly one bit set); zero is not.
    /// Mirrors the `(v & (v - 1)) == 0` test in js_bigint_pow.
    pub fn isPowerOfTwoAbs(self: BigInt) bool {
        if (self.limbs.len == 0) return false;
        const top = self.limbs[self.limbs.len - 1];
        if ((top & (top - 1)) != 0) return false;
        for (self.limbs[0 .. self.limbs.len - 1]) |limb| {
            if (limb != 0) return false;
        }
        return true;
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
        const offset: u6 = @intCast(bit % limb_bits);
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

    pub fn addPositiveSmallInPlace(self: *BigInt, addend: Limb) !void {
        std.debug.assert(!self.negative);
        try addSmallInPlace(self, addend);
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
        const owned = self.*;
        self.* = .{ .allocator = owned.allocator };
        self.* = try normalize(owned);
        return @intCast(remainder);
    }

    fn shrAbs(self: BigInt, allocator: std.mem.Allocator, shift: usize) !BigInt {
        const limb_shift = shift / limb_bits;
        if (limb_shift >= self.limbs.len) return .{ .allocator = allocator };
        const bit_shift: u6 = @intCast(shift % limb_bits);
        const out_len = self.limbs.len - limb_shift;
        const limbs = try allocator.alloc(Limb, out_len);
        if (bit_shift == 0) {
            @memcpy(limbs, self.limbs[limb_shift..]);
        } else {
            for (0..out_len) |i| {
                const low = self.limbs[i + limb_shift] >> bit_shift;
                const high = if (i + limb_shift + 1 < self.limbs.len) self.limbs[i + limb_shift + 1] << @intCast(64 - @as(u7, bit_shift)) else 0;
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
    return divRemAllocOutput(allocator, lhs, rhs, .both);
}

fn divRemAllocOutput(
    allocator: std.mem.Allocator,
    lhs: BigInt,
    rhs: BigInt,
    want: DivOutput,
) !struct { BigInt, BigInt } {
    if (rhs.isZero()) return error.DivisionByZero;
    // Borrowed magnitudes rather than cloned ones. `divRemAbsAlloc` never
    // writes through either operand: the `lhs < rhs` arm clones, the
    // single-limb arm only reads, and the long division copies both into its
    // own `u` and `v` scratch before touching anything. So the only thing the
    // clones ever produced was a sign-cleared copy, which a borrowed view gives
    // for free.
    //
    // The OOM sweep is what keeps this honest: it asserts the caller's operand
    // limbs are byte-for-byte unchanged after every injected failure, so a
    // future write through one of these would fail there rather than silently
    // corrupt a caller's BigInt.
    const lhs_abs = BigInt{ .negative = false, .limbs = lhs.limbs, .allocator = allocator };
    const rhs_abs = BigInt{ .negative = false, .limbs = rhs.limbs, .allocator = allocator };
    const div_rem = try divRemAbsAlloc(allocator, lhs_abs, rhs_abs, want);
    var quotient = div_rem[0];
    var remainder = div_rem[1];
    quotient.negative = (lhs.negative != rhs.negative) and !quotient.isZero();
    remainder.negative = lhs.negative and !remainder.isZero();
    return .{ quotient, remainder };
}

pub fn parseBase10(allocator: std.mem.Allocator, bytes: []const u8) !BigInt {
    return parseBase10Alloc(allocator, bytes);
}

pub fn parseBase10Alloc(allocator: std.mem.Allocator, bytes: []const u8) !BigInt {
    return parseBaseAlloc(allocator, bytes, 10);
}

pub fn parseAutoAlloc(allocator: std.mem.Allocator, bytes: []const u8) !BigInt {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len >= 2 and trimmed[0] == '0' and (trimmed[1] == 'x' or trimmed[1] == 'X')) {
        return parseBaseAlloc(allocator, trimmed[2..], 16);
    }
    if (trimmed.len >= 2 and trimmed[0] == '0' and (trimmed[1] == 'o' or trimmed[1] == 'O')) {
        return parseBaseAlloc(allocator, trimmed[2..], 8);
    }
    if (trimmed.len >= 2 and trimmed[0] == '0' and (trimmed[1] == 'b' or trimmed[1] == 'B')) {
        return parseBaseAlloc(allocator, trimmed[2..], 2);
    }
    return parseBaseAlloc(allocator, trimmed, 10);
}

pub fn pow2(allocator: std.mem.Allocator, bits: usize) !BigInt {
    const limb_index = bits / limb_bits;
    // Materializing 2^bits allocates limb_index+1 limbs; qjs reaches the same
    // js_bigint_new cap when asUintN/asIntN materialize the modulus
    //. Fixes BigInt.asUintN(2**32, -1n) hanging.
    try checkLimbCount(limb_index + 1);
    const offset: u6 = @intCast(bits % limb_bits);
    const limbs = try allocator.alloc(Limb, limb_index + 1);
    @memset(limbs, 0);
    limbs[limb_index] = @as(Limb, 1) << offset;
    return .{ .limbs = limbs, .allocator = allocator };
}

pub fn compareParts(lhs_negative: bool, lhs_limbs: []const Limb, rhs_negative: bool, rhs_limbs: []const Limb) std.math.Order {
    if (lhs_negative != rhs_negative) return if (lhs_negative) .lt else .gt;
    const abs_order = compareAbsParts(lhs_limbs, rhs_limbs);
    return if (lhs_negative) invertOrder(abs_order) else abs_order;
}

/// Single-limb divisor: one high-to-low pass over the numerator instead of the
/// bit loop. This is qjs's shape for the same case -- `mp_div1norm`
/// walks limbs, not bits -- and it is the same kernel
/// `divRemSmallInPlace` already uses for base conversion, lifted to an
/// allocating caller.
///
/// The caller has already returned for `lhs < rhs`, so the quotient has at
/// least one limb. Its exact length is known up front -- the top quotient digit
/// is `lhs_top / divisor`, which is non-zero exactly when `lhs_top >= divisor`
/// -- so the buffer is allocated at its final size and no normalization pass,
/// and therefore no shrinking realloc, is needed. Cost is two allocations at
/// most: the quotient, and the remainder when it is non-zero.
///
/// `noinline` because inlining it into `divRemAbsAlloc` costs the multi-limb
/// bit loop, which shares that function, about 2% at the JS level -- measured,
/// all sixteen build combinations above 1.0. The single-limb path is already a
/// hundred times cheaper than what it replaces, so a call boundary on it is
/// free by comparison, while the loop it sits next to is untouched.
noinline fn divRemAbsByLimbAlloc(
    allocator: std.mem.Allocator,
    lhs: BigInt,
    divisor: Limb,
) !struct { BigInt, BigInt } {
    std.debug.assert(divisor != 0);
    std.debug.assert(lhs.limbs.len != 0);
    const lhs_top = lhs.limbs[lhs.limbs.len - 1];
    const quotient_len = if (lhs_top >= divisor) lhs.limbs.len else lhs.limbs.len - 1;
    std.debug.assert(quotient_len >= 1);

    const quotient_limbs = try allocator.alloc(Limb, quotient_len);
    errdefer allocator.free(quotient_limbs);
    const remainder_limb = divRemAbsByLimb(lhs.limbs, divisor, quotient_limbs);

    var remainder = BigInt{ .allocator = allocator };
    if (remainder_limb != 0) {
        const remainder_limbs = try allocator.alloc(Limb, 1);
        remainder_limbs[0] = remainder_limb;
        remainder = .{ .limbs = remainder_limbs, .allocator = allocator };
    }
    return .{ BigInt{ .limbs = quotient_limbs, .allocator = allocator }, remainder };
}

/// `quotient.len` must be `lhs.len` or `lhs.len - 1`, matching whether the top
/// quotient digit is non-zero. Returns the remainder.
fn divRemAbsByLimb(lhs: []const Limb, divisor: Limb, quotient: []Limb) Limb {
    std.debug.assert(divisor != 0);
    std.debug.assert(lhs.len != 0);
    std.debug.assert(quotient.len == lhs.len or quotient.len + 1 == lhs.len);
    var remainder: DoubleLimb = 0;
    var index = lhs.len;
    if (quotient.len + 1 == lhs.len) {
        // The top quotient digit is zero by construction, so fold the top limb
        // into the running remainder and leave the loop writing exactly one
        // digit per slot.
        index -= 1;
        std.debug.assert(lhs[index] < divisor);
        remainder = lhs[index];
    }
    while (index > 0) {
        index -= 1;
        const current = (remainder << limb_bits) | lhs[index];
        quotient[index] = @intCast(current / divisor);
        remainder = current % divisor;
    }
    return @intCast(remainder);
}

/// Which halves of a division the caller will use. `div` and `rem` each keep
/// exactly one, and materializing the other means an allocation and a copy that
/// are thrown away immediately.
///
/// The division itself is identical in all three modes -- the quotient digits
/// are still computed, because the algorithm needs them, and the numerator
/// scratch is still consumed in place. Only the final construction differs, so
/// the estimate loop carries no extra branch: the "was a quotient requested"
/// question is folded into the `j < quotient_writes` bound that loop already
/// tested.
pub const DivOutput = enum { quotient, remainder, both };

/// Reciprocal of a normalized limb, mirroring qjs `udiv1norm_init`
///. `divisor` must have its high bit set.
///
/// The value is `floor((2^128 - 1) / divisor) - 2^64`, built as qjs builds it
/// -- numerator `((-divisor - 1) : -1)` -- so no 129-bit intermediate is
/// needed. It is never zero (the smallest case, `divisor = 2^64 - 1`, gives
/// 1), which is what lets `0` serve as the "no reciprocal" sentinel in the
/// division loop, exactly as qjs uses `b1_inv`.
///
/// This is the one wide division that remains: a reciprocal-eligible division
/// pays it once instead of once per quotient limb.
pub fn normalizedReciprocalInit(divisor: Limb) Limb {
    std.debug.assert(divisor >> (limb_bits - 1) == 1);
    const a1: Limb = (0 -% divisor) -% 1;
    const a0: Limb = std.math.maxInt(Limb);
    const reciprocal: Limb = @intCast(((@as(DoubleLimb, a1) << limb_bits) | a0) / divisor);
    std.debug.assert(reciprocal != 0);
    return reciprocal;
}

/// Exact `(high:low) / divisor` and its remainder, from the precomputed
/// reciprocal. Mirrors qjs `udiv1norm`.
///
/// **Not an approximation.** The result is identical to what
/// `((high:low)) / divisor` and `% divisor` produce, which is what lets the
/// second-limb correction, multiply-subtract and add-back below stay exactly
/// as they were -- their counts must not move.
///
/// Every step is wrapping on purpose: the middle term deliberately goes
/// negative and is recovered through the all-ones high half.
pub inline fn divTwoByOneReciprocal(
    high: Limb,
    low: Limb,
    divisor: Limb,
    reciprocal: Limb,
) struct { quotient: Limb, remainder: Limb } {
    std.debug.assert(divisor >> (limb_bits - 1) == 1);
    std.debug.assert(high < divisor);
    // 0 or all-ones, depending on `low`'s top bit.
    const n1m: Limb = @bitCast(@as(i64, @bitCast(low)) >> (limb_bits - 1));
    const n_adj: Limb = low +% (n1m & divisor);
    const estimate: DoubleLimb = @as(DoubleLimb, reciprocal) * (high -% n1m) + n_adj;
    var quotient: Limb = @as(Limb, @truncate(estimate >> limb_bits)) +% high;
    // Recover the exact quotient and remainder: subtract one divisor too many
    // so the sign of the result selects the final correction without a branch.
    var value: DoubleLimb = (@as(DoubleLimb, high) << limb_bits) | low;
    value = value -% @as(DoubleLimb, quotient) *% divisor -% divisor;
    const high_half: Limb = @truncate(value >> limb_bits);
    quotient = quotient +% 1 +% high_half;
    const remainder: Limb = @as(Limb, @truncate(value)) +% (high_half & divisor);
    return .{ .quotient = quotient, .remainder = remainder };
}

/// Quotient-position count at which precomputing the reciprocal pays for
/// itself, matching qjs `UDIV1NORM_THRESHOLD`. Below it the
/// loop keeps the direct `u128 / u64` estimate, so short quotients pay neither
/// the initialization nor the extra code.
const reciprocal_threshold: usize = 3;

/// Multi-limb divisor: normalized schoolbook long division, one quotient limb
/// per step. This is qjs's mechanism (`js_bigint_divrem` normalizes and then
/// runs `mp_divnorm`, quickjs.c): normalize so the divisor's top
/// limb has its high bit set, estimate one quotient digit from the leading
/// numerator limbs, multiply-subtract, and add back on the rare overshoot.
///
/// Not a line-for-line port. qjs's `JSBigInt` is two's complement with sign
/// extension, so its top quotient limb can only be 0 or 1 and it special-cases
/// that; zjs is normalized sign-magnitude, where the top quotient limb is any
/// `u64`. What is mirrored is the normalized limb-division mechanism, not the
/// consequences of a different representation.
///
/// Everything is sized exactly up front, so there is no normalization pass and
/// no shrinking realloc anywhere: at most four allocations, three of which are
/// unconditional.
///
/// `noinline` for the reason P6-04b measured: a wide algorithm sharing a
/// function with another branch pollutes it.
noinline fn divRemAbsNormalizedLong(
    allocator: std.mem.Allocator,
    lhs: BigInt,
    rhs: BigInt,
    want: DivOutput,
) !struct { BigInt, BigInt } {
    const na = lhs.limbs.len;
    const nb = rhs.limbs.len;
    std.debug.assert(nb >= 2);
    std.debug.assert(na >= nb);
    std.debug.assert(rhs.limbs[nb - 1] != 0);
    const m = na - nb;
    const shift: u6 = @intCast(@clz(rhs.limbs[nb - 1]));

    // The quotient's exact length, decided before allocating: the top digit is
    // non-zero exactly when the numerator's top `nb` limbs are at least the
    // divisor. `lhs < rhs` was handled by the caller, so this is at least 1.
    const quotient_len = if (compareAbsParts(lhs.limbs[m..na], rhs.limbs) != .lt) m + 1 else m;
    std.debug.assert(quotient_len >= 1);
    const want_quotient = want != .remainder;
    const want_remainder = want != .quotient;

    // `u` and `v` are pure scratch and are always released. Keeping them as two
    // allocations rather than one shared block is deliberate for this cut: it
    // keeps the allocation topology readable and the OOM sweep able to fail
    // each one separately.
    const u = try allocator.alloc(Limb, na + 1);
    defer allocator.free(u);
    const v = try allocator.alloc(Limb, nb);
    defer allocator.free(v);
    // Empty when the caller only wants the remainder. Digits are still computed
    // into the scratch window; this length only decides whether they are stored.
    const q: []Limb = if (want_quotient) try allocator.alloc(Limb, quotient_len) else &.{};
    errdefer allocator.free(q);
    // After the loop starts at `quotient_len`, `q.len` is only "was a quotient
    // requested?". Remainder-only calls have an empty `q` and must not use it
    // as the digit bound.
    const quotient_writes = q.len;

    if (shift == 0) {
        @memcpy(v, rhs.limbs);
        @memcpy(u[0..na], lhs.limbs);
        u[na] = 0;
    } else {
        const divisor_carry = shiftLeftInto(v, rhs.limbs, shift);
        // `shift` is the divisor top limb's leading-zero count, so shifting it
        // left by that much cannot carry out.
        std.debug.assert(divisor_carry == 0);
        u[na] = shiftLeftInto(u[0..na], lhs.limbs, shift);
    }
    std.debug.assert(v[nb - 1] >> (limb_bits - 1) == 1);

    const v1 = v[nb - 1];
    const v0 = v[nb - 2];
    // One wide division for the whole operation instead of one per quotient
    // limb. Zero means "not eligible", which the reciprocal itself can never
    // be; qjs uses `b1_inv` the same way.
    const reciprocal: Limb = if (m >= reciprocal_threshold) normalizedReciprocalInit(v1) else 0;
    // `quotient_len` is computed from the unshifted operands. Never `q.len`:
    // remainder-only calls leave that slice empty.
    var j = quotient_len;
    while (j > 0) {
        j -= 1;
        if (comptime builtin.is_test) TestDigits.count += 1;
        const window = u[j .. j + nb + 1];
        const top = window[nb];
        const high = window[nb - 1];
        const next = window[nb - 2];
        // Normalization keeps the running window below `v * b`, so its top limb
        // never exceeds the divisor's.
        std.debug.assert(top <= v1);

        var qhat: Limb = undefined;
        var rhat: DoubleLimb = undefined;
        if (top == v1) {
            // The true digit would be the base itself; clamp and let the
            // correction below walk it down. The reciprocal helper requires
            // `high < divisor`, so this case never reaches it.
            qhat = std.math.maxInt(Limb);
            rhat = @as(DoubleLimb, high) + v1;
        } else if (reciprocal != 0) {
            const estimate = divTwoByOneReciprocal(top, high, v1, reciprocal);
            qhat = estimate.quotient;
            rhat = estimate.remainder;
        } else {
            const numerator = (@as(DoubleLimb, top) << limb_bits) | high;
            qhat = @intCast(numerator / v1);
            rhat = numerator % v1;
        }
        // Second-divisor-limb correction. `rhat` reaching the base means the
        // estimate is already exact, and shifting it would overflow the u128.
        while (rhat < (@as(DoubleLimb, 1) << limb_bits) and
            @as(DoubleLimb, qhat) * v0 > ((rhat << limb_bits) | next))
        {
            qhat -= 1;
            rhat += v1;
        }

        if (subMulAt(window, v, qhat)) {
            // With the two-limb correction above this happens with probability
            // about 2/b, and never twice: one add-back restores the window.
            qhat -= 1;
            addBackAt(window, v);
        }

        if (j < quotient_writes) {
            q[j] = qhat;
        } else {
            // Remainder-only: no quotient buffer. The known-zero leading digit
            // is skipped by starting at `quotient_len`, not by this branch.
            std.debug.assert(!want_quotient);
        }
    }
    if (want_quotient) std.debug.assert(q[quotient_len - 1] != 0);
    // The remainder is below the divisor, so it fits in `nb` limbs.
    std.debug.assert(u[nb] == 0);

    // The remainder still carries the normalization shift. Measure its
    // unshifted length first so it can be allocated at exactly that size --
    // building `nb` limbs and normalizing afterwards would mean a shrinking
    // realloc, which is the one thing this function avoids everywhere.
    var remainder = BigInt{ .allocator = allocator };
    if (want_remainder) {
        var remainder_len = nb;
        while (remainder_len > 0 and unshiftedLimbAt(u, remainder_len - 1, shift) == 0) : (remainder_len -= 1) {}
        if (remainder_len != 0) {
            const r = try allocator.alloc(Limb, remainder_len);
            for (r, 0..) |*limb, i| limb.* = unshiftedLimbAt(u, i, shift);
            remainder = .{ .limbs = r, .allocator = allocator };
        }
    }
    return .{ BigInt{ .limbs = q, .allocator = allocator }, remainder };
}

/// `dst = src << shift`, returning the bits carried out of the top limb.
/// `shift` must be 1..63; the zero case is a plain copy at the call sites so
/// that `limb_bits - shift` is never an out-of-range shift.
fn shiftLeftInto(dst: []Limb, src: []const Limb, shift: u6) Limb {
    std.debug.assert(shift != 0);
    std.debug.assert(dst.len == src.len);
    const back: u6 = @intCast(@as(u7, limb_bits) - @as(u7, shift));
    var carry: Limb = 0;
    for (src, 0..) |limb, i| {
        dst[i] = (limb << shift) | carry;
        carry = limb >> back;
    }
    return carry;
}

/// One limb of the remainder with the normalization shift removed. Reads
/// `normalized[index + 1]`, so the slice must extend one limb past `index`.
fn unshiftedLimbAt(normalized: []const Limb, index: usize, shift: u6) Limb {
    if (shift == 0) return normalized[index];
    const back: u6 = @intCast(@as(u7, limb_bits) - @as(u7, shift));
    return (normalized[index] >> shift) | (normalized[index + 1] << back);
}

/// `numerator -= divisor * qhat` across `divisor.len + 1` limbs. Returns true
/// when the result went negative, meaning `qhat` was one too large.
///
/// One fused wrapping `u128` chain per limb, mirroring qjs `mp_sub_mul1`
///. The previous shape split the same computation into a
/// product carry plus two `@subWithOverflow` results, and LLVM materialized
/// each of those overflow bits into a register, spilled it to the stack, then
/// re-narrowed and masked it -- six instructions per limb of pure overhead plus
/// two dead stores, visible in the disassembly as `cset` / `strb [sp]` /
/// `and #0xff` / `and #0x1` pairs.
///
/// Here the negated high half of the wide value *is* the next borrow, so no
/// overflow flag ever has to become a value. Note the borrow is a full limb
/// rather than 0 or 1, exactly as in qjs, which is why the top limb is handled
/// with a wrapping subtract and an unsigned-greater test.
pub fn subMulAt(numerator: []Limb, divisor: []const Limb, qhat: Limb) bool {
    std.debug.assert(numerator.len == divisor.len + 1);
    var borrow: Limb = 0;
    for (divisor, 0..) |limb, i| {
        const wide: DoubleLimb = @as(DoubleLimb, numerator[i]) -%
            @as(DoubleLimb, limb) *% @as(DoubleLimb, qhat) -%
            @as(DoubleLimb, borrow);
        numerator[i] = @truncate(wide);
        borrow = 0 -% @as(Limb, @truncate(wide >> limb_bits));
    }
    const top = numerator[divisor.len];
    const updated = top -% borrow;
    numerator[divisor.len] = updated;
    return updated > top;
}

/// `numerator += divisor` across `divisor.len + 1` limbs. The final carry is
/// dropped on purpose: it cancels the borrow left by the failed subtraction.
fn addBackAt(numerator: []Limb, divisor: []const Limb) void {
    std.debug.assert(numerator.len == divisor.len + 1);
    var carry: Limb = 0;
    for (divisor, 0..) |limb, i| {
        const first = @addWithOverflow(numerator[i], limb);
        const second = @addWithOverflow(first[0], carry);
        numerator[i] = second[0];
        carry = @as(Limb, first[1]) + @as(Limb, second[1]);
    }
    numerator[divisor.len] +%= carry;
}

fn divRemAbsAlloc(
    allocator: std.mem.Allocator,
    lhs: BigInt,
    rhs: BigInt,
    want: DivOutput,
) !struct { BigInt, BigInt } {
    if (rhs.isZero()) return error.DivisionByZero;
    if (compareAbs(lhs, rhs) == .lt) {
        // Quotient zero, remainder the dividend. Cloning the dividend is the
        // only allocation here, so skip it when the caller wants the quotient.
        if (want == .quotient) return .{ .{ .allocator = allocator }, .{ .allocator = allocator } };
        return .{ .{ .allocator = allocator }, try lhs.cloneWithAllocator(allocator) };
    }
    // The single-limb path is left alone on purpose: it is already down to two
    // allocations and is the fastest shape in the matrix, so threading the
    // output selection through it would risk a well-behaved path to save at
    // most one small allocation.
    if (rhs.limbs.len == 1) return divRemAbsByLimbAlloc(allocator, lhs, rhs.limbs[0]);
    return divRemAbsNormalizedLong(allocator, lhs, rhs, want);
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
    // qjs js_bigint_mul: js_bigint_new(ctx, a->len + b->len),
    // capped by js_bigint_new. This also bounds js_bigint_pow's repeated
    // squaring the same way qjs does.
    try checkLimbCount(lhs.limbs.len + rhs.limbs.len);
    const limbs = try allocator.alloc(Limb, lhs.limbs.len + rhs.limbs.len);
    errdefer allocator.free(limbs);
    // qjs mp_mul_basecase writes its first pass with
    // mp_mul1 and only accumulates from the second, so js_bigint_new hands back
    // uninitialized memory and no pre-zeroing pass exists at all. Mirror that:
    // the first row overwrites, later rows accumulate.
    //
    // Every result limb is written before it is read. Row 0 overwrites
    // `limbs[0..inner.len]` and then its carry slot at `inner.len`, so the
    // initialized prefix is `limbs[0..inner.len + 1]`. Row `i` reads
    // `limbs[i..i + inner.len]`, whose highest index is `i + inner.len - 1`,
    // and rows `0..i-1` have already initialized through exactly that index; it
    // then overwrites one new slot at `i + inner.len`. After the final row the
    // prefix covers the whole buffer (`outer.len + inner.len` limbs), and the
    // top limb is written even when its carry is zero, which `normalize` then
    // strips.
    //
    // Row count follows the OUTER operand, and only row 0 is a pure write, so
    // the number of accumulating rows is `outer.len - 1`. That makes the loop
    // asymmetric in operand order: measured on the ordered matrix, the same
    // multiply costs 21.8ns as 1x8 and 26.9ns as 8x1. A fixed flip to qjs's
    // outer-over-rhs nesting does not fix this, it only moves the win -- it was
    // measured at -19.0% on 8x1 and +23.6% on 1x8, a clean trade.
    //
    // Take the shorter operand as the outer one instead. Multiplication is
    // commutative, the result length `lhs.len + rhs.len` is order-independent,
    // and the sign below is computed from both operands, so the swap is
    // invisible to the caller.
    const outer = if (lhs.limbs.len <= rhs.limbs.len) lhs.limbs else rhs.limbs;
    const inner = if (lhs.limbs.len <= rhs.limbs.len) rhs.limbs else lhs.limbs;
    for (outer, 0..) |a, i| {
        var carry: DoubleLimb = 0;
        if (i == 0) {
            for (inner, 0..) |b, j| {
                const current: DoubleLimb = @as(DoubleLimb, a) * b + carry;
                limbs[j] = @truncate(current);
                carry = current >> limb_bits;
            }
        } else {
            for (inner, 0..) |b, j| {
                const index = i + j;
                const current: DoubleLimb = @as(DoubleLimb, a) * b + limbs[index] + carry;
                limbs[index] = @truncate(current);
                carry = current >> limb_bits;
            }
        }
        limbs[i + inner.len] = @intCast(carry);
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
    // qjs js_atobigint: skip leading zeros, bound the
    // digit count, then bound the estimated bit width (radix 10 uses
    // (n_digits*27+7)/8 >= n_digits*log2(10); power-of-two radixes use
    // ceil(log2(radix)) bits per digit) before any allocation.
    var digits = text;
    while (digits.len != 0 and digits[0] == '0') digits = digits[1..];
    if (digits.len > max_bits) return error.BigIntTooLarge;
    const log2_radix: usize = 32 - @clz(base - 1);
    const estimated_bits = if (base == 10) (digits.len * 27 + 7) / 8 else digits.len * log2_radix;
    try checkLimbCount((estimated_bits + limb_bits - 1) / limb_bits);
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
    for (0..max_len) |i| {
        const a: DoubleLimb = if (i < lhs.limbs.len) lhs.limbs[i] else 0;
        const b: DoubleLimb = if (i < rhs.limbs.len) rhs.limbs[i] else 0;
        const sum = a + b + carry;
        limbs[i] = @truncate(sum);
        carry = sum >> limb_bits;
    }
    limbs[max_len] = @intCast(carry);
    // qjs js_bigint_add hits the js_bigint_new cap on its max(a,b)+1 result
    // allocation; with 64-bit sign-magnitude limbs the
    // speculative +1 would throw a band earlier than qjs's 32-bit limbs, so
    // the cap is enforced on the normalized result instead.
    var out = try normalize(.{ .limbs = limbs, .allocator = allocator });
    if (out.limbs.len > max_limbs) {
        out.deinit();
        return error.BigIntTooLarge;
    }
    return out;
}

fn subAbsAlloc(allocator: std.mem.Allocator, lhs: BigInt, rhs: BigInt) !BigInt {
    const limbs = try allocator.alloc(Limb, lhs.limbs.len);
    var borrow: i128 = 0;
    for (lhs.limbs, 0..) |a, i| {
        const b: i128 = if (i < rhs.limbs.len) @intCast(rhs.limbs[i]) else 0;
        var diff: i128 = @as(i128, a) - b - borrow;
        if (diff < 0) {
            diff += @as(i128, 1) << limb_bits;
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

fn fromTwosComplement(allocator: std.mem.Allocator, limbs: []const Limb, width: usize) !BigInt {
    if (limbs.len == 0) return .{ .allocator = allocator };
    const sign_limb = (width - 1) / limb_bits;
    const sign_offset: u6 = @intCast((width - 1) % limb_bits);
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
    var out = try normalize(.{ .negative = true, .limbs = out_limbs, .allocator = allocator });
    out.negative = !out.isZero();
    return out;
}

fn compareAbs(lhs: BigInt, rhs: BigInt) std.math.Order {
    return compareAbsParts(lhs.limbs, rhs.limbs);
}

fn compareAbsParts(lhs_limbs: []const Limb, rhs_limbs: []const Limb) std.math.Order {
    if (lhs_limbs.len != rhs_limbs.len) return std.math.order(lhs_limbs.len, rhs_limbs.len);
    var i = lhs_limbs.len;
    while (i > 0) {
        i -= 1;
        if (lhs_limbs[i] != rhs_limbs[i]) return std.math.order(lhs_limbs[i], rhs_limbs[i]);
    }
    return .eq;
}

/// Consuming: takes ownership of `value.limbs` and frees them on its own error
/// path, so a caller must transfer ownership before calling and must not keep
/// an `errdefer` or a live copy aliasing the same slice. Callers below use the
/// `const owned = x; x = .{ .allocator = ... };` handoff for exactly that
/// reason.
fn normalize(value: BigInt) !BigInt {
    var owned = value;
    errdefer if (owned.limbs.len != 0) owned.allocator.free(owned.limbs);

    var len = owned.limbs.len;
    while (len > 0 and owned.limbs[len - 1] == 0) : (len -= 1) {}
    if (len == 0) {
        if (owned.limbs.len != 0) owned.allocator.free(owned.limbs);
        owned.limbs = &.{};
        return .{ .allocator = owned.allocator };
    }
    if (len != owned.limbs.len) {
        owned.limbs = try owned.allocator.realloc(owned.limbs, len);
    }
    return .{ .negative = owned.negative, .limbs = owned.limbs, .allocator = owned.allocator };
}

fn invertOrder(order: std.math.Order) std.math.Order {
    return switch (order) {
        .lt => .gt,
        .eq => .eq,
        .gt => .lt,
    };
}

test "bigint functionality" {
    var forty = try parseBase10(std.testing.allocator, "40");
    defer forty.deinit();
    var two = try BigInt.fromInt(std.testing.allocator, 2);
    defer two.deinit();
    var big = try forty.add(two);
    defer big.deinit();
    const big_text = try big.formatBase10Alloc(std.testing.allocator);
    defer std.testing.allocator.free(big_text);
    try std.testing.expectEqualStrings("42", big_text);
    var zero = try BigInt.fromInt(std.testing.allocator, 0);
    defer zero.deinit();
    try std.testing.expectError(error.DivisionByZero, big.div(zero));
    var huge = try parseBase10(std.testing.allocator, "12345678901234567890123456789012345678901234567890");
    defer huge.deinit();
    const huge_text = try huge.formatBase10Alloc(std.testing.allocator);
    defer std.testing.allocator.free(huge_text);
    try std.testing.expectEqualStrings("12345678901234567890123456789012345678901234567890", huge_text);
    var divisor = try BigInt.fromInt(std.testing.allocator, 97);
    defer divisor.deinit();
    var quotient = try huge.div(divisor);
    defer quotient.deinit();
    var remainder = try huge.rem(divisor);
    defer remainder.deinit();
    const quotient_text = try quotient.formatBase10Alloc(std.testing.allocator);
    defer std.testing.allocator.free(quotient_text);
    const remainder_text = try remainder.formatBase10Alloc(std.testing.allocator);
    defer std.testing.allocator.free(remainder_text);
    try std.testing.expectEqualStrings("127275040218913071032200585453735522462899325442", quotient_text);
    try std.testing.expectEqualStrings("16", remainder_text);
    var neg_seven = try BigInt.fromInt(std.testing.allocator, -7);
    defer neg_seven.deinit();
    var three = try BigInt.fromInt(std.testing.allocator, 3);
    defer three.deinit();
    var neg_q = try neg_seven.div(three);
    defer neg_q.deinit();
    var neg_r = try neg_seven.rem(three);
    defer neg_r.deinit();
    const neg_q_text = try neg_q.formatBase10Alloc(std.testing.allocator);
    defer std.testing.allocator.free(neg_q_text);
    const neg_r_text = try neg_r.formatBase10Alloc(std.testing.allocator);
    defer std.testing.allocator.free(neg_r_text);
    try std.testing.expectEqualStrings("-2", neg_q_text);
    try std.testing.expectEqualStrings("-1", neg_r_text);
}

test "bigint toU64 and toI64 range edges" {
    const t = std.testing;
    // Zero.
    var zero = try BigInt.fromInt(t.allocator, 0);
    defer zero.deinit();
    try t.expectEqual(@as(?u64, 0), zero.toU64());
    try t.expectEqual(@as(?i64, 0), zero.toI64());

    // Mid positive fits both.
    var mid = try BigInt.fromInt(t.allocator, 1234567890123);
    defer mid.deinit();
    try t.expectEqual(@as(?u64, 1234567890123), mid.toU64());
    try t.expectEqual(@as(?i64, 1234567890123), mid.toI64());

    // i64::MAX fits both.
    var i64_max = try BigInt.fromInt(t.allocator, std.math.maxInt(i64));
    defer i64_max.deinit();
    try t.expectEqual(@as(?u64, @as(u64, std.math.maxInt(i64))), i64_max.toU64());
    try t.expectEqual(@as(?i64, std.math.maxInt(i64)), i64_max.toI64());

    // i64::MIN: fits i64 (the edge), out of range for u64.
    var i64_min = try BigInt.fromInt(t.allocator, std.math.minInt(i64));
    defer i64_min.deinit();
    try t.expectEqual(@as(?i64, std.math.minInt(i64)), i64_min.toI64());
    try t.expectEqual(@as(?u64, null), i64_min.toU64());

    // u64::MAX: single non-negative limb with the high bit set. Fits u64,
    // out of range for i64 — the band asUint64 must accept and asInt64 reject.
    var u64_max = try BigInt.fromInt(t.allocator, @as(i128, std.math.maxInt(u64)));
    defer u64_max.deinit();
    try t.expectEqual(@as(?u64, std.math.maxInt(u64)), u64_max.toU64());
    try t.expectEqual(@as(?i64, null), u64_max.toI64());

    // 2^63 exactly: out of range for i64 (positive), in range for u64.
    var two_63 = try BigInt.fromInt(t.allocator, @as(i128, 1) << 63);
    defer two_63.deinit();
    try t.expectEqual(@as(?u64, @as(u64, 1) << 63), two_63.toU64());
    try t.expectEqual(@as(?i64, null), two_63.toI64());

    // Negative non-zero: out of range for u64.
    var neg = try BigInt.fromInt(t.allocator, -5);
    defer neg.deinit();
    try t.expectEqual(@as(?u64, null), neg.toU64());
    try t.expectEqual(@as(?i64, -5), neg.toI64());

    // Beyond u64 (2^64): out of range for both.
    var beyond = try BigInt.fromInt(t.allocator, @as(i128, 1) << 64);
    defer beyond.deinit();
    try t.expectEqual(@as(?u64, null), beyond.toU64());
    try t.expectEqual(@as(?i64, null), beyond.toI64());
}

const bigint = @This();

/// Basecase multiplication writes every result limb before reading it, so it
/// must not depend on the allocator handing back zeroed memory. Run it against
/// an allocator that poisons fresh allocations with a non-zero pattern: any
/// limb the kernel forgets to write, or reads before writing, changes the
/// product. Zeroed memory would hide all three failures, which is why the
/// production path deliberately no longer pre-zeroes and this test does not
/// re-add the guarantee for it.
const PoisonAllocator = struct {
    backing: std.mem.Allocator,

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawAlloc(len, alignment, ra) orelse return null;
        @memset(ptr[0..len], 0xa5);
        return ptr;
    }
    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(buf, alignment, new_len, ra);
    }
    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(buf, alignment, new_len, ra);
    }
    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(buf, alignment, ra);
    }
    fn allocator(self: *PoisonAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
};

/// Deliberately zero-initialized schoolbook multiply, kept in the test rather
/// than in the kernel: it is the thing the production path stopped doing, so it
/// has to exist somewhere independent to compare against. Returns unnormalized
/// limbs with trailing zeros stripped, matching what `mulAlloc` returns.
fn referenceMul(alloc: std.mem.Allocator, lhs: []const Limb, rhs: []const Limb) ![]Limb {
    const Double = u128;
    const out = try alloc.alloc(Limb, lhs.len + rhs.len);
    errdefer alloc.free(out);
    @memset(out, 0);
    for (lhs, 0..) |a, i| {
        var carry: Double = 0;
        for (rhs, 0..) |b, j| {
            const current: Double = @as(Double, a) * b + out[i + j] + carry;
            out[i + j] = @truncate(current);
            carry = current >> 64;
        }
        out[i + rhs.len] = @intCast(carry);
    }
    var len = out.len;
    while (len > 0 and out[len - 1] == 0) : (len -= 1) {}
    if (len == out.len) return out;
    return try alloc.realloc(out, len);
}

/// Fail-index injector for the BigInt division allocation contract.
///
/// Two independent modes. `fail_alloc_index` refuses one numbered allocation,
/// which sweeps the division's allocation points. `fail_shrink` refuses every
/// shrinking realloc -- both the remap attempt and the alloc-and-copy fallback
/// the standard allocator falls back to -- which is the only way to reach
/// `normalize`'s error path, and that path is where ownership has to have been
/// transferred exactly once.
const DivFailAllocator = struct {
    backing: std.mem.Allocator,
    fail_alloc_index: ?usize = null,
    fail_shrink: bool = false,
    alloc_attempts: usize = 0,
    induced: bool = false,
    refuse_next_alloc: bool = false,
    live: isize = 0,

    fn allocator(self: *DivFailAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *DivFailAllocator = @ptrCast(@alignCast(ctx));
        if (self.refuse_next_alloc) {
            self.refuse_next_alloc = false;
            self.induced = true;
            return null;
        }
        const index = self.alloc_attempts;
        self.alloc_attempts += 1;
        if (self.fail_alloc_index) |target| {
            if (index == target) {
                self.induced = true;
                return null;
            }
        }
        const result = self.backing.rawAlloc(len, alignment, ra) orelse return null;
        self.live += 1;
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *DivFailAllocator = @ptrCast(@alignCast(ctx));
        if (self.fail_shrink and new_len < memory.len) return false;
        return self.backing.rawResize(memory, alignment, new_len, ra);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *DivFailAllocator = @ptrCast(@alignCast(ctx));
        if (self.fail_shrink and new_len < memory.len) {
            // Make the alloc-and-copy fallback fail too, so the realloc really
            // fails instead of quietly succeeding down the slow path.
            self.refuse_next_alloc = true;
            return null;
        }
        return self.backing.rawRemap(memory, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *DivFailAllocator = @ptrCast(@alignCast(ctx));
        self.live -= 1;
        self.backing.rawFree(memory, alignment, ra);
    }
};

fn expectDivisionUnderInjection(
    inject: *DivFailAllocator,
    lhs_limbs: []const bigint.Limb,
    lhs_negative: bool,
    rhs_limbs: []const bigint.Limb,
    rhs_negative: bool,
    expected_quotient: bigint.BigInt,
    expected_remainder: bigint.BigInt,
) !void {
    const alloc = inject.allocator();
    const lhs = bigint.BigInt{ .negative = lhs_negative, .limbs = @constCast(lhs_limbs), .allocator = alloc };
    const rhs = bigint.BigInt{ .negative = rhs_negative, .limbs = @constCast(rhs_limbs), .allocator = alloc };

    if (bigint.divRemAlloc(alloc, lhs, rhs)) |pair| {
        var quotient = pair[0];
        defer quotient.deinit();
        var remainder = pair[1];
        defer remainder.deinit();
        // Succeeding under injection is fine; the result must still be right.
        try std.testing.expectEqual(std.math.Order.eq, quotient.compare(expected_quotient));
        try std.testing.expectEqual(std.math.Order.eq, remainder.compare(expected_remainder));
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }
    // Whatever happened, nothing may be left outstanding and the inputs must be
    // untouched -- the caller still owns them.
    try std.testing.expectEqual(@as(isize, 0), inject.live);
    try std.testing.expectEqualSlices(bigint.Limb, lhs_limbs, lhs.limbs);
    try std.testing.expectEqualSlices(bigint.Limb, rhs_limbs, rhs.limbs);
}

/// Checks `q * b + r == a`, `abs(r) < abs(b)`, the remainder's sign, and that
/// neither result carries a leading zero limb.
fn expectDivisionIdentity(
    lhs_limbs: []const bigint.Limb,
    lhs_negative: bool,
    rhs_limbs: []const bigint.Limb,
    rhs_negative: bool,
) !void {
    const alloc = std.testing.allocator;
    const lhs = bigint.BigInt{ .negative = lhs_negative, .limbs = @constCast(lhs_limbs), .allocator = alloc };
    const rhs = bigint.BigInt{ .negative = rhs_negative, .limbs = @constCast(rhs_limbs), .allocator = alloc };

    var quotient = try lhs.div(rhs);
    defer quotient.deinit();
    var remainder = try lhs.rem(rhs);
    defer remainder.deinit();

    var product = try bigint.mulAlloc(alloc, quotient, rhs);
    defer product.deinit();
    var recovered = try bigint.addAlloc(alloc, product, remainder);
    defer recovered.deinit();
    try std.testing.expectEqual(std.math.Order.eq, recovered.compare(lhs));

    const abs_remainder = bigint.BigInt{ .limbs = remainder.limbs, .allocator = alloc };
    const abs_rhs = bigint.BigInt{ .limbs = @constCast(rhs_limbs), .allocator = alloc };
    try std.testing.expectEqual(std.math.Order.lt, abs_remainder.compare(abs_rhs));
    try std.testing.expect(remainder.isZero() or remainder.negative == lhs_negative);
    try std.testing.expect(quotient.isZero() or
        quotient.negative == (lhs_negative != rhs_negative));
    if (quotient.limbs.len != 0)
        try std.testing.expect(quotient.limbs[quotient.limbs.len - 1] != 0);
    if (remainder.limbs.len != 0)
        try std.testing.expect(remainder.limbs[remainder.limbs.len - 1] != 0);
}

test "basecase multiplication never reads an uninitialized result limb" {
    var poison = PoisonAllocator{ .backing = std.testing.allocator };
    const alloc = poison.allocator();

    const shapes = [_][2]usize{
        .{ 1, 1 }, .{ 1, 2 }, .{ 2, 1 }, .{ 2, 2 }, .{ 2, 4 },
        .{ 4, 2 }, .{ 3, 5 }, .{ 4, 4 }, .{ 1, 8 }, .{ 8, 1 },
        .{ 8, 8 },
    };
    // Both the all-ones pattern (maximal carry propagation, top carry non-zero)
    // and a single high bit (top carry zero) are exercised per shape.
    for (shapes) |shape| {
        inline for (.{ true, false }) |saturated| {
            const lhs_limbs = try alloc.alloc(bigint.Limb, shape[0]);
            defer alloc.free(lhs_limbs);
            const rhs_limbs = try alloc.alloc(bigint.Limb, shape[1]);
            defer alloc.free(rhs_limbs);
            for (lhs_limbs) |*l| l.* = if (saturated) std.math.maxInt(bigint.Limb) else 0;
            for (rhs_limbs) |*l| l.* = if (saturated) std.math.maxInt(bigint.Limb) else 0;
            if (!saturated) {
                lhs_limbs[shape[0] - 1] = @as(bigint.Limb, 1) << 63;
                rhs_limbs[shape[1] - 1] = 1;
            }
            const lhs = bigint.BigInt{ .limbs = lhs_limbs, .allocator = alloc };
            const rhs = bigint.BigInt{ .limbs = rhs_limbs, .allocator = alloc };

            var product = try bigint.mulAlloc(alloc, lhs, rhs);
            defer product.deinit();
            const expected = try referenceMul(alloc, lhs_limbs, rhs_limbs);
            defer alloc.free(expected);
            try std.testing.expectEqualSlices(bigint.Limb, expected, product.limbs);
        }
    }
}

test "single-limb division is exact and allocation-bounded" {
    const allocator = std.testing.allocator;

    // P6-04b: the single-limb divisor path allocates the quotient at its exact
    // final length instead of walking the numerator bit by bit, so the sizing
    // rule -- the quotient has one fewer limb exactly when the numerator's top
    // limb is below the divisor -- has to hold for every shape.
    const divisors = [_]bigint.Limb{
        1,                               2,                         3,                            7,                                255, 65537,
        (@as(bigint.Limb, 1) << 63) - 1, @as(bigint.Limb, 1) << 63, std.math.maxInt(bigint.Limb), std.math.maxInt(bigint.Limb) - 1,
    };
    var prng = std.Random.DefaultPrng.init(0x604B);
    const random = prng.random();

    for (1..17) |numerator_len| {
        for (divisors) |divisor| {
            for (0..6) |pattern| {
                const limbs = try allocator.alloc(bigint.Limb, numerator_len);
                defer allocator.free(limbs);
                for (limbs, 0..) |*l, i| l.* = switch (pattern) {
                    0 => std.math.maxInt(bigint.Limb),
                    1 => if (i == numerator_len - 1) @as(bigint.Limb, 1) else 0,
                    2 => if (i % 2 == 0) 0xAAAA_AAAA_AAAA_AAAA else 0x5555_5555_5555_5555,
                    3 => if (i == numerator_len - 1) divisor else 0,
                    4 => if (i == numerator_len - 1) divisor -| 1 else std.math.maxInt(bigint.Limb),
                    else => random.int(bigint.Limb),
                };
                if (limbs[numerator_len - 1] == 0) limbs[numerator_len - 1] = 1;

                const divisor_limbs = try allocator.alloc(bigint.Limb, 1);
                defer allocator.free(divisor_limbs);
                divisor_limbs[0] = divisor;

                inline for (.{ false, true }) |numerator_negative| {
                    inline for (.{ false, true }) |divisor_negative| {
                        const numerator = bigint.BigInt{
                            .negative = numerator_negative,
                            .limbs = limbs,
                            .allocator = allocator,
                        };
                        const denominator = bigint.BigInt{
                            .negative = divisor_negative,
                            .limbs = divisor_limbs,
                            .allocator = allocator,
                        };
                        var quotient = try numerator.div(denominator);
                        defer quotient.deinit();
                        var remainder = try numerator.rem(denominator);
                        defer remainder.deinit();

                        // q * b + r == a, and the remainder takes the
                        // dividend's sign with a magnitude below the divisor's.
                        var product = try bigint.mulAlloc(allocator, quotient, denominator);
                        defer product.deinit();
                        var recovered = try bigint.addAlloc(allocator, product, remainder);
                        defer recovered.deinit();
                        try std.testing.expectEqual(std.math.Order.eq, recovered.compare(numerator));
                        try std.testing.expect(remainder.isZero() or remainder.negative == numerator_negative);
                        const abs_remainder = bigint.BigInt{ .limbs = remainder.limbs, .allocator = allocator };
                        const abs_divisor = bigint.BigInt{ .limbs = divisor_limbs, .allocator = allocator };
                        try std.testing.expectEqual(std.math.Order.lt, abs_remainder.compare(abs_divisor));
                        // Every result stays normalized: no leading zero limb.
                        if (quotient.limbs.len != 0)
                            try std.testing.expect(quotient.limbs[quotient.limbs.len - 1] != 0);
                        if (remainder.limbs.len != 0)
                            try std.testing.expect(remainder.limbs[remainder.limbs.len - 1] != 0);
                    }
                }
            }
        }
    }
}

test "multi-limb division survives a failure at every allocation point" {
    // 6 limbs by 3, chosen so the numerator is strictly larger and the division
    // is a real multi-limb one rather than the early return or the single-limb
    // path. The multi-limb path allocates a normalized numerator scratch, a
    // normalized divisor scratch, the quotient and, when non-zero, the
    // remainder; the sweep fails each in turn.
    const lhs_limbs = [_]bigint.Limb{
        0x0123_4567_89AB_CDEF, 0xFEDC_BA98_7654_3210, 0xAAAA_AAAA_AAAA_AAAB,
        0x0000_0000_0000_0007, 0xFFFF_FFFF_FFFF_FFFF, 0x8000_0000_0000_0001,
    };
    const rhs_limbs = [_]bigint.Limb{
        0xDEAD_BEEF_CAFE_BABE, 0x0000_0000_0000_0001, 0x4000_0000_0000_0000,
    };

    // Reference results, computed with a plain allocator.
    const reference_lhs = bigint.BigInt{ .limbs = @constCast(lhs_limbs[0..]), .allocator = std.testing.allocator };
    const reference_rhs = bigint.BigInt{ .limbs = @constCast(rhs_limbs[0..]), .allocator = std.testing.allocator };
    var expected_quotient = try reference_lhs.div(reference_rhs);
    defer expected_quotient.deinit();
    var expected_remainder = try reference_lhs.rem(reference_rhs);
    defer expected_remainder.deinit();

    // How many allocations a clean division makes, so the sweep covers all of
    // them and stops once the index is past the end.
    var counter = DivFailAllocator{ .backing = std.testing.allocator };
    {
        const pair = try bigint.divRemAlloc(counter.allocator(), reference_lhs, reference_rhs);
        var q = pair[0];
        q.deinit();
        var r = pair[1];
        r.deinit();
    }
    try std.testing.expectEqual(@as(isize, 0), counter.live);
    try std.testing.expect(counter.alloc_attempts > 3);

    for (0..counter.alloc_attempts) |fail_index| {
        inline for (.{ false, true }) |lhs_negative| {
            inline for (.{ false, true }) |rhs_negative| {
                var inject = DivFailAllocator{ .backing = std.testing.allocator, .fail_alloc_index = fail_index };
                try expectDivisionUnderInjection(
                    &inject,
                    &lhs_limbs,
                    lhs_negative,
                    &rhs_limbs,
                    rhs_negative,
                    expected_quotient,
                    expected_remainder,
                );
            }
        }
    }

    // The shrinking-realloc path specifically: `normalize` frees what it is
    // given when this fails, so a caller that kept an aliasing errdefer would
    // free twice here. std.testing.allocator turns that into a failure.
    var shrink = DivFailAllocator{ .backing = std.testing.allocator, .fail_shrink = true };
    try expectDivisionUnderInjection(
        &shrink,
        &lhs_limbs,
        false,
        &rhs_limbs,
        false,
        expected_quotient,
        expected_remainder,
    );

    // And the runtime keeps working afterwards.
    var again = try reference_lhs.div(reference_rhs);
    defer again.deinit();
    try std.testing.expectEqual(std.math.Order.eq, again.compare(expected_quotient));
}

test "normalized long division handles every quotient-estimate correction" {
    // Frozen vectors. Each was found by instrumenting the estimate loop with
    // event counters, searching for inputs that trip it, and then freezing the
    // input; the counters are not in the shipped code. Random differentials
    // will not reach the last two on their own -- an add-back happens for
    // roughly two in 2^64 random digits, and the clamp needs the running
    // window's top limb to equal the divisor's -- so they have to be pinned.
    const Vector = struct { a: []const Limb, b: []const Limb, event: []const u8 };
    const vectors = [_]Vector{
        // qhat overshoots by one; the two-limb correction walks it down once.
        .{ .event = "one correction", .a = &.{
            18446744071130631000, 18446744070582471246, 18446744073293857249,
            18446744072649403833, 18446744073376993945,
        }, .b = &.{ 18292791604476754667, 1966659979700317977 } },
        .{ .event = "one correction", .a = &.{
            12082522041592792640, 15748636029607535374, 15181851967732580813,
        }, .b = &.{ 7374570672812560177, 9114781625496212255 } },
        // Two and three consecutive corrections in a single digit.
        .{ .event = "two corrections", .a = &.{ 6760, 15609, 46248, 25141, 4658, 56091 }, .b = &.{
            13111450017376601947, 15741773727843677049,
        } },
        .{ .event = "three corrections", .a = &.{
            2922364011524419948, 15199577267042544661, 8869955383828204815,
            6086884528135068723, 17470225258706509392, 5989704710919718645,
        }, .b = &.{ 7737569840773542854, 10212381028821443357 } },
        // Multiply-subtract underflow followed by an add-back. Reachable only
        // with three or more divisor limbs, where the two-limb correction can
        // still leave qhat one too large.
        .{ .event = "add-back", .a = &.{
            13465684955894917774, 8558819152265836238, 6820847440565444368,
            18276390249259064961, 7278821098085739655, 6374605922739522640,
            7032115460613293848,
        }, .b = &.{
            12263064420428875817, 15085240911834220974, 12499075520100409598,
            1862140883670459562,  9223372036854776206,
        } },
        .{ .event = "add-back", .a = &.{
            10902867065322963979, 8154025842177743286, 892225491405445580,
            6852634366156024265,  6260784258398759999,
        }, .b = &.{
            15187370619739732000, 16811601731636216368, 9924715777611263663,
            9223372036854775836,
        } },
        .{ .event = "add-back", .a = &.{
            7261502557649319965,  9419382559357885929, 17598245110249695978,
            15137239819430460520, 3808798334777379262, 8297164559207748804,
        }, .b = &.{
            1751729836318627440, 17751592689439995320, 7534591674257631123,
            9223372036863636856,
        } },
        // Window top limb equal to the divisor's, where the estimate would be
        // the base itself and has to be clamped to maxInt before correction.
        // Constructed: the numerator's top two limbs are below the divisor but
        // share its top limb, so the first digit is zero and leaves them in
        // place for the next step to see.
        .{ .event = "clamped estimate", .a = &.{ 0xDEAD_BEEF, 0x1234, 0x8000_0000_0000_0001 }, .b = &.{
            0xFFFF_FFFF_FFFF_FFFF, 0x8000_0000_0000_0001,
        } },
    };

    for (vectors) |vector| {
        inline for (.{ false, true }) |lhs_negative| {
            inline for (.{ false, true }) |rhs_negative| {
                expectDivisionIdentity(vector.a, lhs_negative, vector.b, rhs_negative) catch |err| {
                    std.debug.print("vector failed: {s}\n", .{vector.event});
                    return err;
                };
            }
        }
    }
}

test "normalized long division covers every normalization shift" {
    var prng = std.Random.DefaultPrng.init(0x604C3);
    const random = prng.random();

    // The divisor's top limb decides the shift, so place its most significant
    // bit at 63 - shift for all 64 values rather than sampling a few.
    for (0..64) |shift| {
        const top_bit: u6 = @intCast(63 - shift);
        for (2..6) |nb| {
            for (nb..nb + 4) |na| {
                var b = try std.testing.allocator.alloc(bigint.Limb, nb);
                defer std.testing.allocator.free(b);
                var a = try std.testing.allocator.alloc(bigint.Limb, na);
                defer std.testing.allocator.free(a);
                for (b) |*l| l.* = random.int(bigint.Limb);
                b[nb - 1] = (random.int(bigint.Limb) >> @as(u6, @intCast(63 - @as(u7, top_bit)))) |
                    (@as(bigint.Limb, 1) << top_bit);
                for (a) |*l| l.* = random.int(bigint.Limb);
                a[na - 1] |= 1;
                // Guarantee a real division rather than the early return.
                if (na == nb) a[na - 1] = std.math.maxInt(bigint.Limb);
                try expectDivisionIdentity(a, false, b, false);
                try expectDivisionIdentity(a, true, b, false);
            }
        }
    }
}

test "normalized long division covers the operand relations" {
    const alloc = std.testing.allocator;
    const divisor = [_]bigint.Limb{
        0xDEAD_BEEF_CAFE_BABE, 0x0000_0000_0000_0001, 0x4000_0000_0000_0000,
    };
    const v = bigint.BigInt{ .limbs = @constCast(divisor[0..]), .allocator = alloc };

    // lhs < rhs, lhs == rhs, quotient exactly 1, exact division, and the
    // largest possible non-zero remainder.
    try expectDivisionIdentity(&.{ 1, 2 }, false, &divisor, false);
    try expectDivisionIdentity(&divisor, false, &divisor, false);
    var plus_one = try v.cloneWithAllocator(alloc);
    defer plus_one.deinit();
    try plus_one.addPositiveSmallInPlace(1);
    try expectDivisionIdentity(plus_one.limbs, false, &divisor, false);

    const multiplier = [_]bigint.Limb{ 0x1234_5678_9ABC_DEF0, 0xFFFF_FFFF_FFFF_FFFF };
    const mv = bigint.BigInt{ .limbs = @constCast(multiplier[0..]), .allocator = alloc };
    var exact = try bigint.mulAlloc(alloc, v, mv);
    defer exact.deinit();
    try expectDivisionIdentity(exact.limbs, false, &divisor, false);

    // exact product minus one: the largest remainder for that quotient.
    const one_limbs = [_]bigint.Limb{1};
    const one = bigint.BigInt{ .limbs = @constCast(one_limbs[0..]), .allocator = alloc };
    var largest = try bigint.subAlloc(alloc, exact, one);
    defer largest.deinit();
    try expectDivisionIdentity(largest.limbs, false, &divisor, false);
    try expectDivisionIdentity(largest.limbs, true, &divisor, true);
}

test "normalized long division skips a known-zero leading digit" {
    const alloc = std.testing.allocator;
    const Case = struct {
        lhs: []const Limb,
        rhs: []const Limb,
        digits: usize,
        lhs_negative: bool = false,
        rhs_negative: bool = false,
    };

    // Fixed digit counts from Python `ceil(quotient.bit_length()/64)` on the
    // same integer values; not recomputed from the production H-vs-D test.
    const cases = [_]Case{
        .{ .lhs = &.{ 10, 40, 50 }, .rhs = &.{ 50, 100 }, .digits = 1 },
        .{ .lhs = &.{ 5, 10, 1 }, .rhs = &.{ 1, 1 << 63 }, .digits = 1 },
        .{ .lhs = &.{ 10, 40, 200 }, .rhs = &.{ 50, 100 }, .digits = 2 },
        .{ .lhs = &.{ 10, 40, 500 }, .rhs = &.{ 50, 100 }, .digits = 2 },
        .{ .lhs = &.{ 10, 40, 50 }, .rhs = &.{ 50, 100 }, .digits = 1, .lhs_negative = true },
    };

    for (cases) |case| {
        const lhs = bigint.BigInt{
            .negative = case.lhs_negative,
            .limbs = @constCast(case.lhs),
            .allocator = alloc,
        };
        const rhs = bigint.BigInt{
            .negative = case.rhs_negative,
            .limbs = @constCast(case.rhs),
            .allocator = alloc,
        };

        bigint.test_only.resetDigitIterations();
        var quotient = try lhs.div(rhs);
        defer quotient.deinit();
        try std.testing.expectEqual(case.digits, bigint.test_only.digitIterations());

        bigint.test_only.resetDigitIterations();
        var remainder = try lhs.rem(rhs);
        defer remainder.deinit();
        try std.testing.expectEqual(case.digits, bigint.test_only.digitIterations());

        bigint.test_only.resetDigitIterations();
        const pair = try bigint.divRemAlloc(alloc, lhs, rhs);
        var both_q = pair[0];
        defer both_q.deinit();
        var both_r = pair[1];
        defer both_r.deinit();
        try std.testing.expectEqual(case.digits, bigint.test_only.digitIterations());
        try std.testing.expectEqual(std.math.Order.eq, both_q.compare(quotient));
        try std.testing.expectEqual(std.math.Order.eq, both_r.compare(remainder));

        try expectDivisionIdentity(case.lhs, case.lhs_negative, case.rhs, case.rhs_negative);
    }
}

test "reciprocal two-by-one division is exactly the wide division" {
    const Double = u128;

    // Not an approximation: for every input the reciprocal helper must return
    // the same quotient and remainder the direct u128 / u64 would. If it ever
    // differed, the second-limb correction and add-back counts downstream would
    // move, which would be an implementation defect rather than a performance
    // difference.
    const Case = struct {
        fn check(high: Limb, low: Limb, divisor: Limb) !void {
            const reciprocal = bigint.normalizedReciprocalInit(divisor);
            const got = bigint.divTwoByOneReciprocal(high, low, divisor, reciprocal);
            const numerator = (@as(Double, high) << 64) | low;
            try std.testing.expectEqual(@as(Limb, @intCast(numerator / divisor)), got.quotient);
            try std.testing.expectEqual(@as(Limb, @intCast(numerator % divisor)), got.remainder);
        }
    };

    const divisors = [_]Limb{
        @as(Limb, 1) << 63,
        (@as(Limb, 1) << 63) + 1,
        (@as(Limb, 1) << 63) | 0x5555_5555_5555_5555,
        std.math.maxInt(Limb) - 1,
        std.math.maxInt(Limb),
        0xFFFF_FFFF_0000_0000,
        0x8000_0000_0000_0001,
        0xC000_0000_0000_0000,
    };
    const lows = [_]Limb{
        0,                  1,                        std.math.maxInt(Limb), std.math.maxInt(Limb) - 1,
        @as(Limb, 1) << 63, (@as(Limb, 1) << 63) - 1, 0xAAAA_AAAA_AAAA_AAAA, 0x5555_5555_5555_5555,
    };
    for (divisors) |divisor| {
        // high must stay below divisor, which the division loop guarantees by
        // routing `top == v1` to the clamped branch.
        const highs = [_]Limb{ 0, 1, divisor - 1, divisor - 2, divisor >> 1, (divisor >> 1) + 1 };
        for (highs) |high| {
            for (lows) |low| try Case.check(high, low, divisor);
        }
    }

    var prng = std.Random.DefaultPrng.init(0x604D1);
    const random = prng.random();
    for (0..1_000_000) |_| {
        const divisor = random.int(Limb) | (@as(Limb, 1) << 63);
        const high = random.uintLessThan(Limb, divisor);
        const low = random.int(Limb);
        try Case.check(high, low, divisor);
    }
    // Extra weight on the boundary divisors, where the reciprocal is at its
    // smallest and its largest.
    for (0..200_000) |_| {
        const divisor = if (random.boolean()) @as(Limb, 1) << 63 else std.math.maxInt(Limb);
        const high = random.uintLessThan(Limb, divisor);
        const low = random.int(Limb);
        try Case.check(high, low, divisor);
    }
}

test "toFloat64 rounds to nearest even and overflows to infinity" {
    const allocator = std.testing.allocator;
    // 2^1024 - 2^970: exactly halfway between MAX_VALUE and 2^1024, ties to even -> Infinity.
    var half = [_]Limb{0} ** 16;
    half[15] = 0xFFFFFFFFFFFFFC00;
    try std.testing.expect(std.math.isPositiveInf((BigInt{ .limbs = &half, .allocator = allocator }).toFloat64()));
    try std.testing.expect(std.math.isNegativeInf((BigInt{ .limbs = &half, .negative = true, .allocator = allocator }).toFloat64()));
    // One below the halfway point rounds down to MAX_VALUE.
    var below = [_]Limb{0xFFFFFFFFFFFFFFFF} ** 16;
    below[15] = 0xFFFFFFFFFFFFFBFF;
    try std.testing.expectEqual(std.math.floatMax(f64), (BigInt{ .limbs = &below, .allocator = allocator }).toFloat64());
    // (2^53 + 1) * 2^100 + 1: above the halfway point, rounds up.
    var above = [_]Limb{ 1, (9007199254740993 << 36) & 0xFFFFFFFFFFFFFFFF, 9007199254740993 >> 28 };
    const expected = @as(f64, 9007199254740994) * std.math.pow(f64, 2, 100);
    try std.testing.expectEqual(expected, (BigInt{ .limbs = &above, .allocator = allocator }).toFloat64());
    // Single limb is a plain int -> double conversion.
    var one = [_]Limb{9007199254740993};
    try std.testing.expectEqual(@as(f64, 9007199254740992), (BigInt{ .limbs = &one, .allocator = allocator }).toFloat64());
    try std.testing.expectEqual(@as(f64, 0), (BigInt{ .allocator = allocator }).toFloat64());
}
