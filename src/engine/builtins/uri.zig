const core = @import("../core/root.zig");
const bignum = @import("../libs/bignum.zig");
const std = @import("std");

/// QuickJS source map: global URI encode/decode functions in quickjs.c. This
/// is the current narrow URI subset used by transitional `uri_call` bytecode.
pub fn call(rt: *core.Runtime, mode: u32, input: core.Value) !core.Value {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendValueString(rt, &bytes, input);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(rt.memory.allocator);
    switch (mode) {
        1 => try encodeBytes(rt, &out, bytes.items, false),
        2 => try encodeBytes(rt, &out, bytes.items, true),
        3 => try decodeBytes(rt, &out, bytes.items, false),
        4 => try decodeBytes(rt, &out, bytes.items, true),
        else => return error.UnsupportedUriCall,
    }

    const str = try core.string.String.createUtf8(rt, out.items);
    return str.value();
}

fn encodeBytes(rt: *core.Runtime, out: *std.ArrayList(u8), bytes: []const u8, component: bool) !void {
    for (bytes) |ch| {
        if (isUnescaped(ch) or (!component and isReserved(ch))) {
            try out.append(rt.memory.allocator, ch);
        } else {
            var encoded: [3]u8 = undefined;
            _ = try std.fmt.bufPrint(&encoded, "%{X:0>2}", .{ch});
            try out.appendSlice(rt.memory.allocator, &encoded);
        }
    }
}

fn decodeBytes(rt: *core.Runtime, out: *std.ArrayList(u8), bytes: []const u8, component: bool) !void {
    var index: usize = 0;
    while (index < bytes.len) : (index += 1) {
        if (bytes[index] != '%' or index + 2 >= bytes.len or !std.ascii.isHex(bytes[index + 1]) or !std.ascii.isHex(bytes[index + 2])) {
            try out.append(rt.memory.allocator, bytes[index]);
            continue;
        }
        const decoded: u8 = @intCast((hexValue(bytes[index + 1]) << 4) | hexValue(bytes[index + 2]));
        if (!component and isReserved(decoded)) {
            try out.appendSlice(rt.memory.allocator, bytes[index .. index + 3]);
        } else {
            try out.append(rt.memory.allocator, decoded);
        }
        index += 2;
    }
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
            const data = object_value.string_data orelse return error.UnsupportedUriCall;
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

fn isNegativeZero(value: f64) bool {
    return value == 0 and std.math.isNegativeInf(1.0 / value);
}

fn isUnescaped(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '!' or ch == '~' or ch == '*' or ch == '\'' or ch == '(' or ch == ')';
}

fn isReserved(ch: u8) bool {
    return ch == ';' or ch == ',' or ch == '/' or ch == '?' or ch == ':' or ch == '@' or ch == '&' or ch == '=' or ch == '+' or ch == '$' or ch == '#';
}

fn hexValue(ch: u8) u8 {
    if (ch >= '0' and ch <= '9') return @intCast(ch - '0');
    if (ch >= 'a' and ch <= 'f') return @intCast(ch - 'a' + 10);
    return @intCast(ch - 'A' + 10);
}
