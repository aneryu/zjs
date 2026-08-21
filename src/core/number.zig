//! Pure number-parsing primitives shared by the `Number.parseInt`/`parseFloat`
//! and global `parseInt`/`parseFloat` fast paths and their bare-runtime
//! fallbacks. These are ASCII -> f64 arithmetic parsers with zero exec/VM
//! dependencies: they only reach `std`, the `libs/{number_format,bigint,unicode}`
//! helpers, and core value/string/object plumbing. The realm-coercing record
//! handler and the `Number.prototype.*` formatting methods live in
//! `src/exec/number_ops.zig`.

const core = @import("root.zig");
const unicode = @import("../libs/unicode.zig");
const std = @import("std");

const AppendStringError = core.value_string.AppendStringError;

fn stringFromValue(value: core.JSValue) ?*core.string.String {
    return value.asStringBody();
}

/// QuickJS source map: global parseInt / Number.parseInt. This is still the
/// narrow subset used by transitional `parse_int` bytecode.
pub fn parseIntValue(rt: *core.JSRuntime, input: core.JSValue, radix_value: ?core.JSValue) !f64 {
    if (input.isString()) {
        const radix = if (radix_value) |value| toInt32(try toNumber(rt, value)) else 0;
        const str = stringFromValue(input).?;
        try str.ensureFlat(rt);
        switch (str.resolveData()) {
            .latin1 => |bytes| return parseIntLatin1Bytes(bytes, radix),
            .utf16 => {},
        }
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendValueString(rt, &bytes, input);

    const radix = if (radix_value) |value| toInt32(try toNumber(rt, value)) else 0;
    // appendValueString emits UTF-8 (qjs JS_ToCStringLen2, quickjs.c:4458);
    // trim UTF-8 whitespace first, then scan the remainder as already-decoded
    // code units. parseIntLatin1Bytes itself treats each byte as a latin1
    // code point and must not re-decode UTF-8 whitespace sequences.
    return parseIntLatin1Bytes(core.value_format.trimJsWhitespace(bytes.items), radix);
}

/// QuickJS source map: global parseFloat / Number.parseFloat. This is still the
/// narrow subset used by transitional `parse_float` bytecode.
pub fn parseFloatValue(rt: *core.JSRuntime, input: core.JSValue) !f64 {
    if (input.isString()) {
        const str = stringFromValue(input).?;
        try str.ensureFlat(rt);
        switch (str.resolveData()) {
            .latin1 => |bytes| return parseFloatLatin1Bytes(bytes),
            .utf16 => {},
        }
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendValueString(rt, &bytes, input);
    return parseFloatLatin1Bytes(core.value_format.trimJsWhitespace(bytes.items));
}

pub fn parseIntLatin1Bytes(source: []const u8, initial_radix: i32) f64 {
    var text = trimLeadingJsWhitespace(source);
    var sign: f64 = 1;
    if (text.len != 0 and (text[0] == '+' or text[0] == '-')) {
        if (text[0] == '-') sign = -1;
        text = text[1..];
    }

    var radix = initial_radix;
    if (radix != 0 and (radix < 2 or radix > 36)) return std.math.nan(f64);
    if (radix == 0) {
        radix = 10;
        if (text.len >= 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
            radix = 16;
            text = text[2..];
        }
    } else if (radix == 16 and text.len >= 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        text = text[2..];
    }

    var wide: u128 = 0;
    var overflowed = false;
    var value: f64 = 0;
    var consumed: usize = 0;
    for (text) |ch| {
        const digit: i32 = @intCast(unicode.asciiRadixDigitValueByte(ch) orelse break);
        if (digit >= radix) break;
        consumed += 1;
        if (!overflowed) {
            const mul = @mulWithOverflow(wide, @as(u128, @intCast(radix)));
            const add = @addWithOverflow(mul[0], @as(u128, @intCast(digit)));
            if (mul[1] == 0 and add[1] == 0) {
                wide = add[0];
                continue;
            }
            overflowed = true;
            value = @floatFromInt(wide);
        }
        value = value * @as(f64, @floatFromInt(radix)) + @as(f64, @floatFromInt(digit));
    }
    if (consumed == 0) return std.math.nan(f64);
    if (!overflowed) {
        value = @floatFromInt(wide);
    } else if (radix == 10) {
        // Beyond 128 bits of decimal digits: delegate to the correctly-rounded
        // decimal parser (qjs js_atod exactness) instead of per-digit rounding.
        value = std.fmt.parseFloat(f64, text[0..consumed]) catch value;
    }
    const signed = value * sign;
    if (signed == 0 and sign < 0) return -0.0;
    return signed;
}

pub fn parseFloatLatin1Bytes(source: []const u8) f64 {
    if (source.len != 0 and jsWhitespacePrefixLen(source) == null) {
        if (parseSimpleDecimalFloat(source)) |number| return number;
    }
    const text = trimLeadingJsWhitespace(source);
    if (text.len == 0) return std.math.nan(f64);

    var index: usize = 0;
    if (text[index] == '+' or text[index] == '-') index += 1;

    if (std.mem.startsWith(u8, text[index..], "Infinity")) {
        return if (text[0] == '-') -std.math.inf(f64) else std.math.inf(f64);
    }

    var digits: usize = 0;
    while (index < text.len and unicode.isAsciiDigitCodePoint(text[index])) : (index += 1) digits += 1;
    if (index < text.len and text[index] == '.') {
        index += 1;
        while (index < text.len and unicode.isAsciiDigitCodePoint(text[index])) : (index += 1) digits += 1;
    }
    if (digits == 0) return std.math.nan(f64);

    const exponent_start = index;
    if (index < text.len and (text[index] == 'e' or text[index] == 'E')) {
        index += 1;
        if (index < text.len and (text[index] == '+' or text[index] == '-')) index += 1;
        const exponent_digits_start = index;
        while (index < text.len and unicode.isAsciiDigitCodePoint(text[index])) : (index += 1) {}
        if (index == exponent_digits_start) index = exponent_start;
    }

    if (parseSimpleDecimalFloat(text[0..index])) |number| return number;
    return std.fmt.parseFloat(f64, text[0..index]) catch std.math.nan(f64);
}

fn parseSimpleDecimalFloat(text: []const u8) ?f64 {
    var index: usize = 0;
    var sign: f64 = 1;
    if (index < text.len and (text[index] == '+' or text[index] == '-')) {
        if (text[index] == '-') sign = -1;
        index += 1;
    }

    var value: f64 = 0;
    var digits: usize = 0;
    while (index < text.len and unicode.isAsciiDigitCodePoint(text[index])) : (index += 1) {
        if (digits == 15) return null;
        value = value * 10 + @as(f64, @floatFromInt(text[index] - '0'));
        digits += 1;
    }

    if (index < text.len and text[index] == '.') {
        index += 1;
        var scale: f64 = 1;
        while (index < text.len and unicode.isAsciiDigitCodePoint(text[index])) : (index += 1) {
            if (digits == 15) return null;
            value = value * 10 + @as(f64, @floatFromInt(text[index] - '0'));
            scale *= 10;
            digits += 1;
        }
        value /= scale;
    }

    if (digits == 0 or index != text.len) return null;
    const signed = value * sign;
    if (signed == 0 and sign < 0) return -0.0;
    return signed;
}

pub fn numberValue(value: core.JSValue) ?f64 {
    if (value.asInt32()) |v| return @floatFromInt(v);
    if (value.asFloat64()) |v| return v;
    return null;
}

pub fn toNumber(rt: *core.JSRuntime, value: core.JSValue) !f64 {
    if (numberValue(value)) |number| return number;
    if (value.asBool()) |bool_value| return if (bool_value) 1 else 0;
    if (value.isNull()) return 0;
    if (value.isUndefined()) return std.math.nan(f64);

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendValueString(rt, &bytes, value);
    return parseJsNumber(bytes.items);
}

fn parseJsNumber(bytes: []const u8) f64 {
    return core.value_format.parseJsNumber(bytes);
}

/// Latin1 code-point whitespace. ASCII 0x09-0x0d/0x20 stay the first arm so
/// the ASCII hot path is a single switch match; 0xA0 is NBSP (U+00A0).
/// Multi-byte UTF-8 sequences are NOT whitespace here — those bytes are
/// independent latin1 code points. qjs skip_spaces (qjs:11230) + lre_is_space
/// (libunicode.h:162) classify by CODE POINT.
fn jsWhitespacePrefixLen(bytes: []const u8) ?usize {
    if (bytes.len == 0) return null;
    switch (bytes[0]) {
        0x09...0x0d, 0x20, 0xa0 => return 1,
        else => return null,
    }
}

fn toInt32(number: f64) i32 {
    if (number == 0 or std.math.isNan(number) or !std.math.isFinite(number)) return 0;
    const two32 = 4294967296.0;
    var int = @mod(@floor(@abs(number)), two32);
    if (number < 0 and int != 0) int = two32 - int;
    if (int >= 2147483648.0) return @intFromFloat(int - two32);
    return @intFromFloat(int);
}

fn trimLeadingJsWhitespace(source: []const u8) []const u8 {
    var index: usize = 0;
    while (index < source.len) {
        const width = jsWhitespacePrefixLen(source[index..]) orelse break;
        index += width;
    }
    return source[index..];
}

/// This file's policy for the shared bare-runtime ToString owner.
fn appendValueString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) AppendStringError!void {
    return core.value_string.appendValueString(rt, buffer, value, .{ .unwrap_wrappers = true });
}
