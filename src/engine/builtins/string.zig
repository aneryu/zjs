const core = @import("../core/root.zig");
const bignum = @import("../libs/bignum.zig");
const unicode = @import("../libs/unicode.zig");
const std = @import("std");

pub fn charAt(bytes: []const u8, index: usize) []const u8 {
    if (index >= bytes.len) return "";
    return bytes[index .. index + 1];
}

pub fn toUpperAscii(buf: []u8, bytes: []const u8) []u8 {
    const n = @min(buf.len, bytes.len);
    for (bytes[0..n], 0..) |byte, i| buf[i] = unicode.toUpperAscii(byte);
    return buf[0..n];
}

/// QuickJS source map: narrow String wrapper constructor used by transitional
/// `new_string_object` bytecode.
pub fn construct(rt: *core.Runtime, args: []const core.Value) !core.Value {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    if (args.len >= 1) try appendValueString(rt, &buffer, args[0]);

    const object = try core.Object.create(rt, core.class.ids.string, null);
    errdefer core.Object.destroyFromHeader(rt, &object.header);

    const data = try core.string.String.createUtf8(rt, buffer.items);
    const data_value = data.value();
    defer data_value.free(rt);
    object.string_data = data_value.dup();
    try defineIntProperty(rt, object, "length", @intCast(buffer.items.len));
    return object.value();
}

/// QuickJS source map: narrow String.fromCharCode helper used by transitional
/// `string_from_char_code` bytecode.
pub fn fromCharCode(rt: *core.Runtime, args: []const core.Value) !core.Value {
    if (args.len > 64) return error.UnsupportedStringCall;
    var units: [64]u8 = undefined;
    for (args, 0..) |value, i| {
        const code = value.asInt32() orelse return error.UnsupportedStringCall;
        units[i] = @intCast(@as(u32, @bitCast(code)) & 0xff);
    }
    return createStringValue(rt, units[0..args.len]);
}

/// QuickJS source map: narrow charAt helper used by transitional
/// `string_char_at` bytecode.
pub fn charAtValue(rt: *core.Runtime, receiver: core.Value, index_value: core.Value) !core.Value {
    const index = index_value.asInt32() orelse return error.UnsupportedStringCall;
    if (index < 0) return error.UnsupportedStringCall;
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendStringReceiverBytes(rt, &bytes, receiver);
    const char_index: usize = @intCast(index);
    const out = if (char_index < bytes.items.len) bytes.items[char_index .. char_index + 1] else "";
    return createStringValue(rt, out);
}

/// QuickJS source map: selected String.prototype methods currently covered by
/// smoke fixtures and targeted String validation.
pub fn methodCall(rt: *core.Runtime, receiver: core.Value, id: u32, args: []const core.Value) !core.Value {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendStringReceiverBytes(rt, &bytes, receiver);

    return switch (id) {
        1 => substring(rt, bytes.items, args),
        2 => asciiCase(rt, bytes.items, true),
        3 => asciiCase(rt, bytes.items, false),
        4 => indexOf(rt, bytes.items, args),
        5 => contains(rt, bytes.items, args, .contains),
        6 => contains(rt, bytes.items, args, .starts),
        7 => contains(rt, bytes.items, args, .ends),
        8 => createStringValue(rt, std.mem.trim(u8, bytes.items, " \t\r\n")),
        9 => {
            if (args.len != 0) return error.UnsupportedStringCall;
            return createStringValue(rt, bytes.items);
        },
        else => error.UnsupportedStringCall,
    };
}

fn substring(rt: *core.Runtime, bytes: []const u8, args: []const core.Value) !core.Value {
    if (args.len < 1 or args.len > 2) return error.UnsupportedStringCall;
    const start_raw = args[0].asInt32() orelse return error.UnsupportedStringCall;
    const end_raw = if (args.len >= 2) args[1].asInt32() orelse return error.UnsupportedStringCall else @as(i32, @intCast(bytes.len));
    const start: usize = @intCast(@max(@as(i32, 0), @min(start_raw, @as(i32, @intCast(bytes.len)))));
    const end: usize = @intCast(@max(@as(i32, 0), @min(end_raw, @as(i32, @intCast(bytes.len)))));
    const lo = @min(start, end);
    const hi = @max(start, end);
    return createStringValue(rt, bytes[lo..hi]);
}

