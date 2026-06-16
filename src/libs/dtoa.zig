// Tiny float64 printing and parsing library
//
// Copyright (c) 2024 Fabrice Bellard
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
// THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

const std = @import("std");

// ============================================================
// Public types and constants (match dtoa.h)
// ============================================================

pub const JSDTOATempMem = extern struct {
    mem: [37]u64,
};

pub const JSATODTempMem = extern struct {
    mem: [27]u64,
};

pub const JS_DTOA_MAX_DIGITS: i32 = 101;

pub const JS_DTOA_FORMAT_FREE: i32 = 0 << 0;
pub const JS_DTOA_FORMAT_FIXED: i32 = 1 << 0;
pub const JS_DTOA_FORMAT_FRAC: i32 = 2 << 0;
pub const JS_DTOA_FORMAT_MASK: i32 = 3 << 0;

pub const JS_DTOA_EXP_AUTO: i32 = 0 << 2;
pub const JS_DTOA_EXP_ENABLED: i32 = 1 << 2;
pub const JS_DTOA_EXP_DISABLED: i32 = 2 << 2;
pub const JS_DTOA_EXP_MASK: i32 = 3 << 2;

pub const JS_DTOA_MINUS_ZERO: i32 = 1 << 4;

pub const JS_ATOD_INT_ONLY: i32 = 1 << 0;
pub const JS_ATOD_ACCEPT_BIN_OCT: i32 = 1 << 1;
pub const JS_ATOD_ACCEPT_LEGACY_OCTAL: i32 = 1 << 2;
pub const JS_ATOD_ACCEPT_UNDERSCORES: i32 = 1 << 3;

// ============================================================
// Internal constants
// ============================================================

const LIMB_LOG2_BITS = 5;
const LIMB_BITS = 32;
const limb_t = u32;
const slimb_t = i32;
const dlimb_t = u64;
const LIMB_DIGITS = 9;
const JS_RADIX_MAX = 36;
const DBIGNUM_LEN_MAX = 52;
const MANT_LEN_MAX = 18;

const MUL_LOG2_RADIX_BASE_LOG2 = 24;

const JS_RNDN = 0;
const JS_RNDNA = 1;
const JS_RNDZ = 2;

// ============================================================
// Mpb type (bignum with flexible-array equivalent)
// ============================================================

fn Mpb(comptime cap: usize) type {
    return extern struct {
        len: i32,
        tab: [cap]limb_t,

        const Self = @This();

        fn tabSlice(self: *Self) []limb_t {
            const l: usize = @intCast(@max(self.len, 1));
            return self.tab[0..l];
        }

        fn tabConstSlice(self: *const Self) []const limb_t {
            const l: usize = @intCast(@max(self.len, 1));
            return self.tab[0..l];
        }
    };
}

const MpbMax = Mpb(DBIGNUM_LEN_MAX);

// ============================================================
// Lookup tables
// ============================================================

const pow5_table = [17]u32{
    0x00000005, 0x00000019, 0x0000007d, 0x00000271,
    0x00000c35, 0x00003d09, 0x0001312d, 0x0005f5e1,
    0x001dcd65, 0x009502f9, 0x02e90edd, 0x0e8d4a51,
    0x48c27395, 0x6bcc41e9, 0x1afd498d, 0x86f26fc1,
    0xa2bc2ec5,
};

const pow5h_table = [4]u8{
    0x01, 0x07, 0x23, 0xb1,
};

const pow5_inv_table = [13]u32{
    0x99999999, 0x47ae147a, 0x0624dd2f, 0xa36e2eb1,
    0x4f8b588e, 0x0c6f7a0b, 0xad7f29ab, 0x5798ee23,
    0x12e0be82, 0xb7cdfd9d, 0x5fd7fe17, 0x19799812,
    0xc25c2684,
};

const mul_log2_radix_table = [JS_RADIX_MAX - 1]u32{
    0x000000, 0xa1849d, 0x000000, 0x6e40d2,
    0x6308c9, 0x5b3065, 0x000000, 0x50c24e,
    0x4d104d, 0x4a0027, 0x4768ce, 0x452e54,
    0x433d00, 0x418677, 0x000000, 0x3ea16b,
    0x3d645a, 0x3c43c2, 0x3b3b9a, 0x3a4899,
    0x39680b, 0x3897b3, 0x37d5af, 0x372069,
    0x367686, 0x35d6df, 0x354072, 0x34b261,
    0x342bea, 0x33ac62, 0x000000, 0x32bfd9,
    0x3251dd, 0x31e8d6, 0x318465,
};

const digits_per_limb_table = [JS_RADIX_MAX - 1]u8{
    32, 20, 16, 13, 12, 11, 10, 10, 9, 9, 8, 8, 8, 8, 8, 7, 7, 7,
    7,  7,  7,  7,  6,  6,  6,  6,  6, 6, 6, 6, 6, 6, 6, 6, 6,
};

const radix_base_table = [JS_RADIX_MAX - 1]u32{
    0x00000000, 0xcfd41b91, 0x00000000, 0x48c27395,
    0x81bf1000, 0x75db9c97, 0x40000000, 0xcfd41b91,
    0x3b9aca00, 0x8c8b6d2b, 0x19a10000, 0x309f1021,
    0x57f6c100, 0x98c29b81, 0x00000000, 0x18754571,
    0x247dbc80, 0x3547667b, 0x4c4b4000, 0x6b5a6e1d,
    0x94ace180, 0xcaf18367, 0x0b640000, 0x0e8d4a51,
    0x1269ae40, 0x17179149, 0x1cb91000, 0x23744899,
    0x2b73a840, 0x34e63b41, 0x40000000, 0x4cfa3cc1,
    0x5c13d840, 0x6d91b519, 0x81bf1000,
};

const dtoa_max_digits_table = [JS_RADIX_MAX - 1]u8{
    54, 35, 28, 24, 22, 20, 19, 18, 17, 17, 16, 16, 15, 15, 15, 14, 14, 14,
    14, 14, 13, 13, 13, 13, 13, 13, 13, 12, 12, 12, 12, 12, 12, 12, 12,
};

const atod_max_digits_table = [JS_RADIX_MAX - 1]u8{
    64, 80, 32, 55, 49, 45, 21, 40, 38, 37, 35, 34,
    33, 32, 16, 31, 30, 30, 29, 29, 28, 28, 27, 27,
    27, 26, 26, 26, 26, 25, 12, 25, 25, 24, 24,
};

const max_exponent = [JS_RADIX_MAX - 1]i16{
    1024, 647, 512, 442, 397, 365, 342, 324,
    309,  297, 286, 277, 269, 263, 256, 251,
    246,  242, 237, 234, 230, 227, 224, 221,
    218,  216, 214, 211, 209, 207, 205, 203,
    202,  200, 199,
};

const min_exponent = [JS_RADIX_MAX - 1]i16{
    -1075, -679, -538, -463, -416, -383, -359, -340,
    -324,  -311, -300, -291, -283, -276, -269, -263,
    -258,  -254, -249, -245, -242, -238, -235, -232,
    -229,  -227, -224, -222, -220, -217, -215, -214,
    -212,  -210, -208,
};

// ============================================================
// Utility helpers
// ============================================================

fn minInt(a: anytype, b: anytype) @TypeOf(a, b) {
    return if (a < b) a else b;
}

fn maxInt(a: anytype, b: anytype) @TypeOf(a, b) {
    return if (a > b) a else b;
}

inline fn clz32(a: u32) i32 {
    return @intCast(@clz(a));
}

inline fn clz64(a: u64) i32 {
    return @intCast(@clz(a));
}

inline fn ctz32(a: u32) i32 {
    return @intCast(@ctz(a));
}

inline fn float64AsUint64(d: f64) u64 {
    return @bitCast(d);
}

inline fn uint64AsFloat64(u: u64) f64 {
    return @bitCast(u);
}

