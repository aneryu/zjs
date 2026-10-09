//! Native-record glue for Number/BigInt, parseInt/parseFloat, Date, DataView,
//! collections (Map/Set), WeakRef/FinalizationRegistry, Symbol registry, and
//! related host/output helpers. Math, URI, and JSON live in math_ops /
//! uri_ops / json_ops.

const iterator_ops = @import("iterator_ops.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const bytecode = @import("../bytecode.zig");
const array_ops = @import("array_ops.zig");
const core = @import("../core/root.zig");
const HostError = @import("exception_ops.zig").HostError;
const method_ids = core.host_function.builtin_method_ids;
const buffer_id_lookup = core.host_function.builtin_method_id_lookup.buffer;
const collection_id_lookup = core.host_function.builtin_method_id_lookup.collection;
const frame_mod = @import("frame.zig");
const property_ops = @import("property_ops.zig");
const std = @import("std");
const value_ops = @import("value_ops.zig");

const call_runtime = @import("call_runtime.zig");
const exception_ops = @import("exception_ops.zig");
const object_ops = @import("object_ops.zig");
const string_ops = @import("string_ops.zig");

// Helpers that remain in call_runtime.zig (generic utilities outside the builtin
// glue cluster).
const callValueOrBytecodeRoot = call_runtime.callValueOrBytecodeRoot;
const functionPrototypeFromGlobal = object_ops.functionPrototypeFromGlobal;
const getValueProperty = object_ops.getValueProperty;
const iteratorCloseWithCompletionAndPropagate = iterator_ops.iteratorCloseWithCompletionAndPropagate;
const iteratorStepValue = iterator_ops.iteratorStepValue;
const lengthIndexValue = array_ops.lengthIndexValue;
const objectFromValue = object_ops.objectFromValue;
const arrayBufferAccessor = array_ops.arrayBufferAccessor;
const arrayBufferIsView = array_ops.arrayBufferIsView;
const arrayBufferPrototypeNativeRecord = array_ops.arrayBufferPrototypeNativeRecord;
const sharedArrayBufferAccessor = array_ops.sharedArrayBufferAccessor;
const typedArrayAccessor = array_ops.typedArrayAccessor;
const typedArrayConstructToIndex = array_ops.typedArrayConstructToIndex;
const toPrimitiveForNumber = value_ops.toPrimitiveForNumber;
const toStringBytesForSymbol = string_ops.toStringBytesForSymbol;
const toStringForAnnexB = string_ops.toStringForAnnexB;

pub fn numberFunctionCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    const input = if (args.len >= 1) args[0] else return core.JSValue.int32(0);
    if (input.isBigInt()) return value_ops.numberToValue(try value_ops.bigIntToNumber(ctx.runtime, input));
    const primitive = try toPrimitiveForNumber(ctx, output, global, input);
    if (primitive.isBigInt()) return value_ops.numberToValue(try value_ops.bigIntToNumber(ctx.runtime, primitive));
    return value_ops.toNumberValue(ctx.runtime, primitive);
}

pub fn bigIntFunctionCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    // qjs js_bigint_constructor passes argv[0] — undefined
    // when absent — into JS_ToBigIntCtorFree; ToBigInt(undefined) throws.
    const input = value_ops.argOrUndefined(args, 0);
    const primitive = try toPrimitiveForNumber(ctx, output, global, input);
    if (primitive.as(.int)) |int_value| return value_ops.createBigIntI128(ctx.runtime, int_value);
    if (primitive.as(.float64)) |float_value| {
        return value_ops.integerNumberToBigIntValue(ctx.runtime, float_value);
    }
    // qjs JS_ToBigIntCtorFree null/undefined/default arm:
    // symbols fall into the same default arm and share the message.
    if (primitive.is(.undefined_value) or primitive.is(.null_value) or primitive.is(.symbol)) {
        return exception_ops.throwTypeErrorMessage(ctx, global, "cannot convert to BigInt");
    }
    var bigint = try value_ops.toBigIntValue(ctx.runtime, primitive);
    defer bigint.deinit();
    return value_ops.createBigIntValue(ctx.runtime, bigint);
}

