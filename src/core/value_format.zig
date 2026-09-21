//! Allocation-bounded ECMAScript Number/BigInt parsing and formatting helpers.
//!
//! Fixed-buffer Number paths borrow caller storage; BigInt clone/format paths
//! return or temporarily allocate explicitly-owned library values. JSValue
//! inputs remain borrowed throughout. The routines centralize QuickJS-compatible
//! `ToNumber` whitespace rules and hand the digits to `libs/number_format`
//! (`parseNumberPrefix` / `formatNumber`). This core conversion leaf may import core/libs,
//! never parser/exec/runtime/binding.

const dtoa = @import("../libs/number_format.zig");
const bignum = @import("../libs/bigint.zig");
const std = @import("std");
const BigIntObject = @import("bigint.zig").BigInt;
const JSValue = @import("value.zig").JSValue;

pub fn formatFiniteNumber(buffer: []u8, value: f64) ![]const u8 {
    if (formatSimpleFiniteDecimal(buffer, value)) |text| return text;
    return dtoa.formatNumber(buffer, value);
}

/// ECMAScript's finite Number string fits in 64 bytes. Engine callers with at
/// least that much fixed storage use this form so the caller-sized-buffer
/// `NoSpaceLeft` error cannot pollute the runtime transport surface.
pub fn formatFiniteNumberAssumeCapacity(buffer: []u8, value: f64) []const u8 {
    std.debug.assert(buffer.len >= 64);
    return formatFiniteNumber(buffer, value) catch unreachable;
}

/// Clone a BigInt value into an owned arbitrary-precision integer. Six copies
/// of this existed; `exec.value_ops.cloneBigIntValue` keeps the exec-facing
/// name and forwards here, because `core` cannot import `exec`.
pub fn cloneBigIntValue(allocator: std.mem.Allocator, value: JSValue) !bignum.BigInt {
    if (value.as(.short_big_int)) |short| return bignum.BigInt.fromIntAlloc(allocator, short);
    if (value.isBigInt()) {
        if (value.refHeader()) |header| {
            const big: *BigIntObject = @alignCast(@fieldParentPtr("header", header));
            return big.borrowedValue(allocator).cloneWithAllocator(allocator);
        }
    }
    return error.TypeError;
}

pub fn appendBigIntBase10(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), value: JSValue) !void {
    if (value.as(.short_big_int)) |bigint_value| {
        var bigint_buf: [32]u8 = undefined;
        const printed = dtoa.formatInt64(&bigint_buf, bigint_value);
        return buffer.appendSlice(allocator, printed);
    }
    if (!value.isBigInt()) return error.TypeError;
    const header = value.refHeader() orelse return error.TypeError;
    const big: *BigIntObject = @alignCast(@fieldParentPtr("header", header));
    const printed = try big.borrowedValue(allocator).formatBase10Alloc(allocator);
    defer allocator.free(printed);
    try buffer.appendSlice(allocator, printed);
}

pub fn parseJsNumber(bytes: []const u8) f64 {
    return parseJsNumberTrimmed(trimJsWhitespace(bytes));
}

/// One `std.fmt.parseInt` body for every host integer width. Callers that
/// used to instantiate `parseInt(T)` for `u8`/`i32`/`i64`/`usize` share
/// this outlined `i128` walk and then range-check.
pub fn parseAsciiInt(comptime T: type, buf: []const u8, base: u8) std.fmt.ParseIntError!T {
    const wide = try parseAsciiIntI128(buf, base);
    if (wide < @as(i128, std.math.minInt(T)) or wide > @as(i128, std.math.maxInt(T))) return error.Overflow;
    return @intCast(wide);
}

noinline fn parseAsciiIntI128(buf: []const u8, base: u8) std.fmt.ParseIntError!i128 {
    return std.fmt.parseInt(i128, buf, base);
}

/// ToNumber of a latin1-backed JS string. Each byte is one code point
/// (0x00-0xFF); do not feed the raw sequence to a UTF-8 whitespace decoder.
/// qjs classifies whitespace by CODE POINT after JS_ToCString (skip_spaces
/// qjs:11230, js_atof via JS_ToNumberHintFree qjs:12987-12992).
pub fn parseJsNumberLatin1(bytes: []const u8) f64 {
    return parseJsNumberTrimmed(trimJsWhitespaceLatin1(bytes));
}

/// StringToNumber after whitespace trimming: qjs `JS_ToNumberHintFree`
/// string arm (`js_atof` with `ATOD_ACCEPT_BIN_OCT`, then the whole string
/// must have been consumed).
fn parseJsNumberTrimmed(trimmed: []const u8) f64 {
    if (trimmed.len == 0) return 0;
    return dtoa.parseNumberExact(trimmed, 0, .{ .accept_bin_oct = true }) orelse std.math.nan(f64);
}

