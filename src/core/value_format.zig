const dtoa = @import("../libs/number_format.zig");
const bignum = @import("../libs/bigint.zig");
const std = @import("std");
const BigIntObject = @import("bigint.zig").BigInt;
const JSValue = @import("value.zig").JSValue;

pub fn formatFiniteNumber(buffer: []u8, value: f64) ![]const u8 {
    if (formatSimpleFiniteDecimal(buffer, value)) |text| return text;
    return dtoa.formatNumber(buffer, value);
}

/// Clone a BigInt value into an owned arbitrary-precision integer. Six copies
/// of this existed; `exec.value_ops.cloneBigIntValue` keeps the exec-facing
/// name and forwards here, because `core` cannot import `exec`.
pub fn cloneBigIntValue(allocator: std.mem.Allocator, value: JSValue) !bignum.BigInt {
    if (value.asShortBigInt()) |short| return bignum.BigInt.fromIntAlloc(allocator, short);
    if (value.isBigInt()) {
        if (value.refHeader()) |header| {
            const big: *BigIntObject = @alignCast(@fieldParentPtr("header", header));
            return big.borrowedValue(allocator).cloneWithAllocator(allocator);
        }
    }
    return error.TypeError;
}

pub fn appendBigIntBase10(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), value: JSValue) !void {
    if (value.asShortBigInt()) |bigint_value| {
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

/// ToNumber of a latin1-backed JS string. Each byte is one code point
/// (0x00-0xFF); do not feed the raw sequence to a UTF-8 whitespace decoder.
/// qjs classifies whitespace by CODE POINT after JS_ToCString (skip_spaces
/// qjs:11230, js_atof via JS_ToNumberHintFree qjs:12987-12992).
pub fn parseJsNumberLatin1(bytes: []const u8) f64 {
    return parseJsNumberTrimmed(trimJsWhitespaceLatin1(bytes));
}

fn parseJsNumberTrimmed(trimmed: []const u8) f64 {
    if (trimmed.len == 0) return 0;
    if (std.mem.indexOfScalar(u8, trimmed, '_') != null) return std.math.nan(f64);
    if (hasSignedRadixPrefix(trimmed)) return std.math.nan(f64);
    if (std.mem.eql(u8, trimmed, "Infinity") or std.mem.eql(u8, trimmed, "+Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, trimmed, "-Infinity")) return -std.math.inf(f64);
    if (trimmed.len >= 2 and trimmed[0] == '0' and (trimmed[1] == 'x' or trimmed[1] == 'X')) {
        return parseRadixPrefixedDigits(trimmed[2..], 16);
    }
    if (trimmed.len >= 2 and trimmed[0] == '0' and (trimmed[1] == 'o' or trimmed[1] == 'O')) {
        return parseRadixPrefixedDigits(trimmed[2..], 8);
    }
    if (trimmed.len >= 2 and trimmed[0] == '0' and (trimmed[1] == 'b' or trimmed[1] == 'B')) {
        return parseRadixPrefixedDigits(trimmed[2..], 2);
    }
    const parsed = std.fmt.parseFloat(f64, trimmed) catch return std.math.nan(f64);
    if (std.math.isInf(parsed) and beginsWithAsciiAlphaAfterSign(trimmed)) return std.math.nan(f64);
    return parsed;
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
/// and StringToBigInt, mirroring qjs `skip_spaces` (quickjs.c:11230) which is
/// shared by `js_atof` and `JS_StringToBigInt` (quickjs.c:14609): ASCII
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
/// `lre_is_space` (libunicode.h:162) classifies by code point, never by
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

fn startsWith(bytes: []const u8, prefix: []const u8) bool {
    return bytes.len >= prefix.len and std.mem.eql(u8, bytes[0..prefix.len], prefix);
}

fn endsWith(bytes: []const u8, suffix: []const u8) bool {
    return bytes.len >= suffix.len and std.mem.eql(u8, bytes[bytes.len - suffix.len ..], suffix);
}

/// Digits of a 0x/0o/0b literal for ToNumber(string). Exact through u128
/// (one correctly-rounded int->double conversion); wider literals keep
/// accumulating in f64, mirroring qjs js_atod's accumulate-into-double
/// behaviour instead of failing to NaN.
fn parseRadixPrefixedDigits(digits: []const u8, comptime radix: u8) f64 {
    if (digits.len == 0) return std.math.nan(f64);
    var wide: u128 = 0;
    var overflowed = false;
    var value: f64 = 0;
    for (digits) |ch| {
        const digit: u8 = switch (ch) {
            '0'...'9' => ch - '0',
            'a'...'f' => ch - 'a' + 10,
            'A'...'F' => ch - 'A' + 10,
            else => return std.math.nan(f64),
        };
        if (digit >= radix) return std.math.nan(f64);
        if (!overflowed) {
            const mul = @mulWithOverflow(wide, radix);
            const add = @addWithOverflow(mul[0], digit);
            if (mul[1] == 0 and add[1] == 0) {
                wide = add[0];
                continue;
            }
            overflowed = true;
            value = @floatFromInt(wide);
        }
        value = value * @as(f64, @floatFromInt(radix)) + @as(f64, @floatFromInt(digit));
    }
    if (!overflowed) return @floatFromInt(wide);
    return value;
}

fn hasSignedRadixPrefix(bytes: []const u8) bool {
    return bytes.len >= 3 and (bytes[0] == '+' or bytes[0] == '-') and bytes[1] == '0' and
        (bytes[2] == 'x' or bytes[2] == 'X' or bytes[2] == 'o' or bytes[2] == 'O' or bytes[2] == 'b' or bytes[2] == 'B');
}

fn beginsWithAsciiAlphaAfterSign(bytes: []const u8) bool {
    const index: usize = if (bytes.len > 0 and (bytes[0] == '+' or bytes[0] == '-')) 1 else 0;
    return index < bytes.len and ((bytes[index] >= 'a' and bytes[index] <= 'z') or (bytes[index] >= 'A' and bytes[index] <= 'Z'));
}
