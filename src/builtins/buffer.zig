const core = @import("../core/root.zig");
const std = @import("std");
const builtin_glue = @import("../exec/builtin_glue.zig");

const HostError = @import("../exec/exceptions.zig").HostError;
const InternalCall = core.host_function.InternalCall;

pub const StaticMethod = core.host_function.builtin_method_ids.buffer.StaticMethod;
pub const ConstructorMethod = core.host_function.builtin_method_ids.buffer.ConstructorMethod;
pub const ArrayBufferPrototypeMethod = core.host_function.builtin_method_ids.buffer.ArrayBufferPrototypeMethod;
pub const SharedArrayBufferPrototypeMethod = core.host_function.builtin_method_ids.buffer.SharedArrayBufferPrototypeMethod;

// The DataView get/set + ArrayBuffer/SharedArrayBuffer/DataView/TypedArray
// accessor method-id enums and their pure name<->id / id->name(/kind) mapping
// helpers were relocated to engine core (`core/host_function.zig`:
// `builtin_method_ids.buffer` + `builtin_method_id_lookup.buffer`) in Phase
// 6b-3c. They are re-exported here under their original names so the dispatch/
// install side keeps calling them unchanged, while the VM consumes the same
// helpers through `core` (zero exec->builtins).
pub const DataViewGetMethod = core.host_function.builtin_method_ids.buffer.DataViewGetMethod;
pub const DataViewSetMethod = core.host_function.builtin_method_ids.buffer.DataViewSetMethod;
pub const ArrayBufferAccessorMethod = core.host_function.builtin_method_ids.buffer.ArrayBufferAccessorMethod;
pub const SharedArrayBufferAccessorMethod = core.host_function.builtin_method_ids.buffer.SharedArrayBufferAccessorMethod;
pub const DataViewAccessorMethod = core.host_function.builtin_method_ids.buffer.DataViewAccessorMethod;
pub const TypedArrayAccessorMethod = core.host_function.builtin_method_ids.buffer.TypedArrayAccessorMethod;

const buffer_id_lookup = core.host_function.builtin_method_id_lookup.buffer;
pub const dataViewGetMethodId = buffer_id_lookup.dataViewGetMethodId;
pub const dataViewSetMethodId = buffer_id_lookup.dataViewSetMethodId;
pub const arrayBufferAccessorMethodId = buffer_id_lookup.arrayBufferAccessorMethodId;
pub const sharedArrayBufferAccessorMethodId = buffer_id_lookup.sharedArrayBufferAccessorMethodId;
pub const dataViewAccessorMethodId = buffer_id_lookup.dataViewAccessorMethodId;
pub const typedArrayAccessorMethodId = buffer_id_lookup.typedArrayAccessorMethodId;
pub const dataViewGetKindFromRecordId = buffer_id_lookup.dataViewGetKindFromRecordId;
pub const dataViewSetKindFromRecordId = buffer_id_lookup.dataViewSetKindFromRecordId;
pub const arrayBufferAccessorNameFromRecordId = buffer_id_lookup.arrayBufferAccessorNameFromRecordId;
pub const sharedArrayBufferAccessorNameFromRecordId = buffer_id_lookup.sharedArrayBufferAccessorNameFromRecordId;
pub const dataViewAccessorNameFromRecordId = buffer_id_lookup.dataViewAccessorNameFromRecordId;
pub const typedArrayAccessorNameFromRecordId = buffer_id_lookup.typedArrayAccessorNameFromRecordId;

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