fn strlen(p: [*]const u8) usize {
    var len: usize = 0;
    while (p[len] != 0) : (len += 1) {}
    return len;
}

// ============================================================
// Bump-pointer allocator (matches dtoa_malloc/dtoa_free)
// ============================================================

fn dtoaMalloc(comptime T: type, mptr: *[*]u64) *T {
    const bump = (@sizeOf(T) + 7) / 8;
    const ptr: *T = @ptrCast(@alignCast(mptr.*));
    mptr.* += bump;
    return ptr;
}

// ============================================================
// Bignum operations (internal, operate on slices or Mpb)
// ============================================================

fn mpAddUi(tab: []limb_t, b: limb_t) limb_t {
    var k = b;
    for (tab) |*entry| {
        if (k == 0) break;
        const a = entry.* +% k;
        k = @intFromBool(a < k);
        entry.* = a;
    }
    return k;
}

fn mpMul1(tabr: []limb_t, taba: []const limb_t, b: limb_t, carry: limb_t) limb_t {
    var l = carry;
    for (taba, 0..) |a, i| {
        const t: dlimb_t = @as(dlimb_t, a) * @as(dlimb_t, b) + l;
        tabr[i] = @truncate(t);
        l = @truncate(t >> LIMB_BITS);
    }
    return l;
}

fn udiv1normInit(d: limb_t) limb_t {
    const a1: limb_t = ~d;
    const a0: limb_t = 0xFFFFFFFF;
    const numerator: dlimb_t = (@as(dlimb_t, a1) << LIMB_BITS) | a0;
    return @truncate(numerator / d);
}

fn udiv1norm(pr: *limb_t, a1: limb_t, a0: limb_t, d: limb_t, d_inv: limb_t) limb_t {
    const n1m: limb_t = @bitCast(@as(slimb_t, @bitCast(a0)) >> (LIMB_BITS - 1));
    const n_adj = a0 +% (n1m & d);
    var a: dlimb_t = @as(dlimb_t, d_inv) * @as(dlimb_t, a1 -% n1m) + n_adj;
    var q: limb_t = @as(limb_t, @truncate(a >> LIMB_BITS)) +% a1;
    a = (@as(dlimb_t, a1) << LIMB_BITS) | a0;
    a = a -% @as(dlimb_t, q) * @as(dlimb_t, d) -% d;
    const ah: limb_t = @truncate(a >> LIMB_BITS);
    q +%= 1 +% ah;
    const r = @as(limb_t, @truncate(a)) +% (ah & d);
    pr.* = r;
    return q;
}

fn mpDiv1(tabr: []limb_t, taba: []const limb_t, b: limb_t, r_in: limb_t) limb_t {
    var r = r_in;
    const n = taba.len;
    var i: isize = @as(isize, @intCast(n)) - 1;
    while (i >= 0) : (i -= 1) {
        const a1: dlimb_t = (@as(dlimb_t, r) << LIMB_BITS) | taba[@as(usize, @intCast(i))];
        tabr[@as(usize, @intCast(i))] = @as(limb_t, @truncate(a1 / b));
        r = @as(limb_t, @truncate(a1 % b));
    }
    return r;
}

fn mpShr(tab_r: []limb_t, tab: []const limb_t, shift: u5, high: limb_t) limb_t {
    var l = high;
    const n = tab.len;
    var i: isize = @as(isize, @intCast(n)) - 1;
    while (i >= 0) : (i -= 1) {
        const a = tab[@as(usize, @intCast(i))];
        tab_r[@as(usize, @intCast(i))] = (a >> shift) | (l << @as(u5, @truncate(@as(u32, LIMB_BITS) - shift)));
        l = a;
    }
    return l & ((@as(limb_t, 1) << shift) - 1);
}

fn mpShl(tab_r: []limb_t, tab: []const limb_t, shift: u5, low: limb_t) limb_t {
    var l = low;
    for (tab, 0..) |a, i| {
        tab_r[i] = (a << shift) | l;
        l = a >> @as(u5, @truncate(@as(u32, LIMB_BITS) - shift));
    }
    return l;
}

fn mpDiv1normInternal(tabr: []limb_t, taba: []const limb_t, b: limb_t, r_in: limb_t, b_inv: limb_t, shift: i32) limb_t {
    var r = r_in;
    const n = taba.len;
    if (shift != 0) {
        const sh: u5 = @intCast(shift);
        const high = mpShl(tabr, taba, sh, 0);
        r = (r << sh) | high;
    }
    var i: isize = @as(isize, @intCast(n)) - 1;
    while (i >= 0) : (i -= 1) {
        tabr[@as(usize, @intCast(i))] = udiv1norm(&r, r, taba[@as(usize, @intCast(i))], b, b_inv);
    }
    if (shift != 0) {
        r >>= @intCast(shift);
    }
    return r;
}

fn mpbRenorm(r: *MpbMax) void {
    while (r.len > 1 and r.tab[@intCast(r.len - 1)] == 0) {
        r.len -= 1;
    }
}

fn mpbGetBit(r: *const MpbMax, k: i32) i32 {
    const k_unsigned: u32 = @bitCast(k);
    const l: usize = @intCast(k_unsigned / LIMB_BITS);
    const bit: u5 = @truncate(@as(u32, @bitCast(k)) & (LIMB_BITS - 1));
    if (l >= @as(usize, @intCast(r.len))) {
        return 0;
    }
    return @intCast((r.tab[l] >> bit) & 1);
}

fn mpbShrRound(r: *MpbMax, shift: i32, rnd_mode: i32) void {
    if (shift == 0) return;

    if (shift < 0) {
        const pos_shift: u32 = @bitCast(-shift);
        const l: usize = @intCast(pos_shift / LIMB_BITS);
        const sh: u5 = @truncate(pos_shift & (LIMB_BITS - 1));

        if (sh != 0) {
            const rlen: usize = @intCast(r.len);
            r.tab[rlen] = mpShl(r.tab[0..rlen], r.tab[0..rlen], sh, 0);
            r.len += 1;
            mpbRenorm(r);
        }
        if (l > 0) {
            const rlen: usize = @intCast(r.len);
            var i: isize = @as(isize, @intCast(rlen)) - 1;
            while (i >= 0) : (i -= 1) {
                r.tab[@as(usize, @intCast(i)) + l] = r.tab[@as(usize, @intCast(i))];
            }
            for (0..l) |j| {
                r.tab[j] = 0;
            }
            r.len += @intCast(l);
        }
        return;
    }

    // shift > 0: right shift with rounding
    var add_one: i32 = 0;
    switch (rnd_mode) {
        JS_RNDZ => {
            add_one = 0;
        },
        JS_RNDN, JS_RNDNA => {
            const bit1 = mpbGetBit(r, shift - 1);
            if (bit1 != 0) {
                const bit2: i32 = if (rnd_mode == JS_RNDNA) @as(i32, 1) else blk: {
                    var b2: i32 = 0;
                    if (shift >= 2) {
                        const k: i32 = shift - 1;
                        const l2: usize = @intCast(@as(u32, @bitCast(k)) / LIMB_BITS);
                        const kbit: u5 = @truncate(@as(u32, @bitCast(k)) & (LIMB_BITS - 1));
                        const rlen2: usize = @intCast(r.len);
                        const lim: usize = if (l2 < rlen2) l2 else rlen2;
                        for (0..lim) |j2| {
                            b2 |= @as(i32, @bitCast(r.tab[j2]));
                        }
                        if (l2 < rlen2) {
                            b2 |= @as(i32, @bitCast(r.tab[l2] & ((@as(limb_t, 1) << kbit) - 1)));
                        }
                    }
                    break :blk b2;
                };
                if (bit2 != 0) {
                    add_one = 1;
                } else {
                    add_one = mpbGetBit(r, shift);
                }
            }
        },
        else => {
            add_one = 0;
        },
    }

    const l: usize = @intCast(@as(u32, @bitCast(shift)) / LIMB_BITS);
    const sh: u5 = @truncate(@as(u32, @bitCast(shift)) & (LIMB_BITS - 1));

    if (l >= @as(usize, @intCast(r.len))) {
        r.len = 1;
        r.tab[0] = @intCast(add_one);
    } else {
        if (l > 0) {
            r.len -= @intCast(l);
            for (0..@intCast(r.len)) |j2| {
                r.tab[j2] = r.tab[j2 + l];
            }
        }
        if (sh != 0) {
            const rlen: usize = @intCast(r.len);
            _ = mpShr(r.tab[0..rlen], r.tab[0..rlen], sh, 0);
            mpbRenorm(r);
        }
        if (add_one != 0) {
            const rlen: usize = @intCast(r.len);
            const a = mpAddUi(r.tab[0..rlen], 1);
            if (a != 0) {
                r.tab[@intCast(r.len)] = a;
                r.len += 1;
            }
        }
    }
}