pub fn bigIntAsN(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    unsigned: bool,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    // The caller pair is part of the shared builtin-record argument shape; the
    // coercions below open their own native environment, so neither is read.
    _ = caller_function;
    _ = caller_frame;
    const bits_input = value_ops.argOrUndefined(args, 0);
    const bits_primitive = try toPrimitiveForNumber(ctx, output, global, bits_input);
    if (bits_primitive.isBigInt()) return error.BigIntToNumber;
    if (bits_primitive.is(.symbol)) return error.SymbolToNumber;
    const bits = try value_ops.toIndexUsize(ctx.runtime, bits_primitive);

    const bigint_input = value_ops.argOrUndefined(args, 1);
    const bigint_primitive = try toPrimitiveForNumber(ctx, output, global, bigint_input);
    const bigint_value = try toBigIntFromPrimitive(ctx.runtime, bigint_primitive);
    return value_ops.asN(ctx.runtime, core.JSValue.float64(@floatFromInt(bits)), bigint_value, unsigned);
}

pub fn toBigIntFromPrimitive(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue {
    if (value.isBigInt()) return value;
    if (value.as(.boolean)) |bool_value| return value_ops.createBigIntI128(rt, if (bool_value) 1 else 0);
    if (value.isString()) {
        var bigint = try value_ops.toBigIntValue(rt, value);
        defer bigint.deinit();
        return value_ops.createBigIntValue(rt, bigint);
    }
    return error.CannotConvertToBigInt;
}

pub fn globalIsNaNOrFinite(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    is_nan: bool,
) !core.JSValue {
    const input = value_ops.argOrUndefined(args, 0);
    const primitive = try toPrimitiveForNumber(ctx, output, global, input);
    if (primitive.is(.symbol)) return error.SymbolToNumber;
    if (primitive.isBigInt()) return error.BigIntToNumber;
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    const number = value_ops.numberValue(number_value) orelse std.math.nan(f64);
    return core.JSValue.boolean(if (is_nan) std.math.isNan(number) else std.math.isFinite(number));
}

pub fn globalParseInt(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var values = [_]core.JSValue{
        global.value(),
        value_ops.argOrUndefined(args, 0),
        value_ops.argOrUndefined(args, 1),
    };
    const live: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &live }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);

    if (!values[1].isString()) values[1] = try toStringForAnnexB(ctx, output, objectFromValue(values[0]).?, values[1], caller_function, caller_frame);

    const radix_value: ?core.JSValue = if (args.len >= 2) blk: {
        const radix_input = values[2];
        if (!radix_input.is(.object) and !radix_input.is(.symbol) and !radix_input.isBigInt()) break :blk radix_input;
        values[2] = try toPrimitiveForNumber(ctx, output, objectFromValue(values[0]).?, radix_input);
        const number_value = try value_ops.toNumberValue(ctx.runtime, values[2]);
        break :blk value_ops.numberToValue(value_ops.numberValue(number_value) orelse std.math.nan(f64));
    } else null;
    return value_ops.numberToValue(try core.number.parseIntValue(ctx.runtime, values[1], radix_value));
}

pub fn globalParseFloat(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const input = value_ops.argOrUndefined(args, 0);
    const string_value = if (input.isString())
        input
    else
        try toStringForAnnexB(ctx, output, global, input, caller_function, caller_frame);
    return value_ops.numberToValue(try core.number.parseFloatValue(ctx.runtime, string_value));
}

