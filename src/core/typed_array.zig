//! Engine-core TypedArray / ArrayBuffer / SharedArrayBuffer / DataView
//! element-access, coercion, and storage-operation mechanism.
//!
//! QuickJS source map: the typed-array element read/write fabric, the DataView
//! get/set primitives, and the ArrayBuffer resize/slice/transfer/grow storage
//! operations all live in the engine core (quickjs.c), with the JS-visible
//! builtin methods (`builtins/buffer.zig`) and the VM opcode handlers as
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
//! `typedArrayCanonicalNumericIndex`, the immutable-buffer helpers, ...) live in
//! `object.zig`; this module imports and re-uses them. The pure view-construction
//! primitives (`typedArrayConstructWithOptions` / `...FullBufferOwned` /
//! `dataViewConstruct` and their `typedArrayConstruct*` wrappers) live here
//! (Phase 6b-3c): they shape internal slots over an existing ArrayBuffer using
//! only positional-arg index coercion (`toIndexUsize`, primitive-only) and run no
//! user code. The `*ConstructArgs` family (ArrayBuffer / SharedArrayBuffer) reads
//! the `maxByteLength` option off a user object, so it stays one level up in exec
//! (`exec/typed_array_construct.zig`). The `*MethodId` / `*FromRecordId` /
//! `*NameFromRecordId` name machinery and its method-id enums live in
//! `core/host_function.zig` (`builtin_method_ids` + `builtin_method_id_lookup`);
//! `builtins/buffer.zig` re-exports both. The record dispatch table stays in
//! `builtins/buffer.zig`.

const std = @import("std");

const atom = @import("atom.zig");
const bigint = @import("bigint.zig");
const class = @import("class.zig");
const descriptor = @import("descriptor.zig");
const object = @import("object.zig");
const string = @import("string.zig");
const value_format = @import("value_format.zig");
const value_semantics = @import("value_semantics.zig");

const bignum = @import("../libs/bigint.zig");

const JSValue = @import("value.zig").JSValue;
const JSRuntime = @import("runtime.zig").JSRuntime;
const Object = object.Object;
const Atom = atom.Atom;
const Descriptor = descriptor.Descriptor;

const AppendStringError = error{
    OutOfMemory,
    TypeError,
    InvalidRadix,
    NoSpaceLeft,
};

// --- ArrayBuffer construction / storage helpers (engine core) ---------------

/// QuickJS source map: narrow ArrayBuffer constructor used by transitional
/// `new_array_buffer` bytecode.
pub fn arrayBufferConstruct(rt: *JSRuntime, length_value: JSValue) !JSValue {
    const byte_length = try toIndexUsize(rt, length_value);
    return createArrayBuffer(rt, byte_length, null);
}

pub fn arrayBufferConstructLength(rt: *JSRuntime, byte_length: usize, max_byte_length: ?usize, prototype: ?*Object) !JSValue {
    return createArrayBufferWithPrototype(rt, byte_length, max_byte_length, prototype);
}

pub fn sharedArrayBufferConstructLength(rt: *JSRuntime, byte_length: usize, max_byte_length: ?usize, prototype: ?*Object) !JSValue {
    const obj = try Object.create(rt, class.ids.shared_array_buffer, prototype);
    errdefer Object.destroyFromHeader(rt, &obj.header);
    try validateArrayBufferLength(byte_length);
    if (max_byte_length) |max| try validateArrayBufferLength(max);
    const store = try object.SharedBufferStore.create(rt, byte_length);
    obj.installSharedByteStorage(rt, store);
    obj.arrayBufferMaxByteLengthSlot().* = max_byte_length;
    return obj.value();
}

pub fn sharedArrayBufferFromStore(
    rt: *JSRuntime,
    store: *object.SharedBufferStore,
    max_byte_length: ?usize,
    prototype: ?*Object,
) !JSValue {
    const obj = try Object.create(rt, class.ids.shared_array_buffer, prototype);
    errdefer Object.destroyFromHeader(rt, &obj.header);
    if (max_byte_length) |max| {
        if (max < store.bytes.len) return error.RangeError;
        try validateArrayBufferLength(max);
    }
    store.retain();
    obj.installSharedByteStorage(rt, store);
    obj.arrayBufferMaxByteLengthSlot().* = max_byte_length;
    return obj.value();
}

