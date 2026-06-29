//! Native-record glue for Math, Number/BigInt, parseInt/parseFloat, URI, JSON and Date builtins,
//! plus collections (Map/Set), weak refs/FinalizationRegistry, Symbol registry and DataView.

const call_mod = @import("call.zig");
const bytecode = @import("../bytecode.zig");
const collection_vm = @import("array_ops.zig");
const core = @import("../core/root.zig");
const method_ids = core.host_function.builtin_method_ids;
const buffer_id_lookup = core.host_function.builtin_method_id_lookup.buffer;
const date_vm = @import("date_ops.zig");
const frame_mod = @import("frame.zig");
const property_ops = @import("property_ops.zig");
const std = @import("std");
const value_ops = @import("value_ops.zig");

const call_runtime = @import("call_runtime.zig");
const coercion_ops = @import("coercion_ops.zig");
const object_ops = @import("object_ops.zig");
const string_ops = @import("string_ops.zig");

// Helpers that remain in call_runtime.zig (generic utilities outside the builtin
// glue cluster).
const callValueOrBytecode = call_runtime.callValueOrBytecode;
const constructCollectionWithPrototypeFromVm = object_ops.constructCollectionWithPrototypeFromVm;
const constructorNameEqlLocal = call_runtime.constructorNameEqlLocal;
const constructorPrototypeObject = object_ops.constructorPrototypeObject;
const functionPrototypeFromGlobal = object_ops.functionPrototypeFromGlobal;
const getIteratorMethod = call_runtime.getIteratorMethod;
const getValueProperty = object_ops.getValueProperty;
const isCallableValue = call_runtime.isCallableValue;
const iteratorCloseWithCompletionAndPropagate = call_runtime.iteratorCloseWithCompletionAndPropagate;
const iteratorStepValue = call_runtime.iteratorStepValue;
const lengthIndexValue = collection_vm.lengthIndexValue;
const objectFromValue = object_ops.objectFromValue;
const qjsArrayBufferAccessor = collection_vm.qjsArrayBufferAccessor;
const qjsArrayBufferIsView = collection_vm.qjsArrayBufferIsView;
const qjsArrayBufferPrototypeNativeRecord = collection_vm.qjsArrayBufferPrototypeNativeRecord;
const qjsSharedArrayBufferAccessor = collection_vm.qjsSharedArrayBufferAccessor;
const qjsTypedArrayAccessor = collection_vm.qjsTypedArrayAccessor;
const qjsTypedArrayConstructToIndex = collection_vm.qjsTypedArrayConstructToIndex;
const toPrimitiveForNumber = coercion_ops.toPrimitiveForNumber;
const toStringBytesForSymbol = string_ops.toStringBytesForSymbol;
const toStringForAnnexB = string_ops.toStringForAnnexB;

pub fn qjsNumberFunctionCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    const input = if (args.len >= 1) args[0] else return core.JSValue.int32(0);
    if (input.isBigInt()) return value_ops.numberToValue(try value_ops.bigIntToNumber(ctx.runtime, input));
    const primitive = try toPrimitiveForNumber(ctx, output, global, input);
    defer primitive.free(ctx.runtime);
    if (primitive.isBigInt()) return value_ops.numberToValue(try value_ops.bigIntToNumber(ctx.runtime, primitive));
    return value_ops.toNumberValue(ctx.runtime, primitive);
}

pub fn qjsBigIntFunctionCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    const input = if (args.len >= 1) args[0] else core.JSValue.int32(0);
    const primitive = try toPrimitiveForNumber(ctx, output, global, input);
    defer primitive.free(ctx.runtime);
    if (primitive.asInt32()) |int_value| return value_ops.createBigIntI128(ctx.runtime, int_value);
    if (primitive.asFloat64()) |float_value| {
        return value_ops.integerNumberToBigIntValue(ctx.runtime, float_value);
    }
    var bigint = try value_ops.toBigIntValue(ctx.runtime, primitive);
    defer bigint.deinit();
    return value_ops.createBigIntValue(ctx.runtime, bigint);
}

