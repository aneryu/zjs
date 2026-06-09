const core = @import("../core/root.zig");
const bignum = @import("../libs/bignum.zig");
const std = @import("std");

const AppendStringError = error{
    OutOfMemory,
    TypeError,
    InvalidRadix,
    NoSpaceLeft,
};

pub const StaticMethod = enum(u32) {
    is_view = 1,
};

pub const ConstructorMethod = enum(u32) {
    array_buffer = 901,
    shared_array_buffer = 902,
};

pub const ArrayBufferPrototypeMethod = enum(u32) {
    slice = 101,
    resize = 102,
    transfer = 103,
    transfer_to_fixed_length = 104,
    slice_to_immutable = 105,
    transfer_to_immutable = 106,
};

pub const SharedArrayBufferPrototypeMethod = enum(u32) {
    slice = 201,
    grow = 202,
};

pub const DataViewGetMethod = enum(u32) {
    int8 = 301,
    uint8 = 302,
    int16 = 303,
    uint16 = 304,
    int32 = 305,
    uint32 = 306,
    float16 = 307,
    float32 = 308,
    float64 = 309,
    big_int64 = 310,
    big_uint64 = 311,
};

pub const DataViewSetMethod = enum(u32) {
    int8 = 321,
    uint8 = 322,
    int16 = 323,
    uint16 = 324,
    int32 = 325,
    uint32 = 326,
    float16 = 327,
    float32 = 328,
    float64 = 329,
    big_int64 = 330,
    big_uint64 = 331,
};

pub const ArrayBufferAccessorMethod = enum(u32) {
    byte_length = 401,
    detached = 402,
    max_byte_length = 403,
    resizable = 404,
    immutable = 405,
};

pub const SharedArrayBufferAccessorMethod = enum(u32) {
    byte_length = 421,
    max_byte_length = 422,
    growable = 423,
};

pub const DataViewAccessorMethod = enum(u32) {
    buffer = 441,
    byte_length = 442,
    byte_offset = 443,
};

pub const TypedArrayAccessorMethod = enum(u32) {
    buffer = 461,
    byte_length = 462,
    byte_offset = 463,
    length = 464,
    to_string_tag = 465,
};

pub fn staticMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "isView")) return @intFromEnum(StaticMethod.is_view);
    return null;
}

pub fn arrayBufferPrototypeMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "slice")) return @intFromEnum(ArrayBufferPrototypeMethod.slice);
    if (std.mem.eql(u8, name, "resize")) return @intFromEnum(ArrayBufferPrototypeMethod.resize);
    if (std.mem.eql(u8, name, "transfer")) return @intFromEnum(ArrayBufferPrototypeMethod.transfer);
    if (std.mem.eql(u8, name, "transferToFixedLength")) return @intFromEnum(ArrayBufferPrototypeMethod.transfer_to_fixed_length);
    if (std.mem.eql(u8, name, "sliceToImmutable")) return @intFromEnum(ArrayBufferPrototypeMethod.slice_to_immutable);
    if (std.mem.eql(u8, name, "transferToImmutable")) return @intFromEnum(ArrayBufferPrototypeMethod.transfer_to_immutable);
    return null;
}

pub fn sharedArrayBufferPrototypeMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "slice")) return @intFromEnum(SharedArrayBufferPrototypeMethod.slice);
    if (std.mem.eql(u8, name, "grow")) return @intFromEnum(SharedArrayBufferPrototypeMethod.grow);
    return null;
}

pub fn dataViewPrototypeMethodId(name: []const u8) ?u32 {
    if (dataViewGetMethodId(name)) |id| return id;
    if (dataViewSetMethodId(name)) |id| return id;
    return null;
}

pub fn dataViewGetMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "getInt8")) return @intFromEnum(DataViewGetMethod.int8);
    if (std.mem.eql(u8, name, "getUint8")) return @intFromEnum(DataViewGetMethod.uint8);
    if (std.mem.eql(u8, name, "getInt16")) return @intFromEnum(DataViewGetMethod.int16);
    if (std.mem.eql(u8, name, "getUint16")) return @intFromEnum(DataViewGetMethod.uint16);
    if (std.mem.eql(u8, name, "getInt32")) return @intFromEnum(DataViewGetMethod.int32);
    if (std.mem.eql(u8, name, "getUint32")) return @intFromEnum(DataViewGetMethod.uint32);
    if (std.mem.eql(u8, name, "getFloat16")) return @intFromEnum(DataViewGetMethod.float16);
    if (std.mem.eql(u8, name, "getFloat32")) return @intFromEnum(DataViewGetMethod.float32);
    if (std.mem.eql(u8, name, "getFloat64")) return @intFromEnum(DataViewGetMethod.float64);
    if (std.mem.eql(u8, name, "getBigInt64")) return @intFromEnum(DataViewGetMethod.big_int64);
    if (std.mem.eql(u8, name, "getBigUint64")) return @intFromEnum(DataViewGetMethod.big_uint64);
    return null;
}

pub fn dataViewSetMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "setInt8")) return @intFromEnum(DataViewSetMethod.int8);
    if (std.mem.eql(u8, name, "setUint8")) return @intFromEnum(DataViewSetMethod.uint8);
    if (std.mem.eql(u8, name, "setInt16")) return @intFromEnum(DataViewSetMethod.int16);
    if (std.mem.eql(u8, name, "setUint16")) return @intFromEnum(DataViewSetMethod.uint16);
    if (std.mem.eql(u8, name, "setInt32")) return @intFromEnum(DataViewSetMethod.int32);
    if (std.mem.eql(u8, name, "setUint32")) return @intFromEnum(DataViewSetMethod.uint32);
    if (std.mem.eql(u8, name, "setFloat16")) return @intFromEnum(DataViewSetMethod.float16);
    if (std.mem.eql(u8, name, "setFloat32")) return @intFromEnum(DataViewSetMethod.float32);
    if (std.mem.eql(u8, name, "setFloat64")) return @intFromEnum(DataViewSetMethod.float64);
    if (std.mem.eql(u8, name, "setBigInt64")) return @intFromEnum(DataViewSetMethod.big_int64);
    if (std.mem.eql(u8, name, "setBigUint64")) return @intFromEnum(DataViewSetMethod.big_uint64);
    return null;
}

pub fn arrayBufferAccessorMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "byteLength")) return @intFromEnum(ArrayBufferAccessorMethod.byte_length);
    if (std.mem.eql(u8, name, "detached")) return @intFromEnum(ArrayBufferAccessorMethod.detached);
    if (std.mem.eql(u8, name, "maxByteLength")) return @intFromEnum(ArrayBufferAccessorMethod.max_byte_length);
    if (std.mem.eql(u8, name, "resizable")) return @intFromEnum(ArrayBufferAccessorMethod.resizable);
    if (std.mem.eql(u8, name, "immutable")) return @intFromEnum(ArrayBufferAccessorMethod.immutable);
    return null;
}

pub fn sharedArrayBufferAccessorMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "byteLength")) return @intFromEnum(SharedArrayBufferAccessorMethod.byte_length);
    if (std.mem.eql(u8, name, "maxByteLength")) return @intFromEnum(SharedArrayBufferAccessorMethod.max_byte_length);
    if (std.mem.eql(u8, name, "growable")) return @intFromEnum(SharedArrayBufferAccessorMethod.growable);
    return null;
}

pub fn dataViewAccessorMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "buffer")) return @intFromEnum(DataViewAccessorMethod.buffer);
    if (std.mem.eql(u8, name, "byteLength")) return @intFromEnum(DataViewAccessorMethod.byte_length);
    if (std.mem.eql(u8, name, "byteOffset")) return @intFromEnum(DataViewAccessorMethod.byte_offset);
    return null;
}