/// `.array` domain record glue: resolve the Array and %TypedArray% static
/// methods and hand every prototype id to the Array.prototype record hub.
///
/// Push/pop now use dedicated record functions and bypass this shared glue,
/// including on the prepared no-function-object path. The Array statics and
/// remaining prototype methods arrive with a materialized function object; a
/// corrupt null reaches the hub's TypeError. Caller bytecode/frame are forwarded
/// so the table path keeps its inline-cache hint.
pub fn arrayNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: ?*core.Object,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    return switch (id) {
        @intFromEnum(method_ids.array.StaticMethod.is_array) => core.JSValue.boolean(args.len >= 1 and try core.array.isArrayValue(args[0])),
        @intFromEnum(method_ids.array.StaticMethod.from) => array_ops.arrayFromCall(ctx, output, global, this_value, (function_object orelse return error.TypeError).value(), args, caller_function, caller_frame),
        @intFromEnum(method_ids.array.StaticMethod.from_async) => array_ops.arrayFromAsyncCall(ctx, output, global, this_value, (function_object orelse return error.TypeError).value(), args, caller_function, caller_frame),
        @intFromEnum(method_ids.array.StaticMethod.of) => array_ops.arrayOfCall(ctx, output, global, this_value, (function_object orelse return error.TypeError).value(), args, caller_function, caller_frame),
        @intFromEnum(method_ids.array.TypedArrayMethod.from) => try array_ops.typedArrayFromStaticCall(ctx, output, global, this_value, args, caller_function, caller_frame),
        @intFromEnum(method_ids.array.TypedArrayMethod.of) => try array_ops.typedArrayOfStaticCall(ctx, output, global, this_value, args, caller_function, caller_frame),
        else => array_ops.arrayPrototypeNativeRecord(ctx, output, global, this_value, function_object, id, args, caller_function, caller_frame),
    };
}

pub fn bufferNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    receiver: core.JSValue,
    id: u32,
    args: []const core.JSValue,
) !?core.JSValue {
    if (id == @intFromEnum(method_ids.buffer.StaticMethod.is_view)) return arrayBufferIsView(args);
    if (buffer_id_lookup.arrayBufferAccessorNameFromRecordId(id)) |accessor_name| {
        return @as(?core.JSValue, try arrayBufferAccessor(receiver, accessor_name));
    }
    if (buffer_id_lookup.sharedArrayBufferAccessorNameFromRecordId(id)) |accessor_name| {
        return @as(?core.JSValue, try sharedArrayBufferAccessor(receiver, accessor_name));
    }
    if (buffer_id_lookup.dataViewAccessorNameFromRecordId(id)) |accessor_name| {
        return @as(?core.JSValue, try dataViewAccessor(receiver, accessor_name));
    }
    if (buffer_id_lookup.typedArrayAccessorNameFromRecordId(id)) |accessor_name| {
        return @as(?core.JSValue, try typedArrayAccessor(ctx, receiver, accessor_name));
    }
    if (try arrayBufferPrototypeNativeRecord(ctx, output, receiver, id, args)) |value| return value;
    if (buffer_id_lookup.dataViewGetKindFromRecordId(id)) |method_id| {
        const global = ctx.global orelse return error.InvalidBuiltinRegistry;
        return try dataViewGetCall(ctx, output, global, receiver, method_id, args);
    }
    if (buffer_id_lookup.dataViewSetKindFromRecordId(id)) |method_id| {
        const global = ctx.global orelse return error.InvalidBuiltinRegistry;
        return try dataViewSetCall(ctx, output, global, receiver, method_id, args);
    }
    return null;
}

pub const DataViewConstructorArgs = struct {
    byte_offset: usize,
    view_length: ?usize,
    has_offset: bool,
};