fn formatSimpleFiniteDecimal(buffer: []u8, value: f64) ?[]const u8 {
    if (!std.math.isFinite(value)) return null;
    if (value == 0) return null;
    const abs_value = @abs(value);
    if (abs_value < 1e-6 or abs_value >= 1e21) return null;

    const scaled = value * 10.0;
    if (!std.math.isFinite(scaled)) return null;
    if (@abs(scaled) > 9007199254740991.0) return null;
    if (@trunc(scaled) != scaled) return null;

    const scaled_int: i64 = @intFromFloat(scaled);
    if (@as(f64, @floatFromInt(scaled_int)) / 10.0 != value) return null;
    const sign_len: usize = if (scaled_int < 0) 1 else 0;
    const magnitude: u64 = @intCast(if (scaled_int < 0) -scaled_int else scaled_int);
    const integer = magnitude / 10;
    const fraction: u8 = @intCast(magnitude % 10);

    if (fraction == 0) {
        const needed = sign_len + 20;
        if (buffer.len < needed) return null;
        var temp: [32]u8 = undefined;
        const digits = dtoa.formatInt64(&temp, @intCast(integer));
        if (sign_len + digits.len > buffer.len) return null;
        var index: usize = 0;
        if (scaled_int < 0) {
            buffer[index] = '-';
            index += 1;
        }
        @memcpy(buffer[index .. index + digits.len], digits);
        return buffer[0 .. index + digits.len];
    }

    var temp: [32]u8 = undefined;
    const digits = dtoa.formatInt64(&temp, @intCast(integer));
    const total_len = sign_len + digits.len + 2;
    if (total_len > buffer.len) return null;
    var index: usize = 0;
    if (scaled_int < 0) {
        buffer[index] = '-';
        index += 1;
    }
    @memcpy(buffer[index .. index + digits.len], digits);
    index += digits.len;
    buffer[index] = '.';
    buffer[index + 1] = '0' + fraction;
    return buffer[0..total_len];
}

/// Shared StrWhiteSpaceChar trimmer used by both ToNumber (`parseJsNumber`)
/// and StringToBigInt, mirroring qjs `skip_spaces` which is
/// shared by `js_atof` and `JS_StringToBigInt`: ASCII
/// 0x09-0x0d + 0x20 plus the Unicode space set (NBSP, U+1680, U+2000-200A,
/// U+2028/2029, U+202F, U+205F, U+3000, BOM U+FEFF). `bytes` is UTF-8.
pub fn trimJsWhitespace(bytes: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = bytes.len;
    while (start < end) {
        const width = jsWhitespacePrefixLen(bytes[start..end]) orelse break;
        start += width;
    }
    while (end > start) {
        const width = jsWhitespaceSuffixLen(bytes[start..end]) orelse break;
        end -= width;
    }
    return bytes[start..end];
}

/// Latin1 backing stores one code point per byte. Only ASCII whitespace and
/// U+00A0 (NBSP, latin1 0xA0) are StrWhiteSpaceChar below U+0100; qjs
/// `lre_is_space` classifies by code point, never by
/// treating 0x80-0xFF as a UTF-8 lead byte.
pub fn trimJsWhitespaceLatin1(bytes: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = bytes.len;
    while (start < end) {
        if (!isJsWhitespaceLatin1Byte(bytes[start])) break;
        start += 1;
    }
    while (end > start) {
        if (!isJsWhitespaceLatin1Byte(bytes[end - 1])) break;
        end -= 1;
    }
    return bytes[start..end];
}

inline fn isJsWhitespaceLatin1Byte(byte: u8) bool {
    return switch (byte) {
        0x09...0x0d, 0x20, 0xa0 => true,
        else => false,
    };
}

fn jsWhitespacePrefixLen(bytes: []const u8) ?usize {
    if (bytes.len == 0) return null;
    switch (bytes[0]) {
        0x09...0x0d, 0x20 => return 1,
        0xa0 => return 1,
        0xc2 => if (startsWith(bytes, &.{ 0xc2, 0xa0 })) return 2,
        0xe1 => if (startsWith(bytes, &.{ 0xe1, 0x9a, 0x80 })) return 3,
        0xe2 => {
            if (bytes.len >= 3 and bytes[1] == 0x80 and ((bytes[2] >= 0x80 and bytes[2] <= 0x8a) or bytes[2] == 0xa8 or bytes[2] == 0xa9 or bytes[2] == 0xaf)) return 3;
            if (startsWith(bytes, &.{ 0xe2, 0x81, 0x9f })) return 3;
        },
        0xe3 => if (startsWith(bytes, &.{ 0xe3, 0x80, 0x80 })) return 3,
        0xef => if (startsWith(bytes, &.{ 0xef, 0xbb, 0xbf })) return 3,
        else => {},
    }
    return null;
}

