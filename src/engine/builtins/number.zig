const core = @import("../core/root.zig");
const dtoa = @import("../libs/dtoa.zig");
const bignum = @import("../libs/bignum.zig");
const std = @import("std");

pub fn parseFloat(bytes: []const u8) !f64 {
    return dtoa.parseNumber(bytes);
}

pub fn toString(buf: []u8, value: f64) ![]const u8 {
    return dtoa.formatNumber(buf, value);
}

/// QuickJS source map: global parseInt / Number.parseInt. This is still the
/// narrow subset used by transitional `parse_int` bytecode.
pub fn parseIntValue(rt: *core.Runtime, input: core.Value, radix_value: ?core.Value) !f64 {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendValueString(rt, &bytes, input);

    const radix = if (radix_value) |value| toInt32(try toNumber(rt, value)) else 0;
    return parseIntBytes(bytes.items, radix);
}

/// QuickJS source map: global parseFloat / Number.parseFloat. This is still the
/// narrow subset used by transitional `parse_float` bytecode.
pub fn parseFloatValue(rt: *core.Runtime, input: core.Value) !f64 {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendValueString(rt, &bytes, input);
    return parseFloatBytes(bytes.items);
}

fn parseIntBytes(source: []const u8, initial_radix: i32) f64 {
    var text = trimLeadingAsciiWhitespace(source);
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
        const digit: i32 =
            if (ch >= '0' and ch <= '9') ch - '0' else if (ch >= 'a' and ch <= 'z') ch - 'a' + 10 else if (ch >= 'A' and ch <= 'Z') ch - 'A' + 10 else break;
        if (digit >= radix) break;
        consumed = true;
        value = value * @as(f64, @floatFromInt(radix)) + @as(f64, @floatFromInt(digit));
    }
    if (!consumed) return std.math.nan(f64);
    const signed = value * sign;
    if (signed == 0 and sign < 0) return -0.0;
    return signed;
}

fn parseFloatBytes(source: []const u8) f64 {
    const text = trimLeadingAsciiWhitespace(source);
    if (std.mem.startsWith(u8, text, "Infinity") or std.mem.startsWith(u8, text, "+Infinity")) return std.math.inf(f64);
    if (std.mem.startsWith(u8, text, "-Infinity")) return -std.math.inf(f64);

    var end: usize = 0;
    var best: ?f64 = null;
    while (end < text.len) {
        end += 1;
        if (std.fmt.parseFloat(f64, text[0..end])) |parsed| {
            best = parsed;
        } else |_| {}
    }
    if (best) |parsed| {
        if (parsed == 0 and text.len >= 2 and text[0] == '-' and text[1] == '0') return -0.0;
        return parsed;
    }
    return std.math.nan(f64);
}

fn appendValueString(rt: *core.Runtime, buffer: *std.ArrayList(u8), value: core.Value) anyerror!void {
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
        } else if (isNegativeZero(float_value)) {
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
            const data = object_value.string_data orelse return error.UnsupportedNumberCall;
            try appendValueString(rt, buffer, data);
        } else if (object_value.class_id == core.class.ids.array_buffer) {
            try buffer.appendSlice(rt.memory.allocator, "[object ArrayBuffer]");
        } else if (object_value.class_id == core.class.ids.promise) {
            try buffer.appendSlice(rt.memory.allocator, "[object Promise]");
        } else if (object_value.is_array) {
            try appendArrayString(rt, buffer, object_value);
        } else {
            try buffer.appendSlice(rt.memory.allocator, "[object Object]");
        }
    } else {
        try buffer.appendSlice(rt.memory.allocator, "[object Object]");
    }
}

fn appendRawString(rt: *core.Runtime, buffer: *std.ArrayList(u8), value: core.Value) !void {
    const header = value.refHeader() orelse return;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    switch (string_value.data) {
        .latin1 => |bytes| try buffer.appendSlice(rt.memory.allocator, bytes),
        .utf16 => |units| {
            for (units) |unit| {
                if (unit <= 0x7f) {
                    try buffer.append(rt.memory.allocator, @intCast(unit));
                } else {
                    var unit_buf: [16]u8 = undefined;
                    const printed = try std.fmt.bufPrint(&unit_buf, "\\u{x}", .{unit});
                    try buffer.appendSlice(rt.memory.allocator, printed);
                }
            }
        },
    }
}

fn appendArrayString(rt: *core.Runtime, buffer: *std.ArrayList(u8), object: *core.Object) anyerror!void {
    var index: u32 = 0;
    while (index < object.length) : (index += 1) {
        if (index != 0) try buffer.append(rt.memory.allocator, ',');
        const value = object.getProperty(core.atom.atomFromUInt32(index));
        defer value.free(rt);
        if (!value.isUndefined() and !value.isNull()) try appendValueString(rt, buffer, value);
    }
}

fn cloneBigIntValue(rt: *core.Runtime, value: core.Value) !bignum.BigInt {
    if (value.asShortBigInt()) |big_int| return bignum.BigInt.fromIntAlloc(rt.memory.allocator, big_int);
    if (value.isBigInt() and value.refHeader() != null) {
        const header = value.refHeader().?;
        const big: *core.bigint.BigInt = @alignCast(@fieldParentPtr("header", header));
        return big.value.cloneWithAllocator(rt.memory.allocator);
    }
    return error.TypeError;
}

fn numberValue(value: core.Value) ?f64 {
    if (value.asInt32()) |v| return @floatFromInt(v);
    if (value.asFloat64()) |v| return v;
    return null;
}

fn toNumber(rt: *core.Runtime, value: core.Value) !f64 {
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
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return 0;
    if (std.mem.eql(u8, trimmed, "Infinity") or std.mem.eql(u8, trimmed, "+Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, trimmed, "-Infinity")) return -std.math.inf(f64);
    return std.fmt.parseFloat(f64, trimmed) catch std.math.nan(f64);
}

fn toInt32(number: f64) i32 {
    if (number == 0 or std.math.isNan(number) or !std.math.isFinite(number)) return 0;
    const two32 = 4294967296.0;
    var int = @mod(@floor(@abs(number)), two32);
    if (number < 0 and int != 0) int = two32 - int;
    if (int >= 2147483648.0) return @intFromFloat(int - two32);
    return @intFromFloat(int);
}

fn trimLeadingAsciiWhitespace(source: []const u8) []const u8 {
    var index: usize = 0;
    while (index < source.len and (source[index] == ' ' or source[index] == '\t' or source[index] == '\r' or source[index] == '\n')) : (index += 1) {}
    return source[index..];
}

fn isNegativeZero(value: f64) bool {
    return value == 0 and std.math.isNegativeInf(1.0 / value);
}