pub fn dataViewConstructorArgs(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !DataViewConstructorArgs {
    if (args.len < 1) return error.NotAnArrayBuffer;
    const buffer = try core.typed_array.expectArrayBufferObject(args[0]);
    const byte_offset = if (args.len >= 2)
        try typedArrayConstructToIndex(ctx, output, global, args[1])
    else
        @as(usize, 0);
    // DataView steps 4-6 (detached, offset range) precede ToIndex(byteLength),
    // whose range check uses the buffer length read in step 5.
    try core.typed_array.dataViewValidateConstructorRange(ctx.runtime, args[0], byte_offset, null);
    const buffer_length = core.typed_array.arrayBufferByteLength(buffer);
    const view_length = if (args.len >= 3 and !args[2].is(.undefined_value))
        try typedArrayConstructToIndex(ctx, output, global, args[2])
    else
        null;
    if (view_length) |length| {
        if (length > buffer_length - byte_offset) {
            _ = try exception_ops.throwRangeErrorMessage(ctx, global, "invalid byteLength");
            unreachable;
        }
    }
    return .{
        .byte_offset = byte_offset,
        .view_length = view_length,
        .has_offset = args.len >= 2,
    };
}

pub fn dataViewAccessor(receiver: core.JSValue, accessor: []const u8) !core.JSValue {
    const object = objectFromValue(receiver) orelse return error.IncompatibleReceiver;
    if (object.class_id != core.class.ids.dataview) return error.IncompatibleReceiver;
    if (std.mem.eql(u8, accessor, "buffer")) {
        return (object.typedArrayBuffer() orelse return error.TypeError);
    }
    if (std.mem.eql(u8, accessor, "byteLength")) {
        return core.JSValue.int32(@intCast(try core.typed_array.dataViewByteLength(object)));
    }
    if (std.mem.eql(u8, accessor, "byteOffset")) {
        return core.JSValue.int32(@intCast(try core.typed_array.dataViewByteOffset(object)));
    }
    return error.TypeError;
}

pub fn dataViewGetCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
) !core.JSValue {
    try core.typed_array.dataViewRequire(receiver);
    const index_arg = value_ops.argOrUndefined(args, 0);
    const index = try typedArrayConstructToIndex(ctx, output, global, index_arg);
    const little_endian = args.len >= 2 and value_ops.isTruthy(args[1]);
    const call_args = [_]core.JSValue{ lengthIndexValue(index), core.JSValue.boolean(little_endian) };
    return core.typed_array.dataViewGet(ctx.runtime, receiver, method_id, call_args[0..]);
}

pub fn dataViewSetCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
) !core.JSValue {
    try core.typed_array.dataViewRequire(receiver);
    const index_arg = value_ops.argOrUndefined(args, 0);
    const index = try typedArrayConstructToIndex(ctx, output, global, index_arg);
    const value_arg = value_ops.argOrUndefined(args, 1);
    const coerced_value = try dataViewSetCoerceValue(ctx, output, global, method_id, value_arg);
    const little_endian = args.len >= 3 and value_ops.isTruthy(args[2]);
    const call_args = [_]core.JSValue{ lengthIndexValue(index), coerced_value, core.JSValue.boolean(little_endian) };
    return core.typed_array.dataViewSet(ctx.runtime, receiver, method_id, call_args[0..]);
}

/// The two `core.typed_array.dataViewSet` kind ids whose element type is a
/// BigInt (`setBigInt64` / `setBigUint64`). Derived from the record-id table
/// instead of spelled as literals so a reorder of `DataViewSetMethod` cannot
/// silently shift them.
const data_view_set_kind_big_int64: u32 =
    buffer_id_lookup.dataViewSetKindFromRecordId(@intFromEnum(method_ids.buffer.DataViewSetMethod.big_int64)).?;
const data_view_set_kind_big_uint64: u32 =
    buffer_id_lookup.dataViewSetKindFromRecordId(@intFromEnum(method_ids.buffer.DataViewSetMethod.big_uint64)).?;

pub fn dataViewSetCoerceValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    method_id: u32,
    value: core.JSValue,
) !core.JSValue {
    const primitive = try toPrimitiveForNumber(ctx, output, global, value);
    // BigInt64/BigUint64 skip ToNumber: `dataViewSet` runs ToBigInt itself.
    if (method_id == data_view_set_kind_big_int64 or method_id == data_view_set_kind_big_uint64) return primitive;
    if (primitive.isBigInt()) return error.BigIntToNumber;
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    return number_value;
}

const WeakRefPrototypeMethod = method_ids.weak_ref.PrototypeMethod;

/// Declaration + dispatch table for the `.weak_ref` native-builtin domain:
/// qjs `js_weakref_proto_funcs` and `js_finrec_proto_funcs`.
/// In qjs these are ordinary `JS_CFUNC_DEF` entries reached
/// by `js_call_c_function` like any other builtin method. One shared handler
/// switches on the per-record `magic` (== domain-local id), mirroring the
/// other domain tables.
pub const internal_entries = [_]core.host_function.InternalEntry{
    weakRefEntry("deref", 0, @intFromEnum(WeakRefPrototypeMethod.deref), &weakRefCall),
    weakRefEntry("register", 2, @intFromEnum(WeakRefPrototypeMethod.finrec_register), &weakRefCall),
    weakRefEntry("unregister", 1, @intFromEnum(WeakRefPrototypeMethod.finrec_unregister), &weakRefCall),
};

