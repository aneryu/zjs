//! Buffer builtin records, method-id mapping, and exec/core compatibility seams.
//!
//! Native-call receivers and arguments are borrowed; returned JSValues are
//! owned. Core owns ArrayBuffer, SharedArrayBuffer, DataView, and TypedArray
//! storage mechanics; option-reading constructors and record dispatch remain in
//! exec because they can invoke user code. The Uint8Array base64/hex codecs
//! live in `uint8array_codec.zig`.

const core = @import("../core/root.zig");
const std = @import("std");
const uint8array_codec = @import("uint8array_codec.zig");
const builtin_glue = @import("builtin_glue.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");

const exception_ops = @import("exception_ops.zig");
const HostError = exception_ops.HostError;

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
pub const Uint8ArrayStaticMethod = core.host_function.builtin_method_ids.buffer.Uint8ArrayStaticMethod;
pub const Uint8ArrayPrototypeMethod = core.host_function.builtin_method_ids.buffer.Uint8ArrayPrototypeMethod;

const uint8_array_static_names = std.StaticStringMap(Uint8ArrayStaticMethod).initComptime(.{
    .{ "fromBase64", .from_base64 },
    .{ "fromHex", .from_hex },
});

const uint8_array_prototype_names = std.StaticStringMap(Uint8ArrayPrototypeMethod).initComptime(.{
    .{ "toBase64", .to_base64 },
    .{ "toHex", .to_hex },
    .{ "setFromBase64", .set_from_base64 },
    .{ "setFromHex", .set_from_hex },
});

pub fn uint8ArrayStaticMethodId(name: []const u8) ?u32 {
    return @intFromEnum(uint8_array_static_names.get(name) orelse return null);
}

pub fn uint8ArrayPrototypeMethodId(name: []const u8) ?u32 {
    return @intFromEnum(uint8_array_prototype_names.get(name) orelse return null);
}

const buffer_id_lookup = core.host_function.builtin_method_id_lookup.buffer;
pub const dataViewGetMethodId = buffer_id_lookup.dataViewGetMethodId;
pub const dataViewSetMethodId = buffer_id_lookup.dataViewSetMethodId;
pub const typedArrayAccessorMethodId = buffer_id_lookup.typedArrayAccessorMethodId;
pub const dataViewGetKindFromRecordId = buffer_id_lookup.dataViewGetKindFromRecordId;
pub const arrayBufferAccessorNameFromRecordId = buffer_id_lookup.arrayBufferAccessorNameFromRecordId;

pub fn staticMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "isView")) return @intFromEnum(StaticMethod.is_view);
    return null;
}

