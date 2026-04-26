const core = @import("../core/root.zig");
const bignum = @import("../libs/bignum.zig");
const std = @import("std");

pub const ArrayBuffer = struct {
    bytes: []u8,
    detached: bool = false,

    pub fn byteLength(self: ArrayBuffer) usize {
        return if (self.detached) 0 else self.bytes.len;
    }

    pub fn detach(self: *ArrayBuffer) void {
        self.detached = true;
    }
};

/// QuickJS source map: narrow ArrayBuffer constructor used by transitional
/// `new_array_buffer` bytecode.
pub fn arrayBufferConstruct(rt: *core.Runtime, length_value: core.Value) !core.Value {
    const byte_length = try toIndexUsize(rt, length_value);
    return createArrayBuffer(rt, byte_length);
}

/// QuickJS source map: narrow TypedArray constructor shape used by current
/// smoke coverage. This does not implement element access or species behavior.
pub fn typedArrayConstruct(rt: *core.Runtime, element_size: u32, buffer_value: core.Value) !core.Value {
    if (element_size == 0) return error.UnsupportedBufferCall;
    const buffer = try expectArrayBufferObject(buffer_value);
    const byte_length = try objectIntProperty(rt, buffer.value(), "byteLength");
    const object = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    try defineIntProperty(rt, object, "length", @divTrunc(byte_length, @as(i32, @intCast(element_size))));
    try defineIntProperty(rt, object, "byteLength", byte_length);
    try defineIntProperty(rt, object, "byteOffset", 0);
    return object.value();
}

/// QuickJS source map: narrow DataView constructor used by transitional
/// `new_dataview` bytecode.
pub fn dataViewConstruct(rt: *core.Runtime, args: []const core.Value) !core.Value {
    if (args.len < 1) return error.UnsupportedBufferCall;
    const buffer = try expectArrayBufferObject(args[0]);
    const buffer_length_i32 = try objectIntProperty(rt, args[0], "byteLength");
    if (buffer_length_i32 < 0) return error.RangeError;
    const buffer_length: usize = @intCast(buffer_length_i32);
    const byte_offset = if (args.len >= 2) try toIndexUsize(rt, args[1]) else @as(usize, 0);
    if (byte_offset > buffer_length) return error.RangeError;
    const view_length = if (args.len >= 3 and !args[2].isUndefined())
        try toIndexUsize(rt, args[2])
    else
        buffer_length - byte_offset;
    if (byte_offset + view_length > buffer_length) return error.RangeError;

    const object = try core.Object.create(rt, core.class.ids.dataview, null);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    try defineValueProperty(rt, object, "buffer", buffer.value());
    try defineIntPropertyChecked(rt, object, "byteLength", view_length);
    try defineIntPropertyChecked(rt, object, "byteOffset", byte_offset);
    return object.value();
}

/// QuickJS source map: narrow ArrayBuffer.prototype.slice helper.
pub fn arrayBufferSlice(rt: *core.Runtime, buffer_value: core.Value, start_value: core.Value, end_value: core.Value) !core.Value {
    const buffer = try expectArrayBufferObject(buffer_value);
    const source_length_i32 = try objectIntProperty(rt, buffer_value, "byteLength");
    if (source_length_i32 < 0) return error.RangeError;
    const source_length: usize = @intCast(source_length_i32);
    const start = @min(try toIndexUsize(rt, start_value), source_length);
    const end = @min(try toIndexUsize(rt, end_value), source_length);
    const length = if (end > start) end - start else 0;
    const out = try createArrayBuffer(rt, length);
    errdefer out.free(rt);
    const out_object = try expectArrayBufferObject(out);
    if (length != 0) @memcpy(out_object.byte_storage, buffer.byte_storage[start..end]);
    return out;
}

/// QuickJS source map: narrow DataView.prototype getter helper.
pub fn dataViewGet(rt: *core.Runtime, view_value: core.Value, kind: u32, args: []const core.Value) !core.Value {
    const view = try expectDataViewObject(view_value);
    const index = if (args.len >= 1) try toIndexUsize(rt, args[0]) else @as(usize, 0);
    const little_endian = args.len >= 2 and isTruthy(args[1]);
    const width = dataViewKindWidth(kind);
    try checkDataViewBounds(rt, view, index, width);
    const absolute = @as(usize, @intCast(try getIntProperty(rt, view, "byteOffset"))) + index;
    const buffer = try dataViewBuffer(rt, view);

    var bytes: [8]u8 = undefined;
    var i: usize = 0;
    while (i < width) : (i += 1) bytes[i] = buffer.byte_storage[absolute + i];

    const endian: std.builtin.Endian = if (little_endian) .little else .big;
    return switch (kind) {
        1 => core.Value.int32(@as(i8, @bitCast(bytes[0]))),
        2 => core.Value.int32(bytes[0]),
        3 => core.Value.int32(std.mem.readInt(i16, bytes[0..2], endian)),
        4 => core.Value.int32(std.mem.readInt(u16, bytes[0..2], endian)),
        5 => core.Value.int32(std.mem.readInt(i32, bytes[0..4], endian)),
        6 => numberResult(@floatFromInt(std.mem.readInt(u32, bytes[0..4], endian))),
        7 => numberResult(@floatCast(@as(f32, @bitCast(std.mem.readInt(u32, bytes[0..4], endian))))),
        8 => numberResult(@bitCast(std.mem.readInt(u64, bytes[0..8], endian))),
        9 => bigIntResult(rt, std.mem.readInt(i64, bytes[0..8], endian)),
        10 => bigIntResult(rt, @intCast(std.mem.readInt(u64, bytes[0..8], endian))),
        else => error.UnsupportedBufferCall,
    };
}

