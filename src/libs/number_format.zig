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

//! Binary64 <-> text conversion ported from QuickJS `dtoa.c` / `dtoa.h`, in
//! both directions and with one kernel per direction.
//!
//! Formatting: `formatNumber` (shortest), `formatRadix`, `formatDtoaChecked`
//! (toFixed / toPrecision / toExponential) over `floatToText` (dtoa.c
//! `js_dtoa`). Zig std cannot replace it: `std.fmt.float` rounds the shortest
//! digit string a second time and pads with zeros past 17 digits, so
//! `(1.005).toFixed(2)` and `(0.1).toPrecision(30)` come out wrong, and it
//! has no radix mode.
//!
//! Parsing: `parseNumberPrefix` / `parseNumberExact` over `textToFloat`
//! (dtoa.c `js_atod`, with the prefix / sign / exponent rules of `js_atof`
//! folded in so one scanner serves every caller). `ParseFlags` selects the
//! grammar: ToNumber (`accept_bin_oct`), parseInt (`int_only` +
//! `accept_prefix_after_sign`), parseFloat (radix 10, nothing), source
//! literals (`accept_bin_oct` + `accept_underscores`), JSON (nothing).
//!
//! Deliberate additions over upstream. Formatting: radix-10 FORMAT_FREE
//! takes Ryu (`shortestDecimalRyu`, comptime tables) instead of
//! `dtoaShortest`'s descending bignum trials; the digits feed the same
//! `outputHelper`, so layout rules are untouched. One visible difference
//! from QuickJS: on powers of two the rounding interval is asymmetric and
//! Ryu finds the genuinely shortest string (`2**-1017` prints
//! `7.120236347223045e-307`, as V8 and JSC do), where `dtoaShortest` settles
//! for 17 digits. Both parse back to the same double; the spec asks for the
//! fewest digits. Parsing: `textToFloat` keeps the first
//! FAST_MANTISSA_DIGITS significant decimal digits in a `u64` and converts
//! them with Clinger's exact fast path or Eisel-Lemire (`convertDecimalFast`)
//! before touching the bignum; upstream marks this spot `XXX: add fast path
//! for small integers`. Every accepted / rejected byte is unchanged, and
//! Eisel-Lemire falls back to the bignum whenever it cannot prove the
//! rounding.
//!
//! No heap allocator: callers pass the output buffer; scratch lives in
//! `FormatScratch` / `ParseScratch`. Bignum helpers (`mpb*`, `udiv1norm`,
//! `mulPow`, ...) keep their dtoa.c names so the port can be diffed against
//! upstream.
//!
//! ```
//! formatNumber / formatRadix / formatDtoaChecked
//!   └─ floatToText
//!        ├─ writeNonFinite | integer fast path
//!        ├─ dtoaShortestDecimal (Ryu, radix 10) | dtoaShortest | dtoaFrac | dtoaFixed ─► mulPow
//!        └─ outputDigits / outputHelper
//!
//! parseNumberPrefix / parseNumberExact
//!   └─ textToFloat ─► parseExponent ─► convertDecimalFast (≤19 digits, radix 10)
//!                                    └─► convertBignumToBits ─► buildFloat64
//! ```
const std = @import("std");

// ============================================================
// Public types and flags (dtoa.h)
// ============================================================

/// Fixed workspace for one `floatToText` call (dtoa.c `FormatScratch`).
pub const FormatScratch = extern struct {
    mem: [37]u64,
};

/// Fixed workspace for one `textToFloat` call (dtoa.c `ParseScratch`).
const ParseScratch = extern struct {
    mem: [27]u64,
};

/// Digit-count policy of `floatToText` (dtoa.h format flags).
pub const Format = enum {
    /// Shortest round-tripping digits (`Number#toString`).
    free,
    /// Exactly `n_digits` significant digits (`toPrecision`, `toExponential`).
    fixed,
    /// `n_digits` digits after the point (`toFixed`).
    frac,
};

/// Exponent-notation policy (dtoa.h exponent flags).
pub const ExpMode = enum {
    /// Exponent when the decimal exponent leaves the JS `toString` window.
    auto,
    /// Always exponent notation.
    enabled,
    /// Never exponent notation (radix `toString`).
    disabled,
};

pub const FormatOptions = struct {
    format: Format = .free,
    exp: ExpMode = .auto,
    /// Keep the sign on negative zero (`js_print_float64`).
    minus_zero: bool = false,
};

/// Grammar switches for `parseNumberPrefix` (QuickJS `ATOD_*` flags).
pub const ParseFlags = packed struct {
    /// Integer digits only: no fraction, no exponent, no `Infinity`.
    int_only: bool = false,
    /// `0b` / `0o` prefixes (`0x` is always taken when radix is 0 or 16).
    accept_bin_oct: bool = false,
    /// `0777` as octal; `089` still decimal.
    accept_legacy_octal: bool = false,
    /// `_` between digits.
    accept_underscores: bool = false,
    /// Recognise a radix prefix after a sign (`-0x10`); parseInt only.
    accept_prefix_after_sign: bool = false,
    /// Fraction and `@` / `p` exponent in a non-decimal radix. Only the
    /// `formatRadix` round-trip tests want this; JS grammars never do.
    accept_radix_fraction: bool = false,
};

/// Result of `parseNumberPrefix`: `len` bytes were consumed. `len` is 0 and
/// `value` is NaN when no number starts at the text.
pub const Parsed = struct {
    value: f64,
    len: usize,
};

// ============================================================
// Engine-facing format API
// ============================================================

/// Default `Number#toString` decimal (FREE + EXP_AUTO). Caller must size `buf`;
/// this wrapper does not check capacity. Use `formatDtoaChecked` / `formatRadix`
/// when the bound is not obvious.
pub fn formatNumber(buf: []u8, value: f64) ![]const u8 {
    if (std.math.isNan(value)) return "NaN";
    if (std.math.isPositiveInf(value)) return "Infinity";
    if (std.math.isNegativeInf(value)) return "-Infinity";

    var tmp_mem: FormatScratch = undefined;
    const len = floatToText(buf, value, 10, 0, .{}, &tmp_mem);
    return buf[0..len];
}

pub fn formatInt32(buf: []u8, value: i32) []const u8 {
    const len = i32toa(buf, value);
    return buf[0..len];
}

pub fn formatInt64(buf: []u8, value: i64) []const u8 {
    const len = i64toa(buf, value);
    return buf[0..len];
}

/// Upper bound on the byte length `formatRadix` will write for these
/// arguments, so a caller can size its buffer instead of guessing. Radix 2
/// with `EXP_DISABLED` runs past a thousand digits on a denormal, which is why
/// guessing does not work.
pub fn radixMaxLen(value: f64, radix: i32, n_digits: i32, options: FormatOptions) !usize {
    const len_max = floatToTextMaxLen(value, radix, n_digits, options);
    if (len_max < 0) return error.InvalidRadix;
    return @as(usize, @intCast(len_max)) + 1;
}

/// `Number.prototype.toString(radix)` for any radix in 2..36. Digit generation
/// is the same `floatToText` path radix 10 uses.
pub fn formatRadix(buf: []u8, value: f64, radix: i32, n_digits: i32, options: FormatOptions) ![]const u8 {
    if (buf.len < try radixMaxLen(value, radix, n_digits, options)) return error.NoSpaceLeft;
    var tmp_mem: FormatScratch = undefined;
    const len = floatToText(buf, value, radix, n_digits, options, &tmp_mem);
    if (len >= buf.len) return error.NoSpaceLeft;
    return buf[0..len];
}

