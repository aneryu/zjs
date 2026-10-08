//! Engine-core TypedArray / ArrayBuffer / SharedArrayBuffer / DataView
//! element-access, coercion, and storage-operation mechanism.
//!
//! QuickJS source map: the typed-array element read/write fabric, the DataView
//! get/set primitives, and the ArrayBuffer resize/slice/transfer/grow storage
//! operations all live in the engine core (quickjs.c), with the JS-visible
//! native method bodies (`exec/buffer_ops.zig`) and the VM opcode handlers as
//! clients. These functions operate purely on the core typed-array storage
//! slots (`Object.typedArrayBuffer()`, `typedArrayByteOffset()`,
//! `typedArrayElementSize()`, `typedArrayFixedLength()`, `byteStorage()`,
//! `arrayBufferDetached()`, ...) plus the BigInt / number-format / value
//! primitives (`bignum`, `value_format`, `value_semantics`); they call no VM
//! machinery and never run user code (the spec's full ToNumber / ToBigInt with
//! object coercion is done one level up, at the opcode / builtin-method layer,
//! before reaching here — `coerceNumber` / `toBigIntValue` are the primitive
//! fast paths).
//!
//! The storage-shape predicates (`isTypedArrayObject`, `typedArrayLength`,
//! `typedArrayCanonicalNumericIndex`, ...) live in this file. The pure view-construction
//! primitives (`typedArrayConstructWithOptions` / `...FullBufferOwned` /
//! `dataViewConstruct`) live here: they shape internal slots over an existing ArrayBuffer using
//! only positional-arg index coercion (`toIndexUsize`, primitive-only) and run no
//! user code. The ArrayBuffer / SharedArrayBuffer constructors read the
//! `maxByteLength` option off a user object, so they stay one level up in exec
//! (`exec/array_ops.zig`). The `*MethodId` / `*FromRecordId` /
//! `*NameFromRecordId` name machinery and its method-id enums live in
//! `core/host_function.zig` (`builtin_method_ids` + `builtin_method_id_lookup`);
//! `exec/buffer_ops.zig` re-exports both. The record dispatch table is owned by
//! `exec/buffer_ops.zig`.

const std = @import("std");

const array = @import("array.zig");
const atom = @import("atom.zig");
const bigint = @import("bigint.zig");
const class = @import("class.zig");
const Kind = @import("typed_array_names.zig").Kind;
const object = @import("object.zig");
const string = @import("string.zig");
const value_string = @import("value_string.zig");
const value_format = @import("value_format.zig");
const value_semantics = @import("value_semantics.zig");

const bignum = @import("../libs/bigint.zig");

const JSValue = @import("value.zig").JSValue;
const JSRuntime = @import("../runtime.zig").JSRuntime;
const Object = object.Object;

const AppendStringError = value_string.AppendStringError;

// --- TypedArray storage-shape predicates ------------------------------------
//
// QuickJS source map: the typed-array length/bounds/detach helpers live in the
// engine core (quickjs.c), with builtins as clients. These are thin predicates
// over the core typed-array storage slots (`Object.typedArrayBuffer()`,
// `typedArrayByteOffset()`, `typedArrayElementSize()`, `typedArrayFixedLength()`,
// `arrayBufferDetached()`, ...). The element read/write value coercion and the
// buffer storage operations live below. `src/exec/buffer_ops.zig` owns the
// JS-visible record surface that uses both.

pub fn isTypedArrayObject(obj: *const Object) bool {
    const payload = obj.typedArrayPayloadFast() orelse return false;
    return payload.buffer != null and payload.element_size != 0;
}

pub fn typedArrayOutOfBounds(obj: *Object) !bool {
    const payload = obj.typedArrayPayloadFast() orelse return error.TypeError;
    const backing = payload.backing_payload orelse return error.TypeError;
    if (payload.byte_offset > backing.bytes.len) return true;
    if (payload.fixed_length) |fixed| {
        const bytes = std.math.mul(usize, fixed, payload.element_size) catch return true;
        return bytes > backing.bytes.len - payload.byte_offset;
    }
    return false;
}

pub fn typedArrayDetached(obj: *Object) !bool {
    const payload = obj.typedArrayPayloadFast() orelse return error.TypeError;
    const backing = payload.backing_payload orelse return error.TypeError;
    return backing.detached;
}

pub fn typedArrayLength(rt: *JSRuntime, obj: *Object) !u32 {
    _ = rt;
    const payload = obj.typedArrayPayloadFast() orelse return error.TypeError;
    if (payload.element_size == 0 or payload.buffer == null or payload.backing_payload == null) return error.TypeError;
    return payload.live_length;
}

pub fn typedArrayByteLength(rt: *JSRuntime, obj: *Object) !usize {
    const length = try typedArrayLength(rt, obj);
    return @as(usize, length) * obj.typedArrayElementSize();
}

pub fn typedArrayEffectiveByteOffset(obj: *Object) !usize {
    if (try typedArrayDetached(obj)) return 0;
    if (try typedArrayOutOfBounds(obj)) return 0;
    return obj.typedArrayByteOffset();
}

pub fn typedArrayIndexValid(rt: *JSRuntime, obj: *Object, index: u32) !bool {
    _ = rt;
    const payload = obj.typedArrayPayloadFast() orelse return error.TypeError;
    if (payload.element_size == 0 or payload.buffer == null or payload.backing_payload == null) return error.TypeError;
    return index < payload.live_length;
}

pub const TypedArrayCanonicalIndex = union(enum) {
    none,
    invalid,
    index: u32,
};

