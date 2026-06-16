//! Pure number-parsing primitives shared by the `Number.parseInt`/`parseFloat`
//! and global `parseInt`/`parseFloat` fast paths and their bare-runtime
//! fallbacks. These are ASCII -> f64 arithmetic parsers with zero exec/VM
//! dependencies: they only reach `std`, the `libs/{dtoa,bignum,unicode}`
//! helpers, and core value/string/object plumbing. The realm-coercing record
//! handler and the `Number.prototype.*` formatting methods stay in
//! `src/builtins/number.zig`, which re-exports the entry points below for the
//! install path.

const core = @import("root.zig");
const bignum = @import("../libs/bignum.zig");
const unicode = @import("../libs/unicode.zig");
const std = @import("std");

const AppendStringError = error{
    OutOfMemory,
    TypeError,
    InvalidRadix,
    NoSpaceLeft,
};

fn stringFromValue(value: core.JSValue) ?*core.string.String {
    if (!value.isString()) return null;
    const header = value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
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
    return parseIntLatin1Bytes(bytes.items, radix);
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
    return parseFloatLatin1Bytes(bytes.items);
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

    var value: f64 = 0;
    var consumed = false;
    for (text) |ch| {
        const digit: i32 = @intCast(unicode.asciiRadixDigitValueByte(ch) orelse break);
        if (digit >= radix) break;
        consumed = true;
        value = value * @as(f64, @floatFromInt(radix)) + @as(f64, @floatFromInt(digit));
    }
    if (!consumed) return std.math.nan(f64);
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

fn appendValueString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) AppendStringError!void {
    if (value.asInt32()) |int_value| {
        var int_buf: [32]u8 = undefined;
        const printed = try std.fmt.bufPrint(&int_buf, "{d}", .{int_value});
        try buffer.appendSlice(rt.memory.allocator, printed);
    } else if (value.asFloat64()) |float_value| {
        if (std.math.isNan(float_value)) {
            try buffer.appendSlice(rt.memory.allocator, "NaN");
        } else if (std.math.isPositiveInf(float_value)) {
            try buffer.appendSlice(rt.memory.allocator, "Infinity");
        } else if (std.math.isNegativeInf(float_value)) {
            try buffer.appendSlice(rt.memory.allocator, "-Infinity");
        } else if (std.math.isNegativeZero(float_value)) {
            try buffer.append(rt.memory.allocator, '0');
        } else {
            var float_buf: [64]u8 = undefined;
            const printed = try std.fmt.bufPrint(&float_buf, "{d}", .{float_value});
            try buffer.appendSlice(rt.memory.allocator, printed);
        }
    } else if (value.isBigInt()) {
        var big = try cloneBigIntValue(rt, value);
        defer big.deinit();
        const printed = try big.formatBase10Alloc(rt.memory.allocator);
        defer rt.memory.allocator.free(printed);
        try buffer.appendSlice(rt.memory.allocator, printed);
    } else if (value.asBool()) |bool_value| {
        try buffer.appendSlice(rt.memory.allocator, if (bool_value) "true" else "false");
    } else if (value.isUndefined()) {
        try buffer.appendSlice(rt.memory.allocator, "undefined");
    } else if (value.isNull()) {
        try buffer.appendSlice(rt.memory.allocator, "null");
    } else if (value.isString()) {
        try appendRawString(rt, buffer, value);
    } else if (value.isObject()) {
        const header = value.refHeader() orelse return;
        const object_value: *core.Object = @fieldParentPtr("header", header);
        if (object_value.class_id == core.class.ids.string) {
            const data = object_value.objectData() orelse return error.TypeError;
            try appendValueString(rt, buffer, data);
        } else if (object_value.class_id == core.class.ids.number or object_value.class_id == core.class.ids.boolean or
            object_value.class_id == core.class.ids.big_int or object_value.class_id == core.class.ids.symbol)
        {
            const primitive = (object_value.objectData() orelse return error.TypeError).dup();
            defer primitive.free(rt);
            try appendValueString(rt, buffer, primitive);
        } else if (object_value.class_id == core.class.ids.array_buffer) {
            try buffer.appendSlice(rt.memory.allocator, "[object ArrayBuffer]");
        } else if (object_value.class_id == core.class.ids.promise) {
            try buffer.appendSlice(rt.memory.allocator, "[object Promise]");
        } else if (object_value.flags.is_array) {
            try appendArrayString(rt, buffer, object_value);
        } else {
            try buffer.appendSlice(rt.memory.allocator, "[object Object]");
        }
    } else {
        try buffer.appendSlice(rt.memory.allocator, "[object Object]");
    }
}

fn appendRawString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) !void {
    const header = value.refHeader() orelse return;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    try string_value.ensureFlat(rt);
    switch (string_value.resolveData()) {
        .latin1 => |bytes| try buffer.appendSlice(rt.memory.allocator, bytes),
        .utf16 => |units| {
            for (units) |unit| {
                try appendUtf8CodePoint(rt, buffer, unit);
            }
        },
    }
}

fn appendArrayString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), object: *core.Object) AppendStringError!void {
    var index: u32 = 0;
    while (index < object.length) : (index += 1) {
        if (index != 0) try buffer.append(rt.memory.allocator, ',');
        const value = object.getProperty(core.atom.atomFromUInt32(index));
        defer value.free(rt);
        if (!value.isUndefined() and !value.isNull()) try appendValueString(rt, buffer, value);
    }
}

fn cloneBigIntValue(rt: *core.JSRuntime, value: core.JSValue) !bignum.BigInt {
    if (value.asShortBigInt()) |big_int| return bignum.BigInt.fromIntAlloc(rt.memory.allocator, big_int);
    if (value.isBigInt() and value.refHeader() != null) {
        const header = value.refHeader().?;
        const big: *core.bigint.BigInt = @alignCast(@fieldParentPtr("header", header));
        return big.value.cloneWithAllocator(rt.memory.allocator);
    }
    return error.TypeError;
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

fn startsWith(bytes: []const u8, prefix: []const u8) bool {
    return bytes.len >= prefix.len and std.mem.eql(u8, bytes[0..prefix.len], prefix);
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

fn appendUtf8CodePoint(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), cp: u32) !void {
    return unicode.appendUtf8CodePoint(rt.memory.allocator, buffer, cp);
}