/// Capacity-checked decimal dtoa for `toFixed` / `toExponential` / `toPrecision`.
pub fn formatDtoaChecked(buf: []u8, value: f64, n_digits: i32, options: FormatOptions) ![]const u8 {
    const len_max = floatToTextMaxLen(value, 10, n_digits, options);
    if (len_max < 0) return error.NoSpaceLeft;
    const needed: usize = @as(usize, @intCast(len_max)) + 1;
    if (needed > buf.len) return error.NoSpaceLeft;
    var tmp_mem: FormatScratch = undefined;
    const len = floatToText(buf, value, 10, n_digits, options, &tmp_mem);
    if (len >= buf.len) return error.NoSpaceLeft;
    return buf[0..len];
}

/// Parse the longest number at the start of `text`, QuickJS `js_atof`
/// style: optional sign, optional radix prefix, digits with the separators
/// and fraction / exponent the flags allow, or `Infinity` unless `int_only`.
/// `radix` 0 means 10 unless a prefix says otherwise. The caller trims
/// whitespace first and decides whether trailing bytes are an error.
pub fn parseNumberPrefix(text: []const u8, radix: u8, flags: ParseFlags) Parsed {
    var scratch: ParseScratch = undefined;
    return textToFloat(text, radix, flags, &scratch) orelse .{ .value = std.math.nan(f64), .len = 0 };
}

/// `parseNumberPrefix` that must consume all of `text`; null otherwise.
pub fn parseNumberExact(text: []const u8, radix: u8, flags: ParseFlags) ?f64 {
    const parsed = parseNumberPrefix(text, radix, flags);
    if (parsed.len != text.len) return null;
    return parsed.value;
}

// ============================================================
// Internal constants and tables
// ============================================================

const LIMB_BITS = 32;
const limb_t = u32;
const slimb_t = i32;
const dlimb_t = u64;
const JS_RADIX_MAX = 36;
const DBIGNUM_LEN_MAX = 52;
const MANT_LEN_MAX = 18;

const MUL_LOG2_RADIX_BASE_LOG2 = 24;

const JS_RNDN = 0;
const JS_RNDNA = 1;
const JS_RNDZ = 2;

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

/// Decimal digits `textToFloat` accumulates in a `u64` before spilling to the
/// bignum. 10^19 < 2^64.
const FAST_MANTISSA_DIGITS: i32 = 19;

/// 10^0 .. 10^22 are exactly representable in binary64, so a single
/// multiply or divide by one of them is a single correctly rounded operation
/// (Clinger 1990).
const CLINGER_MAX_EXP10: i32 = 22;
const clinger_pow10 = blk: {
    var t: [CLINGER_MAX_EXP10 + 1]f64 = undefined;
    var v: f64 = 1;
    for (&t) |*e| {
        e.* = v;
        v *= 10;
    }
    break :blk t;
};

/// Eisel-Lemire table: the 128 most significant bits of 5^q for
/// q in [EL_Q_MIN, EL_Q_MAX], truncated for q >= 0 and rounded up for q < 0
/// exactly as fast_float generates them (verified entry-for-entry against
/// Zig std's literal table). Built at comptime, about 1 s of sema, so the
/// 10 KB of constants are not pasted into the source.
const EL_Q_MIN: i32 = -342;
const EL_Q_MAX: i32 = 308;
const el_pow5_128 = blk: {
    @setEvalBranchQuota(2_000_000);
    const Big = u1856; // 2*z+128 bits for 5^342 (z = 800) is 1728, plus headroom
    var table: [EL_Q_MAX - EL_Q_MIN + 1][2]u64 = undefined;
    const one: Big = 1;
    // q >= 0: running power, kept to its top 128 bits.
    var p: Big = 1;
    var q: i32 = 0;
    while (q <= EL_Q_MAX) : (q += 1) {
        var c = p;
        while (c >= (one << 128)) c >>= 1;
        while (c < (one << 127)) c <<= 1;
        table[@intCast(q - EL_Q_MIN)] = .{ @truncate(c >> 64), @truncate(c) };
        p *= 5;
    }
    // q < 0: 2^b / 5^|q| rounded up; b differs below q = -27 as in fast_float.
    p = 5;
    q = -1;
    while (q >= EL_Q_MIN) : (q -= 1) {
        const z: u32 = @bitSizeOf(Big) - @clz(p - 1); // smallest z with 2^z >= 5^|q|
        var c: Big = undefined;
        if (q >= -27) {
            c = ((one << @intCast(z + 127)) / p) + 1;
        } else {
            c = ((one << @intCast(2 * z + 128)) / p) + 1;
            while (c >= (one << 128)) c >>= 1;
        }
        table[@intCast(q - EL_Q_MIN)] = .{ @truncate(c >> 64), @truncate(c) };
        p *= 5;
    }
    break :blk table;
};

/// Ryu tables (Adams 2018, "Ryū: fast float-to-string conversion"): the top
/// 125 bits of 5^i (floor) and of 2^k / 5^i (plus one), exactly the
/// `DOUBLE_POW5_SPLIT` / `DOUBLE_POW5_INV_SPLIT` full tables of the reference
/// implementation. Built at comptime like `el_pow5_128`.
const RYU_POW5_BITCOUNT = 125;
const RYU_POW5_INV_BITCOUNT = 125;
const RYU_POW5_TABLE_SIZE = 326;
const RYU_POW5_INV_TABLE_SIZE = 342;
const ryu_pow5_split = blk: {
    @setEvalBranchQuota(1_000_000);
    const Big = u1024;
    var table: [RYU_POW5_TABLE_SIZE][2]u64 = undefined;
    var p: Big = 1;
    for (&table) |*entry| {
        const bits: u32 = @bitSizeOf(Big) - @clz(p);
        const c: Big = if (bits > RYU_POW5_BITCOUNT) p >> @intCast(bits - RYU_POW5_BITCOUNT) else p << @intCast(RYU_POW5_BITCOUNT - bits);
        entry.* = .{ @truncate(c), @truncate(c >> 64) };
        p *= 5;
    }
    break :blk table;
};
const ryu_pow5_inv_split = blk: {
    @setEvalBranchQuota(1_000_000);
    const Big = u1024;
    var table: [RYU_POW5_INV_TABLE_SIZE][2]u64 = undefined;
    var p: Big = 1;
    for (&table) |*entry| {
        const bits: u32 = @bitSizeOf(Big) - @clz(p);
        const c: Big = ((@as(Big, 1) << @intCast(bits - 1 + RYU_POW5_INV_BITCOUNT)) / p) + 1;
        entry.* = .{ @truncate(c), @truncate(c >> 64) };
        p *= 5;
    }
    break :blk table;
};

// ============================================================
// Scratch arena and Mpb
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

fn dtoaMalloc(comptime T: type, mptr: *[*]u64) *T {
    const bump = (@sizeOf(T) + 7) / 8;
    const ptr: *T = @ptrCast(@alignCast(mptr.*));
    mptr.* += bump;
    return ptr;
}

fn writtenLen(buf: []const u8, cursor: []const u8) usize {
    return @intFromPtr(cursor.ptr) - @intFromPtr(buf.ptr);
}

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

// ============================================================
// Limb arithmetic
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

const DivStep = struct { quotient: limb_t, remainder: limb_t };