pub fn typedArrayAccessorMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "buffer")) return @intFromEnum(TypedArrayAccessorMethod.buffer);
    if (std.mem.eql(u8, name, "byteLength")) return @intFromEnum(TypedArrayAccessorMethod.byte_length);
    if (std.mem.eql(u8, name, "byteOffset")) return @intFromEnum(TypedArrayAccessorMethod.byte_offset);
    if (std.mem.eql(u8, name, "length")) return @intFromEnum(TypedArrayAccessorMethod.length);
    if (std.mem.eql(u8, name, "[Symbol.toStringTag]")) return @intFromEnum(TypedArrayAccessorMethod.to_string_tag);
    return null;
}

pub fn dataViewGetKindFromRecordId(id: u32) ?u32 {
    return switch (id) {
        @intFromEnum(DataViewGetMethod.int8) => 1,
        @intFromEnum(DataViewGetMethod.uint8) => 2,
        @intFromEnum(DataViewGetMethod.int16) => 3,
        @intFromEnum(DataViewGetMethod.uint16) => 4,
        @intFromEnum(DataViewGetMethod.int32) => 5,
        @intFromEnum(DataViewGetMethod.uint32) => 6,
        @intFromEnum(DataViewGetMethod.float16) => 11,
        @intFromEnum(DataViewGetMethod.float32) => 7,
        @intFromEnum(DataViewGetMethod.float64) => 8,
        @intFromEnum(DataViewGetMethod.big_int64) => 9,
        @intFromEnum(DataViewGetMethod.big_uint64) => 10,
        else => null,
    };
}

pub fn dataViewSetKindFromRecordId(id: u32) ?u32 {
    return switch (id) {
        @intFromEnum(DataViewSetMethod.int8) => 1,
        @intFromEnum(DataViewSetMethod.uint8) => 2,
        @intFromEnum(DataViewSetMethod.int16) => 3,
        @intFromEnum(DataViewSetMethod.uint16) => 4,
        @intFromEnum(DataViewSetMethod.int32) => 5,
        @intFromEnum(DataViewSetMethod.uint32) => 6,
        @intFromEnum(DataViewSetMethod.float16) => 11,
        @intFromEnum(DataViewSetMethod.float32) => 7,
        @intFromEnum(DataViewSetMethod.float64) => 8,
        @intFromEnum(DataViewSetMethod.big_int64) => 9,
        @intFromEnum(DataViewSetMethod.big_uint64) => 10,
        else => null,
    };
}

pub fn arrayBufferAccessorNameFromRecordId(id: u32) ?[]const u8 {
    return switch (id) {
        @intFromEnum(ArrayBufferAccessorMethod.byte_length) => "byteLength",
        @intFromEnum(ArrayBufferAccessorMethod.detached) => "detached",
        @intFromEnum(ArrayBufferAccessorMethod.max_byte_length) => "maxByteLength",
        @intFromEnum(ArrayBufferAccessorMethod.resizable) => "resizable",
        @intFromEnum(ArrayBufferAccessorMethod.immutable) => "immutable",
        else => null,
    };
}

pub fn sharedArrayBufferAccessorNameFromRecordId(id: u32) ?[]const u8 {
    return switch (id) {
        @intFromEnum(SharedArrayBufferAccessorMethod.byte_length) => "byteLength",
        @intFromEnum(SharedArrayBufferAccessorMethod.max_byte_length) => "maxByteLength",
        @intFromEnum(SharedArrayBufferAccessorMethod.growable) => "growable",
        else => null,
    };
}

pub fn dataViewAccessorNameFromRecordId(id: u32) ?[]const u8 {
    return switch (id) {
        @intFromEnum(DataViewAccessorMethod.buffer) => "buffer",
        @intFromEnum(DataViewAccessorMethod.byte_length) => "byteLength",
        @intFromEnum(DataViewAccessorMethod.byte_offset) => "byteOffset",
        else => null,
    };
}

pub fn typedArrayAccessorNameFromRecordId(id: u32) ?[]const u8 {
    return switch (id) {
        @intFromEnum(TypedArrayAccessorMethod.buffer) => "buffer",
        @intFromEnum(TypedArrayAccessorMethod.byte_length) => "byteLength",
        @intFromEnum(TypedArrayAccessorMethod.byte_offset) => "byteOffset",
        @intFromEnum(TypedArrayAccessorMethod.length) => "length",
        @intFromEnum(TypedArrayAccessorMethod.to_string_tag) => "[Symbol.toStringTag]",
        else => null,
    };
}

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
pub fn arrayBufferConstruct(rt: *core.JSRuntime, length_value: core.JSValue) !core.JSValue {
    const byte_length = try toIndexUsize(rt, length_value);
    return createArrayBuffer(rt, byte_length, null);
}

pub fn arrayBufferConstructArgs(rt: *core.JSRuntime, args: []const core.JSValue, prototype: ?*core.Object) !core.JSValue {
    const byte_length = if (args.len >= 1) try toIndexUsize(rt, args[0]) else @as(usize, 0);
    var max_byte_length: ?usize = null;
    if (args.len >= 2 and !args[1].isUndefined() and args[1].isObject()) {
        const options = try expectObject(args[1]);
        const key = try rt.internAtom("maxByteLength");
        defer rt.atoms.free(key);
        const max_value = options.getProperty(key);
        defer max_value.free(rt);
        if (!max_value.isUndefined()) {
            const max = try toIndexUsize(rt, max_value);
            if (max < byte_length) return error.RangeError;
            max_byte_length = max;
        }
    }
    return createArrayBufferWithPrototype(rt, byte_length, max_byte_length, prototype);
}

pub fn arrayBufferConstructLength(rt: *core.JSRuntime, byte_length: usize, max_byte_length: ?usize, prototype: ?*core.Object) !core.JSValue {
    return createArrayBufferWithPrototype(rt, byte_length, max_byte_length, prototype);
}

pub fn sharedArrayBufferConstructArgs(rt: *core.JSRuntime, args: []const core.JSValue, prototype: ?*core.Object) !core.JSValue {
    const byte_length = if (args.len >= 1) try toIndexUsize(rt, args[0]) else @as(usize, 0);
    var max_byte_length: ?usize = null;
    if (args.len >= 2 and !args[1].isUndefined() and args[1].isObject()) {
        const options = try expectObject(args[1]);
        const key = try rt.internAtom("maxByteLength");
        defer rt.atoms.free(key);
        const max_value = options.getProperty(key);
        defer max_value.free(rt);
        if (!max_value.isUndefined()) {
            const max = try toIndexUsize(rt, max_value);
            if (max < byte_length) return error.RangeError;
            max_byte_length = max;
        }
    }
    const object = try core.Object.create(rt, core.class.ids.shared_array_buffer, prototype);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    try validateArrayBufferLength(byte_length);
    if (max_byte_length) |max| try validateArrayBufferLength(max);
    const store = try core.object.SharedBufferStore.create(rt, byte_length);
    object.installSharedByteStorage(rt, store);
    object.arrayBufferMaxByteLengthSlot().* = max_byte_length;
    return object.value();
}

pub fn sharedArrayBufferConstructLength(rt: *core.JSRuntime, byte_length: usize, max_byte_length: ?usize, prototype: ?*core.Object) !core.JSValue {
    const object = try core.Object.create(rt, core.class.ids.shared_array_buffer, prototype);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    try validateArrayBufferLength(byte_length);
    if (max_byte_length) |max| try validateArrayBufferLength(max);
    const store = try core.object.SharedBufferStore.create(rt, byte_length);
    object.installSharedByteStorage(rt, store);
    object.arrayBufferMaxByteLengthSlot().* = max_byte_length;
    return object.value();
}