/// Declaration + dispatch table for the `.buffer` native-builtin domain
/// (QuickJS js_array_buffer_funcs / js_shared_array_buffer_funcs /
/// js_dataview_funcs / typed-array accessor analogues). One shared handler
/// `bufferCall` switches on the per-record `magic` (== domain-local id) by
/// forwarding to `builtin_glue.qjsBufferNativeRecord`, the exec VM-op dispatch
/// glue that resolves the ArrayBuffer/SharedArrayBuffer prototype methods,
/// `ArrayBuffer.isView`, the DataView get/set methods, and the ArrayBuffer /
/// SharedArrayBuffer / DataView / TypedArray byte-length accessors against the
/// realm-aware exec ops. Those exec ops stay in exec: the DataView get/set glue
/// is also reached by the VM's own by-name dispatch (`call_runtime`) and the
/// accessor / prototype helpers do species-aware construction through VM
/// machinery (BOTH). The TypedArray `[[Get]]/[[Set]]/[[Delete]]` canonical
/// property semantics and the ArrayBuffer/SharedArrayBuffer constructors plus
/// the construction-fusion peephole are NOT here — they are driven by opcode
/// handlers / the construct path, never by function-object record dispatch.
/// Property installation still resolves names/lengths through the registry's
/// own buffer method tables and the `*MethodId` helpers above; this table is
/// consumed by the slow record-dispatch path (`rt.internal_builtins`).
/// `prepared_call_ok` is uniformly false: no buffer record was ever
/// prepared-call eligible (`vm_call.nativeBuiltinSupportedWithoutFunctionObject`
/// returns false for `.buffer`).
pub const internal_entries = bufferEntries: {
    const Entry = core.host_function.InternalEntry;
    break :bufferEntries [_]Entry{
        bufferEntry("isView", 1, @intFromEnum(StaticMethod.is_view)),
        // ArrayBuffer.prototype methods.
        bufferEntry("slice", 2, @intFromEnum(ArrayBufferPrototypeMethod.slice)),
        bufferEntry("resize", 1, @intFromEnum(ArrayBufferPrototypeMethod.resize)),
        bufferEntry("transfer", 0, @intFromEnum(ArrayBufferPrototypeMethod.transfer)),
        bufferEntry("transferToFixedLength", 0, @intFromEnum(ArrayBufferPrototypeMethod.transfer_to_fixed_length)),
        bufferEntry("sliceToImmutable", 2, @intFromEnum(ArrayBufferPrototypeMethod.slice_to_immutable)),
        bufferEntry("transferToImmutable", 0, @intFromEnum(ArrayBufferPrototypeMethod.transfer_to_immutable)),
        // SharedArrayBuffer.prototype methods.
        bufferEntry("slice", 2, @intFromEnum(SharedArrayBufferPrototypeMethod.slice)),
        bufferEntry("grow", 1, @intFromEnum(SharedArrayBufferPrototypeMethod.grow)),
        // DataView.prototype get methods.
        bufferEntry("getInt8", 1, @intFromEnum(DataViewGetMethod.int8)),
        bufferEntry("getUint8", 1, @intFromEnum(DataViewGetMethod.uint8)),
        bufferEntry("getInt16", 1, @intFromEnum(DataViewGetMethod.int16)),
        bufferEntry("getUint16", 1, @intFromEnum(DataViewGetMethod.uint16)),
        bufferEntry("getInt32", 1, @intFromEnum(DataViewGetMethod.int32)),
        bufferEntry("getUint32", 1, @intFromEnum(DataViewGetMethod.uint32)),
        bufferEntry("getFloat16", 1, @intFromEnum(DataViewGetMethod.float16)),
        bufferEntry("getFloat32", 1, @intFromEnum(DataViewGetMethod.float32)),
        bufferEntry("getFloat64", 1, @intFromEnum(DataViewGetMethod.float64)),
        bufferEntry("getBigInt64", 1, @intFromEnum(DataViewGetMethod.big_int64)),
        bufferEntry("getBigUint64", 1, @intFromEnum(DataViewGetMethod.big_uint64)),
        // DataView.prototype set methods.
        bufferEntry("setInt8", 2, @intFromEnum(DataViewSetMethod.int8)),
        bufferEntry("setUint8", 2, @intFromEnum(DataViewSetMethod.uint8)),
        bufferEntry("setInt16", 2, @intFromEnum(DataViewSetMethod.int16)),
        bufferEntry("setUint16", 2, @intFromEnum(DataViewSetMethod.uint16)),
        bufferEntry("setInt32", 2, @intFromEnum(DataViewSetMethod.int32)),
        bufferEntry("setUint32", 2, @intFromEnum(DataViewSetMethod.uint32)),
        bufferEntry("setFloat16", 2, @intFromEnum(DataViewSetMethod.float16)),
        bufferEntry("setFloat32", 2, @intFromEnum(DataViewSetMethod.float32)),
        bufferEntry("setFloat64", 2, @intFromEnum(DataViewSetMethod.float64)),
        bufferEntry("setBigInt64", 2, @intFromEnum(DataViewSetMethod.big_int64)),
        bufferEntry("setBigUint64", 2, @intFromEnum(DataViewSetMethod.big_uint64)),
        // ArrayBuffer.prototype accessors (lazy native getters).
        bufferEntry("get byteLength", 0, @intFromEnum(ArrayBufferAccessorMethod.byte_length)),
        bufferEntry("get detached", 0, @intFromEnum(ArrayBufferAccessorMethod.detached)),
        bufferEntry("get maxByteLength", 0, @intFromEnum(ArrayBufferAccessorMethod.max_byte_length)),
        bufferEntry("get resizable", 0, @intFromEnum(ArrayBufferAccessorMethod.resizable)),
        bufferEntry("get immutable", 0, @intFromEnum(ArrayBufferAccessorMethod.immutable)),
        // SharedArrayBuffer.prototype accessors.
        bufferEntry("get byteLength", 0, @intFromEnum(SharedArrayBufferAccessorMethod.byte_length)),
        bufferEntry("get maxByteLength", 0, @intFromEnum(SharedArrayBufferAccessorMethod.max_byte_length)),
        bufferEntry("get growable", 0, @intFromEnum(SharedArrayBufferAccessorMethod.growable)),
        // DataView.prototype accessors.
        bufferEntry("get buffer", 0, @intFromEnum(DataViewAccessorMethod.buffer)),
        bufferEntry("get byteLength", 0, @intFromEnum(DataViewAccessorMethod.byte_length)),
        bufferEntry("get byteOffset", 0, @intFromEnum(DataViewAccessorMethod.byte_offset)),
        // %TypedArray%.prototype accessors.
        bufferEntry("get buffer", 0, @intFromEnum(TypedArrayAccessorMethod.buffer)),
        bufferEntry("get byteLength", 0, @intFromEnum(TypedArrayAccessorMethod.byte_length)),
        bufferEntry("get byteOffset", 0, @intFromEnum(TypedArrayAccessorMethod.byte_offset)),
        bufferEntry("get length", 0, @intFromEnum(TypedArrayAccessorMethod.length)),
        bufferEntry("get [Symbol.toStringTag]", 0, @intFromEnum(TypedArrayAccessorMethod.to_string_tag)),
    };
};