fn jsWhitespaceSuffixLen(bytes: []const u8) ?usize {
    if (bytes.len == 0) return null;
    const last = bytes[bytes.len - 1];
    if ((last >= 0x09 and last <= 0x0d) or last == 0x20) return 1;
    if (endsWith(bytes, &.{ 0xc2, 0xa0 })) return 2;
    if (last == 0xa0) return 1;
    if (endsWith(bytes, &.{ 0xe1, 0x9a, 0x80 })) return 3;
    if (endsWith(bytes, &.{ 0xe2, 0x81, 0x9f })) return 3;
    if (endsWith(bytes, &.{ 0xe3, 0x80, 0x80 })) return 3;
    if (endsWith(bytes, &.{ 0xef, 0xbb, 0xbf })) return 3;
    if (bytes.len >= 3 and bytes[bytes.len - 3] == 0xe2 and bytes[bytes.len - 2] == 0x80) {
        const tail = bytes[bytes.len - 1];
        if ((tail >= 0x80 and tail <= 0x8a) or tail == 0xa8 or tail == 0xa9 or tail == 0xaf) return 3;
    }
    return null;
}

/// The four lowercase hex digits of a `\uXXXX` escape. Both JSON
/// serialization and the inspector emit these per escaped code unit, which is
/// hot enough to stay out of `std.fmt`.
pub fn hex4(unit: u16) [4]u8 {
    const digits = "0123456789abcdef";
    return .{
        digits[(unit >> 12) & 0xf],
        digits[(unit >> 8) & 0xf],
        digits[(unit >> 4) & 0xf],
        digits[unit & 0xf],
    };
}

test "hex4 zero-pads every code unit to four digits" {
    try std.testing.expectEqualStrings("0000", &hex4(0));
    try std.testing.expectEqualStrings("000f", &hex4(0xf));
    try std.testing.expectEqualStrings("00ab", &hex4(0xab));
    try std.testing.expectEqualStrings("1f60", &hex4(0x1f60));
    try std.testing.expectEqualStrings("ffff", &hex4(0xffff));
}

fn startsWith(bytes: []const u8, prefix: []const u8) bool {
    return bytes.len >= prefix.len and std.mem.eql(u8, bytes[0..prefix.len], prefix);
}

fn endsWith(bytes: []const u8, suffix: []const u8) bool {
    return bytes.len >= suffix.len and std.mem.eql(u8, bytes[bytes.len - suffix.len ..], suffix);
}

test "parseAsciiInt shares one walk across host integer widths" {
    try std.testing.expectEqual(@as(usize, 7), try parseAsciiInt(usize, "7", 10));
    try std.testing.expectEqual(@as(i32, -3), try parseAsciiInt(i32, "-3", 10));
    try std.testing.expectEqual(@as(i64, 255), try parseAsciiInt(i64, "0xFF", 0));
    try std.testing.expectEqual(@as(usize, std.math.maxInt(usize)), try parseAsciiInt(usize, "18446744073709551615", 10));
    try std.testing.expectError(error.Overflow, parseAsciiInt(i32, "2147483648", 10));
    try std.testing.expectError(error.Overflow, parseAsciiInt(usize, "18446744073709551616", 10));
    try std.testing.expectError(error.Overflow, parseAsciiInt(usize, "-1", 10));
    try std.testing.expectError(error.Overflow, parseAsciiInt(u8, "256", 10));
    try std.testing.expectError(error.InvalidCharacter, parseAsciiInt(usize, "", 10));
    try std.testing.expectError(error.InvalidCharacter, parseAsciiInt(i32, "1x", 10));
}

test "parseJsNumber keeps 0x 0o 0b prefixes exact and rejects bad digits" {
    try std.testing.expectEqual(@as(f64, 255), parseJsNumber("0xFF"));
    try std.testing.expectEqual(@as(f64, 255), parseJsNumber("0Xff"));
    try std.testing.expectEqual(@as(f64, 15), parseJsNumber("0o17"));
    try std.testing.expectEqual(@as(f64, 10), parseJsNumber("0b1010"));
    try std.testing.expect(std.math.isNan(parseJsNumber("0x")));
    try std.testing.expect(std.math.isNan(parseJsNumber("0o8")));
    try std.testing.expect(std.math.isNan(parseJsNumber("0b2")));
    try std.testing.expect(std.math.isNan(parseJsNumber("0xG")));
    try std.testing.expect(std.math.isNan(parseJsNumber("+0x1")));
    try std.testing.expect(std.math.isNan(parseJsNumber("0x1_0")));
    try std.testing.expect(std.math.isNan(parseJsNumber("0x1.8")));
    try std.testing.expect(std.math.isNan(parseJsNumber("1e")));
    try std.testing.expect(std.math.isNan(parseJsNumber("Infinityx")));
    try std.testing.expect(std.math.isNan(parseJsNumber("inf")));
    try std.testing.expectEqual(@as(f64, 1), parseJsNumber(" 1. "));
    try std.testing.expectEqual(@as(f64, 0.5), parseJsNumber(".5"));
    try std.testing.expectEqual(@as(f64, 10), parseJsNumber("010"));
}