pub fn createArrayBuffer(rt: *JSRuntime, byte_length: usize, max_byte_length: ?usize) !JSValue {
    return createArrayBufferWithPrototype(rt, byte_length, max_byte_length, null);
}

pub fn createArrayBufferWithPrototype(rt: *JSRuntime, byte_length: usize, max_byte_length: ?usize, prototype: ?*Object) !JSValue {
    const obj = try Object.create(rt, class.ids.array_buffer, prototype);
    errdefer Object.destroyFromHeader(rt, &obj.header);
    try validateArrayBufferLength(byte_length);
    if (max_byte_length) |max| try validateArrayBufferLength(max);
    if (!try obj.installInlineByteStorage(rt, byte_length)) {
        const bytes = try rt.memory.alloc(u8, byte_length);
        errdefer rt.memory.free(u8, bytes);
        try obj.installByteStorage(rt, bytes);
    }
    @memset(obj.byteStorage(), 0);
    obj.arrayBufferMaxByteLengthSlot().* = max_byte_length;
    return obj.value();
}

pub fn validateArrayBufferLength(byte_length: usize) !void {
    if (byte_length > @as(usize, @intCast(std.math.maxInt(i32)))) return error.RangeError;
}

pub fn arrayBufferByteLength(buffer: *Object) usize {
    return if (buffer.arrayBufferDetached()) 0 else buffer.byteStorage().len;
}

// --- ArrayBuffer / SharedArrayBuffer storage operations ---------------------

/// QuickJS source map: narrow ArrayBuffer.prototype.slice helper.
pub fn arrayBufferSlice(rt: *JSRuntime, buffer_value: JSValue, start_value: JSValue, end_value: JSValue) !JSValue {
    const buffer = try expectArrayBufferObject(buffer_value);
    if (buffer.arrayBufferDetached()) return error.TypeError;
    if (object.arrayBufferIsImmutable(rt, buffer)) return error.TypeError;
    const source_length = arrayBufferByteLength(buffer);
    const start = try relativeSliceIndex(rt, start_value, source_length, false);
    const end = try relativeSliceIndex(rt, end_value, source_length, true);
    return arrayBufferSliceRange(rt, buffer_value, start, end);
}

pub fn arrayBufferSliceRange(rt: *JSRuntime, buffer_value: JSValue, start: usize, end: usize) !JSValue {
    const buffer = try expectArrayBufferObject(buffer_value);
    if (buffer.arrayBufferDetached()) return error.TypeError;
    if (object.arrayBufferIsImmutable(rt, buffer)) return error.TypeError;
    const length = if (end > start) end - start else 0;
    const out = try createArrayBufferWithPrototype(rt, length, null, buffer.getPrototype());
    errdefer out.free(rt);
    const out_object = try expectArrayBufferObject(out);
    if (length != 0) @memcpy(out_object.byteStorage(), buffer.byteStorage()[start..end]);
    return out;
}

pub fn arrayBufferSliceToImmutable(rt: *JSRuntime, buffer_value: JSValue, start_value: JSValue, end_value: JSValue) !JSValue {
    const buffer = try expectArrayBufferOnlyObject(buffer_value);
    if (buffer.arrayBufferDetached()) return error.TypeError;
    if (object.arrayBufferIsImmutable(rt, buffer)) return error.TypeError;
    const source_length = arrayBufferByteLength(buffer);
    const start = try relativeSliceIndex(rt, start_value, source_length, false);
    const end = try relativeSliceIndex(rt, end_value, source_length, true);
    return arrayBufferSliceToImmutableRange(rt, buffer_value, start, end);
}

pub fn arrayBufferSliceToImmutableRange(rt: *JSRuntime, buffer_value: JSValue, start: usize, end: usize) !JSValue {
    const buffer = try expectArrayBufferOnlyObject(buffer_value);
    if (buffer.arrayBufferDetached()) return error.TypeError;
    if (object.arrayBufferIsImmutable(rt, buffer)) return error.TypeError;
    if (buffer.byteStorage().len < end) return error.RangeError;
    const length = if (end > start) end - start else 0;
    const out = try createArrayBufferWithPrototype(rt, length, null, buffer.getPrototype());
    errdefer out.free(rt);
    const out_object = try expectArrayBufferOnlyObject(out);
    if (length != 0) @memcpy(out_object.byteStorage(), buffer.byteStorage()[start..end]);
    try object.markArrayBufferImmutable(rt, out_object);
    return out;
}