pub fn sharedArrayBufferFromStore(
    rt: *core.JSRuntime,
    store: *core.object.SharedBufferStore,
    max_byte_length: ?usize,
    prototype: ?*core.Object,
) !core.JSValue {
    const object = try core.Object.create(rt, core.class.ids.shared_array_buffer, prototype);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    if (max_byte_length) |max| {
        if (max < store.bytes.len) return error.RangeError;
        try validateArrayBufferLength(max);
    }
    store.retain();
    object.installSharedByteStorage(rt, store);
    object.arrayBufferMaxByteLengthSlot().* = max_byte_length;
    return object.value();
}

/// QuickJS source map: typed-array view construction helper. JS-visible
/// element access, species, and prototype methods are handled by the VM
/// builtins; this helper owns the internal slot shape used by those paths.
pub fn typedArrayConstruct(rt: *core.JSRuntime, element_size: u32, buffer_value: core.JSValue) !core.JSValue {
    return typedArrayConstructWithOptions(rt, element_size, 2, buffer_value, &.{buffer_value}, null);
}

fn typedArrayClassIdForKind(kind: u8) ?core.class.ClassId {
    return switch (kind) {
        1 => core.class.ids.int8_array,
        2 => core.class.ids.uint8_array,
        3 => core.class.ids.uint8c_array,
        4 => core.class.ids.int16_array,
        5 => core.class.ids.uint16_array,
        6 => core.class.ids.int32_array,
        7 => core.class.ids.uint32_array,
        8 => core.class.ids.float16_array,
        9 => core.class.ids.float32_array,
        10 => core.class.ids.float64_array,
        11 => core.class.ids.big_int64_array,
        12 => core.class.ids.big_uint64_array,
        else => null,
    };
}

fn createTypedArrayInstance(rt: *core.JSRuntime, kind: u8, prototype: ?*core.Object) !*core.Object {
    const class_id = typedArrayClassIdForKind(kind) orelse core.class.ids.object;
    const object = try core.Object.create(rt, class_id, prototype);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    if (class_id == core.class.ids.object) try object.ensureTypedArrayPayload(rt);
    return object;
}

pub fn typedArrayConstructWithOptions(rt: *core.JSRuntime, element_size: u32, kind: u8, buffer_value: core.JSValue, args: []const core.JSValue, prototype: ?*core.Object) !core.JSValue {
    if (element_size == 0) return error.TypeError;
    const buffer = try expectArrayBufferObject(buffer_value);
    if (buffer.arrayBufferDetached()) return error.TypeError;
    const buffer_length = buffer.byteStorage().len;
    const byte_offset = if (args.len >= 2 and !args[1].isUndefined()) try toIndexUsize(rt, args[1]) else @as(usize, 0);
    if (byte_offset > buffer_length or byte_offset % element_size != 0) return error.RangeError;
    const explicit_fixed_length = args.len >= 3 and !args[2].isUndefined();
    const remaining = buffer_length - byte_offset;
    const fixed_length: ?u32 = if (explicit_fixed_length) blk: {
        const requested = try toIndexUsize(rt, args[2]);
        const byte_length = try std.math.mul(usize, requested, element_size);
        if (byte_length > remaining) return error.RangeError;
        if (requested > @as(usize, @intCast(std.math.maxInt(u32)))) return error.RangeError;
        break :blk @intCast(requested);
    } else if (buffer.arrayBufferMaxByteLength() == null) blk: {
        if (remaining % element_size != 0) return error.RangeError;
        break :blk @as(u32, @intCast(@divTrunc(remaining, element_size)));
    } else null;
    const object = try createTypedArrayInstance(rt, kind, prototype);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    try object.setOptionalValueSlot(rt, object.typedArrayBufferSlot(), buffer.value().dup());
    object.typedArrayByteOffsetSlot().* = byte_offset;
    object.typedArrayElementSizeSlot().* = element_size;
    object.typedArrayFixedLengthSlot().* = fixed_length;
    object.typedArrayKindSlot().* = kind;
    return object.value();
}

pub fn typedArrayConstructFullBuffer(rt: *core.JSRuntime, element_size: u32, kind: u8, buffer_value: core.JSValue, buffer: *core.Object, prototype: ?*core.Object) !core.JSValue {
    return typedArrayConstructFullBufferOwned(rt, element_size, kind, buffer_value.dup(), buffer, prototype);
}

pub fn typedArrayConstructFullBufferOwned(rt: *core.JSRuntime, element_size: u32, kind: u8, buffer_value: core.JSValue, buffer: *core.Object, prototype: ?*core.Object) !core.JSValue {
    var owned_buffer_value = buffer_value;
    errdefer owned_buffer_value.free(rt);
    if (element_size == 0) return error.TypeError;
    if (buffer.arrayBufferDetached()) return error.TypeError;
    if (buffer.arrayBufferMaxByteLength() != null) return error.TypeError;
    const buffer_length = buffer.byteStorage().len;
    if (buffer_length % element_size != 0) return error.RangeError;
    const length = @divTrunc(buffer_length, element_size);
    if (length > @as(usize, @intCast(std.math.maxInt(u32)))) return error.RangeError;

    const object = try createTypedArrayInstance(rt, kind, prototype);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    try object.setOptionalValueSlot(rt, object.typedArrayBufferSlot(), owned_buffer_value);
    owned_buffer_value = core.JSValue.undefinedValue();
    object.typedArrayByteOffsetSlot().* = 0;
    object.typedArrayElementSizeSlot().* = element_size;
    object.typedArrayFixedLengthSlot().* = @intCast(length);
    object.typedArrayKindSlot().* = kind;
    return object.value();
}

/// QuickJS source map: narrow DataView constructor used by transitional
/// `new_dataview` bytecode.
pub fn dataViewConstruct(rt: *core.JSRuntime, args: []const core.JSValue, prototype: ?*core.Object) !core.JSValue {
    if (args.len < 1) return error.TypeError;
    const buffer = try expectArrayBufferObject(args[0]);
    if (buffer.arrayBufferDetached()) return error.TypeError;
    const buffer_length = arrayBufferByteLength(buffer);
    const byte_offset = if (args.len >= 2) try toIndexUsize(rt, args[1]) else @as(usize, 0);
    if (byte_offset > buffer_length) return error.RangeError;
    const auto_length = !(args.len >= 3 and !args[2].isUndefined());
    const view_length = if (!auto_length)
        try toIndexUsize(rt, args[2])
    else
        buffer_length - byte_offset;
    if (byte_offset + view_length > buffer_length) return error.RangeError;

    const object = try core.Object.create(rt, core.class.ids.dataview, prototype);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    if (view_length > @as(usize, @intCast(std.math.maxInt(u32)))) return error.RangeError;
    try object.setOptionalValueSlot(rt, object.typedArrayBufferSlot(), buffer.value().dup());
    object.typedArrayByteOffsetSlot().* = byte_offset;
    object.typedArrayFixedLengthSlot().* = @intCast(view_length);
    object.typedArrayKindSlot().* = if (auto_length) 1 else 0;
    return object.value();
}

pub fn dataViewValidateConstructorRange(_: *core.JSRuntime, buffer_value: core.JSValue, byte_offset: usize, view_length: ?usize) !void {
    const buffer = try expectArrayBufferObject(buffer_value);
    if (buffer.arrayBufferDetached()) return error.TypeError;
    const buffer_length = arrayBufferByteLength(buffer);
    if (byte_offset > buffer_length) return error.RangeError;
    const remaining = buffer_length - byte_offset;
    if (view_length) |length| {
        if (length > remaining) return error.RangeError;
    }
}