fn udiv1norm(a1: limb_t, a0: limb_t, d: limb_t, d_inv: limb_t) DivStep {
    const n1m: limb_t = @bitCast(@as(slimb_t, @bitCast(a0)) >> (LIMB_BITS - 1));
    const n_adj = a0 +% (n1m & d);
    var a: dlimb_t = @as(dlimb_t, d_inv) * @as(dlimb_t, a1 -% n1m) + n_adj;
    var q: limb_t = @as(limb_t, @truncate(a >> LIMB_BITS)) +% a1;
    a = (@as(dlimb_t, a1) << LIMB_BITS) | a0;
    a = a -% @as(dlimb_t, q) * @as(dlimb_t, d) -% d;
    const ah: limb_t = @truncate(a >> LIMB_BITS);
    q +%= 1 +% ah;
    return .{ .quotient = q, .remainder = @as(limb_t, @truncate(a)) +% (ah & d) };
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

fn mpDiv1norm(tabr: []limb_t, taba: []const limb_t, b: limb_t, r_in: limb_t, b_inv: limb_t, shift: i32) limb_t {
    var r = r_in;
    const n = taba.len;
    if (shift != 0) {
        const sh: u5 = @intCast(shift);
        const high = mpShl(tabr, taba, sh, 0);
        r = (r << sh) | high;
    }
    var i: isize = @as(isize, @intCast(n)) - 1;
    while (i >= 0) : (i -= 1) {
        const step = udiv1norm(r, taba[@as(usize, @intCast(i))], b, b_inv);
        tabr[@as(usize, @intCast(i))] = step.quotient;
        r = step.remainder;
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

// ============================================================
// Radix powers and log
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

/// `a^b` normalised to the top bit, with the shift applied and the
/// reciprocal `udiv1norm` needs.
const NormalizedPower = struct { value: u32, inverse: u32, shift: i32 };

fn powUiInv(a: u32, b: u32) NormalizedPower {
    if (a == 5 and b >= 1 and b <= 13) {
        var r: u32 = pow5_table[b - 1];
        const shift: i32 = clz32(r);
        r <<= @intCast(shift);
        return .{ .value = r, .inverse = pow5_inv_table[b - 1], .shift = shift };
    }

    const r: u64 = powUi(a, b);
    var r32: u32 = @truncate(r);
    const shift = clz32(r32);
    r32 <<= @intCast(shift);
    return .{ .value = r32, .inverse = udiv1normInit(r32), .shift = shift };
}

// ============================================================
// Integer ASCII
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

fn u32toa(buf: []u8, n: u32) usize {
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

fn i32toa(buf: []u8, n: i32) usize {
    if (n >= 0) {
        return u32toa(buf, @intCast(n));
    }
    buf[0] = '-';
    return u32toa(buf[1..], @bitCast(-%@as(i32, @bitCast(n)))) + 1;
}

fn u64toa(buf: []u8, n: u64) usize {
    if (n < 0x100000000) {
        return u32toa(buf, @truncate(n));
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
        const len = u32toa(q, @truncate(n1));
        q = q[len..];
    }

    var tmp: [9]u8 = undefined;
    u32toaLen(&tmp, @truncate(n2), 9);
    @memcpy(q[0..9], tmp[0..9]);
    q = q[9..];

    return writtenLen(buf, q);
}

fn i64toa(buf: []u8, n: i64) usize {
    if (n >= 0) {
        return u64toa(buf, @intCast(n));
    }
    buf[0] = '-';
    return u64toa(buf[1..], @bitCast(-%@as(i64, @bitCast(n)))) + 1;
}

fn u64toaRadix(buf: []u8, n: u64, radix: u32) usize {
    if (radix == 10) {
        return u64toa(buf, n);
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

// ============================================================
// Scale and round: mantissa × radix^f → 53-bit
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

            var power: NormalizedPower = .{ .value = 0, .inverse = 0, .shift = 0 };
            var n0: i32 = 0;
            var rem: limb_t = 0;
            while (f2 != 0) {
                const n: i32 = minInt(f2, d);
                if (n != n0) {
                    power = powUiInv(@intCast(radix1), @intCast(n));
                    n0 = n;
                }
                const rlen: usize = @intCast(a.len);
                const r = mpDiv1norm(a.tab[0..rlen], a.tab[0..rlen], power.value, 0, power.inverse, power.shift);
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

/// A binary64 mantissa/exponent pair before `buildFloat64` packs it.
const Rounded = struct { mantissa: u64, exponent: i32 };

fn roundToD(a: *MpbMax, e_offset: i32, rnd_mode: i32) Rounded {
    if (a.tab[0] == 0 and a.len == 1) return .{ .mantissa = 0, .exponent = 0 };

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

    return .{ .mantissa = m, .exponent = e_val };
}

fn mulPowRoundToD(a: *MpbMax, radix1: i32, radix_shift: i32, f: i32, rnd_mode: i32) Rounded {
    const e_offset = mulPow(a, radix1, radix_shift, f, false, 55);
    return roundToD(a, e_offset, rnd_mode);
}

// ============================================================
// Digit emission
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
            const offset: usize = @intCast(n_digits);
            // Straight into the destination, as upstream dtoa.c does. A
            // `[9]u8` bounce buffer used to sit here, sized for the only radix
            // that reached this branch: 10, whose `digits_per_limb` is exactly
            // 9. Every other non-power-of-two radix overflows it — radix 3
            // writes 20 digits — so the first caller to pass one would have
            // smashed the stack.
            limbToA(buf[offset..][0..@intCast(n)], r, radix, n);
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
    options: FormatOptions,
) usize {
    var q = q_start;
    const E_max: i32 = if (options.format == .fixed) n_digits else dtoa_max_digits_table[@intCast(radix - 2)] + 4;

    if (options.exp == .enabled or (options.exp == .auto and (E <= -6 or E > E_max))) {
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
        q = q[u32toa(q, @intCast(E2))..];
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

    return writtenLen(buf_start, q);
}

// ============================================================
// dtoa: f64 → digits
// ============================================================

const DtoaScale = struct { P: i32, E: i32 };

fn floatToTextMaxLen(d: f64, radix: i32, n_digits: i32, options: FormatOptions) i32 {
    var n: i32 = 0;

    if (options.format != .frac) {
        if (options.format == .free) {
            n = dtoa_max_digits_table[@intCast(radix - 2)];
        } else {
            n = n_digits;
        }
        if (options.exp == .disabled) {
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

fn writeNonFinite(buf: []u8, sgn: i32, frac: u64) usize {
    var q = buf;
    if (frac == 0) {
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
    return writtenLen(buf, q);
}

/// FORMAT_FREE: shortest digit string that still round-trips to `(m, e)`.
const ShortestDecimal = struct { mantissa: u64, exponent: i32 };

inline fn ryuMulShift64(m: u64, mul: [2]u64, j: u32) u64 {
    // j is always in (64, 128) for binary64.
    const b0 = @as(u128, m) * mul[0];
    const b2 = @as(u128, m) * mul[1];
    return @intCast(((b0 >> 64) + b2) >> @intCast(j - 64));
}

inline fn ryuLog10Pow2(e: u32) u32 {
    return @intCast((@as(u64, e) * 169464822037455) >> 49);
}

inline fn ryuLog10Pow5(e: u32) u32 {
    return @intCast((@as(u64, e) * 196742565691928) >> 48);
}

inline fn ryuPow5Bits(e: u32) u32 {
    return @intCast(((@as(u64, e) * 163391164108059) >> 46) + 1);
}

fn ryuPow5Factor(value_in: u64) u32 {
    var value = value_in;
    var count: u32 = 0;
    while (value > 0) : ({
        count += 1;
        value /= 5;
    }) {
        if (value % 5 != 0) return count;
    }
    return 0;
}

inline fn ryuMultipleOfPowerOf5(value: u64, p: u32) bool {
    return ryuPow5Factor(value) >= p;
}

inline fn ryuMultipleOfPowerOf2(value: u64, p: u32) bool {
    return (value & ((@as(u64, 1) << @intCast(p)) - 1)) == 0;
}

/// Ryu shortest round-trip decimal for a finite, non-zero binary64 given as
/// its raw IEEE bits: `mantissa * 10^exponent`, the shortest digit string
/// that parses back to the same double and, among those, the closest (ties
/// to even). Same answer as `dtoaShortest` in radix 10, without the bignum
/// trials. Structure follows the reference `d2d` (Adams 2018).
fn shortestDecimalRyu(bits: u64) ShortestDecimal {
    const mantissa_bits = 52;
    const bias = 1023;
    const ieee_mantissa = bits & ((@as(u64, 1) << mantissa_bits) - 1);
    const ieee_exponent: u32 = @intCast((bits >> mantissa_bits) & 0x7ff);

    var e2: i32 = undefined;
    var m2: u64 = undefined;
    if (ieee_exponent == 0) {
        e2 = 1 - bias - mantissa_bits - 2;
        m2 = ieee_mantissa;
    } else {
        e2 = @as(i32, @intCast(ieee_exponent)) - bias - mantissa_bits - 2;
        m2 = (@as(u64, 1) << mantissa_bits) | ieee_mantissa;
    }
    const accept_bounds = (m2 & 1) == 0;

    // Interval of decimals that round to this double, scaled by 4.
    const mv = 4 * m2;
    const mm_shift: u1 = @intFromBool(ieee_mantissa != 0 or ieee_exponent <= 1);

    var vr: u64 = undefined;
    var vp: u64 = undefined;
    var vm: u64 = undefined;
    var e10: i32 = undefined;
    var vm_is_trailing_zeros = false;
    var vr_is_trailing_zeros = false;
    if (e2 >= 0) {
        const q: u32 = ryuLog10Pow2(@intCast(e2)) - @intFromBool(e2 > 3);
        e10 = @intCast(q);
        const k: i32 = @intCast(RYU_POW5_INV_BITCOUNT + ryuPow5Bits(q) - 1);
        const i: u32 = @intCast(-e2 + @as(i32, @intCast(q)) + k);
        const pow5 = ryu_pow5_inv_split[q];
        vr = ryuMulShift64(mv, pow5, i);
        vp = ryuMulShift64(mv + 2, pow5, i);
        vm = ryuMulShift64(mv - 1 - mm_shift, pow5, i);
        if (q <= 21) {
            if (mv % 5 == 0) {
                vr_is_trailing_zeros = ryuMultipleOfPowerOf5(mv, q);
            } else if (accept_bounds) {
                vm_is_trailing_zeros = ryuMultipleOfPowerOf5(mv - 1 - mm_shift, q);
            } else {
                vp -= @intFromBool(ryuMultipleOfPowerOf5(mv + 2, q));
            }
        }
    } else {
        const q: u32 = ryuLog10Pow5(@intCast(-e2)) - @intFromBool(-e2 > 1);
        e10 = @as(i32, @intCast(q)) + e2;
        const i: i32 = -e2 - @as(i32, @intCast(q));
        const k: i32 = @as(i32, @intCast(ryuPow5Bits(@intCast(i)))) - RYU_POW5_BITCOUNT;
        const j: u32 = @intCast(@as(i32, @intCast(q)) - k);
        const pow5 = ryu_pow5_split[@intCast(i)];
        vr = ryuMulShift64(mv, pow5, j);
        vp = ryuMulShift64(mv + 2, pow5, j);
        vm = ryuMulShift64(mv - 1 - mm_shift, pow5, j);
        if (q <= 1) {
            vr_is_trailing_zeros = true;
            if (accept_bounds) {
                vm_is_trailing_zeros = mm_shift == 1;
            } else {
                vp -= 1;
            }
        } else if (q < 63) {
            vr_is_trailing_zeros = ryuMultipleOfPowerOf2(mv, q);
        }
    }

    // Shortest representation inside the interval.
    var removed: i32 = 0;
    var last_removed_digit: u8 = 0;
    if (vm_is_trailing_zeros or vr_is_trailing_zeros) {
        while (vp / 10 > vm / 10) {
            vm_is_trailing_zeros = vm_is_trailing_zeros and vm % 10 == 0;
            vr_is_trailing_zeros = vr_is_trailing_zeros and last_removed_digit == 0;
            last_removed_digit = @intCast(vr % 10);
            vr /= 10;
            vp /= 10;
            vm /= 10;
            removed += 1;
        }
        if (vm_is_trailing_zeros) {
            while (vm % 10 == 0) {
                vr_is_trailing_zeros = vr_is_trailing_zeros and last_removed_digit == 0;
                last_removed_digit = @intCast(vr % 10);
                vr /= 10;
                vp /= 10;
                vm /= 10;
                removed += 1;
            }
        }
        if (vr_is_trailing_zeros and last_removed_digit == 5 and vr % 2 == 0) {
            last_removed_digit = 4; // exactly halfway, round to even
        }
        const round_up = (vr == vm and (!accept_bounds or !vm_is_trailing_zeros)) or last_removed_digit >= 5;
        return .{ .mantissa = vr + @intFromBool(round_up), .exponent = e10 + removed };
    }
    // Common case: no trailing-zero bookkeeping needed.
    while (vp / 10 > vm / 10) {
        last_removed_digit = @intCast(vr % 10);
        vr /= 10;
        vp /= 10;
        vm /= 10;
        removed += 1;
    }
    const round_up = vr == vm or last_removed_digit >= 5;
    return .{ .mantissa = vr + @intFromBool(round_up), .exponent = e10 + removed };
}

/// Radix-10 FORMAT_FREE via Ryu: digits into `tmp1`, returns `{P, E}` with
/// the same meaning as `dtoaShortest` (value = digits * 10^(E - P)).
fn dtoaShortestDecimal(tmp1: *MpbMax, bits: u64) DtoaScale {
    var dec = shortestDecimalRyu(bits);
    while (dec.mantissa % 10 == 0) {
        dec.mantissa /= 10;
        dec.exponent += 1;
    }
    var P: i32 = 1;
    var scale: u64 = 10;
    while (scale <= dec.mantissa) : (scale *= 10) P += 1;
    mpbSetU64(tmp1, dec.mantissa);
    return .{ .P = P, .E = dec.exponent + P };
}

fn dtoaShortest(tmp1: *MpbMax, m: u64, e: i32, radix: i32, radix1: i32, radix_shift: i32) DtoaScale {
    const P_max: i32 = dtoa_max_digits_table[@intCast(radix - 2)];
    const E0 = 1 + mulLog2Radix(e - 1, radix);
    var E_found: i32 = 0;
    var P_found: i32 = 0;
    var mant_found: u64 = 0;
    var P = P_max;

    while (true) {
        var E = E0;
        while (true) {
            mulPowRound(tmp1, m, e - 53, radix1, radix_shift, P - E, JS_RNDN);
            const mant = mpbGetU64(tmp1);
            const mant_max1 = powUi(@intCast(radix), @intCast(P));
            if (mant < mant_max1) break;
            E += 1;
        }
        var mant2 = mpbGetU64(tmp1);
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
        mpbSetU64(tmp1, mant2);
        const rounded = mulPowRoundToD(tmp1, radix1, radix_shift, E - P, JS_RNDN);
        if (rounded.mantissa == m and rounded.exponent == e) {
            P_found = P;
            E_found = E;
            mant_found = mant2;
            if (P == 1) break;
            P -= 1;
        } else {
            break;
        }
    }
    mpbSetU64(tmp1, mant_found);
    return .{ .P = P_found, .E = E_found };
}

/// FORMAT_FRAC: `n_digits` digits after the radix point (toFixed).
fn dtoaFrac(q: []u8, tmp1: *MpbMax, m: u64, e: i32, E: i32, radix: i32, radix1: i32, radix_shift: i32, n_digits: i32) []u8 {
    mulPowRound(tmp1, m, e - 53, radix1, radix_shift, n_digits, JS_RNDNA);
    const tot = maxInt(E + 1, @as(i32, 1)) + n_digits;
    const dot = maxInt(E + 1, @as(i32, 1));
    const out_len = outputDigits(q, tmp1, radix, tot, dot);
    if (q[0] == '0' and out_len >= 2 and q[1] != '.') {
        std.mem.copyForwards(u8, q[0 .. out_len - 1], q[1..out_len]);
        return q[out_len - 1 ..];
    }
    return q[out_len..];
}

/// FORMAT_FIXED: `P` significant digits. Returns the adjusted exponent E.
fn dtoaFixed(tmp1: *MpbMax, mant_max: *MpbMax, m: u64, e: i32, E_in: i32, radix1: i32, radix_shift: i32, P: i32) i32 {
    var E = E_in;
    mant_max.len = 1;
    mant_max.tab[0] = 1;
    const pow_shift = mulPow(mant_max, radix1, radix_shift, P, false, 0);
    mpbShrRound(mant_max, pow_shift, JS_RNDZ);

    while (true) {
        mulPowRound(tmp1, m, e - 53, radix1, radix_shift, P - E, JS_RNDNA);
        if (mpbCmp(tmp1, mant_max) < 0) break;
        E += 1;
    }
    return E;
}

fn floatToText(buf: []u8, d: f64, radix: i32, n_digits: i32, options: FormatOptions, tmp_mem: *FormatScratch) usize {
    var mptr: [*]u64 = &tmp_mem.mem;
    const tmp1 = dtoaMalloc(MpbMax, &mptr);
    const mant_max_small = dtoaMalloc(Mpb(MANT_LEN_MAX), &mptr);
    const mant_max: *MpbMax = @ptrCast(mant_max_small);

    const radix_shift = ctz32(@intCast(radix));
    const radix1: i32 = radix >> @intCast(radix_shift);
    const a = float64AsUint64(d);
    const sgn = @as(i32, @intCast(a >> 63));
    var e: i32 = @intCast((a >> 52) & 0x7ff);
    var m = a & ((@as(u64, 1) << 52) - 1);
    var q = buf;

    if (e == 0x7ff) return writeNonFinite(buf, sgn, m);

    if (e == 0) {
        if (m == 0) {
            tmp1.len = 1;
            tmp1.tab[0] = 0;
            const E: i32 = 1;
            const P: i32 = switch (options.format) {
                .free => 1,
                .frac => n_digits + 1,
                .fixed => n_digits,
            };
            if (sgn != 0 and options.minus_zero) {
                q[0] = '-';
                q = q[1..];
            }
            return outputHelper(q, buf, tmp1, radix, radix1, radix_shift, P, E, n_digits, options);
        }
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

    if (options.format == .free and
        e >= 1 and e <= 53 and
        (m & ((@as(u64, 1) << @intCast(53 - e)) - 1)) == 0 and
        options.exp != .enabled)
    {
        const m_shifted = m >> @intCast(53 - e);
        const len = u64toaRadix(q, m_shifted, @intCast(radix));
        q = q[len..];
        return writtenLen(buf, q);
    }

    var E = 1 + mulLog2Radix(e - 1, radix);
    var P: i32 = 0;

    if (options.format == .free) {
        const scale = if (radix == 10) dtoaShortestDecimal(tmp1, a) else dtoaShortest(tmp1, m, e, radix, radix1, radix_shift);
        P = scale.P;
        E = scale.E;
    } else if (options.format == .frac) {
        return writtenLen(buf, dtoaFrac(q, tmp1, m, e, E, radix, radix1, radix_shift, n_digits));
    } else {
        P = n_digits;
        E = dtoaFixed(tmp1, mant_max, m, e, E, radix1, radix_shift, P);
    }

    return outputHelper(q, buf, tmp1, radix, radix1, radix_shift, P, E, n_digits, options);
}

// ============================================================
// atod: digits → f64
// ============================================================

/// True when all eight bytes of the little-endian word are '0'..'9'.
inline fn isEightAsciiDigits(v: u64) bool {
    const a = v +% 0x4646_4646_4646_4646;
    const b = v -% 0x3030_3030_3030_3030;
    return ((a | b) & 0x8080_8080_8080_8080) == 0;
}

/// Value of eight ASCII digits held little-endian in `v` (first byte is the
/// most significant digit). Standard SWAR reduction: pairs, then quads, then
/// the two halves. Precondition: `isEightAsciiDigits(v)`.
inline fn parseEightAsciiDigits(v_in: u64) u64 {
    var v = v_in -% 0x3030_3030_3030_3030;
    v = (v * 10) + (v >> 8);
    const mask: u64 = 0x0000_00ff_0000_00ff;
    const v1 = (v & mask) *% 0x000f_4240_0000_0064;
    const v2 = ((v >> 16) & mask) *% 0x0000_2710_0000_0001;
    return @as(u32, @truncate((v1 +% v2) >> 32));
}

inline fn toDigit(c: u8) i32 {
    return switch (c) {
        '0'...'9' => @as(i32, c) - '0',
        'A'...'Z' => @as(i32, c) - 'A' + 10,
        'a'...'z' => @as(i32, c) - 'a' + 10,
        else => 36,
    };
}

const ExponentScan = struct {
    p: []const u8,
    expn: i32 = 0,
    overflow: bool = false,
    is_bin_exp: bool = false,
};

fn parseExponent(
    p: []const u8,
    p_start: []const u8,
    radix: i32,
    radix_bits: i32,
    flags: ParseFlags,
    sep: i32,
) ExponentScan {
    if (flags.int_only or p.len == 0 or p.ptr == p_start.ptr) {
        return .{ .p = p };
    }

    const c0 = p[0];
    const has_exp = (radix == 10 and (c0 == 'e' or c0 == 'E')) or
        (radix != 10 and flags.accept_radix_fraction and (c0 == '@' or (radix_bits >= 1 and radix_bits <= 4 and (c0 == 'p' or c0 == 'P'))));
    if (!has_exp) return .{ .p = p };

    var rest = p[1..];
    var exp_is_neg = false;
    if (rest.len > 0 and rest[0] == '+') {
        rest = rest[1..];
    } else if (rest.len > 0 and rest[0] == '-') {
        exp_is_neg = true;
        rest = rest[1..];
    }
    // js_atof: an exponent marker without digits is not part of the number
    // (`parseFloat("1e")` is 1); dtoa.c's own `goto fail` never sees it.
    if (rest.len == 0 or toDigit(rest[0]) >= 10) {
        return .{ .p = p };
    }

    var expn = toDigit(rest[0]);
    rest = rest[1..];
    var expn_overflow = false;
    while (rest.len > 0) {
        if (@as(i32, rest[0]) == sep and rest.len > 1 and toDigit(rest[1]) < 10)
            rest = rest[1..];
        const c1 = toDigit(rest[0]);
        if (c1 >= 10) break;
        if (!expn_overflow) {
            if (expn > (@as(i32, std.math.maxInt(i32)) - 2 - 9) / 10) {
                expn_overflow = true;
            } else {
                expn = expn * 10 + c1;
            }
        }
        rest = rest[1..];
    }
    if (exp_is_neg) expn = -expn;
    return .{
        .p = rest,
        .expn = expn,
        .overflow = expn_overflow,
        .is_bin_exp = (c0 == 'p' or c0 == 'P'),
    };
}

/// Binary64 bits of `mant * 10^exp10` when both operands are exact binary64
/// values, so the one IEEE operation is the one rounding. Covers every
/// literal with at most 15 digits and |exp10| <= 22, plus the "disguised"
/// case where shifting digits into the mantissa keeps it below 2^53.
fn convertClinger(mant: u64, exp10: i32) ?u64 {
    const max_mant: u64 = @as(u64, 1) << 53;
    if (mant > max_mant) return null;
    var m = mant;
    var e = exp10;
    if (e > CLINGER_MAX_EXP10) {
        // Disguised fast path: move digits from the exponent into the
        // mantissa while it stays below 2^53. 10^16 already exceeds 2^53,
        // so larger shifts cannot work (and 10^20 would not fit a u64).
        const shift = e - CLINGER_MAX_EXP10;
        if (shift > 15) return null;
        var pow10: u64 = 1;
        for (0..@intCast(shift)) |_| pow10 *= 10;
        const scaled = @mulWithOverflow(m, pow10);
        if (scaled[1] != 0 or scaled[0] > max_mant) return null;
        m = scaled[0];
        e = CLINGER_MAX_EXP10;
    } else if (e < -CLINGER_MAX_EXP10) {
        return null;
    }
    const f: f64 = @floatFromInt(m);
    const r = if (e < 0) f / clinger_pow10[@intCast(-e)] else f * clinger_pow10[@intCast(e)];
    return @bitCast(r);
}

/// Eisel-Lemire (Lemire 2021, "Number Parsing at a Gigabyte per Second",
/// sections 5-6): binary64 bits of `w * 10^q` for any 64-bit `w`, or null
/// when the 128-bit product cannot prove the rounding and the bignum must
/// decide. Structure follows the reference implementation in fast_float.
fn convertEiselLemire(q: i32, w_in: u64) ?u64 {
    const mantissa_bits = 52;
    const min_exp2 = -1023;
    const infinite_power = 0x7ff;
    var w = w_in;
    if (w == 0 or q < EL_Q_MIN) return 0;
    if (q > EL_Q_MAX) return @as(u64, infinite_power) << mantissa_bits;

    const lz: u6 = @intCast(@clz(w));
    w <<= lz;

    // 128-bit approximation of w * 5^q; a second multiply only when the
    // low word does not settle the bits we keep (mantissa + 3 precision).
    const mask: u64 = 0xffff_ffff_ffff_ffff >> (mantissa_bits + 3);
    const pow5 = el_pow5_128[@intCast(q - EL_Q_MIN)];
    var prod: u128 = @as(u128, w) * pow5[0];
    var hi: u64 = @truncate(prod >> 64);
    var lo: u64 = @truncate(prod);
    if (hi & mask == mask) {
        prod = @as(u128, w) * pow5[1];
        const second_hi: u64 = @truncate(prod >> 64);
        lo +%= second_hi;
        if (second_hi > lo) hi += 1;
    }
    if (lo == 0xffff_ffff_ffff_ffff and (q < -27 or q > 55)) return null;

    const upper_bit: i32 = @intCast(hi >> 63);
    const drop: u6 = @intCast(upper_bit + 64 - mantissa_bits - 3);
    var mantissa: u64 = hi >> drop;
    var power2: i32 = ((q *% (152170 + 65536)) >> 16) + 63 + upper_bit - @as(i32, lz) - min_exp2;
    if (power2 <= 0) {
        if (-power2 + 1 >= 64) return 0;
        mantissa >>= @intCast(-power2 + 1);
        mantissa += mantissa & 1;
        mantissa >>= 1;
        const carried: u64 = @intFromBool(mantissa >= (@as(u64, 1) << mantissa_bits));
        return (carried << mantissa_bits) | (mantissa & ((@as(u64, 1) << mantissa_bits) - 1));
    }
    // Exact halfway between two binary64 values with an even basis: do not
    // round up. Only possible when 5^q fits in 64 bits (q in [-4, 23]).
    if (lo <= 1 and q >= -4 and q <= 23 and mantissa & 3 == 1 and (mantissa << drop) == hi) {
        mantissa &= ~@as(u64, 1);
    }
    mantissa += mantissa & 1;
    mantissa >>= 1;
    if (mantissa >= (@as(u64, 2) << mantissa_bits)) {
        mantissa = @as(u64, 1) << mantissa_bits;
        power2 += 1;
    }
    mantissa &= ~(@as(u64, 1) << mantissa_bits);
    if (power2 >= infinite_power) return @as(u64, infinite_power) << mantissa_bits;
    return (@as(u64, @intCast(power2)) << mantissa_bits) | mantissa;
}

/// Replay `digit_count` decimal digits held in `mant` through the same
/// `mpbMul1Base` calls the limb loop performs (9 digits per limb), leaving the
/// incomplete trailing group in `cur_limb` / `limb_digit_count` so the caller
/// can keep appending or flush it. Keeps the bignum state bit-identical to the
/// upstream loop.
/// Digits of a decimal mantissa that did not fill a whole limb yet.
const PendingLimb = struct { limb: limb_t, digit_count: i32 };

/// Push the full limbs of `mant` into `tmp0` and return the partial tail.
fn replayMantissa(tmp0: *MpbMax, mant: u64, digit_count: i32) PendingLimb {
    const digits_per_limb: i32 = 9;
    const radix_base: limb_t = 1_000_000_000;
    var full_limbs = @divTrunc(digit_count, digits_per_limb);
    const tail_digits = @rem(digit_count, digits_per_limb);
    const tail_pow: u64 = @intFromFloat(clinger_pow10[@intCast(tail_digits)]);
    var head: u64 = mant / tail_pow;
    // Emit the full limbs most significant first.
    var divisor: u64 = 1;
    var k: i32 = 1;
    while (k < full_limbs) : (k += 1) divisor *= radix_base;
    while (full_limbs > 0) : (full_limbs -= 1) {
        mpbMul1Base(tmp0, radix_base, @truncate(head / divisor));
        head %= divisor;
        divisor /= radix_base;
    }
    return .{ .limb = @truncate(mant % tail_pow), .digit_count = tail_digits };
}

/// Radix-10 conversion for inputs whose significant digits fit `mant`
/// (at most FAST_MANTISSA_DIGITS). Null means "let the bignum decide".
fn convertDecimalFast(mant: u64, exp10: i32) ?u64 {
    if (convertClinger(mant, exp10)) |bits| return bits;
    return convertEiselLemire(exp10, mant);
}

fn convertBignumToBits(
    tmp0: *MpbMax,
    radix: i32,
    radix1: i32,
    radix_shift: i32,
    radix_bits: i32,
    digit_count: i32,
    expn: i32,
    expn_offset: i32,
    expn_overflow: bool,
    is_bin_exp: bool,
    is_zero: bool,
) u64 {
    if (is_zero) return 0;
    if (expn_overflow) {
        return if (expn < 0) 0 else @as(u64, 0x7ff) << 52;
    }

    if (radix_bits != 0) {
        var expn_adj = expn;
        if (!is_bin_exp) expn_adj *= radix_bits;
        expn_adj -= expn_offset * radix_bits;
        const expn1 = expn_adj + digit_count * radix_bits;
        if (expn1 >= 1024 + radix_bits) return @as(u64, 0x7ff) << 52;
        if (expn1 <= -1075) return 0;
        const rounded = roundToD(tmp0, -expn_adj, JS_RNDN);
        return buildFloat64(rounded.mantissa, rounded.exponent);
    }

    const expn_adj = expn - expn_offset;
    const expn1 = expn_adj + digit_count;
    if (expn1 >= max_exponent[@intCast(radix - 2)] + 1) return @as(u64, 0x7ff) << 52;
    if (expn1 <= min_exponent[@intCast(radix - 2)]) return 0;
    const rounded = mulPowRoundToD(tmp0, radix1, radix_shift, expn_adj, JS_RNDN);
    return buildFloat64(rounded.mantissa, rounded.exponent);
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

fn finishParse(a: u64, is_neg: i32, str: []const u8, rest: []const u8) Parsed {
    var a2 = a;
    a2 |= @as(u64, @intCast(is_neg)) << 63;
    return .{ .value = uint64AsFloat64(a2), .len = str.len - rest.len };
}

/// Text -> binary64 kernel (dtoa.c `js_atod` plus the `js_atof` scan rules).
/// Returns the value and the number of bytes consumed, or null when no
/// number starts at `str`. Use `parseNumberPrefix`.
fn textToFloat(str: []const u8, radix_arg: u8, flags: ParseFlags, tmp_mem: *ParseScratch) ?Parsed {
    var mptr: [*]u64 = &tmp_mem.mem;
    const tmp0 = dtoaMalloc(MpbMax, &mptr);

    var sep: i32 = if (flags.accept_underscores) @as(i32, '_') else 256;

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

    // js_atof: a radix prefix after a sign is only for parseInt.
    const signed = p.ptr != str.ptr;
    if (p.len > 0 and p[0] == '0' and (!signed or flags.accept_prefix_after_sign)) {
        var no_prefix: bool = false;
        if (p.len >= 2 and (p[1] == 'x' or p[1] == 'X') and (radix == 0 or radix == 16)) {
            p = p[2..];
            radix = 16;
        } else if (p.len >= 2 and (p[1] == 'o' or p[1] == 'O') and radix == 0 and flags.accept_bin_oct) {
            p = p[2..];
            radix = 8;
        } else if (p.len >= 2 and (p[1] == 'b' or p[1] == 'B') and radix == 0 and flags.accept_bin_oct) {
            p = p[2..];
            radix = 2;
        } else if (p.len >= 2 and p[1] >= '0' and p[1] <= '9' and radix == 0 and flags.accept_legacy_octal) {
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
        } else {
            // Plain `0...`: upstream `goto no_prefix` skips the digit-after-prefix check.
            no_prefix = true;
        }
        if (!no_prefix) {
            if (p.len == 0 or toDigit(p[0]) >= radix) return null;
        }
    } else {
        if (!flags.int_only) {
            if (p.len >= 8 and std.mem.eql(u8, p[0..8], "Infinity")) {
                p = p[8..];
                return finishParse(@as(u64, 0x7ff) << 52, is_neg, str, p);
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
    // Radix 10: the first FAST_MANTISSA_DIGITS significant digits live in `mant`;
    // on the next digit they are replayed into tmp0 exactly as the limb loop
    // would have built it (two full 9-digit limbs, one digit pending).
    var mant: u64 = 0;

    while (p.len > 0) {
        if (p[0] == '.' and (p.ptr != p_start.ptr or (p.len > 1 and toDigit(p[1]) < radix)) and !flags.int_only and (radix == 10 or flags.accept_radix_fraction)) {
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
        if (p[0] == '.' and (p.ptr != p_start.ptr or (p.len > 1 and toDigit(p[1]) < radix)) and !flags.int_only and (radix == 10 or flags.accept_radix_fraction)) {
            if (dot_pos >= 0) break;
            dot_pos = pos;
            p = p[1..];
        }
        if (p.len > 1 and @as(i32, p[0]) == sep and p.ptr != p_start.ptr and toDigit(p[1]) < radix)
            p = p[1..];

        if (p.len == 0) break;
        // Radix 10: swallow a run of digit bytes into `mant` while they fit,
        // eight at a time and then singly. A digit byte is never '.' or the
        // separator, so this equals the same number of trips through the
        // generic body below; whatever stops the run is handled there.
        if (radix == 10) {
            const run_start = pos;
            while (p.len >= 8 and digit_count + 8 <= FAST_MANTISSA_DIGITS) {
                const word = std.mem.readInt(u64, p[0..8], .little);
                if (!isEightAsciiDigits(word)) break;
                mant = mant * 100_000_000 + parseEightAsciiDigits(word);
                digit_count += 8;
                pos += 8;
                p = p[8..];
            }
            while (p.len > 0 and digit_count < FAST_MANTISSA_DIGITS) {
                const d = p[0] -% '0';
                if (d > 9) break;
                mant = mant * 10 + d;
                digit_count += 1;
                pos += 1;
                p = p[1..];
            }
            // Back to the loop head so '.' / separator get their checks.
            if (pos != run_start) continue;
        }
        const c = toDigit(p[0]);
        if (c >= radix) break;
        p = p[1..];
        pos += 1;
        if (digit_count < max_digits) {
            // Radix 10 only reaches here once `mant` is full: hand its digits
            // to the bignum and continue with the upstream limb scheme.
            if (radix == 10 and digit_count == FAST_MANTISSA_DIGITS) {
                const pending = replayMantissa(tmp0, mant, digit_count);
                cur_limb = pending.limb;
                limb_digit_count = pending.digit_count;
            }
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

    const exp = parseExponent(p, p_start, radix, radix_bits, flags, sep);
    p = exp.p;

    if (p.ptr == p_start.ptr) return null;

    if (radix == 10 and !is_zero and digit_count <= FAST_MANTISSA_DIGITS) {
        if (!exp.overflow) {
            if (convertDecimalFast(mant, exp.expn - expn_offset)) |bits| {
                return finishParse(bits, is_neg, str, p);
            }
        }
        // Bignum must decide: give it the digits the limb loop would have built.
        const pending = replayMantissa(tmp0, mant, digit_count);
        if (pending.digit_count != 0) {
            mpbMul1Base(tmp0, @truncate(powUi(10, @intCast(pending.digit_count))), pending.limb);
        }
    }

    const a_ret = convertBignumToBits(
        tmp0,
        radix,
        radix1,
        radix_shift,
        radix_bits,
        digit_count,
        exp.expn,
        expn_offset,
        exp.overflow,
        exp.is_bin_exp,
        is_zero,
    );
    return finishParse(a_ret, is_neg, str, p);
}

// ============================================================
// Tests
// ============================================================

test "dtoa functionality" {
    const n = parseNumberExact("12.5", 10, .{}).?;
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("12.5", try formatNumber(&buf, n));
    try std.testing.expect(std.math.isPositiveInf(parseNumberExact("+Infinity", 10, .{}).?));
}

test "textToFloat underscore separator stops at end of input" {
    // Regression: `1_` must parse the `1` and stop at `_`, not read past the
    // end of the slice.
    const parsed = parseNumberPrefix("1_", 10, .{ .accept_underscores = true });
    try std.testing.expectEqual(@as(f64, 1), parsed.value);
    try std.testing.expectEqual(@as(usize, 1), parsed.len);
}

test "formatInt32 formatInt64" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0", formatInt32(&buf, 0));
    try std.testing.expectEqualStrings("-2147483648", formatInt32(&buf, std.math.minInt(i32)));
    try std.testing.expectEqualStrings("9223372036854775807", formatInt64(&buf, std.math.maxInt(i64)));
    try std.testing.expectEqualStrings("-9223372036854775808", formatInt64(&buf, std.math.minInt(i64)));
}

test "formatRadix round-trips odd and power-of-two radices" {
    const values = [_]f64{ 0.1, 1.5, 123456.789, -2.5e-7, 1e300, 3.0 };
    const radices = [_]u8{ 2, 3, 7, 10, 16, 36 };
    var buf: [2200]u8 = undefined;
    for (values) |v| {
        for (radices) |radix| {
            const text = try formatRadix(&buf, v, radix, 0, .{});
            const back = parseNumberExact(text, radix, .{ .accept_radix_fraction = true }).?;
            try std.testing.expectEqual(v, back);
        }
    }
}

test "formatDtoaChecked FRAC FIXED and EXP" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("1.50", try formatDtoaChecked(&buf, 1.5, 2, .{ .format = .frac }));
    try std.testing.expectEqualStrings("1.2e+2", try formatDtoaChecked(&buf, 123.0, 2, .{ .format = .fixed, .exp = .enabled }));
    try std.testing.expectEqualStrings("123", try formatDtoaChecked(&buf, 123.0, 3, .{ .format = .fixed, .exp = .disabled }));
}

test "decimal fast path agrees with the correctly rounded reference" {
    // Clinger, disguised Clinger, Eisel-Lemire, its bignum fallback (exact
    // halfway cases), subnormal boundaries, and the 19/20-digit spill.
    const cases = [_][]const u8{
        "7",                                                       "12345",                   "3.14159",
        "0.1",                                                     "1e-7",                    "2.718281828459045",
        "123e25",                                                  "9007199254740993",        "9007199254740992.5",
        "1.7976931348623157e308",                                  "1.7976931348623158e308",  "1.7976931348623159e308",
        "4.9406564584124654e-324",                                 "2.4703282292062327e-324", "2.4703282292062328e-324",
        "2.2250738585072011e-308",                                 "2.2250738585072012e-308", "8.98846567431158e307",
        "1e23",                                                    "1.0000000000000002",      "0.30000000000000004",
        "1234567890123456789",                                     "12345678901234567890",    "1234567890123456789012345678901234567890",
        "1.00000000000000011102230246251565404236316680908203125", "1e-400",                  "1e400",
        "0.000000000000000000000000000000000000001",               "5e42",                    "1e37",
        "9007199254740991e38",                                     "123e30",
    };
    for (cases) |text| {
        const expected = try std.fmt.parseFloat(f64, text);
        const got = parseNumberExact(text, 10, .{}).?;
        try std.testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(got)));
    }
}

test "parseNumberPrefix follows js_atof scan rules" {
    // Stops at the first byte that cannot continue the number.
    const a = parseNumberPrefix("12.5e3xyz", 10, .{});
    try std.testing.expectEqual(@as(f64, 12500), a.value);
    try std.testing.expectEqual(@as(usize, 6), a.len);
    // Exponent marker without digits is not consumed.
    const b = parseNumberPrefix("1e", 10, .{});
    try std.testing.expectEqual(@as(f64, 1), b.value);
    try std.testing.expectEqual(@as(usize, 1), b.len);
    // int_only: the dot is not consumed.
    const c = parseNumberPrefix("42.5", 10, .{ .int_only = true });
    try std.testing.expectEqual(@as(f64, 42), c.value);
    try std.testing.expectEqual(@as(usize, 2), c.len);
    // Negative zero survives the fast path.
    const z = parseNumberPrefix("-0.0", 10, .{});
    try std.testing.expect(z.value == 0 and std.math.signbit(z.value));
    // Prefix after a sign only with the parseInt flag.
    try std.testing.expectEqual(@as(usize, 2), parseNumberPrefix("-0x10", 0, .{}).len);
    try std.testing.expectEqual(@as(f64, -16), parseNumberPrefix("-0x10", 0, .{ .accept_prefix_after_sign = true }).value);
    // Fraction only in radix 10 unless asked for.
    try std.testing.expectEqual(@as(usize, 3), parseNumberPrefix("0x1.8", 0, .{}).len);
    try std.testing.expectEqual(@as(f64, 1.5), parseNumberExact("0x1.8", 0, .{ .accept_radix_fraction = true }).?);
    // Plain leading zero is a number, not a prefix.
    try std.testing.expectEqual(@as(f64, 0), parseNumberExact("0", 0, .{}).?);
    try std.testing.expectEqual(@as(f64, 0.5), parseNumberExact("0.5", 0, .{ .accept_bin_oct = true }).?);
    try std.testing.expectEqual(@as(f64, 10), parseNumberExact("010", 0, .{ .accept_bin_oct = true }).?);
    // Nothing to parse.
    try std.testing.expectEqual(@as(usize, 0), parseNumberPrefix("-", 10, .{}).len);
    try std.testing.expectEqual(@as(usize, 0), parseNumberPrefix(".", 10, .{}).len);
    try std.testing.expectEqual(@as(usize, 0), parseNumberPrefix("", 10, .{}).len);
    try std.testing.expectEqual(@as(usize, 0), parseNumberPrefix("0x", 0, .{}).len);
    // Prefix grammars.
    try std.testing.expectEqual(@as(f64, 10), parseNumberExact("0b1010", 0, .{ .accept_bin_oct = true }).?);
    try std.testing.expectEqual(@as(f64, 15), parseNumberExact("0o17", 0, .{ .accept_bin_oct = true }).?);
    try std.testing.expectEqual(@as(f64, 511), parseNumberExact("0777", 0, .{ .accept_legacy_octal = true }).?);
    try std.testing.expectEqual(@as(f64, 89), parseNumberExact("089", 0, .{ .accept_legacy_octal = true }).?);
    try std.testing.expectEqual(@as(f64, 1000.5), parseNumberExact("1_000.5", 10, .{ .accept_underscores = true }).?);
    try std.testing.expect(parseNumberExact("1_000", 10, .{}) == null);
}

test "shortest decimal is Ryu-exact and round-trips" {
    var buf: [64]u8 = undefined;
    // Asymmetric interval on a power of two: 16 digits suffice (qjs prints 17).
    const p = std.math.ldexp(@as(f64, 1), -1017);
    try std.testing.expectEqualStrings("7.120236347223045e-307", try formatNumber(&buf, p));
    try std.testing.expectEqual(p, parseNumberExact("7.120236347223045e-307", 10, .{}).?);
    // Layout thresholds and classic cases.
    try std.testing.expectEqualStrings("1e+21", try formatNumber(&buf, 1e21));
    try std.testing.expectEqualStrings("100000000000000000000", try formatNumber(&buf, 1e20));
    try std.testing.expectEqualStrings("1e-7", try formatNumber(&buf, 1e-7));
    try std.testing.expectEqualStrings("0.000001", try formatNumber(&buf, 1e-6));
    var tenth: f64 = 0.1;
    _ = &tenth;
    try std.testing.expectEqualStrings("0.30000000000000004", try formatNumber(&buf, tenth + 0.2));
    try std.testing.expectEqualStrings("5e-324", try formatNumber(&buf, 5e-324));
    try std.testing.expectEqualStrings("1.7976931348623157e+308", try formatNumber(&buf, std.math.floatMax(f64)));
    try std.testing.expectEqualStrings("9007199254740992", try formatNumber(&buf, 9007199254740992));
    try std.testing.expectEqualStrings("-2.5", try formatNumber(&buf, -2.5));
    // Every printed double parses back to itself.
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    for (0..20000) |_| {
        const v: f64 = @bitCast(r.int(u64));
        if (!std.math.isFinite(v)) continue;
        const text = try formatNumber(&buf, v);
        try std.testing.expectEqual(v, parseNumberExact(text, 10, .{}).?);
    }
}