fn bufferEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{ .name = name, .length = length, .id = id, .magic = @intCast(id), .prepared_call_ok = false, .call = &bufferCall };
}

/// Shared record handler for the `.buffer` domain. Mirrors the retired
/// `call.zig` `callBufferNativeFunctionRecord`: forward the record id to the
/// exec dispatch glue, and surface the corrupt-id case (e.g. an ArrayBuffer
/// constructor record invoked as a plain function) as a TypeError, exactly as
/// before.
fn bufferCall(host_call: InternalCall) HostError!core.JSValue {
    if (try builtin_glue.qjsBufferNativeRecord(host_call.ctx, host_call.this_value, host_call.magic, host_call.args)) |value| return value;
    return error.TypeError;
}


// The engine-core TypedArray / ArrayBuffer / DataView element-access, coercion,
// and storage-operation mechanism now lives in core/typed_array.zig (QuickJS
// places these in the engine core, with builtins as clients). This file keeps
// the JS-visible construction primitives that read constructor options / coerce
// arguments (construct-path entangled) plus the record-dispatch table and the
// name/registry helpers above, and re-exports each moved primitive under its
// original name so callers (and the construct-prim implementations below) keep
// resolving them here.
const typed_array_core = core.typed_array;

/// Legacy narrow ArrayBuffer storage struct. Retained as a public type; the
/// live engine-core storage lives on `core.Object`'s array-buffer slots.
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
    return typed_array_core.arrayBufferConstruct(rt, length_value);
}

// ArrayBuffer / SharedArrayBuffer argument-coercing constructors read the
// `maxByteLength` option off a user object, so the conservative Phase 6b-3c
// placement put them in exec (`exec/typed_array_construct.zig`); re-exported
// here under their original names for the install/test side.
const typed_array_construct = @import("../exec/typed_array_construct.zig");
pub const arrayBufferConstructArgs = typed_array_construct.arrayBufferConstructArgs;
pub const sharedArrayBufferConstructArgs = typed_array_construct.sharedArrayBufferConstructArgs;

pub const arrayBufferConstructLength = typed_array_core.arrayBufferConstructLength;
pub const sharedArrayBufferConstructLength = typed_array_core.sharedArrayBufferConstructLength;
pub const sharedArrayBufferFromStore = typed_array_core.sharedArrayBufferFromStore;

// Pure view-construction primitives (no options `Get`, no user code) were
// relocated to engine core (`core/typed_array.zig`) in Phase 6b-3c; re-exported
// here so the install/test side keeps the original names. The VM construct path
// consumes them through `core` directly.
pub const typedArrayConstruct = typed_array_core.typedArrayConstruct;
pub const typedArrayConstructWithOptions = typed_array_core.typedArrayConstructWithOptions;
pub const typedArrayConstructFullBuffer = typed_array_core.typedArrayConstructFullBuffer;
pub const typedArrayConstructFullBufferOwned = typed_array_core.typedArrayConstructFullBufferOwned;
pub const dataViewConstruct = typed_array_core.dataViewConstruct;