pub fn qjsBigIntAsN(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    unsigned: bool,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = caller_function;
    _ = caller_frame;
    const bits_input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const bits_primitive = try toPrimitiveForNumber(ctx, output, global, bits_input);
    defer bits_primitive.free(ctx.runtime);
    if (bits_primitive.isBigInt() or bits_primitive.isSymbol()) return error.TypeError;
    const bits_number_value = try value_ops.toNumberValue(ctx.runtime, bits_primitive);
    defer bits_number_value.free(ctx.runtime);
    const bits_number = value_ops.numberValue(bits_number_value) orelse 0;
    const bits: usize = if (std.math.isNan(bits_number))
        0
    else blk: {
        if (!std.math.isFinite(bits_number)) return error.RangeError;
        const truncated = @trunc(bits_number);
        if (truncated < 0) return error.RangeError;
        if (truncated > 9007199254740991.0) return error.RangeError;
        break :blk @intFromFloat(truncated);
    };

    const bigint_input = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const bigint_primitive = try toPrimitiveForNumber(ctx, output, global, bigint_input);
    defer bigint_primitive.free(ctx.runtime);
    const bigint_value = try toBigIntFromPrimitive(ctx.runtime, bigint_primitive);
    defer bigint_value.free(ctx.runtime);
    return value_ops.asN(ctx.runtime, core.JSValue.float64(@floatFromInt(bits)), bigint_value, unsigned);
}

pub fn toBigIntFromPrimitive(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue {
    if (value.isBigInt()) return value.dup();
    if (value.asBool()) |bool_value| return value_ops.createBigIntI128(rt, if (bool_value) 1 else 0);
    if (value.isString()) {
        var bigint = try value_ops.toBigIntValue(rt, value);
        defer bigint.deinit();
        return value_ops.createBigIntValue(rt, bigint);
    }
    return error.TypeError;
}

pub fn qjsGlobalIsNaNOrFinite(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    is_nan: bool,
) !core.JSValue {
    if (objectFromValue(this_value)) |receiver| {
        if (try constructorNameEqlLocal(ctx.runtime, receiver, "Number")) {
            const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const number = value_ops.numberValue(value);
            if (is_nan) return core.JSValue.boolean(value.isNumber() and std.math.isNan(number orelse std.math.nan(f64)));
            return core.JSValue.boolean(value.isNumber() and std.math.isFinite(number orelse std.math.nan(f64)));
        }
    }
    const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const primitive = try toPrimitiveForNumber(ctx, output, global, input);
    defer primitive.free(ctx.runtime);
    if (primitive.isSymbol() or primitive.isBigInt()) return error.TypeError;
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    defer number_value.free(ctx.runtime);
    const number = value_ops.numberValue(number_value) orelse std.math.nan(f64);
    return core.JSValue.boolean(if (is_nan) std.math.isNan(number) else std.math.isFinite(number));
}

pub fn qjsDateToPrimitiveNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return date_vm.qjsDateToPrimitiveCall(ctx, output, global, this_value, args, caller_function, caller_frame);
}