fn mpbCmp(a: *const MpbMax, b: *const MpbMax) i32 {
    if (a.len < b.len) return -1;
    if (a.len > b.len) return 1;
    var i: isize = @as(isize, @intCast(a.len)) - 1;
    while (i >= 0) : (i -= 1) {
        const ai = a.tab[@as(usize, @intCast(i))];
        const bi = b.tab[@as(usize, @intCast(i))];
        if (ai != bi) {
            return if (ai < bi) @as(i32, -1) else @as(i32, 1);
        }
    }
    return 0;
}

fn mpbSetU64(r: *MpbMax, m: u64) void {
    r.tab[0] = @truncate(m);
    r.tab[1] = @truncate(m >> LIMB_BITS);
    if (r.tab[1] == 0) {
        r.len = 1;
    } else {
        r.len = 2;
    }
}

fn mpbGetU64(r: *const MpbMax) u64 {
    if (r.len == 1) {
        return r.tab[0];
    }
    return @as(u64, r.tab[0]) | (@as(u64, r.tab[1]) << LIMB_BITS);
}

fn mpbFloorLog2(a: *const MpbMax) i32 {
    const v = a.tab[@intCast(a.len - 1)];
    if (v == 0) return -1;
    return a.len * @as(i32, LIMB_BITS) - 1 - clz32(v);
}

fn mpbMul1Base(r: *MpbMax, radix_base: limb_t, a: limb_t) void {
    if (r.tab[0] == 0 and r.len == 1) {
        r.tab[0] = a;
    } else {
        if (radix_base == 0) {
            var i: isize = @as(isize, @intCast(r.len));
            while (i >= 0) : (i -= 1) {
                r.tab[@as(usize, @intCast(i)) + 1] = r.tab[@as(usize, @intCast(i))];
            }
            r.tab[0] = a;
        } else {
            const rlen: usize = @intCast(r.len);
            r.tab[rlen] = mpMul1(r.tab[0..rlen], r.tab[0..rlen], radix_base, a);
        }
        r.len += 1;
        mpbRenorm(r);
    }
}

fn mpbDump(str: []const u8, a: *const MpbMax) void {
    std.debug.print("{s}= 0x", .{str});
    var i: isize = @as(isize, @intCast(a.len)) - 1;
    while (i >= 0) : (i -= 1) {
        std.debug.print("{x:0>8}", .{a.tab[@as(usize, @intCast(i))]});
        if (i != 0) {
            std.debug.print("_", .{});
        }
    }
    std.debug.print("\n", .{});
}

// ============================================================
// mul_log2_radix
// ============================================================

fn mulLog2Radix(a: i32, radix: i32) i32 {
    if ((@as(u32, @bitCast(radix)) & (@as(u32, @bitCast(radix)) - 1)) == 0) {
        const radix_bits: i32 = 31 - clz32(@bitCast(radix));
        var a2 = a;
        if (a2 < 0) a2 -= radix_bits - 1;
        return @divTrunc(a2, radix_bits);
    }
    const mult = mul_log2_radix_table[@intCast(radix - 2)];
    return @intCast(@divFloor(@as(i64, a) * @as(i64, mult), @as(i64, 1 << MUL_LOG2_RADIX_BASE_LOG2)));
}

// ============================================================
// pow_ui / pow_ui_inv
// ============================================================

fn powUi(radix: u32, n: u32) u64 {
    if (n == 0) return 1;
    if (n == 1) return radix;

    if ((radix == 5 or radix == 10) and n <= 17) {
        var r: u64 = pow5_table[n - 1];
        if (n >= 14) {
            r |= @as(u64, pow5h_table[n - 14]) << 32;
        }
        if (radix == 10) {
            r <<= @as(u6, @truncate(n));
        }
        return r;
    }

    var r: u64 = radix;
    const n_bits: i32 = 32 - clz32(n);
    var i: i32 = n_bits - 2;
    while (i >= 0) : (i -= 1) {
        r *= r;
        if ((n >> @intCast(i)) & 1 != 0) {
            r *= radix;
        }
    }
    return r;
}

fn powUiInv(pr_inv: *u32, pshift: *i32, a: u32, b: u32) u32 {
    if (a == 5 and b >= 1 and b <= 13) {
        var r: u32 = pow5_table[b - 1];
        const shift: i32 = clz32(r);
        r <<= @intCast(shift);
        pr_inv.* = pow5_inv_table[b - 1];
        pshift.* = shift;
        return r;
    }

    const r: u64 = powUi(a, b);
    var r32: u32 = @truncate(r);
    const shift = clz32(r32);
    r32 <<= @intCast(shift);
    pr_inv.* = udiv1normInit(r32);
    pshift.* = shift;
    return r32;
}

// ============================================================
// Conversion helpers
// ============================================================

fn u32toaLen(buf: []u8, n: u32, len: usize) void {
    var n2 = n;
    var i: isize = @as(isize, @intCast(len)) - 1;
    while (i >= 0) : (i -= 1) {
        const digit = n2 % 10;
        n2 /= 10;
        buf[@as(usize, @intCast(i))] = @as(u8, @intCast(digit)) + '0';
    }
}

fn u64toaBinLen(buf: []u8, n: u64, radix_bits: u5, len: usize) void {
    const mask: u64 = (@as(u64, 1) << radix_bits) - 1;
    var n2 = n;
    var i: isize = @as(isize, @intCast(len)) - 1;
    while (i >= 0) : (i -= 1) {
        var digit: u8 = @truncate(n2 & mask);
        n2 >>= radix_bits;
        if (digit < 10) {
            digit += '0';
        } else {
            digit += 'a' - 10;
        }
        buf[@intCast(i)] = digit;
    }
}

fn limbToA(buf: []u8, n: limb_t, radix: i32, len: i32) void {
    if (radix == 10) {
        u32toaLen(buf, n, @intCast(len));
        return;
    }

    var n2 = n;
    const r: u32 = @intCast(radix);
    var i: i32 = len - 1;
    while (i >= 0) : (i -= 1) {
        const digit: limb_t = n2 % r;
        n2 /= r;
        var c: u8 = @truncate(digit);
        if (c < 10) {
            c += '0';
        } else {
            c += 'a' - 10;
        }
        buf[@intCast(i)] = c;
    }
}

fn u32toaImpl(buf: []u8, n: u32) usize {
    var buf1: [10]u8 = undefined;
    var pos: usize = 10;
    var n2 = n;
    while (true) {
        pos -= 1;
        buf1[pos] = @as(u8, @intCast(n2 % 10)) + '0';
        n2 /= 10;
        if (n2 == 0) break;
    }
    const len = 10 - pos;
    @memcpy(buf[0..len], buf1[pos..]);
    return len;
}