pub fn arrayBufferTransfer(rt: *JSRuntime, buffer_value: JSValue, new_length_value: JSValue, fixed_length: bool) !JSValue {
    const buffer = try expectArrayBufferOnlyObject(buffer_value);
    const new_length = if (new_length_value.isUndefined()) buffer.byteStorage().len else try toIndexUsize(rt, new_length_value);
    return arrayBufferTransferLength(rt, buffer_value, new_length, fixed_length);
}

pub fn arrayBufferTransferLength(rt: *JSRuntime, buffer_value: JSValue, new_length: usize, fixed_length: bool) !JSValue {
    const buffer = try expectArrayBufferOnlyObject(buffer_value);
    if (buffer.arrayBufferDetached()) return error.TypeError;
    if (object.arrayBufferIsImmutable(rt, buffer)) return error.TypeError;
    if (!fixed_length) {
        if (buffer.arrayBufferMaxByteLength()) |max| {
            if (new_length > max) return error.RangeError;
        }
    }
    const out = try createArrayBufferWithPrototype(rt, new_length, if (fixed_length) null else buffer.arrayBufferMaxByteLength(), buffer.getPrototype());
    errdefer out.free(rt);
    const out_object = try expectArrayBufferObject(out);
    const copy_len = @min(buffer.byteStorage().len, new_length);
    if (copy_len != 0) @memcpy(out_object.byteStorage()[0..copy_len], buffer.byteStorage()[0..copy_len]);
    const detached = try detachArrayBuffer(rt, buffer.value());
    detached.free(rt);
    return out;
}

pub fn arrayBufferTransferToImmutable(rt: *JSRuntime, buffer_value: JSValue, new_length_value: JSValue) !JSValue {
    const buffer = try expectArrayBufferOnlyObject(buffer_value);
    const new_length = if (new_length_value.isUndefined()) buffer.byteStorage().len else try toIndexUsize(rt, new_length_value);
    return arrayBufferTransferToImmutableLength(rt, buffer_value, new_length);
}

pub fn arrayBufferTransferToImmutableLength(rt: *JSRuntime, buffer_value: JSValue, new_length: usize) !JSValue {
    const buffer = try expectArrayBufferOnlyObject(buffer_value);
    if (buffer.arrayBufferDetached()) return error.TypeError;
    if (object.arrayBufferIsImmutable(rt, buffer)) return error.TypeError;
    const out = try createArrayBufferWithPrototype(rt, new_length, null, buffer.getPrototype());
    errdefer out.free(rt);
    const out_object = try expectArrayBufferOnlyObject(out);
    const copy_len = @min(buffer.byteStorage().len, new_length);
    if (copy_len != 0) @memcpy(out_object.byteStorage()[0..copy_len], buffer.byteStorage()[0..copy_len]);
    try object.markArrayBufferImmutable(rt, out_object);
    const detached = try detachArrayBuffer(rt, buffer.value());
    detached.free(rt);
    return out;
}

pub fn sharedArrayBufferSlice(rt: *JSRuntime, buffer_value: JSValue, start_value: JSValue, end_value: JSValue) !JSValue {
    const buffer = try expectSharedArrayBufferObject(buffer_value);
    const source_length = buffer.byteStorage().len;
    const start = try relativeSliceIndex(rt, start_value, source_length, false);
    const end = try relativeSliceIndex(rt, end_value, source_length, true);
    return sharedArrayBufferSliceRange(rt, buffer_value, start, end);
}

pub fn sharedArrayBufferSliceRange(rt: *JSRuntime, buffer_value: JSValue, start: usize, end: usize) !JSValue {
    const buffer = try expectSharedArrayBufferObject(buffer_value);
    const length = if (end > start) end - start else 0;
    const out = try sharedArrayBufferConstructLength(rt, length, null, buffer.getPrototype());
    errdefer out.free(rt);
    const out_object = try expectSharedArrayBufferObject(out);
    if (length != 0) @memcpy(out_object.byteStorage(), buffer.byteStorage()[start..end]);
    return out;
}