pub fn toNumberLikeArgument(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !core.JSValue {
    const primitive = try toPrimitiveForNumber(ctx, output, global, value);
    defer primitive.free(ctx.runtime);
    if (primitive.isBigInt()) return error.TypeError;
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    defer number_value.free(ctx.runtime);
    return value_ops.numberToValue(value_ops.numberValue(number_value) orelse std.math.nan(f64));
}

pub fn qjsGlobalParseInt(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const string_value = if (input.isString())
        input
    else
        try toStringForAnnexB(ctx, output, global, input, caller_function, caller_frame);
    defer if (!input.isString()) string_value.free(ctx.runtime);

    const radix_value: ?core.JSValue = if (args.len >= 2) blk: {
        const radix_input = args[1];
        if (!radix_input.isObject() and !radix_input.isSymbol() and !radix_input.isBigInt()) break :blk radix_input;
        const primitive = try toPrimitiveForNumber(ctx, output, global, radix_input);
        defer primitive.free(ctx.runtime);
        const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
        defer number_value.free(ctx.runtime);
        break :blk value_ops.numberToValue(value_ops.numberValue(number_value) orelse std.math.nan(f64));
    } else null;
    return value_ops.numberToValue(try core.number.parseIntValue(ctx.runtime, string_value, radix_value));
}

pub fn qjsGlobalParseFloat(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const string_value = if (input.isString())
        input
    else
        try toStringForAnnexB(ctx, output, global, input, caller_function, caller_frame);
    defer if (!input.isString()) string_value.free(ctx.runtime);
    return value_ops.numberToValue(try core.number.parseFloatValue(ctx.runtime, string_value));
}

/// `.array` domain VM-op dispatch glue. Mirrors the retired `call.zig`
/// `callArrayNativeFunctionRecord`: resolve the Array static methods
/// (`from`/`of`/`isArray`) and the Array.prototype method record hub against
/// the realm-aware exec ops, which stay in exec because they are also reached
/// by the VM fast-call path (`qjsArrayMethodFastCall`).
///
/// `function_object` is nullable so the prepared (no-function-object) call path
/// routes through this same record glue under the uniform dispatch model. Only
/// `push`/`pop` reach here with `function_object == null` (the prepared-call
/// gate admits no other Array id), and the prototype hub services those two
/// without the function object. The Array statics (`from`/`of`/`isArray`) and
/// every other prototype method need the materialized function object, so they
/// surface the corrupt-id `error.TypeError` (via the hub) under null func_obj —
/// unreachable in practice because the gate blocks those ids. The VM caller
/// bytecode/frame are forwarded so the table path keeps the inline-cache hint
/// the dedicated prepared bypass carried.
pub fn qjsArrayNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: ?*core.Object,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    return switch (id) {
        @intFromEnum(method_ids.array.StaticMethod.is_array) => core.JSValue.boolean(args.len >= 1 and try core.array.isArrayValue(args[0])),
        @intFromEnum(method_ids.array.StaticMethod.from) => collection_vm.qjsArrayFromCall(ctx, output, global, this_value, (function_object orelse return error.TypeError).value(), args, caller_function, caller_frame),
        @intFromEnum(method_ids.array.StaticMethod.of) => collection_vm.qjsArrayOfCall(ctx, output, global, this_value, (function_object orelse return error.TypeError).value(), args, caller_function, caller_frame),
        else => collection_vm.qjsArrayPrototypeNativeRecord(ctx, output, global, this_value, function_object, id, args, caller_function, caller_frame),
    };
}

pub fn qjsBufferNativeRecord(
    ctx: *core.JSContext,
    receiver: core.JSValue,
    id: u32,
    args: []const core.JSValue,
) !?core.JSValue {
    if (id == @intFromEnum(method_ids.buffer.StaticMethod.is_view)) return qjsArrayBufferIsView(args);
    if (buffer_id_lookup.arrayBufferAccessorNameFromRecordId(id)) |accessor_name| {
        return @as(?core.JSValue, try qjsArrayBufferAccessor(ctx, receiver, accessor_name));
    }
    if (buffer_id_lookup.sharedArrayBufferAccessorNameFromRecordId(id)) |accessor_name| {
        return @as(?core.JSValue, try qjsSharedArrayBufferAccessor(ctx, receiver, accessor_name));
    }
    if (buffer_id_lookup.dataViewAccessorNameFromRecordId(id)) |accessor_name| {
        return @as(?core.JSValue, try qjsDataViewAccessor(ctx, receiver, accessor_name));
    }
    if (buffer_id_lookup.typedArrayAccessorNameFromRecordId(id)) |accessor_name| {
        return @as(?core.JSValue, try qjsTypedArrayAccessor(ctx, receiver, accessor_name));
    }
    if (try qjsArrayBufferPrototypeNativeRecord(ctx, receiver, id, args)) |value| return value;
    if (buffer_id_lookup.dataViewGetKindFromRecordId(id)) |method_id| {
        const global = ctx.global orelse {
            const value = try (core.typed_array.dataViewGet(ctx.runtime, receiver, method_id, args) catch |err| switch (err) {
                error.TypeError => error.TypeError,
                error.RangeError => error.RangeError,
                else => err,
            });
            return @as(?core.JSValue, value);
        };
        const value = try (qjsDataViewGet(ctx, null, global, receiver, method_id, args) catch |err| switch (err) {
            error.TypeError => error.TypeError,
            error.RangeError => error.RangeError,
            else => err,
        });
        return @as(?core.JSValue, value);
    }
    if (buffer_id_lookup.dataViewSetKindFromRecordId(id)) |method_id| {
        const global = ctx.global orelse {
            const value = try (core.typed_array.dataViewSet(ctx.runtime, receiver, method_id, args) catch |err| switch (err) {
                error.TypeError => error.TypeError,
                error.RangeError => error.RangeError,
                else => err,
            });
            return @as(?core.JSValue, value);
        };
        const value = try (qjsDataViewSet(ctx, null, global, receiver, method_id, args) catch |err| switch (err) {
            error.TypeError => error.TypeError,
            error.RangeError => error.RangeError,
            else => err,
        });
        return @as(?core.JSValue, value);
    }
    return null;
}