fn i32toaImpl(buf: []u8, n: i32) usize {
    if (n >= 0) {
        return u32toaImpl(buf, @intCast(n));
    }
    buf[0] = '-';
    return u32toaImpl(buf[1..], @bitCast(-%@as(i32, @bitCast(n)))) + 1;
}

fn u64toaImpl(buf: []u8, n: u64) usize {
    if (n < 0x100000000) {
        return u32toaImpl(buf, @truncate(n));
    }

    var q = buf;
    var n2 = n;
    var n1 = n2 / 1000000000;
    n2 %= 1000000000;

    if (n1 >= 0x100000000) {
        var n3: u32 = @truncate(n1 / 1000000000);
        n1 %= 1000000000;
        if (n3 >= 10) {
            q[0] = @as(u8, @intCast(n3 / 10)) + '0';
            q = q[1..];
            n3 %= 10;
        }
        q[0] = @as(u8, @intCast(n3)) + '0';
        q = q[1..];

        var tmp: [9]u8 = undefined;
        u32toaLen(&tmp, @truncate(n1), 9);
        @memcpy(q[0..9], tmp[0..9]);
        q = q[9..];
    } else {
        const len = u32toaImpl(q, @truncate(n1));
        q = q[len..];
    }

    var tmp: [9]u8 = undefined;
    u32toaLen(&tmp, @truncate(n2), 9);
    @memcpy(q[0..9], tmp[0..9]);
    q = q[9..];

    return @intFromPtr(q.ptr) - @intFromPtr(buf.ptr);
}

fn i64toaImpl(buf: []u8, n: i64) usize {
    if (n >= 0) {
        return u64toaImpl(buf, @intCast(n));
    }
    buf[0] = '-';
    return u64toaImpl(buf[1..], @bitCast(-%@as(i64, @bitCast(n)))) + 1;
}

fn u64toaRadixImpl(buf: []u8, n: u64, radix: u32) usize {
    if (radix == 10) {
        return u64toaImpl(buf, n);
    }
    if ((radix & (radix - 1)) == 0) {
        const radix_bits: u5 = @intCast(31 - @clz(radix));
        const l: usize = if (n == 0)
            @as(usize, 1)
        else
            @intCast((64 - @as(u7, @clz(n)) + radix_bits - 1) / radix_bits);
        u64toaBinLen(buf[0..l], n, radix_bits, l);
        return l;
    }

    var buf1: [65]u8 = undefined;
    var pos: usize = 65;
    var n2 = n;
    while (true) {
        pos -= 1;
        var digit: u8 = @truncate(n2 % radix);
        n2 /= radix;
        if (digit < 10) {
            digit += '0';
        } else {
            digit += 'a' - 10;
        }
        buf1[pos] = digit;
        if (n2 == 0) break;
    }
    const len = 65 - pos;
    @memcpy(buf[0..len], buf1[pos..]);
    return len;
}

fn i64toaRadixImpl(buf: []u8, n: i64, radix: u32) usize {
    if (n >= 0) {
        return u64toaRadixImpl(buf, @intCast(n), radix);
    }
    buf[0] = '-';
    return u64toaRadixImpl(buf[1..], @bitCast(-%@as(i64, @bitCast(n))), radix) + 1;
}

// ============================================================
// output_digits
// ============================================================

fn outputDigits(buf: []u8, a: *MpbMax, radix: i32, n_digits1: i32, dot_pos: i32) usize {
    var n_digits = n_digits1;
    const radix_bits: i32 = if ((@as(u32, @bitCast(radix)) & (@as(u32, @bitCast(radix)) - 1)) == 0)
        @as(i32, 31) - clz32(@bitCast(radix))
    else
        0;
    const digits_per_limb = digits_per_limb_table[@intCast(radix - 2)];

    if (radix_bits != 0) {
        const radix_bits_u5: u5 = @intCast(radix_bits);
        while (true) {
            const n: i32 = minInt(n_digits, @as(i32, digits_per_limb));
            n_digits -= n;
            const offset: usize = @intCast(n_digits);
            u64toaBinLen(buf[offset..], a.tab[0], radix_bits_u5, @intCast(n));
            if (n_digits == 0) break;
            mpbShrRound(a, @as(i32, digits_per_limb) * radix_bits, JS_RNDZ);
        }
    } else {
        while (n_digits != 0) {
            const n: i32 = minInt(n_digits, @as(i32, digits_per_limb));
            n_digits -= n;
            const rlen: usize = @intCast(a.len);
            const r = mpDiv1(a.tab[0..rlen], a.tab[0..rlen], radix_base_table[@intCast(radix - 2)], 0);
            mpbRenorm(a);
            var tmp: [9]u8 = undefined;
            limbToA(&tmp, r, radix, n);
            const offset: usize = @intCast(n_digits);
            @memcpy(buf[offset..][0..@intCast(n)], tmp[0..@intCast(n)]);
        }
    }

    var len: usize = @intCast(n_digits1);
    if (dot_pos != n_digits1) {
        const dp: usize = @intCast(dot_pos);
        const n1: usize = @intCast(n_digits1);
        const move_len = n1 - dp;
        std.mem.copyBackwards(u8, buf[dp + 1 .. dp + 1 + move_len], buf[dp .. dp + move_len]);
        buf[dp] = '.';
        len += 1;
    }
    return len;
}

// ============================================================
// mul_pow / mul_pow_round / round_to_d
// ============================================================

fn mulPow(a: *MpbMax, radix1: i32, radix_shift: i32, f: i32, is_int: bool, e: i32) i32 {
    var e_offset: i32 = -f * radix_shift;

    if (radix1 != 1) {
        const d: i32 = digits_per_limb_table[@intCast(radix1 - 2)];

        if (f >= 0) {
            var b: u64 = 0;
            var n0: i32 = 0;
            var f2 = f;
            while (f2 != 0) {
                const n: i32 = minInt(f2, d);
                if (n != n0) {
                    b = powUi(@intCast(radix1), @intCast(n));
                    n0 = n;
                }
                const h = mpMul1(a.tabSlice(), a.tabConstSlice(), @truncate(b), 0);
                if (h != 0) {
                    a.tab[@intCast(a.len)] = h;
                    a.len += 1;
                }
                f2 -= n;
            }
        } else {
            var f2 = -f;
            const l: i32 = @divTrunc(f2 + d - 1, d);
            e_offset += l * @as(i32, LIMB_BITS);

            var extra_bits: i32 = undefined;
            if (!is_int) {
                extra_bits = maxInt(e - mpbFloorLog2(a), @as(i32, 0));
            } else {
                extra_bits = maxInt(2 + e - e_offset, @as(i32, 0));
            }
            e_offset += extra_bits;
            mpbShrRound(a, -(l * @as(i32, LIMB_BITS) + extra_bits), JS_RNDZ);

            var b: u32 = 0;
            var b_inv: u32 = 0;
            var shift: i32 = 0;
            var n0: i32 = 0;
            var rem: limb_t = 0;
            while (f2 != 0) {
                const n: i32 = minInt(f2, d);
                if (n != n0) {
                    b = powUiInv(&b_inv, &shift, @intCast(radix1), @intCast(n));
                    n0 = n;
                }
                const rlen: usize = @intCast(a.len);
                const r = mpDiv1normInternal(a.tab[0..rlen], a.tab[0..rlen], b, 0, b_inv, shift);
                rem |= r;
                mpbRenorm(a);
                f2 -= n;
            }
            a.tab[0] |= @intFromBool(rem != 0);
        }
    }

    return e_offset;
}

fn mulPowRound(tmp1: *MpbMax, m: u64, e: i32, radix1: i32, radix_shift: i32, f: i32, rnd_mode: i32) void {
    mpbSetU64(tmp1, m);
    const e_offset = mulPow(tmp1, radix1, radix_shift, f, true, e);
    mpbShrRound(tmp1, -e + e_offset, rnd_mode);
}