pub fn arrayBufferPrototypeMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "slice")) return @intFromEnum(ArrayBufferPrototypeMethod.slice);
    if (std.mem.eql(u8, name, "resize")) return @intFromEnum(ArrayBufferPrototypeMethod.resize);
    if (std.mem.eql(u8, name, "transfer")) return @intFromEnum(ArrayBufferPrototypeMethod.transfer);
    if (std.mem.eql(u8, name, "transferToFixedLength")) return @intFromEnum(ArrayBufferPrototypeMethod.transfer_to_fixed_length);
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
/// forwarding to `builtin_glue.bufferNativeRecord`, the exec VM-op dispatch
/// glue that resolves the ArrayBuffer/SharedArrayBuffer prototype methods,
/// `ArrayBuffer.isView`, the DataView get/set methods, and the ArrayBuffer /
/// SharedArrayBuffer / DataView / TypedArray byte-length accessors against the
/// realm-aware exec ops. Those exec ops stay in exec: the accessor / prototype
/// helpers do species-aware construction through VM machinery. The TypedArray `[[Get]]/[[Set]]/[[Delete]]` canonical
/// property semantics and the ArrayBuffer/SharedArrayBuffer constructors plus
/// the construction-fusion peephole are NOT here — they are driven by opcode
/// handlers / the construct path, never by function-object record dispatch.
/// Property installation resolves names/lengths through standard-global
/// function lists and the `*MethodId` helpers above; this table is
/// consumed by the record-dispatch path (`internal_builtins.table`).
pub const internal_entries = bufferEntries: {
    const Entry = core.host_function.InternalEntry;
    break :bufferEntries [_]Entry{
        bufferEntry("isView", 1, @intFromEnum(StaticMethod.is_view), &bufferCall),
        // ArrayBuffer.prototype methods.
        bufferEntry("slice", 2, @intFromEnum(ArrayBufferPrototypeMethod.slice), &bufferCall),
        bufferEntry("resize", 1, @intFromEnum(ArrayBufferPrototypeMethod.resize), &bufferCall),
        bufferEntry("transfer", 0, @intFromEnum(ArrayBufferPrototypeMethod.transfer), &bufferCall),
        bufferEntry("transferToFixedLength", 0, @intFromEnum(ArrayBufferPrototypeMethod.transfer_to_fixed_length), &bufferCall),
        // SharedArrayBuffer.prototype methods.
        bufferEntry("slice", 2, @intFromEnum(SharedArrayBufferPrototypeMethod.slice), &bufferCall),
        bufferEntry("grow", 1, @intFromEnum(SharedArrayBufferPrototypeMethod.grow), &bufferCall),
        // DataView.prototype get methods.
        bufferEntry("getInt8", 1, @intFromEnum(DataViewGetMethod.int8), &bufferCall),
        bufferEntry("getUint8", 1, @intFromEnum(DataViewGetMethod.uint8), &bufferCall),
        bufferEntry("getInt16", 1, @intFromEnum(DataViewGetMethod.int16), &bufferCall),
        bufferEntry("getUint16", 1, @intFromEnum(DataViewGetMethod.uint16), &bufferCall),
        bufferEntry("getInt32", 1, @intFromEnum(DataViewGetMethod.int32), &bufferCall),
        bufferEntry("getUint32", 1, @intFromEnum(DataViewGetMethod.uint32), &bufferCall),
        bufferEntry("getFloat16", 1, @intFromEnum(DataViewGetMethod.float16), &bufferCall),
        bufferEntry("getFloat32", 1, @intFromEnum(DataViewGetMethod.float32), &bufferCall),
        bufferEntry("getFloat64", 1, @intFromEnum(DataViewGetMethod.float64), &bufferCall),
        bufferEntry("getBigInt64", 1, @intFromEnum(DataViewGetMethod.big_int64), &bufferCall),
        bufferEntry("getBigUint64", 1, @intFromEnum(DataViewGetMethod.big_uint64), &bufferCall),
        // DataView.prototype set methods.
        bufferEntry("setInt8", 2, @intFromEnum(DataViewSetMethod.int8), &bufferCall),
        bufferEntry("setUint8", 2, @intFromEnum(DataViewSetMethod.uint8), &bufferCall),
        bufferEntry("setInt16", 2, @intFromEnum(DataViewSetMethod.int16), &bufferCall),
        bufferEntry("setUint16", 2, @intFromEnum(DataViewSetMethod.uint16), &bufferCall),
        bufferEntry("setInt32", 2, @intFromEnum(DataViewSetMethod.int32), &bufferCall),
        bufferEntry("setUint32", 2, @intFromEnum(DataViewSetMethod.uint32), &bufferCall),
        bufferEntry("setFloat16", 2, @intFromEnum(DataViewSetMethod.float16), &bufferCall),
        bufferEntry("setFloat32", 2, @intFromEnum(DataViewSetMethod.float32), &bufferCall),
        bufferEntry("setFloat64", 2, @intFromEnum(DataViewSetMethod.float64), &bufferCall),
        bufferEntry("setBigInt64", 2, @intFromEnum(DataViewSetMethod.big_int64), &bufferCall),
        bufferEntry("setBigUint64", 2, @intFromEnum(DataViewSetMethod.big_uint64), &bufferCall),
        // ArrayBuffer.prototype accessors (lazy native getters).
        bufferEntry("get byteLength", 0, @intFromEnum(ArrayBufferAccessorMethod.byte_length), &bufferCall),
        bufferEntry("get detached", 0, @intFromEnum(ArrayBufferAccessorMethod.detached), &bufferCall),
        bufferEntry("get maxByteLength", 0, @intFromEnum(ArrayBufferAccessorMethod.max_byte_length), &bufferCall),
        bufferEntry("get resizable", 0, @intFromEnum(ArrayBufferAccessorMethod.resizable), &bufferCall),
        // SharedArrayBuffer.prototype accessors.
        bufferEntry("get byteLength", 0, @intFromEnum(SharedArrayBufferAccessorMethod.byte_length), &bufferCall),
        bufferEntry("get maxByteLength", 0, @intFromEnum(SharedArrayBufferAccessorMethod.max_byte_length), &bufferCall),
        bufferEntry("get growable", 0, @intFromEnum(SharedArrayBufferAccessorMethod.growable), &bufferCall),
        // DataView.prototype accessors.
        bufferEntry("get buffer", 0, @intFromEnum(DataViewAccessorMethod.buffer), &bufferCall),
        bufferEntry("get byteLength", 0, @intFromEnum(DataViewAccessorMethod.byte_length), &bufferCall),
        bufferEntry("get byteOffset", 0, @intFromEnum(DataViewAccessorMethod.byte_offset), &bufferCall),
        // %TypedArray%.prototype accessors.
        bufferEntry("get buffer", 0, @intFromEnum(TypedArrayAccessorMethod.buffer), &bufferCall),
        bufferEntry("get byteLength", 0, @intFromEnum(TypedArrayAccessorMethod.byte_length), &bufferCall),
        bufferEntry("get byteOffset", 0, @intFromEnum(TypedArrayAccessorMethod.byte_offset), &bufferCall),
        bufferEntry("get length", 0, @intFromEnum(TypedArrayAccessorMethod.length), &bufferCall),
        bufferEntry("get [Symbol.toStringTag]", 0, @intFromEnum(TypedArrayAccessorMethod.to_string_tag), &bufferCall),
        // Uint8Array base64/hex codecs: qjs js_uint8array_funcs
        // and js_uint8array_proto_funcs.
        codecEntry("fromBase64", 1, @intFromEnum(Uint8ArrayStaticMethod.from_base64), &uint8ArrayCodecCall),
        codecEntry("fromHex", 1, @intFromEnum(Uint8ArrayStaticMethod.from_hex), &uint8ArrayCodecCall),
        codecEntry("toBase64", 0, @intFromEnum(Uint8ArrayPrototypeMethod.to_base64), &uint8ArrayCodecCall),
        codecEntry("toHex", 0, @intFromEnum(Uint8ArrayPrototypeMethod.to_hex), &uint8ArrayCodecCall),
        codecEntry("setFromBase64", 1, @intFromEnum(Uint8ArrayPrototypeMethod.set_from_base64), &uint8ArrayCodecCall),
        codecEntry("setFromHex", 1, @intFromEnum(Uint8ArrayPrototypeMethod.set_from_hex), &uint8ArrayCodecCall),
        // The two buffer constructor ids. `installStandardConstructor` stamps these
        // ids onto the live `ArrayBuffer` / `SharedArrayBuffer` objects
        // (standard_globals.zig), so they must resolve to a record; without
        // these rows the id decoded but pointed past the end of the domain's
        // record array, leaving `nativeEntrySlot` null.
        //
        // `new ArrayBuffer(n)` never reaches this record: construction is
        // intercepted upstream by `array_ops.constructArrayBufferNativeRecord`
        // (called from call_runtime.zig), which reads the raw id. What lands here is
        // the *plain call* `ArrayBuffer(8)`, which must throw -- and does,
        // because `bufferNativeRecord` has no arm for these ids and
        // `bufferCall` turns that miss into a TypeError. Hence `generic_magic`
        // rather than a constructor cproto: a constructor cproto would also
        // make `callConstructRecordImpl` claim the construct path and route it
        // into the same TypeError.
        bufferEntry("ArrayBuffer", 1, @intFromEnum(ConstructorMethod.array_buffer), &bufferCall),
        bufferEntry("SharedArrayBuffer", 1, @intFromEnum(ConstructorMethod.shared_array_buffer), &bufferCall),
    };
};