const weakRefEntry = builtin_dispatch.entryWithHandler;

/// Shared record handler for the `.weak_ref` domain. The bodies below keep
/// their receiver-class checks, so a stolen method applied to a foreign
/// receiver throws TypeError (qjs `JS_GetOpaque2`, quickjs.c).
fn weakRefCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const ctx = host_call.ctx;
    const this_value = host_call.this_value;
    const args = host_call.args;
    return switch (host_call.magic) {
        @intFromEnum(WeakRefPrototypeMethod.deref) => try weakRefDerefCall(ctx.runtime, this_value),
        @intFromEnum(WeakRefPrototypeMethod.finrec_register) => try finalizationRegistryRegister(ctx, this_value, args),
        @intFromEnum(WeakRefPrototypeMethod.finrec_unregister) => try finalizationRegistryUnregister(ctx, this_value, args),
        else => error.TypeError,
    };
}

pub fn weakRefDerefCall(rt: *core.JSRuntime, receiver: core.JSValue) !core.JSValue {
    const object = objectFromValue(receiver) orelse return error.IncompatibleReceiver;
    if (object.class_id != core.class.ids.weak_ref) return error.IncompatibleReceiver;
    return try object.weakRefDeref(rt);
}

pub fn finalizationRegistryRegister(ctx: *core.JSContext, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const object = objectFromValue(receiver) orelse return error.IncompatibleReceiver;
    if (object.class_id != core.class.ids.finalization_registry) return error.IncompatibleReceiver;
    const target = value_ops.argOrUndefined(args, 0);
    const held_value = value_ops.argOrUndefined(args, 1);
    const unregister_token = value_ops.argOrUndefined(args, 2);
    if (!core.symbol.canBeHeldWeakly(ctx.runtime, target)) return error.InvalidWeakTarget;
    if (target.sameValue(held_value)) return error.HeldValueIsTarget;
    if (!unregister_token.is(.undefined_value) and !core.symbol.canBeHeldWeakly(ctx.runtime, unregister_token)) return error.InvalidUnregisterToken;
    // No self-target exclusion: qjs js_finrec_register appends
    // the entry unconditionally after the three checks above — a registry may
    // register itself as target (the cell holds only a weak ref to it).
    try finalizationRegistryAppendCell(ctx.runtime, object, target, held_value, unregister_token);
    return core.JSValue.undefinedValue();
}

pub fn finalizationRegistryUnregister(ctx: *core.JSContext, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const object = objectFromValue(receiver) orelse return error.IncompatibleReceiver;
    if (object.class_id != core.class.ids.finalization_registry) return error.IncompatibleReceiver;
    const token = value_ops.argOrUndefined(args, 0);
    if (!core.symbol.canBeHeldWeakly(ctx.runtime, token)) return error.InvalidUnregisterToken;
    return core.JSValue.boolean(object.unregisterFinalizationRegistryCells(ctx.runtime, token));
}

pub fn finalizationRegistryAppendCell(
    rt: *core.JSRuntime,
    object: *core.Object,
    target: core.JSValue,
    held_value: core.JSValue,
    unregister_token: core.JSValue,
) !void {
    try object.appendFinalizationRegistryCell(rt, target, held_value, unregister_token);
}

pub fn symbolFor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const key = if (args.len >= 1)
        try toStringBytesForSymbol(ctx, output, global, args[0], caller_function, caller_frame)
    else
        try ctx.runtime.nativeAllocator().dupe(u8, "undefined");
    defer ctx.runtime.nativeAllocator().free(key);

    return ctx.runtime.globalSymbolValue(key);
}