fn roundToD(pe: *i32, a: *MpbMax, e_offset: i32, rnd_mode: i32) u64 {
    if (a.tab[0] == 0 and a.len == 1) {
        pe.* = 0;
        return 0;
    }

    var e_val = mpbFloorLog2(a) + 1 - e_offset;
    const prec1: i32 = 53;
    const e_min: i32 = -1021;
    var prec: i32 = undefined;

    if (e_val < e_min) {
        prec = prec1 - (e_min - e_val);
    } else {
        prec = prec1;
    }

    mpbShrRound(a, e_val + e_offset - prec, rnd_mode);
    var m = mpbGetU64(a);
    m <<= @intCast(53 - prec);

    if (m >= (@as(u64, 1) << 53)) {
        m >>= 1;
        e_val += 1;
    }

    pe.* = e_val;
    return m;
}

fn mulPowRoundToD(pe: *i32, a: *MpbMax, radix1: i32, radix_shift: i32, f: i32, rnd_mode: i32) u64 {
    const e_offset = mulPow(a, radix1, radix_shift, f, false, 55);
    return roundToD(pe, a, e_offset, rnd_mode);
}

// ============================================================
// to_digit
// ============================================================

inline fn toDigit(c: u8) i32 {
    return switch (c) {
        '0'...'9' => @as(i32, c) - '0',
        'A'...'Z' => @as(i32, c) - 'A' + 10,
        'a'...'z' => @as(i32, c) - 'a' + 10,
        else => 36,
    };
}

// ============================================================
// js_dtoa_max_len
// ============================================================

fn jsDtoaMaxLenImpl(d: f64, radix: i32, n_digits: i32, flags: i32) i32 {
    const fmt = flags & JS_DTOA_FORMAT_MASK;
    var n: i32 = 0;

    if (fmt != JS_DTOA_FORMAT_FRAC) {
        if (fmt == JS_DTOA_FORMAT_FREE) {
            n = dtoa_max_digits_table[@intCast(radix - 2)];
        } else {
            n = n_digits;
        }
        if ((flags & JS_DTOA_EXP_MASK) == JS_DTOA_EXP_DISABLED) {
            const a = float64AsUint64(d);
            var e: i32 = @intCast((a >> 52) & 0x7ff);
            if (e == 0x7ff) {
                n = 0;
            } else {
                e -= 1023;
                n += 10 + @as(i32, @intCast(@abs(mulLog2Radix(e - 1, radix))));
            }
        } else {
            n += 1 + 1 + 6;
        }
    } else {
        const a = float64AsUint64(d);
        var e: i32 = @intCast((a >> 52) & 0x7ff);
        if (e == 0x7ff) {
            n = 0;
        } else {
            e -= 1023;
            if (e < 0) {
                n = 1;
            } else {
                n = 2 + mulLog2Radix(e - 1, radix);
            }
            n += 1 + 1 + 1 + n_digits;
        }
    }
    return maxInt(n, 9);
}

// ============================================================
// js_dtoa
// ============================================================

fn jsDtoaImpl(buf: []u8, d: f64, radix: i32, n_digits: i32, flags: i32, tmp_mem: *JSDTOATempMem) usize {
    var mptr: [*]u64 = &tmp_mem.mem;
    const tmp1 = dtoaMalloc(Mpb(DBIGNUM_LEN_MAX), &mptr);
    const mant_max_small = dtoaMalloc(Mpb(MANT_LEN_MAX), &mptr);
    const mant_max: *MpbMax = @ptrCast(mant_max_small);

    const radix_shift = ctz32(@intCast(radix));
    const radix1: i32 = radix >> @intCast(radix_shift);
    const a = float64AsUint64(d);
    const sgn = @as(i32, @intCast(a >> 63));
    var e: i32 = @intCast((a >> 52) & 0x7ff);
    var m = a & ((@as(u64, 1) << 52) - 1);
    var q = buf;
    var E: i32 = 0;
    var P: i32 = 0;

    if (e == 0x7ff) {
        if (m == 0) {
            if (sgn != 0) {
                q[0] = '-';
                q = q[1..];
            }
            @memcpy(q[0..8], "Infinity");
            q = q[8..];
        } else {
            @memcpy(q[0..3], "NaN");
            q = q[3..];
        }
        return @intFromPtr(q.ptr) - @intFromPtr(buf.ptr);
    }

    if (e == 0) {
        if (m == 0) {
            tmp1.len = 1;
            tmp1.tab[0] = 0;
            E = 1;
            if ((flags & JS_DTOA_FORMAT_MASK) == JS_DTOA_FORMAT_FREE) {
                P = 1;
            } else if ((flags & JS_DTOA_FORMAT_MASK) == JS_DTOA_FORMAT_FRAC) {
                P = n_digits + 1;
            } else {
                P = n_digits;
            }
            if (sgn != 0 and (flags & JS_DTOA_MINUS_ZERO) != 0) {
                q[0] = '-';
                q = q[1..];
            }
            return outputHelper(q, buf, tmp1, radix, radix1, radix_shift, P, E, n_digits, flags);
        }
        // denormal: normalize
        const l = clz64(m) - 11;
        e -= l - 1;
        m <<= @intCast(l);
    } else {
        m |= @as(u64, 1) << 52;
    }

    if (sgn != 0) {
        q[0] = '-';
        q = q[1..];
    }

    e -= 1022;

    // USE_FAST_INT fast path
    if ((flags & JS_DTOA_FORMAT_MASK) == JS_DTOA_FORMAT_FREE and
        e >= 1 and e <= 53 and
        (m & ((@as(u64, 1) << @intCast(53 - e)) - 1)) == 0 and
        (flags & JS_DTOA_EXP_MASK) != JS_DTOA_EXP_ENABLED)
    {
        const m_shifted = m >> @intCast(53 - e);
        const len = u64toaRadixImpl(q, m_shifted, @intCast(radix));
        q = q[len..];
        return @intFromPtr(q.ptr) - @intFromPtr(buf.ptr);
    }

    E = 1 + mulLog2Radix(e - 1, radix);
    const fmt = flags & JS_DTOA_FORMAT_MASK;

    if (fmt == JS_DTOA_FORMAT_FREE) {
        const P_max: i32 = dtoa_max_digits_table[@intCast(radix - 2)];
        const E0 = E;
        var E_found: i32 = 0;
        var P_found: i32 = 0;
        var mant_found: u64 = 0;

        P = P_max;
        while (true) {
            _ = powUi(@intCast(radix), @intCast(P));
            E = E0;
            while (true) {
                mulPowRound(tmp1, m, e - 53, radix1, radix_shift, P - E, JS_RNDN);
                const mant = mpbGetU64(tmp1);
                const mant_max1 = powUi(@intCast(radix), @intCast(P));
                if (mant < mant_max1) break;
                E += 1;
            }
            var mant2 = mpbGetU64(tmp1);
            // remove trailing zeros
            const r: u32 = @intCast(radix);
            while (mant2 != 0 and (mant2 % r) == 0) {
                mant2 /= r;
                P -= 1;
            }
            if (P_found == 0) {
                P_found = P;
                E_found = E;
                mant_found = mant2;
                if (P == 1) break;
                P -= 1;
                continue;
            }
            // convert back
            mpbSetU64(tmp1, mant2);
            var e1: i32 = 0;
            const m1 = mulPowRoundToD(&e1, tmp1, radix1, radix_shift, E - P, JS_RNDN);
            if (m1 == m and e1 == e) {
                P_found = P;
                E_found = E;
                mant_found = mant2;
                if (P == 1) break;
                P -= 1;
            } else {
                break;
            }
        }
        P = P_found;
        E = E_found;
        mpbSetU64(tmp1, mant_found);
    } else if (fmt == JS_DTOA_FORMAT_FRAC) {
        mulPowRound(tmp1, m, e - 53, radix1, radix_shift, n_digits, JS_RNDNA);

        const tot = maxInt(E + 1, @as(i32, 1)) + n_digits;
        const dot = maxInt(E + 1, @as(i32, 1));
        const out_len = outputDigits(q, tmp1, radix, tot, dot);
        if (q[0] == '0' and out_len >= 2 and q[1] != '.') {
            std.mem.copyForwards(u8, q[0 .. out_len - 1], q[1..out_len]);
            q = q[out_len - 1 ..];
        } else {
            q = q[out_len..];
        }
        return @intFromPtr(q.ptr) - @intFromPtr(buf.ptr);
    } else {
        // FIXED format
        P = n_digits;
        mant_max.len = 1;
        mant_max.tab[0] = 1;
        const pow_shift = mulPow(mant_max, radix1, radix_shift, P, false, 0);
        mpbShrRound(mant_max, pow_shift, JS_RNDZ);

        while (true) {
            mulPowRound(tmp1, m, e - 53, radix1, radix_shift, P - E, JS_RNDNA);
            if (mpbCmp(tmp1, mant_max) < 0) break;
            E += 1;
        }
    }

    return outputHelper(q, buf, tmp1, radix, radix1, radix_shift, P, E, n_digits, flags);
}