pub const DataViewConstructorArgs = struct {
    byte_offset: usize,
    view_length: ?usize,
    has_offset: bool,
};

pub fn qjsDataViewConstructorArgs(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !DataViewConstructorArgs {
    if (args.len < 1) return error.TypeError;
    try core.typed_array.dataViewRequireArrayBuffer(args[0]);
    const byte_offset = if (args.len >= 2)
        try qjsTypedArrayConstructToIndex(ctx, output, global, args[1])
    else
        @as(usize, 0);
    const view_length = if (args.len >= 3 and !args[2].isUndefined())
        try qjsTypedArrayConstructToIndex(ctx, output, global, args[2])
    else
        null;
    try core.typed_array.dataViewValidateConstructorRange(ctx.runtime, args[0], byte_offset, view_length);
    return .{
        .byte_offset = byte_offset,
        .view_length = view_length,
        .has_offset = args.len >= 2,
    };
}

pub fn qjsDataViewAccessor(ctx: *core.JSContext, receiver: core.JSValue, accessor: []const u8) !core.JSValue {
    const object = objectFromValue(receiver) orelse return error.TypeError;
    if (object.class_id != core.class.ids.dataview) return error.TypeError;
    if (std.mem.eql(u8, accessor, "buffer")) {
        return (object.typedArrayBuffer() orelse return error.TypeError).dup();
    }
    if (std.mem.eql(u8, accessor, "byteLength")) {
        return core.JSValue.int32(@intCast(try core.typed_array.dataViewByteLength(ctx.runtime, object)));
    }
    if (std.mem.eql(u8, accessor, "byteOffset")) {
        return core.JSValue.int32(@intCast(try core.typed_array.dataViewByteOffset(ctx.runtime, object)));
    }
    return error.TypeError;
}

pub fn qjsDataViewGet(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
) !core.JSValue {
    try core.typed_array.dataViewRequire(receiver);
    const index_arg = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const index = try qjsTypedArrayConstructToIndex(ctx, output, global, index_arg);
    const little_endian = args.len >= 2 and value_ops.isTruthy(args[1]);
    const call_args = [_]core.JSValue{ lengthIndexValue(index), core.JSValue.boolean(little_endian) };
    return core.typed_array.dataViewGet(ctx.runtime, receiver, method_id, call_args[0..]);
}

pub fn qjsDataViewSet(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
) !core.JSValue {
    try core.typed_array.dataViewRejectImmutable(ctx.runtime, receiver);
    const index_arg = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const index = try qjsTypedArrayConstructToIndex(ctx, output, global, index_arg);
    const value_arg = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const coerced_value = try qjsDataViewSetCoerceValue(ctx, output, global, method_id, value_arg);
    defer coerced_value.free(ctx.runtime);
    const little_endian = args.len >= 3 and value_ops.isTruthy(args[2]);
    const call_args = [_]core.JSValue{ lengthIndexValue(index), coerced_value, core.JSValue.boolean(little_endian) };
    return core.typed_array.dataViewSet(ctx.runtime, receiver, method_id, call_args[0..]);
}

pub fn qjsDataViewSetCoerceValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    method_id: u32,
    value: core.JSValue,
) !core.JSValue {
    const primitive = try toPrimitiveForNumber(ctx, output, global, value);
    errdefer primitive.free(ctx.runtime);
    if (method_id == 9 or method_id == 10) return primitive;
    if (primitive.isBigInt()) return error.TypeError;
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    primitive.free(ctx.runtime);
    return number_value;
}