pub fn dataViewRequireArrayBuffer(buffer_value: core.JSValue) !void {
    _ = try expectArrayBufferObject(buffer_value);
}

/// QuickJS source map: narrow ArrayBuffer.prototype.slice helper.
pub fn arrayBufferSlice(rt: *core.JSRuntime, buffer_value: core.JSValue, start_value: core.JSValue, end_value: core.JSValue) !core.JSValue {
    const buffer = try expectArrayBufferObject(buffer_value);
    if (buffer.arrayBufferDetached()) return error.TypeError;
    if (arrayBufferIsImmutable(rt, buffer)) return error.TypeError;
    const source_length = arrayBufferByteLength(buffer);
    const start = try relativeSliceIndex(rt, start_value, source_length, false);
    const end = try relativeSliceIndex(rt, end_value, source_length, true);
    return arrayBufferSliceRange(rt, buffer_value, start, end);
}

pub fn arrayBufferSliceRange(rt: *core.JSRuntime, buffer_value: core.JSValue, start: usize, end: usize) !core.JSValue {
    const buffer = try expectArrayBufferObject(buffer_value);
    if (buffer.arrayBufferDetached()) return error.TypeError;
    if (arrayBufferIsImmutable(rt, buffer)) return error.TypeError;
    const length = if (end > start) end - start else 0;
    const out = try createArrayBufferWithPrototype(rt, length, null, buffer.prototype);
    errdefer out.free(rt);
    const out_object = try expectArrayBufferObject(out);
    if (length != 0) @memcpy(out_object.byteStorage(), buffer.byteStorage()[start..end]);
    return out;
}

pub fn arrayBufferSliceToImmutable(rt: *core.JSRuntime, buffer_value: core.JSValue, start_value: core.JSValue, end_value: core.JSValue) !core.JSValue {
    const buffer = try expectArrayBufferOnlyObject(buffer_value);
    if (buffer.arrayBufferDetached()) return error.TypeError;
    if (arrayBufferIsImmutable(rt, buffer)) return error.TypeError;
    const source_length = arrayBufferByteLength(buffer);
    const start = try relativeSliceIndex(rt, start_value, source_length, false);
    const end = try relativeSliceIndex(rt, end_value, source_length, true);
    return arrayBufferSliceToImmutableRange(rt, buffer_value, start, end);
}

pub fn arrayBufferSliceToImmutableRange(rt: *core.JSRuntime, buffer_value: core.JSValue, start: usize, end: usize) !core.JSValue {
    const buffer = try expectArrayBufferOnlyObject(buffer_value);
    if (buffer.arrayBufferDetached()) return error.TypeError;
    if (arrayBufferIsImmutable(rt, buffer)) return error.TypeError;
    if (buffer.byteStorage().len < end) return error.RangeError;
    const length = if (end > start) end - start else 0;
    const out = try createArrayBufferWithPrototype(rt, length, null, buffer.prototype);
    errdefer out.free(rt);
    const out_object = try expectArrayBufferOnlyObject(out);
    if (length != 0) @memcpy(out_object.byteStorage(), buffer.byteStorage()[start..end]);
    try markArrayBufferImmutable(rt, out_object);
    return out;
}

pub fn arrayBufferTransfer(rt: *core.JSRuntime, buffer_value: core.JSValue, new_length_value: core.JSValue, fixed_length: bool) !core.JSValue {
    const buffer = try expectArrayBufferOnlyObject(buffer_value);
    const new_length = if (new_length_value.isUndefined()) buffer.byteStorage().len else try toIndexUsize(rt, new_length_value);
    return arrayBufferTransferLength(rt, buffer_value, new_length, fixed_length);
}

pub fn arrayBufferTransferLength(rt: *core.JSRuntime, buffer_value: core.JSValue, new_length: usize, fixed_length: bool) !core.JSValue {
    const buffer = try expectArrayBufferOnlyObject(buffer_value);
    if (buffer.arrayBufferDetached()) return error.TypeError;
    if (arrayBufferIsImmutable(rt, buffer)) return error.TypeError;
    if (!fixed_length) {
        if (buffer.arrayBufferMaxByteLength()) |max| {
            if (new_length > max) return error.RangeError;
        }
    }
    const out = try createArrayBufferWithPrototype(rt, new_length, if (fixed_length) null else buffer.arrayBufferMaxByteLength(), buffer.prototype);
    errdefer out.free(rt);
    const out_object = try expectArrayBufferObject(out);
    const copy_len = @min(buffer.byteStorage().len, new_length);
    if (copy_len != 0) @memcpy(out_object.byteStorage()[0..copy_len], buffer.byteStorage()[0..copy_len]);
    const detached = try detachArrayBuffer(rt, buffer.value());
    detached.free(rt);
    return out;
}

pub fn arrayBufferTransferToImmutable(rt: *core.JSRuntime, buffer_value: core.JSValue, new_length_value: core.JSValue) !core.JSValue {
    const buffer = try expectArrayBufferOnlyObject(buffer_value);
    const new_length = if (new_length_value.isUndefined()) buffer.byteStorage().len else try toIndexUsize(rt, new_length_value);
    return arrayBufferTransferToImmutableLength(rt, buffer_value, new_length);
}

pub fn arrayBufferTransferToImmutableLength(rt: *core.JSRuntime, buffer_value: core.JSValue, new_length: usize) !core.JSValue {
    const buffer = try expectArrayBufferOnlyObject(buffer_value);
    if (buffer.arrayBufferDetached()) return error.TypeError;
    if (arrayBufferIsImmutable(rt, buffer)) return error.TypeError;
    const out = try createArrayBufferWithPrototype(rt, new_length, null, buffer.prototype);
    errdefer out.free(rt);
    const out_object = try expectArrayBufferOnlyObject(out);
    const copy_len = @min(buffer.byteStorage().len, new_length);
    if (copy_len != 0) @memcpy(out_object.byteStorage()[0..copy_len], buffer.byteStorage()[0..copy_len]);
    try markArrayBufferImmutable(rt, out_object);
    const detached = try detachArrayBuffer(rt, buffer.value());
    detached.free(rt);
    return out;
}

pub fn sharedArrayBufferSlice(rt: *core.JSRuntime, buffer_value: core.JSValue, start_value: core.JSValue, end_value: core.JSValue) !core.JSValue {
    const buffer = try expectSharedArrayBufferObject(buffer_value);
    const source_length = buffer.byteStorage().len;
    const start = try relativeSliceIndex(rt, start_value, source_length, false);
    const end = try relativeSliceIndex(rt, end_value, source_length, true);
    return sharedArrayBufferSliceRange(rt, buffer_value, start, end);
}

pub fn sharedArrayBufferSliceRange(rt: *core.JSRuntime, buffer_value: core.JSValue, start: usize, end: usize) !core.JSValue {
    const buffer = try expectSharedArrayBufferObject(buffer_value);
    const length = if (end > start) end - start else 0;
    const out = try sharedArrayBufferConstructArgs(rt, &.{core.JSValue.int32(@intCast(length))}, buffer.prototype);
    errdefer out.free(rt);
    const out_object = try expectSharedArrayBufferObject(out);
    if (length != 0) @memcpy(out_object.byteStorage(), buffer.byteStorage()[start..end]);
    return out;
}

pub fn sharedArrayBufferGrow(rt: *core.JSRuntime, buffer_value: core.JSValue, new_length_value: core.JSValue) !core.JSValue {
    const new_length = try toIndexUsize(rt, new_length_value);
    return sharedArrayBufferGrowLength(rt, buffer_value, new_length);
}