fn outputHelper(
    q_start: []u8,
    buf_start: []u8,
    tmp1: *MpbMax,
    radix: i32,
    radix1: i32,
    radix_shift: i32,
    P: i32,
    E: i32,
    n_digits: i32,
    flags: i32,
) usize {
    var q = q_start;
    const fmt = flags & JS_DTOA_FORMAT_MASK;

    var E_max: i32 = undefined;
    if (fmt == JS_DTOA_FORMAT_FIXED) {
        E_max = n_digits;
    } else {
        E_max = dtoa_max_digits_table[@intCast(radix - 2)] + 4;
    }

    if ((flags & JS_DTOA_EXP_MASK) == JS_DTOA_EXP_ENABLED or
        ((flags & JS_DTOA_EXP_MASK) == JS_DTOA_EXP_AUTO and (E <= -6 or E > E_max)))
    {
        q = q[outputDigits(q, tmp1, radix, P, 1)..];
        var E2 = E - 1;
        if (radix == 10) {
            q[0] = 'e';
            q = q[1..];
        } else if (radix1 == 1 and radix_shift <= 4) {
            E2 *= radix_shift;
            q[0] = 'p';
            q = q[1..];
        } else {
            q[0] = '@';
            q = q[1..];
        }
        if (E2 < 0) {
            q[0] = '-';
            q = q[1..];
            E2 = -E2;
        } else {
            q[0] = '+';
            q = q[1..];
        }
        q = q[u32toaImpl(q, @intCast(E2))..];
    } else if (E <= 0) {
        q[0] = '0';
        q[1] = '.';
        q = q[2..];
        for (0..@intCast(-E)) |_| {
            q[0] = '0';
            q = q[1..];
        }
        q = q[outputDigits(q, tmp1, radix, P, P)..];
    } else {
        q = q[outputDigits(q, tmp1, radix, P, minInt(P, E))..];
        for (0..@intCast(@max(E - P, 0))) |_| {
            q[0] = '0';
            q = q[1..];
        }
    }

    return @intFromPtr(q.ptr) - @intFromPtr(buf_start.ptr);
}

// ============================================================
// js_atod
// ============================================================