pub const dataViewValidateConstructorRange = typed_array_core.dataViewValidateConstructorRange;
pub const dataViewRequireArrayBuffer = typed_array_core.dataViewRequireArrayBuffer;

// --- Engine-core mechanism re-exports (moved to core/typed_array.zig) -------
//
// ArrayBuffer / SharedArrayBuffer storage operations.
pub const arrayBufferSlice = typed_array_core.arrayBufferSlice;
pub const arrayBufferSliceRange = typed_array_core.arrayBufferSliceRange;
pub const arrayBufferSliceToImmutable = typed_array_core.arrayBufferSliceToImmutable;
pub const arrayBufferSliceToImmutableRange = typed_array_core.arrayBufferSliceToImmutableRange;
pub const arrayBufferTransfer = typed_array_core.arrayBufferTransfer;
pub const arrayBufferTransferLength = typed_array_core.arrayBufferTransferLength;
pub const arrayBufferTransferToImmutable = typed_array_core.arrayBufferTransferToImmutable;
pub const arrayBufferTransferToImmutableLength = typed_array_core.arrayBufferTransferToImmutableLength;
pub const sharedArrayBufferSlice = typed_array_core.sharedArrayBufferSlice;
pub const sharedArrayBufferSliceRange = typed_array_core.sharedArrayBufferSliceRange;
pub const sharedArrayBufferGrow = typed_array_core.sharedArrayBufferGrow;
pub const sharedArrayBufferGrowLength = typed_array_core.sharedArrayBufferGrowLength;
pub const arrayBufferResize = typed_array_core.arrayBufferResize;
pub const arrayBufferResizeLength = typed_array_core.arrayBufferResizeLength;
pub const detachArrayBuffer = typed_array_core.detachArrayBuffer;

// TypedArray element read / write fabric.
pub const typedArrayGetIndex = typed_array_core.typedArrayGetIndex;
pub const typedArraySetIndex = typed_array_core.typedArraySetIndex;
pub const typedArraySetElement = typed_array_core.typedArraySetElement;
pub const typedArrayCoerceElementValue = typed_array_core.typedArrayCoerceElementValue;
pub const typedArraySetInt32IndexFast = typed_array_core.typedArraySetInt32IndexFast;
pub const typedArrayDefineOwnProperty = typed_array_core.typedArrayDefineOwnProperty;

// DataView get/set primitives.
pub const dataViewGet = typed_array_core.dataViewGet;
pub const dataViewSet = typed_array_core.dataViewSet;
pub const dataViewRejectImmutable = typed_array_core.dataViewRejectImmutable;
pub const dataViewRequire = typed_array_core.dataViewRequire;
pub const dataViewByteLength = typed_array_core.dataViewByteLength;
pub const dataViewByteOffset = typed_array_core.dataViewByteOffset;

// TypedArray element-mechanism predicates live in core/object.zig (the engine-
// core storage layer); re-export under the original names so this file's
// construction primitives and external callers keep resolving them locally.
pub const isTypedArrayObject = core.object.isTypedArrayObject;
pub const typedArrayOutOfBounds = core.object.typedArrayOutOfBounds;
pub const typedArrayDetached = core.object.typedArrayDetached;
pub const typedArrayLength = core.object.typedArrayLength;
pub const typedArrayByteLength = core.object.typedArrayByteLength;
pub const typedArrayByteOffset = core.object.typedArrayEffectiveByteOffset;
pub const typedArrayIndexValid = core.object.typedArrayIndexValid;
pub const TypedArrayCanonicalIndex = core.object.TypedArrayCanonicalIndex;
pub const typedArrayCanonicalNumericIndex = core.object.typedArrayCanonicalNumericIndex;
pub const typedArrayBackedByResizableBuffer = core.object.typedArrayBackedByResizableBuffer;
pub const typedArrayRejectImmutableBuffer = core.object.typedArrayRejectImmutableBuffer;
pub const typedArrayImmutableBuffer = core.object.typedArrayImmutableBuffer;
pub const markArrayBufferImmutable = core.object.markArrayBufferImmutable;
pub const arrayBufferIsImmutable = core.object.arrayBufferIsImmutable;