pub fn sharedArrayBufferGrowLength(rt: *core.JSRuntime, buffer_value: core.JSValue, new_length: usize) !core.JSValue {
    const buffer = try expectSharedArrayBufferObject(buffer_value);
    const max = buffer.arrayBufferMaxByteLength() orelse return error.TypeError;
    if (new_length < buffer.byteStorage().len) return error.RangeError;
    if (new_length > max) return error.RangeError;
    const old = buffer.byteStorage();
    const store = try core.object.SharedBufferStore.create(rt, new_length);
    errdefer store.release();
    if (old.len != 0) @memcpy(store.bytes[0..old.len], old);
    buffer.installSharedByteStorage(rt, store);
    return core.JSValue.undefinedValue();
}

/// QuickJS source map: narrow DataView.prototype getter helper.
pub fn dataViewGet(rt: *core.JSRuntime, view_value: core.JSValue, kind: u32, args: []const core.JSValue) !core.JSValue {
    const view = try expectDataViewObject(view_value);
    const index = if (args.len >= 1) try toIndexUsize(rt, args[0]) else @as(usize, 0);
    const little_endian = args.len >= 2 and isTruthy(args[1]);
    const width = dataViewKindWidth(kind);
    try checkDataViewAttached(rt, view);
    try checkDataViewBounds(rt, view, index, width);
    const absolute = view.typedArrayByteOffset() + index;
    const buffer = try dataViewBuffer(view);

    var bytes: [8]u8 = undefined;
    var i: usize = 0;
    while (i < width) : (i += 1) bytes[i] = buffer.byteStorage()[absolute + i];

    const endian: std.builtin.Endian = if (little_endian) .little else .big;
    return switch (kind) {
        1 => core.JSValue.int32(@as(i8, @bitCast(bytes[0]))),
        2 => core.JSValue.int32(bytes[0]),
        3 => core.JSValue.int32(std.mem.readInt(i16, bytes[0..2], endian)),
        4 => core.JSValue.int32(std.mem.readInt(u16, bytes[0..2], endian)),
        5 => core.JSValue.int32(std.mem.readInt(i32, bytes[0..4], endian)),
        6 => numberResult(@floatFromInt(std.mem.readInt(u32, bytes[0..4], endian))),
        7 => numberResult(@floatCast(@as(f32, @bitCast(std.mem.readInt(u32, bytes[0..4], endian))))),
        8 => numberResult(@bitCast(std.mem.readInt(u64, bytes[0..8], endian))),
        9 => bigIntResult(rt, std.mem.readInt(i64, bytes[0..8], endian)),
        10 => bigIntResult(rt, @intCast(std.mem.readInt(u64, bytes[0..8], endian))),
        11 => numberResult(float16ToF64(std.mem.readInt(u16, bytes[0..2], endian))),
        else => error.TypeError,
    };
}

/// QuickJS source map: narrow DataView.prototype setter helper.
pub fn dataViewSet(rt: *core.JSRuntime, view_value: core.JSValue, kind: u32, args: []const core.JSValue) !core.JSValue {
    const view = try expectDataViewObject(view_value);
    const buffer = try dataViewBuffer(view);
    if (arrayBufferIsImmutable(rt, buffer)) return error.TypeError;
    const index_arg = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const index = try toIndexUsize(rt, index_arg);
    const value_arg = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const little_endian = args.len >= 3 and isTruthy(args[2]);
    const width = dataViewKindWidth(kind);

    var bytes: [8]u8 = undefined;
    const endian: std.builtin.Endian = if (little_endian) .little else .big;
    switch (kind) {
        1, 2 => bytes[0] = @truncate(numberToUint32(try coerceNumber(rt, value_arg))),
        3, 4 => std.mem.writeInt(u16, bytes[0..2], @truncate(numberToUint32(try coerceNumber(rt, value_arg))), endian),
        5 => std.mem.writeInt(u32, bytes[0..4], numberToUint32(try coerceNumber(rt, value_arg)), endian),
        6 => std.mem.writeInt(u32, bytes[0..4], numberToUint32(try coerceNumber(rt, value_arg)), endian),
        7 => std.mem.writeInt(u32, bytes[0..4], @bitCast(@as(f32, @floatCast(try coerceNumber(rt, value_arg)))), endian),
        8 => std.mem.writeInt(u64, bytes[0..8], @bitCast(try coerceNumber(rt, value_arg)), endian),
        9, 10 => std.mem.writeInt(u64, bytes[0..8], try valueToBigInt64Bits(rt, value_arg), endian),
        11 => std.mem.writeInt(u16, bytes[0..2], f64ToFloat16(try coerceNumber(rt, value_arg)), endian),
        else => return error.TypeError,
    }

    try checkDataViewAttached(rt, view);
    try checkDataViewBounds(rt, view, index, width);
    const absolute = view.typedArrayByteOffset() + index;
    var i: usize = 0;
    while (i < width) : (i += 1) buffer.byteStorage()[absolute + i] = bytes[i];
    return core.JSValue.undefinedValue();
}

pub fn dataViewRejectImmutable(rt: *core.JSRuntime, view_value: core.JSValue) !void {
    const view = try expectDataViewObject(view_value);
    const buffer = try dataViewBuffer(view);
    if (arrayBufferIsImmutable(rt, buffer)) return error.TypeError;
}

pub fn dataViewRequire(view_value: core.JSValue) !void {
    _ = try expectDataViewObject(view_value);
}

pub fn dataViewByteLength(rt: *core.JSRuntime, view: *core.Object) !usize {
    return dataViewEffectiveByteLength(rt, view);
}

pub fn dataViewByteOffset(rt: *core.JSRuntime, view: *core.Object) !usize {
    _ = try dataViewEffectiveByteLength(rt, view);
    return view.typedArrayByteOffset();
}

pub fn arrayBufferResize(rt: *core.JSRuntime, buffer_value: core.JSValue, new_length_value: core.JSValue) !core.JSValue {
    const buffer = try expectArrayBufferOnlyObject(buffer_value);
    if (arrayBufferIsImmutable(rt, buffer)) return error.TypeError;
    const new_length = try toIndexUsize(rt, new_length_value);
    if (buffer.arrayBufferDetached()) return error.TypeError;
    return arrayBufferResizeLength(rt, buffer_value, new_length);
}

pub fn arrayBufferResizeLength(rt: *core.JSRuntime, buffer_value: core.JSValue, new_length: usize) !core.JSValue {
    const buffer = try expectArrayBufferOnlyObject(buffer_value);
    if (buffer.arrayBufferDetached()) return error.TypeError;
    if (arrayBufferIsImmutable(rt, buffer)) return error.TypeError;
    const max = buffer.arrayBufferMaxByteLength() orelse return error.TypeError;
    if (new_length > max) return error.RangeError;
    const old = buffer.byteStorage();
    const next = try rt.memory.alloc(u8, new_length);
    errdefer rt.memory.free(u8, next);
    const copy_len = @min(old.len, new_length);
    if (copy_len != 0) @memcpy(next[0..copy_len], old[0..copy_len]);
    if (new_length > copy_len) @memset(next[copy_len..], 0);
    try buffer.installByteStorage(rt, next);
    return core.JSValue.undefinedValue();
}

pub fn detachArrayBuffer(rt: *core.JSRuntime, buffer_value: core.JSValue) !core.JSValue {
    const buffer = try expectArrayBufferOnlyObject(buffer_value);
    buffer.detachByteStorage(rt);
    return core.JSValue.undefinedValue();
}

pub fn isTypedArrayObject(object: *const core.Object) bool {
    return object.typedArrayBuffer() != null and object.typedArrayElementSize() != 0;
}

pub fn typedArrayOutOfBounds(object: *core.Object) !bool {
    const buffer = try typedArrayBufferObject(object);
    if (object.typedArrayByteOffset() > buffer.byteStorage().len) return true;
    if (object.typedArrayFixedLength()) |fixed| {
        const bytes = @as(usize, fixed) * object.typedArrayElementSize();
        return bytes > buffer.byteStorage().len - object.typedArrayByteOffset();
    }
    return false;
}