/// QuickJS source map: narrow DataView.prototype setter helper.
pub fn dataViewSet(rt: *core.Runtime, view_value: core.Value, kind: u32, args: []const core.Value) !core.Value {
    if (args.len < 2) return error.UnsupportedBufferCall;
    const view = try expectDataViewObject(view_value);
    const index = try toIndexUsize(rt, args[0]);
    const little_endian = args.len >= 3 and isTruthy(args[2]);
    const width = dataViewKindWidth(kind);
    try checkDataViewBounds(rt, view, index, width);
    const absolute = @as(usize, @intCast(try getIntProperty(rt, view, "byteOffset"))) + index;

    var bytes: [8]u8 = undefined;
    const endian: std.builtin.Endian = if (little_endian) .little else .big;
    switch (kind) {
        1, 2 => bytes[0] = @truncate(valueToUint32(args[1])),
        3, 4 => std.mem.writeInt(u16, bytes[0..2], @truncate(valueToUint32(args[1])), endian),
        5 => std.mem.writeInt(u32, bytes[0..4], @bitCast(valueToInt32(args[1])), endian),
        6 => std.mem.writeInt(u32, bytes[0..4], valueToUint32(args[1]), endian),
        7 => std.mem.writeInt(u32, bytes[0..4], @bitCast(@as(f32, @floatCast(numberValue(args[1]) orelse 0))), endian),
        8 => std.mem.writeInt(u64, bytes[0..8], @bitCast(numberValue(args[1]) orelse 0), endian),
        9, 10 => std.mem.writeInt(u64, bytes[0..8], try valueToBigInt64Bits(rt, args[1]), endian),
        else => return error.UnsupportedBufferCall,
    }

    const buffer = try dataViewBuffer(rt, view);
    var i: usize = 0;
    while (i < width) : (i += 1) buffer.byte_storage[absolute + i] = bytes[i];
    return core.Value.undefinedValue();
}

fn createArrayBuffer(rt: *core.Runtime, byte_length: usize) !core.Value {
    const object = try core.Object.create(rt, core.class.ids.array_buffer, null);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    object.byte_storage = try rt.memory.alloc(u8, byte_length);
    @memset(object.byte_storage, 0);
    try defineIntPropertyChecked(rt, object, "byteLength", byte_length);
    return object.value();
}

fn expectObject(value: core.Value) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    return @fieldParentPtr("header", header);
}

fn expectArrayBufferObject(value: core.Value) !*core.Object {
    const object = try expectObject(value);
    if (object.class_id != core.class.ids.array_buffer) return error.TypeError;
    return object;
}

fn expectDataViewObject(value: core.Value) !*core.Object {
    const object = try expectObject(value);
    if (object.class_id != core.class.ids.dataview) return error.TypeError;
    return object;
}

fn defineIntPropertyChecked(rt: *core.Runtime, object: *core.Object, name: []const u8, value: usize) !void {
    if (value > @as(usize, @intCast(std.math.maxInt(i32)))) return error.RangeError;
    try defineIntProperty(rt, object, name, @intCast(value));
}

fn defineIntProperty(rt: *core.Runtime, object: *core.Object, name: []const u8, value: i32) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(core.Value.int32(value), true, true, true));
}

fn defineValueProperty(rt: *core.Runtime, object: *core.Object, name: []const u8, value: core.Value) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value, true, true, true));
}

fn getNamedProperty(rt: *core.Runtime, object: *core.Object, name: []const u8) !core.Value {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    return object.getProperty(key);
}

fn getIntProperty(rt: *core.Runtime, object: *core.Object, name: []const u8) !i32 {
    const value = try getNamedProperty(rt, object, name);
    defer value.free(rt);
    return value.asInt32() orelse 0;
}

fn objectIntProperty(rt: *core.Runtime, object_value: core.Value, name: []const u8) !i32 {
    const object = try expectObject(object_value);
    return getIntProperty(rt, object, name);
}

fn checkDataViewBounds(rt: *core.Runtime, view: *core.Object, index: usize, width: usize) !void {
    const byte_length = try getIntProperty(rt, view, "byteLength");
    if (byte_length < 0) return error.RangeError;
    const length: usize = @intCast(byte_length);
    if (index > length or width > length - index) return error.RangeError;
}