pub fn sharedArrayBufferGrow(rt: *JSRuntime, buffer_value: JSValue, new_length_value: JSValue) !JSValue {
    const new_length = try toIndexUsize(rt, new_length_value);
    return sharedArrayBufferGrowLength(rt, buffer_value, new_length);
}

pub fn sharedArrayBufferGrowLength(rt: *JSRuntime, buffer_value: JSValue, new_length: usize) !JSValue {
    const buffer = try expectSharedArrayBufferObject(buffer_value);
    const max = buffer.arrayBufferMaxByteLength() orelse return error.TypeError;
    if (new_length < buffer.byteStorage().len) return error.RangeError;
    if (new_length > max) return error.RangeError;
    const old = buffer.byteStorage();
    const store = try object.SharedBufferStore.create(rt, new_length);
    errdefer store.release();
    if (old.len != 0) @memcpy(store.bytes[0..old.len], old);
    buffer.installSharedByteStorage(rt, store);
    return JSValue.undefinedValue();
}

pub fn arrayBufferResize(rt: *JSRuntime, buffer_value: JSValue, new_length_value: JSValue) !JSValue {
    const buffer = try expectArrayBufferOnlyObject(buffer_value);
    if (object.arrayBufferIsImmutable(rt, buffer)) return error.TypeError;
    const new_length = try toIndexUsize(rt, new_length_value);
    if (buffer.arrayBufferDetached()) return error.TypeError;
    return arrayBufferResizeLength(rt, buffer_value, new_length);
}