pub fn qjsErrorIsError(args: []const core.JSValue) core.JSValue {
    if (args.len < 1) return core.JSValue.boolean(false);
    const object = objectFromValue(args[0]) orelse return core.JSValue.boolean(false);
    return core.JSValue.boolean(object.class_id == core.class.ids.error_);
}

pub fn qjsWeakRefDeref(rt: *core.JSRuntime, receiver: core.JSValue) !core.JSValue {
    const object = objectFromValue(receiver) orelse return error.TypeError;
    if (object.class_id != core.class.ids.weak_ref) return error.TypeError;
    return object.weakRefDeref(rt);
}

pub fn qjsFinalizationRegistryRegister(ctx: *core.JSContext, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const object = objectFromValue(receiver) orelse return error.TypeError;
    if (object.class_id != core.class.ids.finalization_registry) return error.TypeError;
    const target = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const held_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const unregister_token = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
    if (!qjsCanBeHeldWeakly(ctx.runtime, target)) return error.TypeError;
    if (target.sameValue(held_value)) return error.TypeError;
    if (!unregister_token.isUndefined() and !qjsCanBeHeldWeakly(ctx.runtime, unregister_token)) return error.TypeError;
    if (target.sameValue(receiver)) return core.JSValue.undefinedValue();
    try qjsFinalizationRegistryAppendCell(ctx.runtime, object, target, held_value, unregister_token);
    return core.JSValue.undefinedValue();
}

pub fn qjsFinalizationRegistryUnregister(ctx: *core.JSContext, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const object = objectFromValue(receiver) orelse return error.TypeError;
    if (object.class_id != core.class.ids.finalization_registry) return error.TypeError;
    const token = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (!qjsCanBeHeldWeakly(ctx.runtime, token)) return error.TypeError;
    return core.JSValue.boolean(object.unregisterFinalizationRegistryCells(ctx.runtime, token));
}

pub fn qjsFinalizationRegistryAppendCell(
    rt: *core.JSRuntime,
    object: *core.Object,
    target: core.JSValue,
    held_value: core.JSValue,
    unregister_token: core.JSValue,
) !void {
    try object.appendFinalizationRegistryCell(rt, target, held_value, unregister_token);
}

pub fn qjsCanBeHeldWeakly(rt: *core.JSRuntime, value: core.JSValue) bool {
    if (value.isObject()) return true;
    if (value.asSymbolAtom()) |atom_id| {
        return rt.atoms.kind(atom_id) == .symbol;
    }
    return false;
}

pub fn qjsSymbolFor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const key = if (args.len >= 1)
        try toStringBytesForSymbol(ctx, output, global, args[0], caller_function, caller_frame)
    else
        try ctx.runtime.memory.allocator.dupe(u8, "undefined");
    defer ctx.runtime.memory.allocator.free(key);

    return ctx.runtime.globalSymbolValue(key);
}

pub fn qjsSymbolKeyFor(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue {
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const atom_id = value.asSymbolAtom() orelse return error.TypeError;
    const key = core.symbol.registryKey(&rt.atoms, atom_id) orelse return core.JSValue.undefinedValue();
    return value_ops.createStringValue(rt, key);
}

pub fn qjsCreateBuiltinFunction(rt: *core.JSRuntime, global: *core.Object, name: []const u8, length: i32) !core.JSValue {
    const function = try core.function.nativeFunction(rt, name, length);
    errdefer function.free(rt);
    const object = objectFromValue(function) orelse return error.TypeError;
    try object.setFunctionRealmGlobalPtr(rt, global);
    if (functionPrototypeFromGlobal(rt, global)) |function_proto| {
        try object.setPrototype(rt, function_proto);
    }
    return function;
}

pub fn constructCollectionFromVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: core.JSValue,
    kind: u32,
    args: []const core.JSValue,
) !core.JSValue {
    const prototype = try constructorPrototypeObject(ctx.runtime, constructor);
    return constructCollectionWithPrototypeFromVm(ctx, output, global, kind, args, prototype);
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
    const iterator_method = try getIteratorMethod(ctx, output, global, iterable_value);
    defer iterator_method.free(ctx.runtime);
    if (!isCallableValue(iterator_method)) return error.TypeError;
    const iterator_value = try callValueOrBytecode(ctx, output, global, iterable_value, iterator_method, &.{}, null, null);
    defer iterator_value.free(ctx.runtime);
    _ = try property_ops.expectObject(iterator_value);

    while (true) {
        const step = iteratorStepValue(ctx, output, global, iterator_value) catch |err| {
            return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator_value, err, null, null);
        };
        defer step.value.free(ctx.runtime);
        if (step.done) return;

        if (kind == 1 or kind == 3) {
            const entry = property_ops.expectObject(step.value) catch {
                return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator_value, error.TypeError, null, null);
            };
            const key = getValueProperty(ctx, output, global, entry.value(), core.atom.atomFromUInt32(0), null, null) catch |err| {
                return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator_value, err, null, null);
            };
            defer key.free(ctx.runtime);
            const value = getValueProperty(ctx, output, global, entry.value(), core.atom.atomFromUInt32(1), null, null) catch |err| {
                return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator_value, err, null, null);
            };
            defer value.free(ctx.runtime);
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
    const out = try callValueOrBytecode(ctx, output, global, collection_value, adder, args, null, null);
    out.free(ctx.runtime);
}