fn jsAtodImpl(str: []const u8, pnext: *?[*]const u8, radix_arg: i32, flags: i32, tmp_mem: *JSATODTempMem) f64 {
    var mptr: [*]u64 = &tmp_mem.mem;
    const tmp0 = dtoaMalloc(Mpb(DBIGNUM_LEN_MAX), &mptr);

    var sep: i32 = if ((flags & JS_ATOD_ACCEPT_UNDERSCORES) != 0) @as(i32, '_') else 256;

    var p = str;
    var is_neg: i32 = 0;
    var p_start = p;

    if (p.len > 0 and p[0] == '+') {
        p = p[1..];
        p_start = p;
    } else if (p.len > 0 and p[0] == '-') {
        is_neg = 1;
        p = p[1..];
        p_start = p;
    }

    var radix: i32 = radix_arg;

    if (p.len > 0 and p[0] == '0') {
        var no_prefix: bool = false;
        if (p.len >= 2 and (p[1] == 'x' or p[1] == 'X') and (radix == 0 or radix == 16)) {
            p = p[2..];
            radix = 16;
        } else if (p.len >= 2 and (p[1] == 'o' or p[1] == 'O') and radix == 0 and (flags & JS_ATOD_ACCEPT_BIN_OCT) != 0) {
            p = p[2..];
            radix = 8;
        } else if (p.len >= 2 and (p[1] == 'b' or p[1] == 'B') and radix == 0 and (flags & JS_ATOD_ACCEPT_BIN_OCT) != 0) {
            p = p[2..];
            radix = 2;
        } else if (p.len >= 2 and p[1] >= '0' and p[1] <= '9' and radix == 0 and (flags & JS_ATOD_ACCEPT_LEGACY_OCTAL) != 0) {
            sep = 256;
            const i2_end = blk: {
                var idx: usize = 1;
                while (idx < p.len and p[idx] >= '0' and p[idx] <= '7') : (idx += 1) {}
                break :blk idx;
            };
            if (i2_end < p.len and (p[i2_end] == '8' or p[i2_end] == '9')) {
                no_prefix = true;
            } else {
                p = p[1..];
                radix = 8;
            }
        }
        if (!no_prefix) {
            if (p.len == 0 or toDigit(p[0]) >= radix) {
                pnext.* = p_start.ptr;
                return std.math.nan(f64);
            }
        }
    } else {
        if ((flags & JS_ATOD_INT_ONLY) == 0) {
            if (p.len >= 8 and std.mem.eql(u8, p[0..8], "Infinity")) {
                p = p[8..];
                var a_ret: u64 = @as(u64, 0x7ff) << 52;
                a_ret |= @as(u64, @intCast(is_neg)) << 63;
                pnext.* = p.ptr;
                return uint64AsFloat64(a_ret);
            }
        }
    }

    if (radix == 0) radix = 10;

    var cur_limb: limb_t = 0;
    var expn_offset: i32 = 0;
    var digit_count: i32 = 0;
    var limb_digit_count: i32 = 0;
    const max_digits: i32 = atod_max_digits_table[@intCast(radix - 2)];
    const digits_per_limb: i32 = digits_per_limb_table[@intCast(radix - 2)];
    const radix_base: limb_t = radix_base_table[@intCast(radix - 2)];
    const radix_shift: i32 = ctz32(@intCast(radix));
    const radix1: i32 = radix >> @intCast(radix_shift);
    const radix_bits: i32 = if (radix1 == 1) radix_shift else 0;

    tmp0.len = 1;
    tmp0.tab[0] = 0;
    var extra_digits: limb_t = 0;
    var pos: i32 = 0;
    var dot_pos: i32 = -1;

    // skip leading zeros
    while (p.len > 0) {
        if (p[0] == '.' and (p.ptr != p_start.ptr or (p.len > 1 and toDigit(p[1]) < radix)) and (flags & JS_ATOD_INT_ONLY) == 0) {
            if (@as(i32, p[0]) == sep) {
                pnext.* = p_start.ptr;
                return std.math.nan(f64);
            }
            if (dot_pos >= 0) break;
            dot_pos = pos;
            p = p[1..];
        }
        if (p.len > 0 and @as(i32, p[0]) == sep and p.ptr != p_start.ptr and (p.len > 1 and p[1] == '0'))
            p = p[1..];
        if (p.len == 0 or p[0] != '0') break;
        p = p[1..];
        pos += 1;
    }

    const sig_pos = pos;

    while (p.len > 0) {
        if (p[0] == '.' and (p.ptr != p_start.ptr or (p.len > 1 and toDigit(p[1]) < radix)) and (flags & JS_ATOD_INT_ONLY) == 0) {
            if (@as(i32, p[0]) == sep) {
                pnext.* = p_start.ptr;
                return std.math.nan(f64);
            }
            if (dot_pos >= 0) break;
            dot_pos = pos;
            p = p[1..];
        }
        if (p.len > 0 and @as(i32, p[0]) == sep and p.ptr != p_start.ptr and toDigit(p[1]) < radix)
            p = p[1..];

        if (p.len == 0) break;
        const c = toDigit(p[0]);
        if (c >= radix) break;
        p = p[1..];
        pos += 1;
        if (digit_count < max_digits) {
            cur_limb = cur_limb * @as(limb_t, @intCast(radix)) + @as(limb_t, @intCast(c));
            limb_digit_count += 1;
            if (limb_digit_count == digits_per_limb) {
                mpbMul1Base(tmp0, radix_base, cur_limb);
                cur_limb = 0;
                limb_digit_count = 0;
            }
            digit_count += 1;
        } else {
            extra_digits |= @as(limb_t, @intCast(c));
        }
    }

    if (limb_digit_count != 0) {
        mpbMul1Base(tmp0, @truncate(powUi(@intCast(radix), @intCast(limb_digit_count))), cur_limb);
    }

    const is_zero: bool = (digit_count == 0);
    if (!is_zero) {
        if (dot_pos < 0) dot_pos = pos;
        expn_offset = sig_pos + digit_count - dot_pos;
    }

    if (radix_bits != 0 and extra_digits != 0) {
        tmp0.tab[0] |= 1;
    }

    // parse exponent
    var expn: i32 = 0;
    var expn_overflow = false;
    var is_bin_exp = false;

    if ((flags & JS_ATOD_INT_ONLY) == 0 and p.len > 0 and p.ptr != p_start.ptr) {
        const c0 = p[0];
        const has_exp = (radix == 10 and (c0 == 'e' or c0 == 'E')) or
            (radix != 10 and (c0 == '@' or (radix_bits >= 1 and radix_bits <= 4 and (c0 == 'p' or c0 == 'P'))));

        if (has_exp) {
            is_bin_exp = (c0 == 'p' or c0 == 'P');
            p = p[1..];
            var exp_is_neg = false;
            if (p.len > 0 and p[0] == '+') {
                p = p[1..];
            } else if (p.len > 0 and p[0] == '-') {
                exp_is_neg = true;
                p = p[1..];
            }
            if (p.len == 0 or toDigit(p[0]) >= 10) {
                pnext.* = p_start.ptr;
                return std.math.nan(f64);
            }
            expn = toDigit(p[0]);
            p = p[1..];
            while (p.len > 0) {
                if (@as(i32, p[0]) == sep and p.len > 1 and toDigit(p[1]) < 10)
                    p = p[1..];
                const c1 = toDigit(p[0]);
                if (c1 >= 10) break;
                if (!expn_overflow) {
                    if (expn > (@as(i32, std.math.maxInt(i32)) - 2 - 9) / 10) {
                        expn_overflow = true;
                    } else {
                        expn = expn * 10 + c1;
                    }
                }
                p = p[1..];
            }
            if (exp_is_neg) expn = -expn;
        }
    }

    if (p.ptr == p_start.ptr) {
        pnext.* = p_start.ptr;
        return std.math.nan(f64);
    }

    var a_ret: u64 = undefined;

    if (is_zero) {
        a_ret = 0;
    } else {
        if (expn_overflow) {
            if (expn < 0) {
                a_ret = 0;
                return finishAtod(a_ret, is_neg, p, pnext);
            } else {
                a_ret = @as(u64, 0x7ff) << 52;
                return finishAtod(a_ret, is_neg, p, pnext);
            }
        }

        if (radix_bits != 0) {
            if (!is_bin_exp) expn *= radix_bits;
            expn -= expn_offset * radix_bits;
            const expn1 = expn + digit_count * radix_bits;
            if (expn1 >= 1024 + radix_bits) {
                a_ret = @as(u64, 0x7ff) << 52;
            } else if (expn1 <= -1075) {
                a_ret = 0;
            } else {
                var e_val: i32 = 0;
                const m_val = roundToD(&e_val, tmp0, -expn, JS_RNDN);
                a_ret = buildFloat64(m_val, e_val);
            }
        } else {
            expn -= expn_offset;
            const expn1 = expn + digit_count;
            if (expn1 >= max_exponent[@intCast(radix - 2)] + 1) {
                a_ret = @as(u64, 0x7ff) << 52;
            } else if (expn1 <= min_exponent[@intCast(radix - 2)]) {
                a_ret = 0;
            } else {
                var e_val: i32 = 0;
                const m_val = mulPowRoundToD(&e_val, tmp0, radix1, radix_shift, expn, JS_RNDN);
                a_ret = buildFloat64(m_val, e_val);
            }
        }
    }

    return finishAtod(a_ret, is_neg, p, pnext);
}

fn buildFloat64(m: u64, e: i32) u64 {
    if (m == 0) return 0;
    if (e > 1024) return @as(u64, 0x7ff) << 52;
    if (e < -1073) return 0;
    if (e < -1021) {
        return m >> @intCast(-e - 1021);
    }
    return (@as(u64, @intCast(e + 1022)) << 52) | (m & ((@as(u64, 1) << 52) - 1));
}

fn finishAtod(a: u64, is_neg: i32, p: []const u8, pnext: *?[*]const u8) f64 {
    var a2 = a;
    a2 |= @as(u64, @intCast(is_neg)) << 63;
    pnext.* = p.ptr;
    return uint64AsFloat64(a2);
}

// ============================================================
// Engine-facing helpers
// ============================================================

pub fn parseNumber(bytes: []const u8) !f64 {
    if (std.mem.eql(u8, bytes, "NaN")) return std.math.nan(f64);

    var tmp_mem: JSATODTempMem = undefined;
    var parsed_end: ?[*]const u8 = null;
    const value = jsAtodImpl(bytes, &parsed_end, 10, 0, &tmp_mem);
    const end_ptr = @intFromPtr(bytes.ptr) + bytes.len;
    if (parsed_end == null or @intFromPtr(parsed_end.?) != end_ptr) {
        return error.InvalidCharacter;
    }
    if (std.math.isNan(value)) return error.InvalidCharacter;
    return value;
}

pub fn formatNumber(buf: []u8, value: f64) ![]const u8 {
    if (std.math.isNan(value)) return "NaN";
    if (std.math.isPositiveInf(value)) return "Infinity";
    if (std.math.isNegativeInf(value)) return "-Infinity";

    var tmp_mem: JSDTOATempMem = undefined;
    const len = jsDtoaImpl(buf, value, 10, 0, JS_DTOA_FORMAT_FREE | JS_DTOA_EXP_AUTO, &tmp_mem);
    return buf[0..len];
}

pub fn formatInt32(buf: []u8, value: i32) []const u8 {
    const len = i32toaImpl(buf, value);
    return buf[0..len];
}

pub fn formatInt64(buf: []u8, value: i64) []const u8 {
    const len = i64toaImpl(buf, value);
    return buf[0..len];
}

pub fn formatDtoa(buf: []u8, value: f64, n_digits: i32, flags: i32) []const u8 {
    var tmp_mem: JSDTOATempMem = undefined;
    const len = jsDtoaImpl(buf, value, 10, n_digits, flags, &tmp_mem);
    return buf[0..len];
}

pub fn formatDtoaChecked(buf: []u8, value: f64, n_digits: i32, flags: i32) ![]const u8 {
    const len_max = jsDtoaMaxLenImpl(value, 10, n_digits, flags);
    if (len_max < 0) return error.NoSpaceLeft;
    const needed: usize = @as(usize, @intCast(len_max)) + 1;
    if (needed > buf.len) return error.NoSpaceLeft;
    var tmp_mem: JSDTOATempMem = undefined;
    const len = jsDtoaImpl(buf, value, 10, n_digits, flags, &tmp_mem);
    if (len >= buf.len) return error.NoSpaceLeft;
    return buf[0..len];
}