pub fn arrayBufferResizeLength(rt: *JSRuntime, buffer_value: JSValue, new_length: usize) !JSValue {
    const buffer = try expectArrayBufferOnlyObject(buffer_value);
    if (buffer.arrayBufferDetached()) return error.TypeError;
    if (object.arrayBufferIsImmutable(rt, buffer)) return error.TypeError;
    const max = buffer.arrayBufferMaxByteLength() orelse return error.TypeError;
    if (new_length > max) return error.RangeError;
    const old = buffer.byteStorage();
    const next = try rt.memory.alloc(u8, new_length);
    errdefer rt.memory.free(u8, next);
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
// stay pure core. The `*ConstructArgs` family (ArrayBuffer / SharedArrayBuffer),
// which reads the `maxByteLength` option off a user object, stays one level up
// in exec (`exec/typed_array_construct.zig`).

fn typedArrayClassIdForKind(kind: u8) ?class.ClassId {
    return switch (kind) {
        1 => class.ids.int8_array,
        2 => class.ids.uint8_array,
        3 => class.ids.uint8c_array,
        4 => class.ids.int16_array,
        5 => class.ids.uint16_array,
        6 => class.ids.int32_array,
        7 => class.ids.uint32_array,
        8 => class.ids.float16_array,
        9 => class.ids.float32_array,
        10 => class.ids.float64_array,
        11 => class.ids.big_int64_array,
        12 => class.ids.big_uint64_array,
        else => null,
    };
}

fn createTypedArrayInstance(rt: *JSRuntime, kind: u8, prototype: ?*Object) !*Object {
    const class_id = typedArrayClassIdForKind(kind) orelse class.ids.object;
    const obj = try Object.create(rt, class_id, prototype);
    errdefer Object.destroyFromHeader(rt, &obj.header);
    if (class_id == class.ids.object) try obj.ensureTypedArrayPayload(rt);
    return obj;
}

/// QuickJS source map: typed-array view construction helper. JS-visible
/// element access, species, and prototype methods are handled by the VM
/// builtins; this helper owns the internal slot shape used by those paths.
pub fn typedArrayConstruct(rt: *JSRuntime, element_size: u32, buffer_value: JSValue) !JSValue {
    return typedArrayConstructWithOptions(rt, element_size, 2, buffer_value, &.{buffer_value}, null);
}

pub fn typedArrayConstructWithOptions(rt: *JSRuntime, element_size: u32, kind: u8, buffer_value: JSValue, args: []const JSValue, prototype: ?*Object) !JSValue {
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
    const obj = try createTypedArrayInstance(rt, kind, prototype);
    errdefer Object.destroyFromHeader(rt, &obj.header);
    try obj.setOptionalValueSlot(rt, obj.typedArrayBufferSlot(), buffer.value().dup());
    obj.typedArrayByteOffsetSlot().* = byte_offset;
    obj.typedArrayElementSizeSlot().* = element_size;
    obj.typedArrayFixedLengthSlot().* = fixed_length;
    obj.typedArrayKindSlot().* = kind;
    return obj.value();
}

pub fn typedArrayConstructFullBuffer(rt: *JSRuntime, element_size: u32, kind: u8, buffer_value: JSValue, buffer: *Object, prototype: ?*Object) !JSValue {
    return typedArrayConstructFullBufferOwned(rt, element_size, kind, buffer_value.dup(), buffer, prototype);
}

pub fn typedArrayConstructFullBufferOwned(rt: *JSRuntime, element_size: u32, kind: u8, buffer_value: JSValue, buffer: *Object, prototype: ?*Object) !JSValue {
    var owned_buffer_value = buffer_value;
    errdefer owned_buffer_value.free(rt);
    if (element_size == 0) return error.TypeError;
    if (buffer.arrayBufferDetached()) return error.TypeError;
    if (buffer.arrayBufferMaxByteLength() != null) return error.TypeError;
    const buffer_length = buffer.byteStorage().len;
    if (buffer_length % element_size != 0) return error.RangeError;
    const length = @divTrunc(buffer_length, element_size);
    if (length > @as(usize, @intCast(std.math.maxInt(u32)))) return error.RangeError;

    const obj = try createTypedArrayInstance(rt, kind, prototype);
    errdefer Object.destroyFromHeader(rt, &obj.header);
    try obj.setOptionalValueSlot(rt, obj.typedArrayBufferSlot(), owned_buffer_value);
    owned_buffer_value = JSValue.undefinedValue();
    obj.typedArrayByteOffsetSlot().* = 0;
    obj.typedArrayElementSizeSlot().* = element_size;
    obj.typedArrayFixedLengthSlot().* = @intCast(length);
    obj.typedArrayKindSlot().* = kind;
    return obj.value();
}

/// QuickJS source map: narrow DataView constructor used by transitional
/// `new_dataview` bytecode.
pub fn dataViewConstruct(rt: *JSRuntime, args: []const JSValue, prototype: ?*Object) !JSValue {
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

    const obj = try Object.create(rt, class.ids.dataview, prototype);
    errdefer Object.destroyFromHeader(rt, &obj.header);
    if (view_length > @as(usize, @intCast(std.math.maxInt(u32)))) return error.RangeError;
    try obj.setOptionalValueSlot(rt, obj.typedArrayBufferSlot(), buffer.value().dup());
    obj.typedArrayByteOffsetSlot().* = byte_offset;
    obj.typedArrayFixedLengthSlot().* = @intCast(view_length);
    obj.typedArrayKindSlot().* = if (auto_length) 1 else 0;
    return obj.value();
}

// --- TypedArray element read / write (engine core) --------------------------

pub fn typedArrayGetIndex(rt: *JSRuntime, obj: *Object, index: u32) !JSValue {
    const length = try object.typedArrayLength(rt, obj);
    if (index >= length) return JSValue.undefinedValue();
    const buffer = try typedArrayBufferObject(obj);
    const offset = obj.typedArrayByteOffset() + @as(usize, index) * obj.typedArrayElementSize();
    return readElement(rt, obj.typedArrayKind(), buffer.byteStorage()[offset..][0..obj.typedArrayElementSize()]);
}

pub fn typedArrayCoerceElementValue(rt: *JSRuntime, obj: *Object, value: JSValue) !void {
    var scratch: [8]u8 = undefined;
    try writeElement(rt, obj.typedArrayKind(), scratch[0..obj.typedArrayElementSize()], value);
}

pub fn typedArraySetElement(rt: *JSRuntime, obj: *Object, index: u32, value: JSValue) !bool {
    if (try object.typedArrayImmutableBuffer(rt, obj)) return false;
    var scratch: [8]u8 = undefined;
    const width = obj.typedArrayElementSize();
    try writeElement(rt, obj.typedArrayKind(), scratch[0..width], value);
    if (!try object.typedArrayIndexValid(rt, obj, index)) return false;
    const buffer = try typedArrayBufferObject(obj);
    const offset = obj.typedArrayByteOffset() + @as(usize, index) * width;
    @memcpy(buffer.byteStorage()[offset..][0..width], scratch[0..width]);
    return true;
}

pub fn typedArraySetIndex(rt: *JSRuntime, obj: *Object, index: u32, value: JSValue) !bool {
    if (try object.typedArrayImmutableBuffer(rt, obj)) return false;
    const length = try object.typedArrayLength(rt, obj);
    if (index >= length) return true;
    const buffer = try typedArrayBufferObject(obj);
    const offset = obj.typedArrayByteOffset() + @as(usize, index) * obj.typedArrayElementSize();
    try writeElement(rt, obj.typedArrayKind(), buffer.byteStorage()[offset..][0..obj.typedArrayElementSize()], value);
    return true;
}

/// QuickJS source map: js_typed_array_fill (quickjs.c:57979-58002).
/// `value` has already been coerced to the target element type once by the
/// caller; coerce it to raw element bytes ONCE here, then fill the contiguous
/// byte range directly (memset for 1-byte kinds, tight typed-store loop for
/// wider kinds), exactly as qjs's switch(shift) does. The caller has already
/// re-validated detach/out-of-bounds and clamped `final` to the live length.
pub fn typedArrayFillRange(rt: *JSRuntime, obj: *Object, start: u32, final: u32, value: JSValue) !void {
    if (start >= final) return;
    const kind = obj.typedArrayKind();
    const width = obj.typedArrayElementSize();
    var scratch: [8]u8 = undefined;
    try writeElement(rt, kind, scratch[0..width], value);

    const buffer = try typedArrayBufferObject(obj);
    const storage = buffer.byteStorage();
    const base = obj.typedArrayByteOffset();
    var offset = base + @as(usize, start) * width;
    const end = base + @as(usize, final) * width;
    switch (width) {
        1 => @memset(storage[offset..end], scratch[0]),
        else => {
            const cell = scratch[0..width];
            while (offset < end) : (offset += width) {
                @memcpy(storage[offset..][0..width], cell);
            }
        },
    }
}

pub fn typedArraySetInt32IndexFast(rt: *JSRuntime, obj: *Object, index: u32, value: i32) !bool {
    if (obj.typedArrayKind() != 6) return false;
    if (try object.typedArrayImmutableBuffer(rt, obj)) return false;
    const length = try object.typedArrayLength(rt, obj);
    if (index >= length) return true;
    const buffer = try typedArrayBufferObject(obj);
    const offset = obj.typedArrayByteOffset() + @as(usize, index) * 4;
    std.mem.writeInt(i32, buffer.byteStorage()[offset..][0..4], value, .little);
    return true;
}

pub fn typedArrayDefineOwnProperty(rt: *JSRuntime, obj: *Object, atom_id: Atom, desc: Descriptor) !?bool {
    if (!object.isTypedArrayObject(obj)) return null;
    switch (try object.typedArrayCanonicalNumericIndex(rt, atom_id)) {
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
            if (!try object.typedArrayIndexValid(rt, obj, index)) return false;
            if (try object.typedArrayImmutableBuffer(rt, obj)) return false;
            if (desc.value_present) _ = try typedArraySetElement(rt, obj, index, desc.value);
            return true;
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
    try checkDataViewAttached(rt, view);
    try checkDataViewBounds(rt, view, index, width);
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
pub fn dataViewSet(rt: *JSRuntime, view_value: JSValue, kind: u32, args: []const JSValue) !JSValue {
    const view = try expectDataViewObject(view_value);
    const buffer = try dataViewBuffer(view);
    if (object.arrayBufferIsImmutable(rt, buffer)) return error.TypeError;
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

    try checkDataViewAttached(rt, view);
    try checkDataViewBounds(rt, view, index, width);
    const absolute = view.typedArrayByteOffset() + index;
    var i: usize = 0;
    while (i < width) : (i += 1) buffer.byteStorage()[absolute + i] = bytes[i];
    return JSValue.undefinedValue();
}

pub fn dataViewRejectImmutable(rt: *JSRuntime, view_value: JSValue) !void {
    const view = try expectDataViewObject(view_value);
    const buffer = try dataViewBuffer(view);
    if (object.arrayBufferIsImmutable(rt, buffer)) return error.TypeError;
}

pub fn dataViewRequire(view_value: JSValue) !void {
    _ = try expectDataViewObject(view_value);
}

pub fn dataViewByteLength(rt: *JSRuntime, view: *Object) !usize {
    return dataViewEffectiveByteLength(rt, view);
}

pub fn dataViewByteOffset(rt: *JSRuntime, view: *Object) !usize {
    _ = try dataViewEffectiveByteLength(rt, view);
    return view.typedArrayByteOffset();
}

pub fn dataViewValidateConstructorRange(_: *JSRuntime, buffer_value: JSValue, byte_offset: usize, view_length: ?usize) !void {
    const buffer = try expectArrayBufferObject(buffer_value);
    if (buffer.arrayBufferDetached()) return error.TypeError;
    const buffer_length = arrayBufferByteLength(buffer);
    if (byte_offset > buffer_length) return error.RangeError;
    const remaining = buffer_length - byte_offset;
    if (view_length) |length| {
        if (length > remaining) return error.RangeError;
    }
}

pub fn dataViewRequireArrayBuffer(buffer_value: JSValue) !void {
    _ = try expectArrayBufferObject(buffer_value);
}

fn checkDataViewBounds(rt: *JSRuntime, view: *Object, index: usize, width: usize) !void {
    const length = try dataViewEffectiveByteLength(rt, view);
    if (index > length or width > length - index) return error.RangeError;
}

fn checkDataViewAttached(rt: *JSRuntime, view: *Object) !void {
    _ = rt;
    const buffer = try dataViewBuffer(view);
    if (buffer.arrayBufferDetached()) return error.TypeError;
}

fn dataViewEffectiveByteLength(rt: *JSRuntime, view: *Object) !usize {
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

pub fn expectObject(value: JSValue) !*Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    return @fieldParentPtr("header", header);
}

pub fn expectArrayBufferObject(value: JSValue) !*Object {
    const obj = try expectObject(value);
    if (obj.class_id != class.ids.array_buffer and obj.class_id != class.ids.shared_array_buffer) return error.TypeError;
    return obj;
}

pub fn expectArrayBufferOnlyObject(value: JSValue) !*Object {
    const obj = try expectObject(value);
    if (obj.class_id != class.ids.array_buffer) return error.TypeError;
    return obj;
}

pub fn expectSharedArrayBufferObject(value: JSValue) !*Object {
    const obj = try expectObject(value);
    if (obj.class_id != class.ids.shared_array_buffer) return error.TypeError;
    return obj;
}

pub fn expectDataViewObject(value: JSValue) !*Object {
    const obj = try expectObject(value);
    if (obj.class_id != class.ids.dataview) return error.TypeError;
    return obj;
}

// --- Index / number coercion primitives -------------------------------------

fn relativeSliceIndex(rt: *JSRuntime, value: JSValue, len: usize, undefined_is_len: bool) !usize {
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

fn numberResult(value: f64) JSValue {
    if (std.math.isFinite(value) and @floor(value) == value and value >= @as(f64, @floatFromInt(std.math.minInt(i32))) and value <= @as(f64, @floatFromInt(std.math.maxInt(i32))) and !std.math.isNegativeZero(value)) {
        return JSValue.int32(@intFromFloat(value));
    }
    return JSValue.float64(value);
}

fn bigIntResult(rt: *JSRuntime, value: i128) !JSValue {
    const big = try bigint.BigInt.create(rt, value);
    return big.valueRef();
}

fn numberValue(value: JSValue) ?f64 {
    if (value.asInt32()) |int_value| return @floatFromInt(int_value);
    if (value.asFloat64()) |float_value| return float_value;
    return null;
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

fn coerceNumber(rt: *JSRuntime, value: JSValue) !f64 {
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

fn float16ToF64(bits: u16) f64 {
    return @floatCast(@as(f16, @bitCast(bits)));
}

fn f64ToFloat16(value: f64) u16 {
    return @bitCast(@as(f16, @floatCast(value)));
}

fn readElement(rt: *JSRuntime, kind: u8, bytes: []const u8) !JSValue {
    return switch (kind) {
        1 => JSValue.int32(@as(i8, @bitCast(bytes[0]))),
        2 => JSValue.int32(bytes[0]),
        3 => JSValue.int32(bytes[0]),
        4 => JSValue.int32(std.mem.readInt(i16, bytes[0..2], .little)),
        5 => JSValue.int32(std.mem.readInt(u16, bytes[0..2], .little)),
        6 => JSValue.int32(std.mem.readInt(i32, bytes[0..4], .little)),
        7 => numberResult(@floatFromInt(std.mem.readInt(u32, bytes[0..4], .little))),
        8 => numberResult(float16ToF64(std.mem.readInt(u16, bytes[0..2], .little))),
        9 => numberResult(@floatCast(@as(f32, @bitCast(std.mem.readInt(u32, bytes[0..4], .little))))),
        10 => numberResult(@bitCast(std.mem.readInt(u64, bytes[0..8], .little))),
        11 => bigIntResult(rt, std.mem.readInt(i64, bytes[0..8], .little)),
        12 => bigIntResult(rt, @intCast(std.mem.readInt(u64, bytes[0..8], .little))),
        else => error.TypeError,
    };
}

fn writeElement(rt: *JSRuntime, kind: u8, bytes: []u8, value: JSValue) !void {
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

fn valueToBigInt64Bits(rt: *JSRuntime, value: JSValue) !u64 {
    var big = try toBigIntValue(rt, value);
    defer big.deinit();
    const low: u64 = if (big.limbs.len >= 1) big.limbs[0] else 0;
    return if (big.negative) 0 -% low else low;
}

fn toBigIntValue(rt: *JSRuntime, value: JSValue) !bignum.BigInt {
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

fn cloneBigIntValue(rt: *JSRuntime, value: JSValue) !bignum.BigInt {
    if (value.asShortBigInt()) |big_int| return bignum.BigInt.fromIntAlloc(rt.memory.allocator, big_int);
    if (value.isBigInt() and value.refHeader() != null) {
        const header = value.refHeader().?;
        const big: *bigint.BigInt = @alignCast(@fieldParentPtr("header", header));
        return big.value.cloneWithAllocator(rt.memory.allocator);
    }
    return error.TypeError;
}

fn toIntegerOrInfinity(rt: *JSRuntime, value: JSValue) !f64 {
    if (numberValue(value)) |number| return number;
    if (value.asBool()) |bool_value| return if (bool_value) 1 else 0;
    if (value.isNull()) return 0;
    if (value.isUndefined()) return std.math.nan(f64);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try appendValueString(rt, &buffer, value);
    return parseJsNumber(buffer.items);
}

pub fn toIndexUsize(rt: *JSRuntime, value: JSValue) !usize {
    const number = try toIntegerOrInfinity(rt, value);
    if (std.math.isNan(number)) return 0;
    if (!std.math.isFinite(number)) return error.RangeError;
    const truncated = @trunc(number);
    if (truncated < 0) return error.RangeError;
    if (truncated == 0) return 0;
    return @intFromFloat(truncated);
}

fn parseJsNumber(bytes: []const u8) f64 {
    return value_format.parseJsNumber(bytes);
}

fn appendValueString(rt: *JSRuntime, buffer: *std.ArrayList(u8), value: JSValue) AppendStringError!void {
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
        const object_value: *Object = @fieldParentPtr("header", header);
        if (object_value.class_id == class.ids.string) {
            const data = object_value.objectData() orelse return error.TypeError;
            try appendValueString(rt, buffer, data);
        } else if (object_value.class_id == class.ids.array_buffer) {
            try buffer.appendSlice(rt.memory.allocator, "[object ArrayBuffer]");
        } else if (object_value.class_id == class.ids.promise) {
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

fn appendRawString(rt: *JSRuntime, buffer: *std.ArrayList(u8), value: JSValue) !void {
    const string_value = value.asStringBody() orelse return;
    try string_value.ensureFlat(rt);
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

fn appendArrayString(rt: *JSRuntime, buffer: *std.ArrayList(u8), obj: *Object) AppendStringError!void {
    var index: u32 = 0;
    while (index < obj.arrayLength()) : (index += 1) {
        if (index != 0) try buffer.append(rt.memory.allocator, ',');
        const value = obj.getProperty(atom.atomFromUInt32(index));
        defer value.free(rt);
        if (!value.isUndefined() and !value.isNull()) try appendValueString(rt, buffer, value);
    }
}