pub fn typedArrayDetached(object: *core.Object) !bool {
    const buffer = try typedArrayBufferObject(object);
    return buffer.arrayBufferDetached();
}

pub fn typedArrayLength(rt: *core.JSRuntime, object: *core.Object) !u32 {
    _ = rt;
    const buffer = try typedArrayBufferObject(object);
    if (buffer.arrayBufferDetached()) return 0;
    if (object.typedArrayByteOffset() > buffer.byteStorage().len) return 0;
    if (object.typedArrayFixedLength()) |fixed| {
        const bytes = @as(usize, fixed) * object.typedArrayElementSize();
        if (bytes > buffer.byteStorage().len - object.typedArrayByteOffset()) return 0;
        return fixed;
    }
    return @intCast(@divTrunc(buffer.byteStorage().len - object.typedArrayByteOffset(), object.typedArrayElementSize()));
}

pub fn typedArrayByteLength(rt: *core.JSRuntime, object: *core.Object) !usize {
    const length = try typedArrayLength(rt, object);
    return @as(usize, length) * object.typedArrayElementSize();
}

pub fn typedArrayByteOffset(object: *core.Object) !usize {
    if (try typedArrayDetached(object)) return 0;
    if (try typedArrayOutOfBounds(object)) return 0;
    return object.typedArrayByteOffset();
}

pub fn typedArrayGetIndex(rt: *core.JSRuntime, object: *core.Object, index: u32) !core.JSValue {
    const length = try typedArrayLength(rt, object);
    if (index >= length) return core.JSValue.undefinedValue();
    const buffer = try typedArrayBufferObject(object);
    const offset = object.typedArrayByteOffset() + @as(usize, index) * object.typedArrayElementSize();
    return readElement(rt, object.typedArrayKind(), buffer.byteStorage()[offset..][0..object.typedArrayElementSize()]);
}

pub fn typedArrayIndexValid(rt: *core.JSRuntime, object: *core.Object, index: u32) !bool {
    const length = try typedArrayLength(rt, object);
    return index < length;
}

pub fn typedArrayCoerceElementValue(rt: *core.JSRuntime, object: *core.Object, value: core.JSValue) !void {
    var scratch: [8]u8 = undefined;
    try writeElement(rt, object.typedArrayKind(), scratch[0..object.typedArrayElementSize()], value);
}

pub fn typedArraySetElement(rt: *core.JSRuntime, object: *core.Object, index: u32, value: core.JSValue) !bool {
    if (try typedArrayImmutableBuffer(rt, object)) return false;
    var scratch: [8]u8 = undefined;
    const width = object.typedArrayElementSize();
    try writeElement(rt, object.typedArrayKind(), scratch[0..width], value);
    if (!try typedArrayIndexValid(rt, object, index)) return false;
    const buffer = try typedArrayBufferObject(object);
    const offset = object.typedArrayByteOffset() + @as(usize, index) * width;
    @memcpy(buffer.byteStorage()[offset..][0..width], scratch[0..width]);
    return true;
}

pub fn typedArraySetIndex(rt: *core.JSRuntime, object: *core.Object, index: u32, value: core.JSValue) !bool {
    if (try typedArrayImmutableBuffer(rt, object)) return false;
    const length = try typedArrayLength(rt, object);
    if (index >= length) return true;
    const buffer = try typedArrayBufferObject(object);
    const offset = object.typedArrayByteOffset() + @as(usize, index) * object.typedArrayElementSize();
    try writeElement(rt, object.typedArrayKind(), buffer.byteStorage()[offset..][0..object.typedArrayElementSize()], value);
    return true;
}

pub fn typedArraySetInt32IndexFast(rt: *core.JSRuntime, object: *core.Object, index: u32, value: i32) !bool {
    if (object.typedArrayKind() != 6) return false;
    if (try typedArrayImmutableBuffer(rt, object)) return false;
    const length = try typedArrayLength(rt, object);
    if (index >= length) return true;
    const buffer = try typedArrayBufferObject(object);
    const offset = object.typedArrayByteOffset() + @as(usize, index) * 4;
    std.mem.writeInt(i32, buffer.byteStorage()[offset..][0..4], value, .little);
    return true;
}

const TypedArrayCanonicalIndex = union(enum) {
    none,
    invalid,
    index: u32,
};

fn typedArrayCanonicalNumericIndex(rt: *core.JSRuntime, atom_id: core.Atom) !TypedArrayCanonicalIndex {
    if (core.array.arrayIndexFromAtom(&rt.atoms, atom_id)) |index| return .{ .index = index };
    if (rt.atoms.kind(atom_id) != .string) return .none;
    const name = rt.atoms.name(atom_id) orelse return .none;
    if (name.len == 0) return .none;
    if (std.mem.eql(u8, name, "-0")) return .invalid;

    const number: f64 = if (std.mem.eql(u8, name, "NaN"))
        std.math.nan(f64)
    else if (std.mem.eql(u8, name, "Infinity"))
        std.math.inf(f64)
    else if (std.mem.eql(u8, name, "-Infinity"))
        -std.math.inf(f64)
    else
        std.fmt.parseFloat(f64, name) catch return .none;

    var buf: [64]u8 = undefined;
    const printed = if (std.math.isNan(number))
        "NaN"
    else if (std.math.isPositiveInf(number))
        "Infinity"
    else if (std.math.isNegativeInf(number))
        "-Infinity"
    else
        try core.value_format.formatFiniteNumber(&buf, number);
    if (!std.mem.eql(u8, name, printed)) return .none;
    if (!std.math.isFinite(number) or @trunc(number) != number or number < 0 or number > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return .invalid;
    return .{ .index = @intFromFloat(number) };
}

pub fn typedArrayDefineOwnProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, desc: core.Descriptor) !?bool {
    if (!isTypedArrayObject(object)) return null;
    switch (try typedArrayCanonicalNumericIndex(rt, atom_id)) {
        .none => return null,
        .invalid => return false,
        .index => |index| {
            if (desc.kind == .accessor) return false;
            if (desc.configurable) |configurable| {
                if (!configurable) return false;
            }
            if (desc.enumerable) |enumerable| {
                if (!enumerable) return false;
            }
            if (desc.writable) |writable| {
                if (!writable) return false;
            }
            if (!try typedArrayIndexValid(rt, object, index)) return false;
            if (try typedArrayImmutableBuffer(rt, object)) return false;
            if (desc.value_present) _ = try typedArraySetElement(rt, object, index, desc.value);
            return true;
        },
    }
}

pub fn typedArrayBackedByResizableBuffer(object: *core.Object) bool {
    if (!isTypedArrayObject(object)) return false;
    const buffer = typedArrayBufferObject(object) catch return false;
    return buffer.arrayBufferMaxByteLength() != null;
}

fn createArrayBuffer(rt: *core.JSRuntime, byte_length: usize, max_byte_length: ?usize) !core.JSValue {
    return createArrayBufferWithPrototype(rt, byte_length, max_byte_length, null);
}

fn relativeSliceIndex(rt: *core.JSRuntime, value: core.JSValue, len: usize, undefined_is_len: bool) !usize {
    if (undefined_is_len and value.isUndefined()) return len;

    const relative = try toIntegerOrInfinity(rt, value);
    if (std.math.isNan(relative)) return 0;
    if (std.math.isNegativeInf(relative)) return 0;
    if (std.math.isPositiveInf(relative)) return len;

    const truncated = @trunc(relative);
    if (truncated < 0) {
        const len_float: f64 = @floatFromInt(len);
        const from_end = len_float + truncated;
        if (from_end <= 0) return 0;
        if (from_end >= len_float) return len;
        return @intFromFloat(from_end);
    }
    if (truncated == 0) return 0;

    const len_float: f64 = @floatFromInt(len);
    if (truncated >= len_float) return len;
    return @intFromFloat(truncated);
}