pub fn symbolKeyFor(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue {
    const value = value_ops.argOrUndefined(args, 0);
    const atom_id = value.asSymbolAtom() orelse return error.NotASymbol;
    const key = core.symbol.registryKey(rt.atoms, atom_id) orelse return core.JSValue.undefinedValue();
    return value_ops.createStringValue(rt, key);
}

/// C_FUNCTION_DATA analogue for internal callbacks whose semantics explicitly
/// use the caller realm rather than the realm in which the carrier was made.
pub fn createDataFunction(rt: *core.JSRuntime, global: *core.Object, name: []const u8, length: i32) !core.JSValue {
    const function_proto = functionPrototypeFromGlobal(global) orelse return error.InvalidBuiltinRegistry;
    return core.function.nativeDataFunctionWithPrototype(rt, function_proto, name, length);
}

pub fn addCollectionEntriesFromIterator(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    collection_value: core.JSValue,
    kind: u32,
    iterable_value: core.JSValue,
    adder: core.JSValue,
) !void {
    const record = try iterator_ops.getIterator(ctx, output, global, iterable_value, null, null);
    const iterator_value = record.iterator;
    const iterator = try property_ops.expectObject(iterator_value);

    // Dense bulk fill, taken ONLY when the default Array iteration protocol is
    // provably intact: the constructed iterator is a default Array Iterator of
    // value kind, its `next` is the builtin, and its target is a hole-free
    // fast array. Same guard as `call_runtime.appendSpreadValuesEnumerate`,
    // and read from the ITERATOR'S target rather than from the source, so a
    // repointed `@@iterator` still lands on the right array.
    //
    // The adder must be the builtin too. Bulk filling advances the iterator's
    // cursor once at the end instead of once per element, and skips the
    // per-element IteratorClose, so a user-visible `add`/`set` would observe
    // both: `class S extends Set { add(v) { return it.next().value; } }` reads
    // a cursor that has not moved, and an `add` that throws would escape
    // without running the iterator's `return`. A builtin adder runs no user
    // code, which is what makes the whole batch unobservable.
    fast: {
        const next_obj = objectFromValue(record.next) orelse break :fast;
        if (!next_obj.isArrayIteratorNextFunction()) break :fast;
        if (iterator.class_id != core.class.ids.array_iterator) break :fast;
        if (iterator_ops.arrayIteratorKind(iterator) != .value) break :fast;
        if (iterator.iteratorIndexSlot().* != 0) break :fast; // partially drained
        const adder_obj = objectFromValue(adder) orelse break :fast;
        const adder_ref = core.function.decodeNativeBuiltinId(adder_obj.nativeFunctionId()) orelse break :fast;
        if (adder_ref.domain != .collection) break :fast;
        const adder_name: []const u8 = if (kind == 1 or kind == 3) "set" else "add";
        const builtin_adder_id = collection_id_lookup.prototypeMethodId(adder_name) orelse break :fast;
        if (adder_ref.id != builtin_adder_id) break :fast;
        const target_value = (iterator.iteratorTargetSlot().*) orelse break :fast;
        const target_obj = objectFromValue(target_value) orelse break :fast;
        if (!target_obj.isArray() or target_obj.hasExoticMethods() or target_obj.proxyTarget() != null) break :fast;
        const elements = target_obj.arrayElements();
        if (@as(usize, @intCast(target_obj.arrayLength())) != elements.len) break :fast;
        // Entry reads can run user code and fail; `return` is still the
        // user's, and IteratorClose has to run before the failure propagates.
        array_ops.addCollectionEntriesFromArray(ctx, output, global, collection_value, kind, target_obj, adder, iterator) catch |err| {
            return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator_value, err, null, null);
        };
        return;
    }

    while (true) {
        // Failures inside IteratorStepValue propagate without closing.
        const step = try iteratorStepValue(ctx, output, global, record);
        if (step.done) return;

        if (kind == 1 or kind == 3) {
            const entry = core.value_semantics.objectFromValue(step.value) orelse {
                _ = exception_ops.throwTypeErrorMessage(ctx, global, "iterator value is not an entry object") catch |err|
                    return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator_value, err, null, null);
                unreachable;
            };
            const key = getValueProperty(ctx, output, global, entry.value(), core.Atom.taggedInt(0), null, null) catch |err| {
                return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator_value, err, null, null);
            };
            const value = getValueProperty(ctx, output, global, entry.value(), core.Atom.taggedInt(1), null, null) catch |err| {
                return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator_value, err, null, null);
            };
            callCollectionAdderFromVm(ctx, output, global, collection_value, adder, &.{ key, value }) catch |err| {
                return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator_value, err, null, null);
            };
        } else {
            callCollectionAdderFromVm(ctx, output, global, collection_value, adder, &.{step.value}) catch |err| {
                return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator_value, err, null, null);
            };
        }
    }
}