pub fn typedArrayCanonicalNumericIndex(rt: *JSRuntime, atom_id: atom.Atom) !TypedArrayCanonicalIndex {
    if (array.arrayIndexFromAtom(rt.atoms, atom_id)) |index| return .{ .index = index };
    if (rt.atoms.kind(atom_id) != .string) return .none;
    const name = rt.atoms.name(atom_id) orelse return .none;
    if (name.len == 0) return .none;
    if (std.mem.eql(u8, name, "-0")) return .invalid;

    // CanonicalNumericIndexString: ToString(ToNumber(name)) must give name back.
    const number: f64 = value_format.parseJsNumber(name);

    var buf: [64]u8 = undefined;
    const printed = if (std.math.isNan(number))
        "NaN"
    else if (std.math.isPositiveInf(number))
        "Infinity"
    else if (std.math.isNegativeInf(number))
        "-Infinity"
    else
        value_format.formatFiniteNumberAssumeCapacity(&buf, number);
    if (!std.mem.eql(u8, name, printed)) return .none;
    if (!std.math.isFinite(number) or @trunc(number) != number or number < 0 or number > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return .invalid;
    return .{ .index = @intFromFloat(number) };
}

/// IsTypedArrayFixedLength: false for a length-tracking view or any view on
/// a resizable (non-shared) ArrayBuffer.
pub fn typedArrayIsFixedLength(obj: *Object) bool {
    const payload = obj.typedArrayPayloadFast() orelse return true;
    if (payload.fixed_length == null) return false;
    const backing = payload.backing_payload orelse return true;
    return backing.max_byte_length == null or backing.shared_store != null;
}

// --- ArrayBuffer construction / storage helpers (engine core) ---------------

pub fn arrayBufferConstructLength(rt: *JSRuntime, byte_length: usize, max_byte_length: ?usize, prototype: ?*Object) !JSValue {
    return createArrayBufferWithPrototype(rt, byte_length, max_byte_length, prototype);
}

pub fn sharedArrayBufferConstructLength(rt: *JSRuntime, byte_length: usize, max_byte_length: ?usize, prototype: ?*Object) !JSValue {
    const obj = try Object.create(rt, class.ids.shared_array_buffer, prototype);
    errdefer Object.destroyFromHeader(rt, obj.gcHeader());
    try validateArrayBufferLength(byte_length);
    if (max_byte_length) |max| try validateArrayBufferLength(max);
    // Mirrors js_array_buffer_constructor3: a growable
    // SharedArrayBuffer commits maxByteLength bytes upfront, and the visible
    // byte length is a prefix of that committed block, so grow never moves or
    // re-identifies the backing store.
    const store = try object.SharedBufferStore.create(rt, max_byte_length orelse byte_length);
    obj.installSharedByteStorage(rt, store);
    try obj.setSharedByteStorageLength(byte_length);
    obj.arrayBufferMaxByteLengthSlot().* = max_byte_length;
    return obj.value();
}

pub fn createArrayBufferWithPrototype(rt: *JSRuntime, byte_length: usize, max_byte_length: ?usize, prototype: ?*Object) !JSValue {
    const obj = try Object.create(rt, class.ids.array_buffer, prototype);
    errdefer Object.destroyFromHeader(rt, obj.gcHeader());
    try validateArrayBufferLength(byte_length);
    if (max_byte_length) |max| try validateArrayBufferLength(max);
    if (!try obj.installInlineByteStorage(rt, byte_length)) {
        const bytes = try rt.allocNative(u8, byte_length);
        errdefer rt.freeNative(u8, bytes);
        try obj.installByteStorage(rt, bytes);
    }
    @memset(obj.byteStorage(), 0);
    obj.arrayBufferMaxByteLengthSlot().* = max_byte_length;
    return obj.value();
}

fn validateArrayBufferLength(byte_length: usize) !void {
    if (byte_length > @as(usize, @intCast(std.math.maxInt(i32)))) return error.InvalidArrayBufferLength;
}

pub fn arrayBufferByteLength(buffer: *Object) usize {
    return if (buffer.arrayBufferDetached()) 0 else buffer.byteStorage().len;
}

// --- ArrayBuffer / SharedArrayBuffer storage operations ---------------------

/// ArrayBufferCopyAndDetach: the new buffer is allocated from %ArrayBuffer%,
/// so `prototype` is the realm's %ArrayBuffer.prototype%, not the receiver's.
pub fn arrayBufferTransferLength(rt: *JSRuntime, buffer_value: JSValue, new_length: usize, fixed_length: bool, prototype: ?*Object) !JSValue {
    const buffer = try expectArrayBufferOnlyObject(buffer_value);
    if (buffer.arrayBufferDetached()) return error.DetachedArrayBuffer;
    if (!fixed_length) {
        if (buffer.arrayBufferMaxByteLength()) |max| {
            // AllocateArrayBuffer: a length past maxByteLength is a RangeError.
            if (new_length > max) return error.InvalidArrayBufferLength;
        }
    }
    const out = try createArrayBufferWithPrototype(rt, new_length, if (fixed_length) null else buffer.arrayBufferMaxByteLength(), prototype);
    const out_object = try expectArrayBufferObject(out);
    const copy_len = @min(buffer.byteStorage().len, new_length);
    if (copy_len != 0) @memcpy(out_object.byteStorage()[0..copy_len], buffer.byteStorage()[0..copy_len]);
    _ = try detachArrayBuffer(rt, buffer.value());
    return out;
}

pub fn sharedArrayBufferGrowLength(rt: *JSRuntime, buffer_value: JSValue, new_length: usize) !JSValue {
    const buffer = try expectSharedArrayBufferObject(buffer_value);
    const max = buffer.arrayBufferMaxByteLength() orelse return error.IncompatibleReceiver;
    if (new_length < buffer.byteStorage().len) return error.InvalidArrayBufferLength;
    if (new_length > max) return error.InvalidArrayBufferLength;
    // Mirrors js_array_buffer_resize shared branch:
    // memory was committed upfront at maxByteLength by the constructor, so
    // grow only bumps the visible byte length (`abuf->byte_length = len`).
    // The store identity stays stable, keeping cross-runtime sharers and
    // Atomics waiter keys valid.
    if (buffer.sharedByteStorageStore()) |store| {
        if (store.bytes.len >= new_length) {
            try buffer.setSharedByteStorageLength(new_length);
            return JSValue.undefinedValue();
        }
    }
    // Fallback for embedder-adopted stores committed below maxByteLength
    // (JSContext.sharedArrayBufferFromRef with max > store capacity): qjs has no such
    // under-committed state, so keep the legacy copy-into-larger-store path.
    const old = buffer.byteStorage();
    const store = try object.SharedBufferStore.create(rt, new_length);
    errdefer store.release();
    if (old.len != 0) @memcpy(store.bytes[0..old.len], old);
    buffer.installSharedByteStorage(rt, store);
    return JSValue.undefinedValue();
}

pub fn arrayBufferResizeLength(rt: *JSRuntime, buffer_value: JSValue, new_length: usize) !JSValue {
    const buffer = try expectArrayBufferOnlyObject(buffer_value);
    if (buffer.arrayBufferDetached()) return error.DetachedArrayBuffer;
    const max = buffer.arrayBufferMaxByteLength() orelse return error.IncompatibleReceiver;
    if (new_length > max) return error.InvalidArrayBufferLength;
    // Growing a buffer step by step copied the whole buffer every time.
    if (try buffer.remapOwnedByteStorage(rt, new_length)) return JSValue.undefinedValue();
    const old = buffer.byteStorage();
    const next = try rt.allocNative(u8, new_length);
    errdefer rt.freeNative(u8, next);
    const copy_len = @min(old.len, new_length);
    if (copy_len != 0) @memcpy(next[0..copy_len], old[0..copy_len]);
    if (new_length > copy_len) @memset(next[copy_len..], 0);
    try buffer.installByteStorage(rt, next);
    return JSValue.undefinedValue();
}

pub fn detachArrayBuffer(rt: *JSRuntime, buffer_value: JSValue) !JSValue {
    const buffer = try expectArrayBufferOnlyObject(buffer_value);
    buffer.detachByteStorage(rt);
    return JSValue.undefinedValue();
}

// --- TypedArray / DataView view construction (engine core) ------------------
//
// QuickJS source map: typed-array / DataView view construction (`typed_array_init`
// / `js_dataview_constructor` storage shaping). These set up the internal slot
// shape over an existing ArrayBuffer; they read only positional arguments via
// the core `toIndexUsize` index coercion (which never invokes user `valueOf` /
// `Symbol.toPrimitive` — primitive-only, per this module's contract) and never
// perform a `Get(options, ...)` property lookup, so they run no user code and
// stay pure core. The ArrayBuffer / SharedArrayBuffer constructors, which read
// the `maxByteLength` option off a user object, stay one level up in exec
// (`exec/array_ops.zig`).

pub fn typedArrayClassIdForKind(kind: Kind) ?class.ClassId {
    return switch (kind) {
        .int8 => class.ids.int8_array,
        .uint8 => class.ids.uint8_array,
        .uint8_clamped => class.ids.uint8c_array,
        .int16 => class.ids.int16_array,
        .uint16 => class.ids.uint16_array,
        .int32 => class.ids.int32_array,
        .uint32 => class.ids.uint32_array,
        .float16 => class.ids.float16_array,
        .float32 => class.ids.float32_array,
        .float64 => class.ids.float64_array,
        .bigint64 => class.ids.big_int64_array,
        .biguint64 => class.ids.big_uint64_array,
        .none, .data_view_length_tracking => null,
    };
}

fn createTypedArrayInstance(rt: *JSRuntime, kind: Kind, prototype: ?*Object) !*Object {
    const class_id = typedArrayClassIdForKind(kind) orelse class.ids.object;
    const obj = try Object.create(rt, class_id, prototype);
    errdefer Object.destroyFromHeader(rt, obj.gcHeader());
    if (class_id == class.ids.object) try obj.ensureTypedArrayPayload(rt);
    return obj;
}

pub fn typedArrayConstructWithOptions(rt: *JSRuntime, element_size: u32, kind: Kind, buffer_value: JSValue, args: []const JSValue, prototype: ?*Object) !JSValue {
    if (element_size == 0) return error.TypeError;
    const buffer = try expectArrayBufferObject(buffer_value);
    if (buffer.arrayBufferDetached()) return error.DetachedArrayBuffer;
    const buffer_length = buffer.byteStorage().len;
    const byte_offset = if (args.len >= 2 and !args[1].is(.undefined_value)) try toIndexUsize(rt, args[1]) else @as(usize, 0);
    if (byte_offset > buffer_length or byte_offset % element_size != 0) return error.InvalidOffset;
    const explicit_fixed_length = args.len >= 3 and !args[2].is(.undefined_value);
    const remaining = buffer_length - byte_offset;
    const fixed_length: ?u32 = if (explicit_fixed_length) blk: {
        const requested = try toIndexUsize(rt, args[2]);
        const byte_length = try std.math.mul(usize, requested, element_size);
        if (byte_length > remaining) return error.InvalidArrayLength;
        if (requested > @as(usize, @intCast(std.math.maxInt(u32)))) return error.InvalidArrayLength;
        break :blk @intCast(requested);
    } else if (buffer.arrayBufferMaxByteLength() == null) blk: {
        if (remaining % element_size != 0) return error.InvalidArrayLength;
        break :blk @as(u32, @intCast(@divTrunc(remaining, element_size)));
    } else null;
    const obj = try createTypedArrayInstance(rt, kind, prototype);
    errdefer Object.destroyFromHeader(rt, obj.gcHeader());
    try obj.initTypedArrayView(rt, buffer.value(), byte_offset, element_size, fixed_length, kind);
    return obj.value();
}

pub fn typedArrayConstructFullBufferOwned(rt: *JSRuntime, element_size: u32, kind: Kind, buffer_value: JSValue, buffer: *Object, prototype: ?*Object) !JSValue {
    if (element_size == 0) return error.TypeError;
    if (buffer.arrayBufferDetached()) return error.DetachedArrayBuffer;
    if (buffer.arrayBufferMaxByteLength() != null) return error.TypeError;
    const buffer_length = buffer.byteStorage().len;
    if (buffer_length % element_size != 0) return error.InvalidArrayLength;
    const length = @divTrunc(buffer_length, element_size);
    if (length > @as(usize, @intCast(std.math.maxInt(u32)))) return error.InvalidArrayLength;

    const obj = try createTypedArrayInstance(rt, kind, prototype);
    errdefer Object.destroyFromHeader(rt, obj.gcHeader());
    try obj.initTypedArrayView(rt, buffer_value, 0, element_size, @intCast(length), kind);
    return obj.value();
}

/// DataView constructor body over an existing buffer (reached from
/// object_ops.dataViewConstructWithPrototype after the observable coercions).
pub fn dataViewConstruct(rt: *JSRuntime, args: []const JSValue, prototype: ?*Object) !JSValue {
    if (args.len < 1) return error.NotAnArrayBuffer;
    const buffer = try expectArrayBufferObject(args[0]);
    if (buffer.arrayBufferDetached()) return error.DetachedArrayBuffer;
    const buffer_length = arrayBufferByteLength(buffer);
    const byte_offset = if (args.len >= 2) try toIndexUsize(rt, args[1]) else @as(usize, 0);
    if (byte_offset > buffer_length) return error.InvalidOffset;
    const auto_length = !(args.len >= 3 and !args[2].is(.undefined_value));
    const view_length = if (!auto_length)
        try toIndexUsize(rt, args[2])
    else
        buffer_length - byte_offset;
    if (byte_offset + view_length > buffer_length) return error.InvalidOffset;

    const obj = try Object.create(rt, class.ids.dataview, prototype);
    errdefer Object.destroyFromHeader(rt, obj.gcHeader());
    if (view_length > @as(usize, @intCast(std.math.maxInt(u32)))) return error.InvalidArrayLength;
    try obj.initTypedArrayView(
        rt,
        buffer.value(),
        byte_offset,
        0,
        @intCast(view_length),
        if (auto_length) .data_view_length_tracking else .none,
    );
    return obj.value();
}

// --- TypedArray element read / write (engine core) --------------------------

pub fn typedArrayGetIndex(rt: *JSRuntime, obj: *Object, index: u32) !JSValue {
    const payload = obj.typedArrayPayloadFast() orelse return error.TypeError;
    if (payload.element_size == 0) return error.TypeError;
    if (index >= payload.live_length) return JSValue.undefinedValue();
    const data = payload.data orelse return JSValue.undefinedValue();
    const width: usize = payload.element_size;
    const offset = @as(usize, index) * width;
    return readElement(rt, payload.kind, data[offset .. offset + width]);
}

pub fn typedArrayCoerceElementValue(rt: *JSRuntime, obj: *Object, value: JSValue) !void {
    var scratch: [8]u8 = undefined;
    try writeElement(rt, obj.typedArrayKind(), scratch[0..obj.typedArrayElementSize()], value);
}

pub fn typedArraySetElement(rt: *JSRuntime, obj: *Object, index: u32, value: JSValue) !bool {
    const payload = obj.typedArrayPayloadFast() orelse return error.TypeError;
    if (payload.backing_payload == null) return error.TypeError;
    var scratch: [8]u8 = undefined;
    const width: usize = payload.element_size;
    if (width == 0) return error.TypeError;
    try writeElement(rt, payload.kind, scratch[0..width], value);
    if (index >= payload.live_length) return false;
    const data = payload.data orelse return false;
    const offset = @as(usize, index) * width;
    @memcpy(data[offset .. offset + width], scratch[0..width]);
    return true;
}

/// TypedArraySetElement for callers that ignore an out-of-bounds index: the
/// value is converted first (its ToNumber/ToBigInt can throw) even when the
/// array is detached or out of bounds by then.
pub fn typedArraySetIndex(rt: *JSRuntime, obj: *Object, index: u32, value: JSValue) !bool {
    _ = try typedArraySetElement(rt, obj, index, value);
    return true;
}

/// QuickJS source map: js_typed_array_fill.
/// `value` has already been coerced to the target element type once by the
/// caller; coerce it to raw element bytes ONCE here, then fill the contiguous
/// byte range directly (memset for 1-byte kinds, tight typed-store loop for
/// wider kinds), exactly as qjs's switch(shift) does. The caller has already
/// re-validated detach/out-of-bounds and clamped `final` to the live length.
pub fn typedArrayFillRange(rt: *JSRuntime, obj: *Object, start: u32, final: u32, value: JSValue) !void {
    if (start >= final) return;
    const payload = obj.typedArrayPayloadFast() orelse return error.TypeError;
    const kind = payload.kind;
    const width: usize = payload.element_size;
    if (width == 0) return error.TypeError;
    var scratch: [8]u8 = undefined;
    try writeElement(rt, kind, scratch[0..width], value);

    const data = payload.data orelse return error.TypeError;
    var offset = @as(usize, start) * width;
    const end = @as(usize, final) * width;
    switch (width) {
        1 => @memset(data[offset..end], scratch[0]),
        else => {
            const cell = scratch[0..width];
            while (offset < end) : (offset += width) {
                @memcpy(data[offset .. offset + width], cell);
            }
        },
    }
}

pub fn typedArrayBufferObject(obj: *Object) !*Object {
    const value = obj.typedArrayBuffer() orelse return error.TypeError;
    return expectArrayBufferObject(value);
}

// --- DataView primitives (engine core) --------------------------------------

/// QuickJS source map: narrow DataView.prototype getter helper.
pub fn dataViewGet(rt: *JSRuntime, view_value: JSValue, kind: u32, args: []const JSValue) !JSValue {
    const view = try expectDataViewObject(view_value);
    const index = if (args.len >= 1) try toIndexUsize(rt, args[0]) else @as(usize, 0);
    const little_endian = args.len >= 2 and value_semantics.toBoolean(args[1]);
    const width = dataViewKindWidth(kind);
    try checkDataViewInBounds(view, index, width);
    const absolute = view.typedArrayByteOffset() + index;
    const buffer = try dataViewBuffer(view);

    var bytes: [8]u8 = undefined;
    var i: usize = 0;
    while (i < width) : (i += 1) bytes[i] = buffer.byteStorage()[absolute + i];

    const endian: std.builtin.Endian = if (little_endian) .little else .big;
    return switch (kind) {
        1 => JSValue.int32(@as(i8, @bitCast(bytes[0]))),
        2 => JSValue.int32(bytes[0]),
        3 => JSValue.int32(std.mem.readInt(i16, bytes[0..2], endian)),
        4 => JSValue.int32(std.mem.readInt(u16, bytes[0..2], endian)),
        5 => JSValue.int32(std.mem.readInt(i32, bytes[0..4], endian)),
        6 => decodeUint32(std.mem.readInt(u32, bytes[0..4], endian)),
        7 => JSValue.float64(@floatCast(@as(f32, @bitCast(std.mem.readInt(u32, bytes[0..4], endian))))),
        8 => JSValue.float64(@bitCast(std.mem.readInt(u64, bytes[0..8], endian))),
        9 => bigIntResult(rt, std.mem.readInt(i64, bytes[0..8], endian)),
        10 => bigIntResult(rt, @intCast(std.mem.readInt(u64, bytes[0..8], endian))),
        11 => JSValue.float64(float16ToF64(std.mem.readInt(u16, bytes[0..2], endian))),
        else => error.TypeError,
    };
}

/// QuickJS source map: narrow DataView.prototype setter helper.
pub fn dataViewSet(rt: *JSRuntime, view_value: JSValue, kind: u32, args: []const JSValue) !JSValue {
    const view = try expectDataViewObject(view_value);
    const buffer = try dataViewBuffer(view);
    const index_arg = if (args.len >= 1) args[0] else JSValue.undefinedValue();
    const index = try toIndexUsize(rt, index_arg);
    const value_arg = if (args.len >= 2) args[1] else JSValue.undefinedValue();
    const little_endian = args.len >= 3 and value_semantics.toBoolean(args[2]);
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

    try checkDataViewInBounds(view, index, width);
    const absolute = view.typedArrayByteOffset() + index;
    var i: usize = 0;
    while (i < width) : (i += 1) buffer.byteStorage()[absolute + i] = bytes[i];
    return JSValue.undefinedValue();
}

pub fn dataViewRequire(view_value: JSValue) !void {
    _ = try expectDataViewObject(view_value);
}

pub fn dataViewByteLength(view: *Object) !usize {
    return dataViewEffectiveByteLength(view);
}

pub fn dataViewByteOffset(view: *Object) !usize {
    _ = try dataViewEffectiveByteLength(view);
    return view.typedArrayByteOffset();
}

pub fn dataViewValidateConstructorRange(_: *JSRuntime, buffer_value: JSValue, byte_offset: usize, view_length: ?usize) !void {
    const buffer = try expectArrayBufferObject(buffer_value);
    if (buffer.arrayBufferDetached()) return error.DetachedArrayBuffer;
    const buffer_length = arrayBufferByteLength(buffer);
    if (byte_offset > buffer_length) return error.InvalidOffset;
    const remaining = buffer_length - byte_offset;
    if (view_length) |length| {
        if (length > remaining) return error.InvalidOffset;
    }
}

/// GetViewValue / SetViewValue steps 7-11: a detached buffer, then an
/// out-of-bounds view (both TypeError), before the index is checked against
/// the view's byte length (RangeError). QuickJS checks the index first.
fn checkDataViewInBounds(view: *Object, index: usize, width: usize) !void {
    const buffer = try dataViewBuffer(view);
    if (buffer.arrayBufferDetached()) return error.DetachedArrayBuffer;
    const buffer_len = buffer.byteStorage().len;
    const byte_offset = view.typedArrayByteOffset();
    const stored_length: usize = view.typedArrayFixedLength() orelse return error.DataViewOutOfBounds;
    const tracking = view.typedArrayKind() == .data_view_length_tracking and buffer.arrayBufferMaxByteLength() != null;
    if (byte_offset > buffer_len) return error.DataViewOutOfBounds;
    const view_size = if (tracking) buffer_len - byte_offset else blk: {
        if (stored_length > buffer_len - byte_offset) return error.DataViewOutOfBounds;
        break :blk stored_length;
    };
    if (index > view_size or width > view_size - index) return error.DataViewOffsetOutOfRange;
}

fn dataViewEffectiveByteLength(view: *Object) !usize {
    const buffer = try dataViewBuffer(view);
    if (buffer.arrayBufferDetached()) return error.DetachedArrayBuffer;
    const byte_offset = view.typedArrayByteOffset();
    const stored_length = view.typedArrayFixedLength() orelse return error.TypeError;
    if (buffer.arrayBufferMaxByteLength() == null) return stored_length;

    if (view.typedArrayKind() == .data_view_length_tracking) {
        if (buffer.byteStorage().len < byte_offset) return error.DataViewOutOfBounds;
        return buffer.byteStorage().len - byte_offset;
    }
    if (buffer.byteStorage().len < byte_offset or stored_length > buffer.byteStorage().len - byte_offset) return error.DataViewOutOfBounds;
    return stored_length;
}

fn dataViewBuffer(view: *Object) !*Object {
    return expectArrayBufferObject(view.typedArrayBuffer() orelse return error.TypeError);
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

// --- Object-shape guards ----------------------------------------------------

pub const expectObject = @import("value_semantics.zig").expectObject;

pub fn expectArrayBufferObject(value: JSValue) !*Object {
    const obj = try expectObject(value);
    if (obj.class_id != class.ids.array_buffer and obj.class_id != class.ids.shared_array_buffer) return error.NotAnArrayBuffer;
    return obj;
}

fn expectArrayBufferOnlyObject(value: JSValue) !*Object {
    const obj = try expectObject(value);
    if (obj.class_id != class.ids.array_buffer) return error.NotAnArrayBuffer;
    return obj;
}

fn expectSharedArrayBufferObject(value: JSValue) !*Object {
    const obj = try expectObject(value);
    if (obj.class_id != class.ids.shared_array_buffer) return error.IncompatibleReceiver;
    return obj;
}

fn expectDataViewObject(value: JSValue) !*Object {
    const obj = try expectObject(value);
    if (obj.class_id != class.ids.dataview) return error.IncompatibleReceiver;
    return obj;
}

// --- Index / number coercion primitives -------------------------------------

/// qjs JS_NewUint32: fits int32 stays int-tagged; bit31 set becomes float64.
inline fn decodeUint32(bits: u32) JSValue {
    if (bits <= std.math.maxInt(i32)) return JSValue.int32(@intCast(bits));
    return JSValue.float64(@floatFromInt(bits));
}

/// qjs `[i]` / `js_TA_get_*` decode: integer kinds are JS_NewInt32, Uint32 is
/// JS_NewUint32 (one high-bit test), floats are a bare float64 tag
/// (`__JS_NewFloat64`). Do not scan "can this float be an int32" — that
/// canonicalizer is the helper tax on zlib's HEAPF64/HEAP32 path.
inline fn decodeNumericElement(kind: Kind, bytes: [*]const u8) JSValue {
    return switch (kind) {
        .int8 => JSValue.int32(@as(i8, @bitCast(bytes[0]))),
        .uint8, .uint8_clamped => JSValue.int32(bytes[0]),
        .int16 => JSValue.int32(std.mem.readInt(i16, bytes[0..2], .little)),
        .uint16 => JSValue.int32(std.mem.readInt(u16, bytes[0..2], .little)),
        .int32 => JSValue.int32(std.mem.readInt(i32, bytes[0..4], .little)),
        .uint32 => decodeUint32(std.mem.readInt(u32, bytes[0..4], .little)),
        .float16 => JSValue.float64(float16ToF64(std.mem.readInt(u16, bytes[0..2], .little))),
        .float32 => JSValue.float64(@floatCast(@as(f32, @bitCast(std.mem.readInt(u32, bytes[0..4], .little))))),
        .float64 => JSValue.float64(@bitCast(std.mem.readInt(u64, bytes[0..8], .little))),
        else => unreachable,
    };
}

/// Class-id twin of `decodeNumericElement` so `[i]` can jumptable on
/// `object.class_id` like qjs JS_GetPropertyValue, with the element width
/// folded into each arm (no extra `element_size` load).
pub inline fn decodeNumericElementByClass(class_id: class.ClassId, data: [*]const u8, index: u32) JSValue {
    const i: usize = index;
    return switch (class_id) {
        class.ids.int8_array => JSValue.int32(@as(i8, @bitCast(data[i]))),
        class.ids.uint8_array, class.ids.uint8c_array => JSValue.int32(data[i]),
        class.ids.int16_array => JSValue.int32(std.mem.readInt(i16, data[i * 2 ..][0..2], .little)),
        class.ids.uint16_array => JSValue.int32(std.mem.readInt(u16, data[i * 2 ..][0..2], .little)),
        class.ids.int32_array => JSValue.int32(std.mem.readInt(i32, data[i * 4 ..][0..4], .little)),
        class.ids.uint32_array => decodeUint32(std.mem.readInt(u32, data[i * 4 ..][0..4], .little)),
        class.ids.float16_array => JSValue.float64(float16ToF64(std.mem.readInt(u16, data[i * 2 ..][0..2], .little))),
        class.ids.float32_array => JSValue.float64(@floatCast(@as(f32, @bitCast(std.mem.readInt(u32, data[i * 4 ..][0..4], .little))))),
        class.ids.float64_array => JSValue.float64(@bitCast(std.mem.readInt(u64, data[i * 8 ..][0..8], .little))),
        else => unreachable,
    };
}

/// Class-id twin of `writeInt32NumericElement` for the `[i] = int32` arm
/// (qjs JS_SetPropertyValue UINT8..FLOAT64). Conversion is infallible, so
/// the caller only rechecks `live_length` then stores. Width lives in the
/// arm; Uint8C clamps, integer kinds truncate, floats are `@floatFromInt`.
pub inline fn writeInt32NumericElementByClass(
    class_id: class.ClassId,
    data: [*]u8,
    index: u32,
    integer: i32,
) void {
    const i: usize = index;
    const bits: u32 = @bitCast(integer);
    switch (class_id) {
        class.ids.int8_array, class.ids.uint8_array => data[i] = @truncate(bits),
        class.ids.uint8c_array => data[i] = if (integer <= 0)
            0
        else if (integer >= 255)
            255
        else
            @intCast(integer),
        class.ids.int16_array, class.ids.uint16_array => std.mem.writeInt(u16, data[i * 2 ..][0..2], @truncate(bits), .little),
        class.ids.int32_array, class.ids.uint32_array => std.mem.writeInt(u32, data[i * 4 ..][0..4], bits, .little),
        class.ids.float16_array => std.mem.writeInt(u16, data[i * 2 ..][0..2], f64ToFloat16(@floatFromInt(integer)), .little),
        class.ids.float32_array => std.mem.writeInt(u32, data[i * 4 ..][0..4], @bitCast(@as(f32, @floatFromInt(integer))), .little),
        class.ids.float64_array => std.mem.writeInt(u64, data[i * 8 ..][0..8], @bitCast(@as(f64, @floatFromInt(integer))), .little),
        else => unreachable,
    }
}

fn bigIntResult(rt: *JSRuntime, value: i128) !JSValue {
    const big = try bigint.BigInt.create(rt, value);
    return big.valueRef();
}

fn numberValue(value: JSValue) ?f64 {
    if (value.as(.int)) |int_value| return @floatFromInt(int_value);
    if (value.as(.float64)) |float_value| return float_value;
    return null;
}

fn numberToUint32(number: f64) u32 {
    // `isFinite` is already false for NaN, so no separate NaN test is needed.
    if (!std.math.isFinite(number)) return 0;
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

/// Primitive-only ToNumber: callers ran ToPrimitive (and rejected BigInt for
/// Number kinds) first; anything else non-numeric reads as NaN.
fn coerceNumber(rt: *JSRuntime, value: JSValue) !f64 {
    if (value.is(.symbol)) return error.SymbolToNumber;
    if (value.isBigInt()) return error.BigIntToNumber;
    if (numberValue(value)) |number| return number;
    if (value.as(.boolean)) |bool_value| return if (bool_value) 1 else 0;
    if (value.is(.null_value)) return 0;
    if (value.isString()) {
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(rt.nativeAllocator());
        try string.appendValueUtf8(rt, &bytes, value);
        return parseJsNumber(bytes.items);
    }
    return std.math.nan(f64);
}

fn float16ToF64(bits: u16) f64 {
    return @floatCast(@as(f16, @bitCast(bits)));
}

fn f64ToFloat16(value: f64) u16 {
    return @bitCast(@as(f16, @floatCast(value)));
}

/// Decode one non-BigInt TypedArray element without entering the allocating
/// BigInt/error-union path. QuickJS's JS_GetPropertyValue typed-array arm
/// switches on the concrete numeric class and returns the value directly; keep
/// the same split here so the VM's already-validated numeric fast path does not
/// acquire the stack frame needed by kinds 11/12. Use the platform C ABI for
/// this leaf just as QuickJS's C helper does: a 16-byte JSValue is returned in
/// the ABI result registers on 64-bit targets instead of through Zig's internal
/// sret pointer. The raw byte pointer is safe because every caller has already
/// validated the concrete typed-array kind and its fixed element width.
///
/// This is also the single source of truth for numeric decoding: readElement
/// delegates kinds 1..10 here before handling the allocating BigInt kinds.
pub noinline fn readNumericElement(kind: Kind, bytes: [*]const u8) callconv(.c) JSValue {
    return decodeNumericElement(kind, bytes);
}

fn readElement(rt: *JSRuntime, kind: Kind, bytes: []const u8) !JSValue {
    if (kind.isNumeric()) return readNumericElement(kind, bytes.ptr);
    return switch (kind) {
        .bigint64 => bigIntResult(rt, std.mem.readInt(i64, bytes[0..8], .little)),
        .biguint64 => bigIntResult(rt, @intCast(std.mem.readInt(u64, bytes[0..8], .little))),
        else => error.TypeError,
    };
}

/// Coerce and encode one non-BigInt TypedArray element. QuickJS groups the
/// JS_SetPropertyValue class-id arms by conversion mechanism: truncating
/// integer arrays use JS_ToInt32Free, Uint8Clamped uses JS_ToUint8ClampFree,
/// and floating arrays use JS_ToFloat64Free. Preserve those three groups here.
/// In particular, an existing int32 value reaches integer storage as raw bits
/// instead of making a round trip through f64 and the generic 2^32 modulo.
///
/// The VM's numeric element fast path calls this directly; writeElement also
/// delegates kinds 1..10 here so the encoding remains canonical.
pub inline fn writeNumericElement(rt: *JSRuntime, kind: Kind, bytes: []u8, value: JSValue) !void {
    if (value.isBigInt()) return error.BigIntToNumber;
    switch (kind) {
        .int8, .uint8, .int16, .uint16, .int32, .uint32 => return writeTruncatingIntegerElement(rt, kind, bytes, value),
        .uint8_clamped => return writeClampedElement(rt, bytes, value),
        .float16 => return writeFloatingElement(.float16, rt, bytes, value),
        .float32 => return writeFloatingElement(.float32, rt, bytes, value),
        .float64 => return writeFloatingElement(.float64, rt, bytes, value),
        else => unreachable,
    }
}

/// Whether a concrete TypedArray kind uses an integer element representation.
pub inline fn isIntegerNumericKind(kind: Kind) bool {
    return kind.isInteger();
}

/// Store an already-decoded int32 into one of the integer TypedArray kinds.
/// QuickJS's JS_SetPropertyValue arms perform JS_ToInt32Free (or the clamped
/// conversion) and then issue the concrete-width store in the same class arm.
/// A tagged int32 needs neither observable coercion nor allocation, so callers
/// that have already validated the typed-array payload can keep that common
/// path out of the scratch-buffer/error-union writer below. Float and BigInt
/// kinds return false and continue through their canonical converters.
pub inline fn writeInt32NumericElement(kind: Kind, bytes: [*]u8, integer: i32) bool {
    const bits: u32 = @bitCast(integer);
    switch (kind) {
        .int8, .uint8 => bytes[0] = @truncate(bits),
        .uint8_clamped => bytes[0] = if (integer <= 0)
            0
        else if (integer >= 255)
            255
        else
            @intCast(integer),
        .int16, .uint16 => std.mem.writeInt(u16, bytes[0..2], @truncate(bits), .little),
        .int32, .uint32 => std.mem.writeInt(u32, bytes[0..4], bits, .little),
        else => return false,
    }
    return true;
}

noinline fn writeTruncatingIntegerElement(rt: *JSRuntime, kind: Kind, bytes: []u8, value: JSValue) !void {
    const bits: u32 = if (value.as(.int)) |integer|
        @bitCast(integer)
    else
        numberToUint32(try coerceNumber(rt, value));
    switch (kind) {
        .int8, .uint8 => bytes[0] = @truncate(bits),
        .int16, .uint16 => std.mem.writeInt(u16, bytes[0..2], @truncate(bits), .little),
        .int32, .uint32 => std.mem.writeInt(u32, bytes[0..4], bits, .little),
        else => unreachable,
    }
}

noinline fn writeClampedElement(rt: *JSRuntime, bytes: []u8, value: JSValue) !void {
    bytes[0] = if (value.as(.int)) |integer|
        if (integer <= 0)
            0
        else if (integer >= 255)
            255
        else
            @intCast(integer)
    else
        numberToUint8Clamp(try coerceNumber(rt, value));
}

noinline fn writeFloatingElement(comptime kind: Kind, rt: *JSRuntime, bytes: []u8, value: JSValue) !void {
    const number = try coerceNumber(rt, value);
    switch (kind) {
        .float16 => std.mem.writeInt(u16, bytes[0..2], f64ToFloat16(number), .little),
        .float32 => std.mem.writeInt(u32, bytes[0..4], @bitCast(@as(f32, @floatCast(number))), .little),
        .float64 => std.mem.writeInt(u64, bytes[0..8], @bitCast(number), .little),
        else => comptime unreachable,
    }
}

fn writeElement(rt: *JSRuntime, kind: Kind, bytes: []u8, value: JSValue) !void {
    if (kind.isNumeric()) return writeNumericElement(rt, kind, bytes, value);
    switch (kind) {
        .bigint64, .biguint64 => std.mem.writeInt(u64, bytes[0..8], try valueToBigInt64Bits(rt, value), .little),
        else => return error.TypeError,
    }
}

fn valueToBigInt64Bits(rt: *JSRuntime, value: JSValue) !u64 {
    // Only the low limb matters: read a BigInt in place instead of copying
    // every limb of a possibly huge value.
    if (value.isBigInt()) {
        var view = try value_format.BigIntView.init(rt.nativeAllocator(), value);
        defer view.deinit();
        return lowLimbBits(view.int);
    }
    var big = try toBigIntValue(rt, value);
    defer big.deinit();
    return lowLimbBits(big);
}

fn lowLimbBits(big: bignum.BigInt) u64 {
    const low: u64 = if (big.limbs.len >= 1) big.limbs[0] else 0;
    return if (big.negative) 0 -% low else low;
}

fn toBigIntValue(rt: *JSRuntime, value: JSValue) !bignum.BigInt {
    if (value.isBigInt()) return value_format.cloneBigIntValue(rt.nativeAllocator(), value);
    if (value.isNumber()) return error.CannotConvertToBigInt;
    if (value.as(.boolean)) |bool_value| return bignum.BigInt.fromIntAlloc(rt.nativeAllocator(), if (bool_value) 1 else 0);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.nativeAllocator());
    if (value.isString() or value.is(.object)) {
        try appendValueString(rt, &buffer, value);
        // qjs JS_StringToBigInt + skip_spaces.
        const trimmed = value_format.trimJsWhitespace(buffer.items);
        if (trimmed.len == 0) return bignum.BigInt.fromIntAlloc(rt.nativeAllocator(), 0);
        return bignum.parseAutoAlloc(rt.nativeAllocator(), trimmed, rt) catch |err| switch (err) {
            // qjs js_atobigint throws its RangeError through js_atof rather
            // than folding it into the bad-literal SyntaxError.
            error.BigIntTooLarge => error.BigIntTooLarge,
            error.OutOfMemory => error.OutOfMemory,
            error.Interrupted => error.Interrupted,
            error.InvalidBigInt => error.SyntaxError,
        };
    }
    return error.CannotConvertToBigInt;
}

/// ToNumber of an already-primitive value (callers run ToPrimitive first):
/// not truncated, `undefined` is NaN, and a BigInt or Symbol throws
/// TypeError (qjs JS_ToFloat64Free).
pub fn primitiveToNumber(rt: *JSRuntime, value: JSValue) !f64 {
    if (numberValue(value)) |number| return number;
    if (value.isBigInt()) return error.BigIntToNumber;
    if (value.is(.symbol)) return error.SymbolToNumber;
    if (value.as(.boolean)) |bool_value| return if (bool_value) 1 else 0;
    if (value.is(.null_value)) return 0;
    if (value.is(.undefined_value)) return std.math.nan(f64);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.nativeAllocator());
    try appendValueString(rt, &buffer, value);
    return parseJsNumber(buffer.items);
}

pub fn toIndexUsize(rt: *JSRuntime, value: JSValue) !usize {
    const number = try primitiveToNumber(rt, value);
    if (std.math.isNan(number)) return 0;
    const integer = @trunc(number);
    // ToIndex: RangeError outside [0, 2^53 - 1]; this also bounds the cast.
    if (!(integer >= 0 and integer <= std.math.maxInt(u53))) return error.InvalidArrayIndex;
    return @intFromFloat(integer);
}

fn parseJsNumber(bytes: []const u8) f64 {
    return value_format.parseJsNumber(bytes);
}

/// This file's policy for the shared bare-runtime ToString owner.
fn appendValueString(rt: *JSRuntime, buffer: *std.ArrayList(u8), value: JSValue) AppendStringError!void {
    return value_string.appendValueString(rt, buffer, value, .{});
}