fn createArrayBufferWithPrototype(rt: *core.JSRuntime, byte_length: usize, max_byte_length: ?usize, prototype: ?*core.Object) !core.JSValue {
    const object = try core.Object.create(rt, core.class.ids.array_buffer, prototype);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    try validateArrayBufferLength(byte_length);
    if (max_byte_length) |max| try validateArrayBufferLength(max);
    if (!try object.installInlineByteStorage(rt, byte_length)) {
        const bytes = try rt.memory.alloc(u8, byte_length);
        errdefer rt.memory.free(u8, bytes);
        try object.installByteStorage(rt, bytes);
    }
    @memset(object.byteStorage(), 0);
    object.arrayBufferMaxByteLengthSlot().* = max_byte_length;
    return object.value();
}

fn validateArrayBufferLength(byte_length: usize) !void {
    if (byte_length > @as(usize, @intCast(std.math.maxInt(i32)))) return error.RangeError;
}

fn arrayBufferByteLength(buffer: *core.Object) usize {
    return if (buffer.arrayBufferDetached()) 0 else buffer.byteStorage().len;
}

fn typedArrayLengthFromObject(object: *core.Object) !u32 {
    const buffer = try typedArrayBufferObject(object);
    if (object.typedArrayByteOffset() > buffer.byteStorage().len) return 0;
    if (object.typedArrayFixedLength()) |fixed| {
        const bytes = @as(usize, fixed) * object.typedArrayElementSize();
        if (bytes > buffer.byteStorage().len - object.typedArrayByteOffset()) return 0;
        return fixed;
    }
    return @intCast(@divTrunc(buffer.byteStorage().len - object.typedArrayByteOffset(), object.typedArrayElementSize()));
}

fn typedArrayBufferObject(object: *core.Object) !*core.Object {
    const value = object.typedArrayBuffer() orelse return error.TypeError;
    return expectArrayBufferObject(value);
}

pub fn typedArrayRejectImmutableBuffer(rt: *core.JSRuntime, object: *core.Object) !void {
    if (try typedArrayImmutableBuffer(rt, object)) return error.TypeError;
}

pub fn typedArrayImmutableBuffer(rt: *core.JSRuntime, object: *core.Object) !bool {
    const buffer = try typedArrayBufferObject(object);
    return arrayBufferIsImmutable(rt, buffer);
}

fn expectObject(value: core.JSValue) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    return @fieldParentPtr("header", header);
}

fn expectArrayBufferObject(value: core.JSValue) !*core.Object {
    const object = try expectObject(value);
    if (object.class_id != core.class.ids.array_buffer and object.class_id != core.class.ids.shared_array_buffer) return error.TypeError;
    return object;
}

fn expectArrayBufferOnlyObject(value: core.JSValue) !*core.Object {
    const object = try expectObject(value);
    if (object.class_id != core.class.ids.array_buffer) return error.TypeError;
    return object;
}

fn expectSharedArrayBufferObject(value: core.JSValue) !*core.Object {
    const object = try expectObject(value);
    if (object.class_id != core.class.ids.shared_array_buffer) return error.TypeError;
    return object;
}

fn expectDataViewObject(value: core.JSValue) !*core.Object {
    const object = try expectObject(value);
    if (object.class_id != core.class.ids.dataview) return error.TypeError;
    return object;
}

fn defineIntPropertyChecked(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: usize) !void {
    try defineIntPropertyCheckedFlags(rt, object, name, value, true);
}

fn defineIntPropertyCheckedFlags(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: usize, enumerable: bool) !void {
    if (value > @as(usize, @intCast(std.math.maxInt(i32)))) return error.RangeError;
    try defineIntPropertyFlags(rt, object, name, @intCast(value), enumerable);
}

fn setIntPropertyChecked(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: usize) !void {
    if (value > @as(usize, @intCast(std.math.maxInt(i32)))) return error.RangeError;
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.setProperty(rt, key, core.JSValue.int32(@intCast(value)));
}

fn defineIntProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: i32) !void {
    try defineIntPropertyFlags(rt, object, name, value, true);
}

fn defineIntPropertyFlags(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: i32, enumerable: bool) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(value), true, enumerable, true));
}

fn defineValueProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: core.JSValue) !void {
    try defineValuePropertyFlags(rt, object, name, value, true);
}

fn defineValuePropertyFlags(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: core.JSValue, enumerable: bool) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value, true, enumerable, true));
}

pub fn markArrayBufferImmutable(rt: *core.JSRuntime, object: *core.Object) !void {
    _ = rt;
    object.arrayBufferImmutableSlot().* = true;
}

pub fn arrayBufferIsImmutable(rt: *core.JSRuntime, object: *core.Object) bool {
    _ = rt;
    return object.arrayBufferImmutable();
}

fn getNamedProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8) !core.JSValue {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    return object.getProperty(key);
}

fn getIntProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8) !i32 {
    const value = try getNamedProperty(rt, object, name);
    defer value.free(rt);
    return value.asInt32() orelse 0;
}

fn objectIntProperty(rt: *core.JSRuntime, object_value: core.JSValue, name: []const u8) !i32 {
    const object = try expectObject(object_value);
    return getIntProperty(rt, object, name);
}

fn checkDataViewBounds(rt: *core.JSRuntime, view: *core.Object, index: usize, width: usize) !void {
    const length = try dataViewEffectiveByteLength(rt, view);
    if (index > length or width > length - index) return error.RangeError;
}

fn checkDataViewAttached(rt: *core.JSRuntime, view: *core.Object) !void {
    _ = rt;
    const buffer = try dataViewBuffer(view);
    if (buffer.arrayBufferDetached()) return error.TypeError;
}

fn dataViewEffectiveByteLength(rt: *core.JSRuntime, view: *core.Object) !usize {
    _ = rt;
    const buffer = try dataViewBuffer(view);
    if (buffer.arrayBufferDetached()) return error.TypeError;
    const byte_offset = view.typedArrayByteOffset();
    const stored_length = view.typedArrayFixedLength() orelse return error.TypeError;
    if (buffer.arrayBufferMaxByteLength() == null) return stored_length;

    if (view.typedArrayKind() == 1) {
        if (buffer.byteStorage().len < byte_offset) return error.TypeError;
        return buffer.byteStorage().len - byte_offset;
    }
    if (buffer.byteStorage().len < byte_offset or stored_length > buffer.byteStorage().len - byte_offset) return error.TypeError;
    return stored_length;
}

fn dataViewBuffer(view: *core.Object) !*core.Object {
    return expectArrayBufferObject(view.typedArrayBuffer() orelse return error.TypeError);
}

fn numberResult(value: f64) core.JSValue {
    if (std.math.isFinite(value) and @floor(value) == value and value >= @as(f64, @floatFromInt(std.math.minInt(i32))) and value <= @as(f64, @floatFromInt(std.math.maxInt(i32))) and !isNegativeZero(value)) {
        return core.JSValue.int32(@intFromFloat(value));
    }
    return core.JSValue.float64(value);
}

fn bigIntResult(rt: *core.JSRuntime, value: i128) !core.JSValue {
    const big = try core.bigint.BigInt.create(rt, value);
    return big.valueRef();
}

fn numberValue(value: core.JSValue) ?f64 {
    if (value.asInt32()) |int_value| return @floatFromInt(int_value);
    if (value.asFloat64()) |float_value| return float_value;
    return null;
}