fn asciiCase(rt: *core.Runtime, bytes: []const u8, upper: bool) !core.Value {
    var out = try rt.memory.allocator.alloc(u8, bytes.len);
    defer rt.memory.allocator.free(out);
    for (bytes, 0..) |c, i| out[i] = if (upper) std.ascii.toUpper(c) else std.ascii.toLower(c);
    return createStringValue(rt, out);
}

fn indexOf(rt: *core.Runtime, bytes: []const u8, args: []const core.Value) !core.Value {
    if (args.len < 1 or args.len > 2) return error.UnsupportedStringCall;
    var needle = std.ArrayList(u8).empty;
    defer needle.deinit(rt.memory.allocator);
    try appendValueString(rt, &needle, args[0]);
    const start = if (args.len >= 2) try stringSearchStart(rt, bytes.len, args[1]) else @as(usize, 0);
    const index = if (start <= bytes.len) std.mem.indexOfPos(u8, bytes, start, needle.items) else null;
    return core.Value.int32(if (index) |value| @intCast(value) else -1);
}

const StringContainsMode = enum { contains, starts, ends };

fn contains(rt: *core.Runtime, bytes: []const u8, args: []const core.Value, mode: StringContainsMode) !core.Value {
    if (args.len != 1) return error.UnsupportedStringCall;
    var needle = std.ArrayList(u8).empty;
    defer needle.deinit(rt.memory.allocator);
    try appendValueString(rt, &needle, args[0]);
    const found = switch (mode) {
        .contains => std.mem.indexOf(u8, bytes, needle.items) != null,
        .starts => std.mem.startsWith(u8, bytes, needle.items),
        .ends => std.mem.endsWith(u8, bytes, needle.items),
    };
    return core.Value.boolean(found);
}

fn appendStringReceiverBytes(rt: *core.Runtime, buffer: *std.ArrayList(u8), target: core.Value) !void {
    if (target.isString()) {
        try appendRawString(rt, buffer, target);
        return;
    }
    if (target.isObject()) {
        const object = try expectObject(target);
        if (object.class_id == core.class.ids.string) {
            const data = object.string_data orelse return error.UnsupportedStringCall;
            try appendValueString(rt, buffer, data);
            return;
        }
        try appendValueString(rt, buffer, target);
        return;
    }
    if (target.isNull() or target.isUndefined()) return error.UnsupportedStringCall;
    try appendValueString(rt, buffer, target);
}

fn createStringValue(rt: *core.Runtime, bytes: []const u8) !core.Value {
    const str = try core.string.String.createUtf8(rt, bytes);
    return str.value();
}

fn expectObject(value: core.Value) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    return @fieldParentPtr("header", header);
}

fn defineIntProperty(rt: *core.Runtime, object: *core.Object, name: []const u8, value: i32) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(core.Value.int32(value), true, true, true));
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
            const data = object_value.string_data orelse return error.UnsupportedStringCall;
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

fn stringSearchStart(rt: *core.Runtime, length: usize, value: core.Value) !usize {
    const number = try toIntegerOrInfinity(rt, value);
    if (std.math.isNan(number) or number <= 0) return 0;
    if (std.math.isPositiveInf(number)) return length;
    const truncated = @trunc(number);
    if (truncated >= @as(f64, @floatFromInt(length))) return length;
    return @intFromFloat(truncated);
}

fn toIntegerOrInfinity(rt: *core.Runtime, value: core.Value) !f64 {
    if (numberValue(value)) |number| return number;
    if (value.asBool()) |bool_value| return if (bool_value) 1 else 0;
    if (value.isNull()) return 0;
    if (value.isUndefined()) return std.math.nan(f64);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try appendValueString(rt, &buffer, value);
    return parseJsNumber(buffer.items);
}

fn parseJsNumber(bytes: []const u8) f64 {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return std.math.nan(f64);
    if (std.mem.eql(u8, trimmed, "Infinity") or std.mem.eql(u8, trimmed, "+Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, trimmed, "-Infinity")) return -std.math.inf(f64);
    return std.fmt.parseFloat(f64, trimmed) catch std.math.nan(f64);
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

fn isNegativeZero(value: f64) bool {
    return value == 0 and std.math.isNegativeInf(1.0 / value);
}