const bufferEntry = builtin_dispatch.entryWithHandler;

/// Shared record handler for the `.buffer` domain: forward the record id to
/// the exec dispatch glue, and surface the corrupt-id case (e.g. an
/// ArrayBuffer constructor record invoked as a plain function) as a
/// TypeError.
fn bufferCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    if (try builtin_glue.bufferNativeRecord(host_call.ctx, host_call.output, host_call.this_value, host_call.magic, host_call.args)) |value| return value;
    // The constructor ids reach this record only as a plain call.
    const constructor_ids = [_]ConstructorMethod{ .array_buffer, .shared_array_buffer };
    for (constructor_ids) |id| {
        if (host_call.magic != @intFromEnum(id)) continue;
        const global = host_call.ctx.global orelse return error.TypeError;
        _ = try exception_ops.throwTypeErrorMessage(host_call.ctx, global, "must be called with new");
        unreachable;
    }
    return error.TypeError;
}

const codecEntry = builtin_dispatch.entryWithHandler;

/// Record handler for the Uint8Array base64/hex codecs. Unlike the rest of the
/// `.buffer` domain these need the writer/caller-frame context, because
/// `check_options_object` and the `alphabet` /
/// `lastChunkHandling` / `omitPadding` reads run user getters. The magic only
/// picks which constant name `uint8ArrayCodecCall` branches on, so each
/// body -- and with it the qjs-ordered receiver check / string check /
/// GetOptionsObject / option Get sequence -- is reached unchanged.
fn uint8ArrayCodecCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const realm = try builtin_dispatch.callableRealm(host_call);
    const name: []const u8 = switch (host_call.magic) {
        @intFromEnum(Uint8ArrayStaticMethod.from_base64) => "fromBase64",
        @intFromEnum(Uint8ArrayStaticMethod.from_hex) => "fromHex",
        @intFromEnum(Uint8ArrayPrototypeMethod.to_base64) => "toBase64",
        @intFromEnum(Uint8ArrayPrototypeMethod.to_hex) => "toHex",
        @intFromEnum(Uint8ArrayPrototypeMethod.set_from_base64) => "setFromBase64",
        @intFromEnum(Uint8ArrayPrototypeMethod.set_from_hex) => "setFromHex",
        else => return error.TypeError,
    };
    const result = try uint8array_codec.uint8ArrayCodecCall(
        realm.realm,
        host_call.output,
        realm.global,
        host_call.this_value,
        name,
        host_call.args,
        builtin_dispatch.callerBytecode(host_call),
        builtin_dispatch.callerFrame(host_call),
    );
    return result orelse error.TypeError;
}

// The engine-core TypedArray / ArrayBuffer / DataView element-access, coercion,
// and storage-operation mechanism lives in core/typed_array.zig (QuickJS
// places these in the engine core, with builtins as clients). This file keeps
// the JS-visible construction primitives that read constructor options /
// coerce arguments, plus the record-dispatch table and the name/id helpers
// above. The two re-exports below serve the test262 host and the tests.
const typed_array_core = core.typed_array;

pub const typedArrayConstructWithOptions = typed_array_core.typedArrayConstructWithOptions;
pub const detachArrayBuffer = typed_array_core.detachArrayBuffer;