fn valueToInt32(value: core.JSValue) i32 {
    return @bitCast(valueToUint32(value));
}

fn valueToUint32(value: core.JSValue) u32 {
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

fn numberToUint32(number: f64) u32 {
    if (!std.math.isFinite(number) or std.math.isNan(number)) return 0;
    const two32 = 4294967296.0;
    var modulo = @mod(@trunc(number), two32);
    if (modulo < 0) modulo += two32;
    return @intFromFloat(modulo);
}

fn numberToUint8Clamp(number: f64) u8 {
    if (std.math.isNan(number) or number <= 0) return 0;
    if (number >= 255) return 255;

    const lower = std.math.floor(number);
    const diff = number - lower;
    if (diff < 0.5) return @intFromFloat(lower);
    if (diff > 0.5) return @intFromFloat(lower + 1);

    const lower_int: u32 = @intFromFloat(lower);
    if ((lower_int & 1) == 0) return @intCast(lower_int);
    return @intCast(lower_int + 1);
}

fn coerceNumber(rt: *core.JSRuntime, value: core.JSValue) !f64 {
    if (value.isSymbol()) return error.TypeError;
    if (numberValue(value)) |number| return number;
    if (value.asBool()) |bool_value| return if (bool_value) 1 else 0;
    if (value.isNull()) return 0;
    if (value.isString()) {
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(rt.memory.allocator);
        try appendRawString(rt, &bytes, value);
        return parseJsNumber(bytes.items);
    }
    return std.math.nan(f64);
}

fn dataViewKindWidth(kind: u32) usize {
    return switch (kind) {
        1, 2 => 1,
        3, 4, 11 => 2,
        5, 6, 7 => 4,
        8, 9, 10 => 8,
        else => 0,
    };
}

fn float16ToF64(bits: u16) f64 {
    return @floatCast(@as(f16, @bitCast(bits)));
}

fn f64ToFloat16(value: f64) u16 {
    return @bitCast(@as(f16, @floatCast(value)));
}

fn readElement(rt: *core.JSRuntime, kind: u8, bytes: []const u8) !core.JSValue {
    return switch (kind) {
        1 => core.JSValue.int32(@as(i8, @bitCast(bytes[0]))),
        2 => core.JSValue.int32(bytes[0]),
        3 => core.JSValue.int32(bytes[0]),
        4 => core.JSValue.int32(std.mem.readInt(i16, bytes[0..2], .little)),
        5 => core.JSValue.int32(std.mem.readInt(u16, bytes[0..2], .little)),
        6 => core.JSValue.int32(std.mem.readInt(i32, bytes[0..4], .little)),
        7 => numberResult(@floatFromInt(std.mem.readInt(u32, bytes[0..4], .little))),
        8 => numberResult(float16ToF64(std.mem.readInt(u16, bytes[0..2], .little))),
        9 => numberResult(@floatCast(@as(f32, @bitCast(std.mem.readInt(u32, bytes[0..4], .little))))),
        10 => numberResult(@bitCast(std.mem.readInt(u64, bytes[0..8], .little))),
        11 => bigIntResult(rt, std.mem.readInt(i64, bytes[0..8], .little)),
        12 => bigIntResult(rt, @intCast(std.mem.readInt(u64, bytes[0..8], .little))),
        else => error.TypeError,
    };
}

fn writeElement(rt: *core.JSRuntime, kind: u8, bytes: []u8, value: core.JSValue) !void {
    switch (kind) {
        1, 2 => {
            if (value.isBigInt()) return error.TypeError;
            bytes[0] = @truncate(numberToUint32(try coerceNumber(rt, value)));
        },
        3 => {
            if (value.isBigInt()) return error.TypeError;
            bytes[0] = numberToUint8Clamp(try coerceNumber(rt, value));
        },
        4, 5 => {
            if (value.isBigInt()) return error.TypeError;
            std.mem.writeInt(u16, bytes[0..2], @truncate(numberToUint32(try coerceNumber(rt, value))), .little);
        },
        6, 7 => {
            if (value.isBigInt()) return error.TypeError;
            std.mem.writeInt(u32, bytes[0..4], numberToUint32(try coerceNumber(rt, value)), .little);
        },
        8 => {
            if (value.isBigInt()) return error.TypeError;
            std.mem.writeInt(u16, bytes[0..2], f64ToFloat16(try coerceNumber(rt, value)), .little);
        },
        9 => {
            if (value.isBigInt()) return error.TypeError;
            std.mem.writeInt(u32, bytes[0..4], @bitCast(@as(f32, @floatCast(try coerceNumber(rt, value)))), .little);
        },
        10 => {
            if (value.isBigInt()) return error.TypeError;
            std.mem.writeInt(u64, bytes[0..8], @bitCast(try coerceNumber(rt, value)), .little);
        },
        11, 12 => std.mem.writeInt(u64, bytes[0..8], try valueToBigInt64Bits(rt, value), .little),
        else => return error.TypeError,
    }
}

fn valueToBigInt64Bits(rt: *core.JSRuntime, value: core.JSValue) !u64 {
    var big = try toBigIntValue(rt, value);
    defer big.deinit();
    const low: u64 = if (big.limbs.len >= 1) big.limbs[0] else 0;
    return if (big.negative) 0 -% low else low;
}

fn toBigIntValue(rt: *core.JSRuntime, value: core.JSValue) !bignum.BigInt {
    if (value.isBigInt()) return cloneBigIntValue(rt, value);
    if (value.isNumber()) return error.TypeError;
    if (value.asBool()) |bool_value| return bignum.BigInt.fromIntAlloc(rt.memory.allocator, if (bool_value) 1 else 0);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    if (value.isString() or value.isObject()) {
        try appendValueString(rt, &buffer, value);
        const trimmed = std.mem.trim(u8, buffer.items, " \t\r\n");
        if (trimmed.len == 0) return bignum.BigInt.fromIntAlloc(rt.memory.allocator, 0);
        return bignum.parseAutoAlloc(rt.memory.allocator, trimmed) catch error.SyntaxError;
    }
    return error.TypeError;
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

fn toIntegerOrInfinity(rt: *core.JSRuntime, value: core.JSValue) !f64 {
    if (numberValue(value)) |number| return number;
    if (value.asBool()) |bool_value| return if (bool_value) 1 else 0;
    if (value.isNull()) return 0;
    if (value.isUndefined()) return std.math.nan(f64);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try appendValueString(rt, &buffer, value);
    return parseJsNumber(buffer.items);
}

fn toIndexUsize(rt: *core.JSRuntime, value: core.JSValue) !usize {
    const number = try toIntegerOrInfinity(rt, value);
    if (std.math.isNan(number)) return 0;
    if (!std.math.isFinite(number)) return error.RangeError;
    const truncated = @trunc(number);
    if (truncated < 0) return error.RangeError;
    if (truncated == 0) return 0;
    return @intFromFloat(truncated);
}

fn parseJsNumber(bytes: []const u8) f64 {
    return core.value_format.parseJsNumber(bytes);
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
            const data = object_value.objectData() orelse return error.TypeError;
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

fn appendRawString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) !void {
    const header = value.refHeader() orelse return;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    switch (string_value.resolveData()) {
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

fn appendArrayString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), object: *core.Object) AppendStringError!void {
    var index: u32 = 0;
    while (index < object.length) : (index += 1) {
        if (index != 0) try buffer.append(rt.memory.allocator, ',');
        const value = object.getProperty(core.atom.atomFromUInt32(index));
        defer value.free(rt);
        if (!value.isUndefined() and !value.isNull()) try appendValueString(rt, buffer, value);
    }
}

fn isTruthy(value: core.JSValue) bool {
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