fn dataViewBuffer(rt: *core.Runtime, view: *core.Object) !*core.Object {
    const value = try getNamedProperty(rt, view, "buffer");
    defer value.free(rt);
    return expectArrayBufferObject(value);
}

fn numberResult(value: f64) core.Value {
    if (std.math.isFinite(value) and @floor(value) == value and value >= @as(f64, @floatFromInt(std.math.minInt(i32))) and value <= @as(f64, @floatFromInt(std.math.maxInt(i32))) and !isNegativeZero(value)) {
        return core.Value.int32(@intFromFloat(value));
    }
    return core.Value.float64(value);
}

fn bigIntResult(rt: *core.Runtime, value: i128) !core.Value {
    const big = try core.bigint.BigInt.create(rt, value);
    return big.valueRef();
}

fn numberValue(value: core.Value) ?f64 {
    if (value.asInt32()) |int_value| return @floatFromInt(int_value);
    if (value.asFloat64()) |float_value| return float_value;
    return null;
}

fn valueToInt32(value: core.Value) i32 {
    return @bitCast(valueToUint32(value));
}

fn valueToUint32(value: core.Value) u32 {
    const number = if (numberValue(value)) |n|
        n
    else if (value.asBool()) |bool_value|
        if (bool_value) @as(f64, 1) else @as(f64, 0)
    else
        @as(f64, 0);
    if (!std.math.isFinite(number) or std.math.isNan(number)) return 0;
    const two32 = 4294967296.0;
    var modulo = @mod(@trunc(number), two32);
    if (modulo < 0) modulo += two32;
    return @intFromFloat(modulo);
}

fn dataViewKindWidth(kind: u32) usize {
    return switch (kind) {
        1, 2 => 1,
        3, 4 => 2,
        5, 6, 7 => 4,
        8, 9, 10 => 8,
        else => 0,
    };
}

fn valueToBigInt64Bits(rt: *core.Runtime, value: core.Value) !u64 {
    var big = try toBigIntValue(rt, value);
    defer big.deinit();
    var low: u64 = 0;
    if (big.limbs.len >= 1) low |= big.limbs[0];
    if (big.limbs.len >= 2) low |= @as(u64, big.limbs[1]) << 32;
    return if (big.negative) 0 -% low else low;
}

fn toBigIntValue(rt: *core.Runtime, value: core.Value) !bignum.BigInt {
    if (value.isBigInt()) return cloneBigIntValue(rt, value);
    if (value.asInt32()) |int_value| return bignum.BigInt.fromIntAlloc(rt.memory.allocator, int_value);
    if (value.asFloat64()) |float_value| {
        if (!std.math.isFinite(float_value) or @trunc(float_value) != float_value) return error.TypeError;
        return bignum.BigInt.fromIntAlloc(rt.memory.allocator, @intFromFloat(float_value));
    }
    if (value.asBool()) |bool_value| return bignum.BigInt.fromIntAlloc(rt.memory.allocator, if (bool_value) 1 else 0);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    if (value.isString() or value.isObject()) {
        try appendValueString(rt, &buffer, value);
        const trimmed = std.mem.trim(u8, buffer.items, " \t\r\n");
        if (trimmed.len == 0) return error.TypeError;
        return bignum.parseAutoAlloc(rt.memory.allocator, trimmed) catch error.TypeError;
    }
    return error.TypeError;
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

fn toIndexUsize(rt: *core.Runtime, value: core.Value) !usize {
    const number = try toIntegerOrInfinity(rt, value);
    if (std.math.isNan(number)) return 0;
    if (!std.math.isFinite(number)) return error.RangeError;
    const truncated = @trunc(number);
    if (truncated < 0) return error.RangeError;
    if (truncated == 0) return 0;
    return @intFromFloat(truncated);
}

fn parseJsNumber(bytes: []const u8) f64 {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return std.math.nan(f64);
    if (std.mem.eql(u8, trimmed, "Infinity") or std.mem.eql(u8, trimmed, "+Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, trimmed, "-Infinity")) return -std.math.inf(f64);
    return std.fmt.parseFloat(f64, trimmed) catch std.math.nan(f64);
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
            const data = object_value.string_data orelse return error.UnsupportedBufferCall;
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

fn isTruthy(value: core.Value) bool {
    if (value.isUndefined() or value.isNull()) return false;
    if (value.asBool()) |bool_value| return bool_value;
    if (value.asInt32()) |int_value| return int_value != 0;
    if (value.asFloat64()) |float_value| return float_value != 0 and !std.math.isNan(float_value);
    if (value.isString()) {
        const header = value.refHeader() orelse return false;
        const string_value: *core.string.String = @fieldParentPtr("header", header);
        return string_value.len() != 0;
    }
    return true;
}

fn isNegativeZero(value: f64) bool {
    return value == 0 and std.math.isNegativeInf(1.0 / value);
}