// ============================================================
// Exported wrappers (C ABI)
// ============================================================

pub export fn js_dtoa_max_len(d: f64, radix: c_int, n_digits: c_int, flags: c_int) callconv(.c) c_int {
    return jsDtoaMaxLenImpl(d, radix, n_digits, flags);
}

pub export fn js_dtoa(buf_ptr: [*]u8, d: f64, radix: c_int, n_digits: c_int, flags: c_int, tmp_mem: *JSDTOATempMem) callconv(.c) c_int {
    const max_len: usize = @intCast(jsDtoaMaxLenImpl(d, radix, n_digits, flags));
    const len = jsDtoaImpl(buf_ptr[0 .. max_len + 10], d, radix, n_digits, flags, tmp_mem);
    return @intCast(len);
}

pub export fn js_atod(str_ptr: [*]const u8, pnext: [*c][*c]const u8, radix: c_int, flags: c_int, tmp_mem: *JSATODTempMem) callconv(.c) f64 {
    const s = str_ptr[0..strlen(str_ptr)];
    var pn: ?[*]const u8 = null;
    const val = jsAtodImpl(s, &pn, radix, flags, tmp_mem);
    if (@intFromPtr(pnext) != 0) {
        pnext.* = if (pn) |p| p else str_ptr;
    }
    return val;
}

pub export fn u32toa(buf: [*]u8, n: u32) callconv(.c) usize {
    return u32toaImpl(buf[0..10], n);
}

pub export fn i32toa(buf: [*]u8, n: i32) callconv(.c) usize {
    return i32toaImpl(buf[0..11], n);
}

pub export fn u64toa(buf: [*]u8, n: u64) callconv(.c) usize {
    return u64toaImpl(buf[0..21], n);
}

pub export fn i64toa(buf: [*]u8, n: i64) callconv(.c) usize {
    return i64toaImpl(buf[0..22], n);
}

pub export fn u64toa_radix(buf: [*]u8, n: u64, radix: c_uint) callconv(.c) usize {
    return u64toaRadixImpl(buf[0..65], n, radix);
}

pub export fn i64toa_radix(buf: [*]u8, n: i64, radix: c_uint) callconv(.c) usize {
    return i64toaRadixImpl(buf[0..66], n, radix);
}

pub export fn mp_add_ui(tab: [*]limb_t, b: limb_t, n: usize) callconv(.c) limb_t {
    return mpAddUi(tab[0..n], b);
}

pub export fn mp_shr(tab_r: [*]limb_t, tab: [*]const limb_t, n: isize, shift: c_int, high: limb_t) callconv(.c) limb_t {
    const len: usize = @intCast(n);
    return mpShr(tab_r[0..len], tab[0..len], @intCast(shift), high);
}

pub export fn mp_shl(tab_r: [*]limb_t, tab: [*]const limb_t, n: isize, shift: c_int, low: limb_t) callconv(.c) limb_t {
    const len: usize = @intCast(n);
    return mpShl(tab_r[0..len], tab[0..len], @intCast(shift), low);
}

pub export fn mpb_set_u64(r: *anyopaque, m: u64) callconv(.c) void {
    const mpb: *MpbMax = @ptrCast(@alignCast(r));
    mpbSetU64(mpb, m);
}

pub export fn mpb_get_u64(r: *anyopaque) callconv(.c) u64 {
    const mpb: *const MpbMax = @ptrCast(@alignCast(r));
    return mpbGetU64(mpb);
}

pub export fn mpb_floor_log2(a: *anyopaque) callconv(.c) c_int {
    const mpb: *const MpbMax = @ptrCast(@alignCast(a));
    return mpbFloorLog2(mpb);
}

pub export fn mul_log2_radix(a: c_int, radix: c_int) callconv(.c) c_int {
    return mulLog2Radix(a, radix);
}

pub export fn pow_ui(radix: c_int, n: c_int) callconv(.c) u64 {
    return powUi(@intCast(radix), @intCast(n));
}

pub export fn pow_ui_inv(pr_inv: *u32, pshift: *c_int, radix: c_int, n: c_int) callconv(.c) void {
    _ = powUiInv(pr_inv, pshift, @intCast(radix), @intCast(n));
}

pub export fn mpb_shr_round(r: *anyopaque, shift: c_int, rnd_mode: c_int) callconv(.c) void {
    const mpb: *MpbMax = @ptrCast(@alignCast(r));
    mpbShrRound(mpb, shift, rnd_mode);
}

pub export fn mpb_cmp(a: *const anyopaque, b: *const anyopaque) callconv(.c) c_int {
    const ma: *const MpbMax = @ptrCast(@alignCast(a));
    const mb: *const MpbMax = @ptrCast(@alignCast(b));
    return mpbCmp(ma, mb);
}

pub export fn mpb_renorm(r: *anyopaque) callconv(.c) void {
    const mpb: *MpbMax = @ptrCast(@alignCast(r));
    mpbRenorm(mpb);
}

pub export fn mpb_mul1_base(r: *anyopaque, radix_base: limb_t, b: limb_t) callconv(.c) void {
    const mpb: *MpbMax = @ptrCast(@alignCast(r));
    mpbMul1Base(mpb, radix_base, b);
}

pub export fn limb_to_a(buf: [*]u8, a: limb_t, radix: c_int, len: c_int) callconv(.c) void {
    limbToA(buf[0..@intCast(len)], a, radix, len);
}

pub export fn output_digits(buf: [*]u8, a: *const anyopaque, radix: c_int, n_digits: c_int, dot_pos: c_int) callconv(.c) c_int {
    const mpb: *MpbMax = @ptrCast(@alignCast(@constCast(a)));
    const max_out: usize = @intCast(n_digits + 2);
    return @intCast(outputDigits(buf[0..max_out], mpb, radix, n_digits, dot_pos));
}

pub export fn round_to_d(pe: *c_int, a: *anyopaque, e_offset: c_int, rnd_mode: c_int) callconv(.c) u64 {
    const mpb: *MpbMax = @ptrCast(@alignCast(a));
    return roundToD(pe, mpb, e_offset, rnd_mode);
}

pub export fn mul_pow_round_to_d(pe: *c_int, a: *anyopaque, radix1: c_int, radix_shift: c_int, f: c_int, rnd_mode: c_int) callconv(.c) u64 {
    const mpb: *MpbMax = @ptrCast(@alignCast(a));
    return mulPowRoundToD(pe, mpb, radix1, radix_shift, f, rnd_mode);
}

pub export fn udiv1norm_init(d: limb_t) callconv(.c) limb_t {
    return udiv1normInit(d);
}

pub export fn mp_div1norm(tabr: [*]limb_t, taba: [*]const limb_t, n: limb_t, b: limb_t, r: limb_t, b_inv: limb_t, shift: c_int) callconv(.c) limb_t {
    const len: usize = @intCast(n);
    return mpDiv1normInternal(tabr[0..len], taba[0..len], b, r, b_inv, shift);
}

pub export fn mpb_dump(str_ptr: [*]const u8, a: *const anyopaque) callconv(.c) void {
    const mpb: *const MpbMax = @ptrCast(@alignCast(a));
    const s = str_ptr[0..strlen(str_ptr)];
    mpbDump(s, mpb);
}

pub export fn mpb_get_bit(r: *const anyopaque, pos: c_int) callconv(.c) c_int {
    const mpb: *const MpbMax = @ptrCast(@alignCast(r));
    return mpbGetBit(mpb, pos);
}

test "dtoa functionality" {
    const n = try parseNumber("12.5");
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("12.5", try formatNumber(&buf, n));
    try std.testing.expect(std.math.isPositiveInf(try parseNumber("+Infinity")));
}