// Host output fast-path probes (moved from the VM call runtime).

pub fn printHostOutputArgs(rt: *core.JSRuntime, output: ?*std.Io.Writer, args: []const core.JSValue) !void {
    if (output) |writer| {
        for (args, 0..) |arg, idx| {
            if (idx != 0) try writer.writeByte(' ');
            try call_mod.printValue(rt, writer, arg);
        }
        try writer.writeByte('\n');
    }
}

pub fn globalHostOutputAutoInit(rt: *core.JSRuntime, global: *core.Object, atom_id: core.Atom) bool {
    if (global.hasExoticMethods()) return false;
    for (global.shapeProps(), 0..) |prop, property_index| {
        const prop_flags = core.property.Flags.fromBits(prop.flags);
        if (prop_flags.deleted or prop.atom_id != atom_id) continue;
        if (prop_flags.isAccessor()) return false;
        return switch (global.properties[property_index].slot) {
            .auto_init => |info| info.host_function_kind == core.host_function.ids.output or
                (info.host_function_kind == core.host_function.ids.external_host and
                    call_mod.isOutputExternalHostFunctionId(rt, info.external_host_function_id)),
            .data, .accessor, .deleted => false,
        };
    }
    return false;
}

// Realm slot and native-method helpers (moved from the VM call runtime).

pub fn functionConstructorFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object {
    if (global.getOwnDataObjectBorrowed(core.atom.ids.Function)) |constructor| return constructor;
    const function_value = global.getProperty(core.atom.ids.Function);
    defer function_value.free(rt);
    return property_ops.expectObject(function_value) catch null;
}

pub fn storeRealmValue(rt: *core.JSRuntime, global: *core.Object, slot: core.object.RealmValueSlot, value: core.JSValue) !void {
    const cached = try global.cachedRealmValueSlot(rt, slot);
    try global.setOptionalValueSlot(rt, cached, value.dup());
}

pub fn defineNativeDataMethod(rt: *core.JSRuntime, object: *core.Object, name: []const u8, length: i32) !void {
    const atom_id = try rt.internAtom(name);
    defer rt.atoms.free(atom_id);
    const method = try core.function.nativeFunction(rt, name, length);
    defer method.free(rt);
    try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(method, true, false, true));
}

/// Same as `defineNativeDataMethod`, but stamps the function object with a
/// native-builtin record id so calls dispatch through the integer record
/// mechanism instead of the legacy name chain.
pub fn defineNativeDataMethodWithNativeId(rt: *core.JSRuntime, object: *core.Object, name: []const u8, length: i32, native_builtin_id: i32) !void {
    const atom_id = try rt.internAtom(name);
    defer rt.atoms.free(atom_id);
    const method = try core.function.nativeFunction(rt, name, length);
    defer method.free(rt);
    const method_object = property_ops.expectObject(method) catch return error.TypeError;
    method_object.nativeFunctionIdSlot().* = native_builtin_id;
    try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(method, true, false, true));
}

// --- Primitive coercion moved to coercion_ops.zig ---