pub fn callCollectionAdderFromVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    collection_value: core.JSValue,
    adder: core.JSValue,
    args: []const core.JSValue,
) !void {
    _ = try callValueOrBytecodeRoot(ctx, output, global, collection_value, adder, args, null, null);
}

// Host output fast-path probes (moved from the VM call runtime).

// Realm slot and native-method helpers (moved from the VM call runtime).

pub fn functionConstructorFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object {
    // Borrowed own-property read; `rt` is kept to match the sibling
    // `*FromGlobal` realm-slot helpers its callers use side by side.
    _ = rt;
    if (global.getOwnDataObjectBorrowed(core.atom.ids.Function)) |constructor| return constructor;
    return null;
}

pub fn storeRealmValue(rt: *core.JSRuntime, global: *core.Object, slot: core.object.RealmValueSlot, value: core.JSValue) !void {
    try global.setCachedRealmValue(rt, slot, value);
}

/// Define a native data method on `object`. Shares the outlined
/// `defineNativeDataMethodMaybeId` walk with the native-id variant.
pub inline fn defineNativeDataMethod(rt: *core.JSRuntime, global: *core.Object, object: *core.Object, atom_id: core.Atom, length: i32) !void {
    return defineNativeDataMethodMaybeId(rt, global, object, atom_id, length, null);
}

/// Same as `defineNativeDataMethod`, but stamps the function object with a
/// native-builtin record id so calls dispatch through the integer record
/// mechanism instead of the legacy name chain.
pub inline fn defineNativeDataMethodWithNativeId(rt: *core.JSRuntime, global: *core.Object, object: *core.Object, atom_id: core.Atom, length: i32, native_builtin_id: i32) !void {
    return defineNativeDataMethodMaybeId(rt, global, object, atom_id, length, native_builtin_id);
}

noinline fn defineNativeDataMethodMaybeId(
    rt: *core.JSRuntime,
    global: *core.Object,
    object: *core.Object,
    atom_id: core.Atom,
    length: i32,
    native_builtin_id: ?i32,
) !void {
    var values = [_]core.JSValue{ object.value(), core.JSValue.undefinedValue() };
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    values[1] = try core.function.nativeFunctionForGlobal(rt, global, core.atom.predefinedName(atom_id), length);
    if (native_builtin_id) |id| {
        const method_object = try property_ops.expectObject(values[1]);
        method_object.setNativeBuiltinIdAndRecord(id);
    }
    try (try property_ops.expectObject(values[0])).defineOwnProperty(rt, atom_id, core.Descriptor.data(values[1], .method));
}

/// Bytes-taking form for the one caller whose method name comes out of a table
/// rather than a predefined-atom constant (`object_ops` CallSite prototype).
pub fn defineNativeDataMethodNamedWithNativeId(rt: *core.JSRuntime, global: *core.Object, object: *core.Object, name: []const u8, length: i32, native_builtin_id: i32) !void {
    var values = [_]core.JSValue{ object.value(), core.JSValue.undefinedValue() };
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    // Same protocol as `standard_globals.temporaryStringAtom` (TGC S3 §4
    // class B): a name outside `predefined_atoms` interns to a bare id that
    // the tracer cannot see, and it has to survive the two allocating calls
    // below before the property table takes it over. Pin it for the window.
    // Both helpers are no-ops for const/tagged-int ids.
    const atom_id = try rt.internAtom(name);
    rt.atoms.pinForHost(atom_id);
    defer rt.atoms.unpinForHost(atom_id);
    values[1] = try core.function.nativeFunctionForGlobal(rt, global, name, length);
    const method_object = try property_ops.expectObject(values[1]);
    method_object.setNativeBuiltinIdAndRecord(native_builtin_id);
    try (try property_ops.expectObject(values[0])).defineOwnProperty(rt, atom_id, core.Descriptor.data(values[1], .method));
}

// --- Primitive coercion moved to value_ops.zig ---
