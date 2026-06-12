const fusion_stats = @import("vm_fusion_stats.zig");
const std = @import("std");
const bytecode = @import("../bytecode/root.zig");
const builtins = @import("../builtins/root.zig");
const unicode_lib = @import("../libs/unicode.zig");
const core = @import("../core/root.zig");
const call_mod = @import("call.zig");
// const collection_vm = merged
const construct_mod = @import("construct.zig");
const frame_mod = @import("frame.zig");
const iter_vm = @import("iterator_ops.zig");
const property_ops = @import("property_ops.zig");
const zjs_vm = @import("zjs_vm.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");
pub const createNamedError = exception_ops.createNamedError;
pub const createNamedErrorWithConstructor = exception_ops.createNamedErrorWithConstructor;
const op = bytecode.opcode.op;
const atom_buffer = core.atom.predefinedId("buffer", .string).?;
const atom_byte_length = core.atom.predefinedId("byteLength", .string).?;
const atom_byte_offset = core.atom.predefinedId("byteOffset", .string).?;
const exception_ops = @import("vm_exception_ops.zig");

const call_runtime = @import("call_runtime.zig");
const builtin_glue = @import("builtin_glue.zig");
const coercion_ops = @import("coercion_ops.zig");
const error_stack_ops = @import("error_stack_ops.zig");
const forof_ops = @import("forof_ops.zig");
const object_ops = @import("object_ops.zig");
const regexp_fastpath = @import("regexp_fastpath.zig");
const slot_ops = @import("slot_ops.zig");
const string_ops = @import("string_ops.zig");
const utils = @import("vm_utils.zig");
const ActiveRootValueProbe = call_runtime.ActiveRootValueProbe;
const IteratorZipRecord = iter_vm.IteratorZipRecord;
const RegExpMatch = string_ops.RegExpMatch;
const SimpleCaptureSequenceAtom = regexp_fastpath.SimpleCaptureSequenceAtom;
const SimpleClassPredicate = regexp_fastpath.SimpleClassPredicate;
const SimpleNumericArg0Bytecode = call_runtime.SimpleNumericArg0Bytecode;
const WorkerMessage = call_runtime.WorkerMessage;
const WorkerPostTarget = call_runtime.WorkerPostTarget;
const appendAtom = utils.appendAtom;
const atomIdOrNameEql = call_runtime.atomIdOrNameEql;
const atomListContains = utils.atomListContains;
const atomicsBufferObject = object_ops.atomicsBufferObject;
const backtraceFunctionNameEql = error_stack_ops.backtraceFunctionNameEql;
const cacheIteratorNextMethod = call_runtime.cacheIteratorNextMethod;
const callCollectionAdderFromVm = builtin_glue.callCollectionAdderFromVm;
const callValueOrBytecode = call_runtime.callValueOrBytecode;
const callableObjectFromValue = object_ops.callableObjectFromValue;
const catchTargetFromMarker = utils.catchTargetFromMarker;
const constructValueOrBytecode = call_runtime.constructValueOrBytecode;
const constructorPrototypeFromGlobal = object_ops.constructorPrototypeFromGlobal;
const constructorPrototypeFromGlobalAtom = object_ops.constructorPrototypeFromGlobalAtom;
const constructorPrototypeObject = object_ops.constructorPrototypeObject;
const createBytecodeFunctionObject = object_ops.createBytecodeFunctionObject;
const createCallSiteObject = object_ops.createCallSiteObject;
const createDataPropertyOrThrow = object_ops.createDataPropertyOrThrow;
const createIteratorResult = call_runtime.createIteratorResult;
const createRegExpIndexPair = regexp_fastpath.createRegExpIndexPair;
const defineNativeDataMethod = builtin_glue.defineNativeDataMethod;
const defineRegExpIndicesGroupsProperty = object_ops.defineRegExpIndicesGroupsProperty;
const defineSplitValueElement = string_ops.defineSplitValueElement;
const defineValueProperty = object_ops.defineValueProperty;
const deleteValuePropertyOrThrow = object_ops.deleteValuePropertyOrThrow;
const errorStackTraceLimit = error_stack_ops.errorStackTraceLimit;
const findPropertyDescriptor = object_ops.findPropertyDescriptor;
const functionBytecodeFromValue = call_runtime.functionBytecodeFromValue;
const functionObjectFromValue = object_ops.functionObjectFromValue;
const getIteratorMethod = call_runtime.getIteratorMethod;
const getStringPrototypeMethodId = string_ops.getStringPrototypeMethodId;
const getValueProperty = object_ops.getValueProperty;
const globalHostOutputAutoInit = builtin_glue.globalHostOutputAutoInit;
const hasValueProperty = object_ops.hasValueProperty;
const isBuiltinConstructorName = call_runtime.isBuiltinConstructorName;
const isCallableValue = call_runtime.isCallableValue;
const isConstructorLike = call_runtime.isConstructorLike;
const isDirectIteratorClass = call_runtime.isDirectIteratorClass;
const isIteratorLikeValue = forof_ops.isIteratorLikeValue;
const objectFromValue = object_ops.objectFromValue;
const objectPrototypeFromGlobal = object_ops.objectPrototypeFromGlobal;
const objectRealmGlobal = object_ops.objectRealmGlobal;
const primitiveObjectForAccess = object_ops.primitiveObjectForAccess;
const printHostOutputArgs = builtin_glue.printHostOutputArgs;
const propertyAtomFromLengthIndex = object_ops.propertyAtomFromLengthIndex;
const propertyIndexFromLengthKey = object_ops.propertyIndexFromLengthKey;
const proxyDefineValueForReflectSet = object_ops.proxyDefineValueForReflectSet;
const qjsArrayConcatCall = string_ops.qjsArrayConcatCall;
const qjsArraySearchCall = string_ops.qjsArraySearchCall;
const qjsArrayToLocaleStringCall = string_ops.qjsArrayToLocaleStringCall;
const qjsArrayToStringCall = string_ops.qjsArrayToStringCall;
const qjsCollectIteratorValues = call_runtime.qjsCollectIteratorValues;
const qjsGeneratorNext = call_runtime.qjsGeneratorNext;
const qjsIteratorCallForNativeRecord = call_runtime.qjsIteratorCallForNativeRecord;
const qjsIteratorClose = call_runtime.qjsIteratorClose;
const qjsIteratorPrototype = object_ops.qjsIteratorPrototype;
const qjsObjectEnumerableOwnPropertiesCall = object_ops.qjsObjectEnumerableOwnPropertiesCall;
const qjsWorkerByIdLocked = call_runtime.qjsWorkerByIdLocked;
const qjsWorkerIo = call_runtime.qjsWorkerIo;
const readInt = call_runtime.readInt;
const sameObjectIdentity = object_ops.sameObjectIdentity;
const setValueProperty = object_ops.setValueProperty;
const simpleClassPredicateMatches = string_ops.simpleClassPredicateMatches;
const simpleNumericArg0Callback = call_runtime.simpleNumericArg0Callback;
const simpleNumericBinary = call_runtime.simpleNumericBinary;
const slotValueBorrow = slot_ops.slotValueBorrow;
const stringSliceValue = string_ops.stringSliceValue;
const workerPageAllocator = call_runtime.workerPageAllocator;
const throwTypeErrorMessage = call_runtime.throwTypeErrorMessage;
const toLengthIndex = coercion_ops.toLengthIndex;
const toNumberForDateMethod = coercion_ops.toNumberForDateMethod;
const toPrimitiveForNumber = coercion_ops.toPrimitiveForNumber;
const toStringForAnnexB = string_ops.toStringForAnnexB;
const uint8ArrayStringBytes = string_ops.uint8ArrayStringBytes;
const valueTruthy = coercion_ops.valueTruthy;
const valuesStrictEqual = value_ops.valuesStrictEqual;

pub fn popCatchMarker(rt: *core.JSRuntime, stack: *stack_mod.Stack) !??usize {
    while (stack.peek()) |marker| {
        defer marker.free(rt);
        if (marker.isCatchOffset() and stack.values.len >= 3) {
            const maybe_next = stack.values[stack.values.len - 2];
            const maybe_iterator = stack.values[stack.values.len - 3];
            if (isCallableValue(maybe_next) and isIteratorLikeValue(rt, maybe_iterator)) {
                const record_marker = try stack.pop();
                record_marker.free(rt);
                const next_method = try stack.pop();
                next_method.free(rt);
                const iterator_value = try stack.pop();
                iterator_value.free(rt);
                continue;
            }
        }
        const popped = try stack.pop();
        if (marker.isCatchOffset()) return catchTargetFromMarker(popped);
        popped.free(rt);
    }
    return null;
}

pub fn arrayPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object {
    if (global.cachedRealmValue(.array_prototype)) |stored| {
        return property_ops.expectObject(stored) catch null;
    }
    if (global.getOwnDataObjectBorrowed(core.atom.ids.Array)) |constructor| {
        if (constructor.getOwnDataObjectBorrowed(core.atom.ids.prototype)) |prototype| return prototype;
    }
    const array_value = global.getProperty(core.atom.ids.Array);
    defer array_value.free(rt);
    const array_constructor = property_ops.expectObject(array_value) catch return null;
    if (array_constructor.getOwnDataObjectBorrowed(core.atom.ids.prototype)) |prototype| return prototype;
    const prototype_value = array_constructor.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    return property_ops.expectObject(prototype_value) catch null;
}

pub fn arrayIteratorPrototypeFromContext(ctx: *core.JSContext, global: *core.Object) !*core.Object {
    return iter_vm.arrayIteratorPrototypeFromContext(ctx, global);
}

pub fn isArrayMethodReceiver(value: core.JSValue) bool {
    const object = objectFromValue(value) orelse return false;
    return object.flags.is_array;
}

pub fn pushSlotValue(stack: *stack_mod.Stack, slot: core.JSValue) !void {
    if (!slot.requiresRefCount()) return stack.pushOwned(slot);
    try stack.push(slotValueBorrow(slot));
}

pub fn pushFunctionClosure(
    ctx: *core.JSContext,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    index: usize,
    opc: u8,
    eval_local_names: []const core.Atom,
    eval_local_slots: []core.JSValue,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
) !void {
    const value = function.constants.get(index) orelse return error.InvalidBytecode;
    defer value.free(ctx.runtime);
    const object_value = try createBytecodeFunctionObject(ctx, frame, function, global, value, function.name, opc, true, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, stack.values);
    defer object_value.free(ctx.runtime);
    try stack.push(object_value);
}

pub fn qjsArrayMethodFastCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (callableObjectFromValue(func)) |function_object| {
        if (core.function.decodeNativeBuiltinId(function_object.nativeFunctionIdSlot().*)) |native_ref| {
            if (native_ref.domain == .iterator) {
                if (try qjsIteratorCallForNativeRecord(ctx, output, global, receiver, native_ref.id, args, caller_function, caller_frame)) |value| return value;
            }
        }
    }
    if (try qjsArrayIterationCall(ctx, output, global, receiver, func, args, caller_function, caller_frame)) |value| return value;
    if (try qjsArrayAtCall(ctx, output, global, receiver, func, args)) |value| return value;
    if (try qjsArrayReduceCall(ctx, output, global, receiver, func, args, false)) |value| return value;
    if (try qjsArrayReduceCall(ctx, output, global, receiver, func, args, true)) |value| return value;
    if (try qjsArraySearchCall(ctx, output, global, receiver, func, args)) |value| return value;
    if (try qjsArrayCopyWithinCall(ctx, output, global, receiver, func, args)) |value| return value;
    if (try qjsArrayFillCall(ctx, output, global, receiver, func, args)) |value| return value;
    if (try qjsArrayPushCall(ctx, output, global, receiver, func, args, caller_function, caller_frame)) |value| return value;
    if (try qjsArrayPopCall(ctx, output, global, receiver, func, caller_function, caller_frame)) |value| return value;
    if (try qjsArrayShiftCall(ctx, output, global, receiver, func)) |value| return value;
    if (try qjsArrayUnshiftCall(ctx, output, global, receiver, func, args)) |value| return value;
    if (try qjsArrayReverseCall(ctx, output, global, receiver, func, caller_function, caller_frame)) |value| return value;
    if (try qjsArraySpliceCall(ctx, output, global, receiver, func, args)) |value| return value;
    if (try qjsTypedArraySliceSubarrayCall(ctx, output, global, receiver, func, args)) |value| return value;
    if (try qjsArraySliceCall(ctx, output, global, receiver, func, args)) |value| return value;
    if (try qjsArrayMapCall(ctx, output, global, receiver, func, args)) |value| return value;
    if (try qjsArrayFlatCall(ctx, output, global, receiver, func, args, caller_function, caller_frame)) |value| return value;
    if (try qjsArraySortCall(ctx, output, global, receiver, func, args, caller_function, caller_frame)) |value| return value;
    if (try qjsArrayByCopyCall(ctx, output, global, receiver, func, args, caller_function, caller_frame)) |value| return value;
    if (try qjsArrayConcatCall(ctx, output, global, receiver, func, args, caller_function, caller_frame)) |value| return value;
    return null;
}

pub fn qjsArrayPreparedNativeCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    return switch (method_id) {
        @intFromEnum(builtins.array.PrototypeMethod.push) => qjsArrayPushCallImpl(ctx, output, global, receiver, args, caller_function, caller_frame),
        @intFromEnum(builtins.array.PrototypeMethod.pop) => qjsArrayPopCallImpl(ctx, output, global, receiver, caller_function, caller_frame),
        else => null,
    };
}

pub fn qjsArrayPrototypeNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const array_mod = builtins.array;
    return switch (id) {
        @intFromEnum(array_mod.PrototypeMethod.to_string) => qjsArrayToStringCall(ctx, output, global, receiver, function_object, caller_function, caller_frame),
        @intFromEnum(array_mod.PrototypeMethod.to_locale_string) => qjsArrayToLocaleStringCall(ctx, output, global, receiver, function_object, caller_function, caller_frame),
        @intFromEnum(array_mod.PrototypeMethod.map),
        @intFromEnum(array_mod.PrototypeMethod.filter),
        @intFromEnum(array_mod.PrototypeMethod.for_each),
        @intFromEnum(array_mod.PrototypeMethod.some),
        @intFromEnum(array_mod.PrototypeMethod.every),
        @intFromEnum(array_mod.PrototypeMethod.find),
        @intFromEnum(array_mod.PrototypeMethod.find_index),
        @intFromEnum(array_mod.PrototypeMethod.find_last),
        @intFromEnum(array_mod.PrototypeMethod.find_last_index),
        => qjsArrayIterationCall(ctx, output, global, receiver, function_object.value(), args, caller_function, caller_frame),
        @intFromEnum(array_mod.PrototypeMethod.reduce) => qjsArrayReduceCall(ctx, output, global, receiver, function_object.value(), args, false),
        @intFromEnum(array_mod.PrototypeMethod.reduce_right) => qjsArrayReduceCall(ctx, output, global, receiver, function_object.value(), args, true),
        @intFromEnum(array_mod.PrototypeMethod.at) => qjsArrayAtCall(ctx, output, global, receiver, function_object.value(), args),
        @intFromEnum(array_mod.PrototypeMethod.includes),
        @intFromEnum(array_mod.PrototypeMethod.index_of),
        @intFromEnum(array_mod.PrototypeMethod.last_index_of),
        => qjsArraySearchCall(ctx, output, global, receiver, function_object.value(), args),
        @intFromEnum(array_mod.PrototypeMethod.copy_within) => qjsArrayCopyWithinCall(ctx, output, global, receiver, function_object.value(), args),
        @intFromEnum(array_mod.PrototypeMethod.fill) => qjsArrayFillCall(ctx, output, global, receiver, function_object.value(), args),
        @intFromEnum(array_mod.PrototypeMethod.push) => qjsArrayPushCall(ctx, output, global, receiver, function_object.value(), args, caller_function, caller_frame),
        @intFromEnum(array_mod.PrototypeMethod.pop) => qjsArrayPopCall(ctx, output, global, receiver, function_object.value(), caller_function, caller_frame),
        @intFromEnum(array_mod.PrototypeMethod.shift) => qjsArrayShiftCall(ctx, output, global, receiver, function_object.value()),
        @intFromEnum(array_mod.PrototypeMethod.unshift) => qjsArrayUnshiftCall(ctx, output, global, receiver, function_object.value(), args),
        @intFromEnum(array_mod.PrototypeMethod.reverse) => qjsArrayReverseCall(ctx, output, global, receiver, function_object.value(), caller_function, caller_frame),
        @intFromEnum(array_mod.PrototypeMethod.splice) => qjsArraySpliceCall(ctx, output, global, receiver, function_object.value(), args),
        @intFromEnum(array_mod.PrototypeMethod.slice) => qjsArraySliceCall(ctx, output, global, receiver, function_object.value(), args),
        @intFromEnum(array_mod.PrototypeMethod.join) => qjsArrayJoinCall(ctx, output, global, receiver, function_object, args, caller_function, caller_frame),
        @intFromEnum(array_mod.PrototypeMethod.concat) => qjsArrayConcatCall(ctx, output, global, receiver, function_object.value(), args, caller_function, caller_frame),
        @intFromEnum(array_mod.PrototypeMethod.sort) => qjsArraySortCall(ctx, output, global, receiver, function_object.value(), args, caller_function, caller_frame),
        @intFromEnum(array_mod.PrototypeMethod.flat),
        @intFromEnum(array_mod.PrototypeMethod.flat_map),
        => qjsArrayFlatCall(ctx, output, global, receiver, function_object.value(), args, caller_function, caller_frame),
        @intFromEnum(array_mod.PrototypeMethod.to_reversed),
        @intFromEnum(array_mod.PrototypeMethod.to_sorted),
        @intFromEnum(array_mod.PrototypeMethod.to_spliced),
        @intFromEnum(array_mod.PrototypeMethod.with_),
        => qjsArrayByCopyCall(ctx, output, global, receiver, function_object.value(), args, caller_function, caller_frame),
        @intFromEnum(array_mod.PrototypeMethod.keys),
        @intFromEnum(array_mod.PrototypeMethod.values),
        @intFromEnum(array_mod.PrototypeMethod.entries),
        => qjsArrayIteratorMethodRecord(ctx, global, receiver, function_object, id),
        else => null,
    };
}

pub fn buildCallSiteArray(ctx: *core.JSContext, global: *core.Object, skip_name: ?[]const u8) !core.JSValue {
    const array = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
    errdefer core.Object.destroyFromHeader(ctx.runtime, &array.header);
    const limit = errorStackTraceLimit(ctx.runtime, global);
    var idx = ctx.backtrace_frames.len;
    var emitted: usize = 0;
    var skipping = skip_name != null;
    while (idx > 0) {
        idx -= 1;
        _ = exception_ops.resolvedBacktraceFunctionNameAt(ctx, idx);
        if (skipping) {
            if (backtraceFunctionNameEql(ctx, ctx.backtrace_frames[idx], skip_name.?)) skipping = false;
            continue;
        }
        if (emitted >= limit) break;
        const site = try createCallSiteObject(ctx, global, ctx.backtrace_frames[idx]);
        defer site.free(ctx.runtime);
        try array.defineOwnProperty(ctx.runtime, core.atom.atomFromUInt32(@intCast(emitted)), core.Descriptor.data(site, true, true, true));
        emitted += 1;
    }
    array.length = @intCast(emitted);
    try array.defineOwnProperty(ctx.runtime, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(@intCast(emitted)), true, false, false));
    return array.value();
}

pub fn aggregateErrorsIterableToArray(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterable: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !*core.Object {
    var rooted_iterable = iterable;
    var iterator_method = core.JSValue.undefinedValue();
    var iterator_value = core.JSValue.undefinedValue();
    var next_method = core.JSValue.undefinedValue();
    var out_value = core.JSValue.undefinedValue();
    var next_result_value = core.JSValue.undefinedValue();
    var done = core.JSValue.undefinedValue();
    var item = core.JSValue.undefinedValue();

    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_iterable },
        .{ .value = &iterator_method },
        .{ .value = &iterator_value },
        .{ .value = &next_method },
        .{ .value = &out_value },
        .{ .value = &next_result_value },
        .{ .value = &done },
        .{ .value = &item },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    defer iterator_method.free(ctx.runtime);
    defer iterator_value.free(ctx.runtime);
    defer next_method.free(ctx.runtime);
    errdefer out_value.free(ctx.runtime);
    defer next_result_value.free(ctx.runtime);
    defer done.free(ctx.runtime);
    defer item.free(ctx.runtime);

    iterator_method = try getIteratorMethod(ctx, output, global, rooted_iterable);
    if (iterator_method.isUndefined() or iterator_method.isNull() or !isCallableValue(iterator_method)) return error.TypeError;

    iterator_value = try callValueOrBytecode(ctx, output, global, rooted_iterable, iterator_method, &.{}, caller_function, caller_frame);
    const iterator = objectFromValue(iterator_value) orelse return error.TypeError;

    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    next_method = try getValueProperty(ctx, output, global, iterator.value(), next_key, caller_function, caller_frame);
    if (!isCallableValue(next_method)) return error.TypeError;

    const done_key = core.atom.predefinedId("done", .string) orelse return error.TypeError;
    const value_key = core.atom.predefinedId("value", .string) orelse return error.TypeError;
    const out = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
    out_value = out.value();

    var index: u32 = 0;
    while (true) : (index += 1) {
        next_result_value.free(ctx.runtime);
        next_result_value = core.JSValue.undefinedValue();
        done.free(ctx.runtime);
        done = core.JSValue.undefinedValue();
        item.free(ctx.runtime);
        item = core.JSValue.undefinedValue();

        next_result_value = try callValueOrBytecode(ctx, output, global, iterator.value(), next_method, &.{}, caller_function, caller_frame);
        const next_result = objectFromValue(next_result_value) orelse return error.TypeError;
        done = try getValueProperty(ctx, output, global, next_result.value(), done_key, caller_function, caller_frame);
        if (valueTruthy(done)) break;
        item = try getValueProperty(ctx, output, global, next_result.value(), value_key, caller_function, caller_frame);
        try out.defineOwnProperty(ctx.runtime, core.atom.atomFromUInt32(index), core.Descriptor.data(item, true, true, true));
    }
    out.length = index;
    try out.defineOwnProperty(ctx.runtime, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(@intCast(index)), true, false, false));
    return out;
}

pub const RegExpLegacyNoCaptureSlice = enum {
    match,
    left,
    right,
};

pub fn regExpLegacyNoCaptureSliceValue(rt: *core.JSRuntime, legacy: anytype, kind: RegExpLegacyNoCaptureSlice) ?core.JSValue {
    if (!legacy.lazy_no_capture_match) return null;
    const input = legacy.input orelse return null;
    return switch (kind) {
        .match => stringSliceValue(rt, input, legacy.lazy_match_index, legacy.lazy_match_len) catch null,
        .left => if (legacy.lazy_match_index == 0)
            value_ops.createStringValue(rt, "") catch null
        else
            stringSliceValue(rt, input, 0, legacy.lazy_match_index) catch null,
        .right => blk: {
            const right_start = @min(legacy.lazy_match_index + legacy.lazy_match_len, legacy.lazy_input_len);
            if (right_start >= legacy.lazy_input_len) break :blk value_ops.createStringValue(rt, "") catch null;
            break :blk stringSliceValue(rt, input, right_start, legacy.lazy_input_len - right_start) catch null;
        },
    };
}

pub fn throwRegExpAccessorTypeError(ctx: *core.JSContext, global: *core.Object, getter_value: core.JSValue) !?core.JSValue {
    const error_value = if (objectFromValue(getter_value)) |getter_object| blk: {
        const ctor_value = getter_object.functionRealmTypeErrorConstructor() orelse break :blk try createNamedError(ctx.runtime, global, "TypeError", "not a Date object");
        break :blk try createNamedErrorWithConstructor(ctx.runtime, ctor_value, "TypeError", "not a Date object");
    } else try createNamedError(ctx.runtime, global, "TypeError", "not a Date object");
    _ = ctx.throwValue(error_value);
    return error.JSException;
}

pub fn simpleCaptureAtomsKnownDisjoint(first: SimpleCaptureSequenceAtom, second: SimpleCaptureSequenceAtom) bool {
    if (first.kind == .literal and second.kind == .literal) return first.literal != second.literal;
    if (first.kind == .literal and second.kind == .class) return !simpleClassPredicateMatches(second.class_predicate, second.class_source, first.literal);
    if (first.kind == .class and second.kind == .literal) return !simpleClassPredicateMatches(first.class_predicate, first.class_source, second.literal);
    if (first.kind != .class or second.kind != .class) return false;
    return simpleClassPredicatesKnownDisjoint(first.class_predicate, second.class_predicate);
}

pub fn simpleClassPredicatesKnownDisjoint(first: SimpleClassPredicate, second: SimpleClassPredicate) bool {
    return switch (first) {
        .ascii_digit, .ascii_decimal => switch (second) {
            .ascii_not_digit => true,
            .ascii_lower, .ascii_alpha => true,
            else => false,
        },
        .ascii_not_digit => switch (second) {
            .ascii_digit, .ascii_decimal => true,
            else => false,
        },
        .ascii_lower => switch (second) {
            .ascii_digit, .ascii_decimal => true,
            else => false,
        },
        .ascii_alpha => switch (second) {
            .ascii_digit, .ascii_decimal => true,
            else => false,
        },
        else => false,
    };
}

pub fn createRegExpIndicesArray(rt: *core.JSRuntime, global: *core.Object, input_bytes: []const u8, found: RegExpMatch) !core.JSValue {
    const out = try core.Object.createArray(rt, arrayPrototypeFromGlobal(rt, global));
    errdefer core.Object.destroyFromHeader(rt, &out.header);

    const full = try createRegExpIndexPair(rt, global, found.index, found.index + found.len);
    defer full.free(rt);
    try defineSplitValueElement(rt, out, 0, full);

    var capture_index: usize = 0;
    while (capture_index < found.capture_count) : (capture_index += 1) {
        const capture = found.captures[capture_index];
        if (capture.undefined) {
            try defineSplitValueElement(rt, out, @intCast(capture_index + 1), core.JSValue.undefinedValue());
        } else {
            const pair = try createRegExpIndexPair(rt, global, capture.start, capture.start + capture.len);
            defer pair.free(rt);
            try defineSplitValueElement(rt, out, @intCast(capture_index + 1), pair);
        }
    }

    try defineRegExpIndicesGroupsProperty(rt, global, out, found);
    _ = input_bytes;
    return out.value();
}

pub fn constructArrayBufferNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    func: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    new_target: core.JSValue,
) !?core.JSValue {
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionIdSlot().*) orelse return null;
    if (native_ref.domain != .buffer) return null;
    const shared = switch (native_ref.id) {
        @intFromEnum(builtins.buffer.ConstructorMethod.array_buffer) => false,
        @intFromEnum(builtins.buffer.ConstructorMethod.shared_array_buffer) => true,
        else => return null,
    };
    if (!builtins.object.sameValue(new_target, func)) return null;

    const prototype = try constructorPrototypeObject(ctx.runtime, new_target);
    if (args.len == 0) {
        if (shared) return try builtins.buffer.sharedArrayBufferConstructLength(ctx.runtime, 0, null, prototype);
        return try builtins.buffer.arrayBufferConstructLength(ctx.runtime, 0, null, prototype);
    }
    if (args.len == 1) {
        if (args[0].asInt32()) |length_i32| {
            if (length_i32 >= 0) {
                const byte_length: usize = @intCast(length_i32);
                if (shared) return try builtins.buffer.sharedArrayBufferConstructLength(ctx.runtime, byte_length, null, prototype);
                return try builtins.buffer.arrayBufferConstructLength(ctx.runtime, byte_length, null, prototype);
            }
        }
    }
    return try qjsArrayBufferConstructWithPrototype(ctx, output, global, args, prototype, shared);
}

pub fn tryFuseTypedArrayFromArrayBufferConstructorSequence(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    array_buffer_constructor: core.JSValue,
    array_buffer_new_target: core.JSValue,
    args: []const core.JSValue,
) !?core.JSValue {
    if (args.len != 1) return null;
    if (!builtins.object.sameValue(array_buffer_constructor, array_buffer_new_target)) return null;
    if (frame.pc + 3 > function.code.len) return null;
    if (function.code[frame.pc] != op.call_constructor) return null;
    if (readInt(u16, function.code[frame.pc + 1 ..][0..2]) != 1) return null;
    if (stack.values.len < 2) return null;

    const outer_constructor = stack.values[stack.values.len - 2];
    const outer_new_target = stack.values[stack.values.len - 1];
    if (!builtins.object.sameValue(outer_constructor, outer_new_target)) return null;

    const buffer_constructor_object = callableObjectFromValue(array_buffer_constructor) orelse return null;
    const native_ref = core.function.decodeNativeBuiltinId(buffer_constructor_object.nativeFunctionIdSlot().*) orelse return null;
    if (native_ref.domain != .buffer) return null;
    const shared = switch (native_ref.id) {
        @intFromEnum(builtins.buffer.ConstructorMethod.array_buffer) => false,
        @intFromEnum(builtins.buffer.ConstructorMethod.shared_array_buffer) => true,
        else => return null,
    };

    const typed_array_constructor_object = callableObjectFromValue(outer_constructor) orelse return null;
    const element_size_u32 = typed_array_constructor_object.typedArrayElementSize();
    const element_kind = typed_array_constructor_object.typedArrayKind();
    if (element_size_u32 == 0 or element_kind == 0) return null;

    const byte_length_i32 = args[0].asInt32() orelse return null;
    if (byte_length_i32 < 0) return null;
    const byte_length: usize = @intCast(byte_length_i32);
    const element_size: usize = @intCast(element_size_u32);
    if (byte_length % element_size != 0) return null;
    const typed_length = @divExact(byte_length, element_size);
    if (typed_length > @as(usize, @intCast(std.math.maxInt(u32)))) return null;

    const buffer_prototype = buffer_constructor_object.getOwnDataObjectBorrowed(core.atom.ids.prototype) orelse return null;
    const typed_array_prototype = typed_array_constructor_object.getOwnDataObjectBorrowed(core.atom.ids.prototype) orelse return null;

    const backing_buffer = if (shared)
        try builtins.buffer.sharedArrayBufferConstructLength(ctx.runtime, byte_length, null, buffer_prototype)
    else
        try builtins.buffer.arrayBufferConstructLength(ctx.runtime, byte_length, null, buffer_prototype);
    var backing_buffer_owned = true;
    errdefer if (backing_buffer_owned) backing_buffer.free(ctx.runtime);
    const backing_buffer_object = objectFromValue(backing_buffer) orelse return error.TypeError;
    backing_buffer_owned = false;
    const result = try builtins.buffer.typedArrayConstructFullBufferOwned(ctx.runtime, element_size_u32, element_kind, backing_buffer, backing_buffer_object, typed_array_prototype);
    errdefer result.free(ctx.runtime);

    const dropped_new_target = try stack.pop();
    const dropped_constructor = try stack.pop();
    frame.pc += 3;
    dropped_new_target.free(ctx.runtime);
    dropped_constructor.free(ctx.runtime);
    return result;
}

pub const TypedArrayLengthPrintStore = struct {
    local_index: u16,
    next_pc: usize,
};

pub fn decodeTypedArrayLengthPrintStore(code: []const u8, pc: usize) ?TypedArrayLengthPrintStore {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.put_loc0 => .{ .local_index = 0, .next_pc = pc + 1 },
        op.put_loc1 => .{ .local_index = 1, .next_pc = pc + 1 },
        op.put_loc2 => .{ .local_index = 2, .next_pc = pc + 1 },
        op.put_loc3 => .{ .local_index = 3, .next_pc = pc + 1 },
        op.put_loc, op.put_loc_check, op.put_loc_check_init => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{ .local_index = readInt(u16, code[pc + 1 ..][0..2]), .next_pc = pc + 3 };
        },
        op.put_loc8 => blk: {
            if (pc + 2 > code.len) return null;
            break :blk .{ .local_index = code[pc + 1], .next_pc = pc + 2 };
        },
        else => null,
    };
}

pub const TypedArrayLengthPrintLocalGet = struct {
    idx: u16,
    next_pc: usize,
};

pub fn decodeTypedArrayLengthPrintLocalGet(code: []const u8, pc: usize) ?TypedArrayLengthPrintLocalGet {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.get_loc0 => .{ .idx = 0, .next_pc = pc + 1 },
        op.get_loc1 => .{ .idx = 1, .next_pc = pc + 1 },
        op.get_loc2 => .{ .idx = 2, .next_pc = pc + 1 },
        op.get_loc3 => .{ .idx = 3, .next_pc = pc + 1 },
        op.get_loc, op.get_loc_check => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{ .idx = readInt(u16, code[pc + 1 ..][0..2]), .next_pc = pc + 3 };
        },
        op.get_loc8 => blk: {
            if (pc + 2 > code.len) return null;
            break :blk .{ .idx = code[pc + 1], .next_pc = pc + 2 };
        },
        else => null,
    };
}

pub fn qjsTypedArrayConstructVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const kind = function_object.typedArrayKind();
    const element = construct_mod.TypedArrayElement{
        .size = function_object.typedArrayElementSize(),
        .kind = kind,
    };
    const constructor_global = objectRealmGlobal(function_object) orelse global;

    if (args.len < 1) {
        const prototype = try qjsTypedArrayConstructorPrototypeVm(ctx, output, global, constructor, function_object, caller_function, caller_frame);
        return try qjsTypedArrayConstructLengthVm(ctx.runtime, constructor_global, prototype, element, 0);
    }

    const first = args[0];
    if (!first.isObject()) {
        const length = try qjsTypedArrayConstructToIndex(ctx, output, global, first);
        const prototype = try qjsTypedArrayConstructorPrototypeVm(ctx, output, global, constructor, function_object, caller_function, caller_frame);
        return try qjsTypedArrayConstructLengthVm(ctx.runtime, constructor_global, prototype, element, length);
    }

    const source_object = objectFromValue(first) orelse return error.TypeError;
    if (builtins.buffer.isTypedArrayObject(source_object)) return null;
    if (source_object.class_id == core.class.ids.array_buffer or source_object.class_id == core.class.ids.shared_array_buffer) {
        const prototype = try qjsTypedArrayConstructorPrototypeVm(ctx, output, global, constructor, function_object, caller_function, caller_frame);
        if (args.len == 1) {
            return try builtins.buffer.typedArrayConstructWithOptions(ctx.runtime, element.size, element.kind, first, args, prototype);
        }
        return try qjsTypedArrayConstructBufferVm(ctx, output, global, prototype, element, args);
    }
    if (try qjsTypedArrayConstructFromIterable(ctx, output, global, constructor, args, caller_function, caller_frame)) |value| {
        return value;
    }
    const prototype = try qjsTypedArrayConstructorPrototypeVm(ctx, output, global, constructor, function_object, caller_function, caller_frame);
    return try qjsTypedArrayConstructArrayLikeVm(ctx, output, global, constructor_global, prototype, element, first, caller_function, caller_frame);
}

pub fn qjsTypedArrayConstructLengthVm(
    rt: *core.JSRuntime,
    constructor_global: *core.Object,
    prototype: ?*core.Object,
    element: construct_mod.TypedArrayElement,
    length: usize,
) !core.JSValue {
    if (length > @as(usize, @intCast(std.math.maxInt(u32)))) return error.RangeError;
    const byte_length = try std.math.mul(usize, length, element.size);
    const buffer_proto = qjsTypedArrayArrayBufferPrototypeVm(rt, constructor_global, prototype);
    const backing_buffer = try builtins.buffer.arrayBufferConstructLength(rt, byte_length, null, buffer_proto);
    var backing_buffer_owned = true;
    errdefer if (backing_buffer_owned) backing_buffer.free(rt);
    const backing_buffer_object = objectFromValue(backing_buffer) orelse return error.TypeError;
    backing_buffer_owned = false;
    return builtins.buffer.typedArrayConstructFullBufferOwned(rt, element.size, element.kind, backing_buffer, backing_buffer_object, prototype);
}

pub fn qjsTypedArrayConstructBufferVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    prototype: ?*core.Object,
    element: construct_mod.TypedArrayElement,
    args: []const core.JSValue,
) !core.JSValue {
    const byte_offset = if (args.len >= 2 and !args[1].isUndefined())
        try qjsTypedArrayConstructToIndex(ctx, output, global, args[1])
    else
        @as(usize, 0);
    const has_length = args.len >= 3 and !args[2].isUndefined();
    const requested_length = if (has_length)
        try qjsTypedArrayConstructToIndex(ctx, output, global, args[2])
    else
        @as(usize, 0);

    const offset_value = if (args.len >= 2 and !args[1].isUndefined()) lengthIndexValue(byte_offset) else core.JSValue.undefinedValue();
    const length_value = if (has_length) lengthIndexValue(requested_length) else core.JSValue.undefinedValue();
    const construct_args = [_]core.JSValue{ args[0], offset_value, length_value };
    const used_args = if (has_length)
        construct_args[0..3]
    else if (!offset_value.isUndefined())
        construct_args[0..2]
    else
        construct_args[0..1];
    return builtins.buffer.typedArrayConstructWithOptions(ctx.runtime, element.size, element.kind, args[0], used_args, prototype);
}

pub fn qjsTypedArrayConstructArrayLikeVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_global: *core.Object,
    prototype: ?*core.Object,
    element: construct_mod.TypedArrayElement,
    source_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var result_value = core.JSValue.undefinedValue();
    var item = core.JSValue.undefinedValue();
    var coerced = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &result_value },
        .{ .value = &item },
        .{ .value = &coerced },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    defer result_value.free(ctx.runtime);
    defer item.free(ctx.runtime);
    defer coerced.free(ctx.runtime);

    const length_value = try getValueProperty(ctx, output, global, source_value, core.atom.ids.length, caller_function, caller_frame);
    defer length_value.free(ctx.runtime);
    const length = try toLengthIndex(ctx, output, global, length_value);

    result_value = try qjsTypedArrayConstructLengthVm(ctx.runtime, constructor_global, prototype, element, length);
    const result_object = objectFromValue(result_value) orelse return error.TypeError;
    if (objectFromValue(source_value)) |source_object| {
        if (try qjsTypedArrayConstructArrayLikeOwnDataFast(ctx, output, global, result_object, source_object, length)) {
            return result_value.dup();
        }
    }

    var index: usize = 0;
    while (index < length) : (index += 1) {
        const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
        defer key.deinit(ctx.runtime);

        item.free(ctx.runtime);
        item = try getValueProperty(ctx, output, global, source_value, key.atom, caller_function, caller_frame);

        coerced.free(ctx.runtime);
        coerced = try qjsTypedArrayByCopyCoerceValue(ctx, output, global, result_object, item);

        _ = try builtins.buffer.typedArraySetIndex(ctx.runtime, result_object, @intCast(index), coerced);

        coerced.free(ctx.runtime);
        coerced = core.JSValue.undefinedValue();
        item.free(ctx.runtime);
        item = core.JSValue.undefinedValue();
    }
    return result_value.dup();
}

pub fn qjsTypedArrayConstructArrayLikeOwnDataFast(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    result_object: *core.Object,
    source_object: *core.Object,
    length: usize,
) !bool {
    if (source_object.proxyTarget() != null or source_object.exotic != null) return false;
    if (length > @as(usize, @intCast(std.math.maxInt(u32)))) return false;

    var first_index_property: ?usize = null;
    for (source_object.shapeProps(), 0..) |prop, property_index| {
        const prop_flags = core.property.Flags.fromBits(prop.flags);
        if (prop_flags.deleted or prop_flags.accessor) continue;
        if (prop.atom_id == core.atom.atomFromUInt32(0)) {
            first_index_property = property_index;
            break;
        }
    }
    const first_property = first_index_property orelse return length == 0;
    if (!typedArrayArrayLikeOwnDataFastPathUsable(source_object, first_property, length)) return false;

    var item = core.JSValue.undefinedValue();
    var coerced = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &item },
        .{ .value = &coerced },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;
    defer item.free(ctx.runtime);
    defer coerced.free(ctx.runtime);

    var index: usize = 0;
    while (index < length) : (index += 1) {
        const atom_id = core.atom.atomFromUInt32(@intCast(index));
        item.free(ctx.runtime);
        item = source_object.getOwnDataPropertyValueAt(first_property + index, atom_id) orelse return false;

        coerced.free(ctx.runtime);
        coerced = try qjsTypedArrayByCopyCoerceValue(ctx, output, global, result_object, item);
        _ = try builtins.buffer.typedArraySetIndex(ctx.runtime, result_object, @intCast(index), coerced);

        coerced.free(ctx.runtime);
        coerced = core.JSValue.undefinedValue();
        item.free(ctx.runtime);
        item = core.JSValue.undefinedValue();
    }
    return true;
}

pub fn typedArrayArrayLikeOwnDataFastPathUsable(source_object: *core.Object, first_property: usize, length: usize) bool {
    var index: usize = 0;
    while (index < length) : (index += 1) {
        const property_index = first_property + index;
        if (property_index >= source_object.shapeProps().len) return false;
        const prop = source_object.shapeProps()[property_index];
        const prop_flags = core.property.Flags.fromBits(prop.flags);
        if (prop.atom_id != core.atom.atomFromUInt32(@intCast(index)) or prop_flags.deleted or prop_flags.accessor) return false;
        switch (source_object.properties[property_index].slot) {
            .data => |stored| if (stored.isObject()) return false,
            .auto_init, .accessor, .deleted => return false,
        }
    }
    return true;
}

pub fn qjsTypedArrayConstructorPrototypeVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: core.JSValue,
    function_object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?*core.Object {
    const prototype_value = try getValueProperty(ctx, output, global, constructor, core.atom.ids.prototype, caller_function, caller_frame);
    defer prototype_value.free(ctx.runtime);
    if (prototype_value.isObject()) return objectFromValue(prototype_value);
    const constructor_name = typedArrayNameFromKind(function_object.typedArrayKind()) orelse return null;
    const constructor_global = objectRealmGlobal(function_object) orelse global;
    return constructorPrototypeFromGlobal(ctx.runtime, constructor_global, constructor_name);
}

pub fn qjsTypedArrayArrayBufferPrototypeVm(
    rt: *core.JSRuntime,
    global: *core.Object,
    prototype: ?*core.Object,
) ?*core.Object {
    if (qjsArrayBufferPrototypeFromTypedArrayPrototype(prototype)) |buffer_prototype| return buffer_prototype;
    return constructorPrototypeFromGlobal(rt, global, "ArrayBuffer");
}

pub fn qjsArrayBufferPrototypeFromTypedArrayPrototype(prototype: ?*core.Object) ?*core.Object {
    var current = prototype orelse return null;
    while (true) {
        if (current.typedArrayArrayBufferPrototype()) |proto_value| {
            if (objectFromValue(proto_value)) |buffer_prototype| return buffer_prototype;
        }
        current = current.prototype orelse return null;
    }
}

pub fn qjsTypedArrayConstructToIndex(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !usize {
    const primitive = try toPrimitiveForNumber(ctx, output, global, value);
    defer primitive.free(ctx.runtime);
    if (primitive.isBigInt()) return error.TypeError;
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    defer number_value.free(ctx.runtime);
    const number = value_ops.numberValue(number_value) orelse std.math.nan(f64);
    if (std.math.isNan(number)) return 0;
    if (!std.math.isFinite(number)) return error.RangeError;
    const truncated = @trunc(number);
    if (truncated < 0) return error.RangeError;
    if (truncated == 0) return 0;
    if (truncated > 9007199254740991.0) return error.RangeError;
    return @intFromFloat(truncated);
}

pub fn qjsArrayBufferConstructWithPrototype(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    prototype: ?*core.Object,
    shared: bool,
) !core.JSValue {
    const byte_length = if (args.len >= 1)
        try qjsTypedArrayConstructToIndex(ctx, output, global, args[0])
    else
        @as(usize, 0);
    const max_byte_length = try qjsArrayBufferMaxByteLengthOption(ctx, output, global, args, byte_length);
    if (shared) return builtins.buffer.sharedArrayBufferConstructLength(ctx.runtime, byte_length, max_byte_length, prototype);
    return builtins.buffer.arrayBufferConstructLength(ctx.runtime, byte_length, max_byte_length, prototype);
}

pub fn qjsArrayBufferMaxByteLengthOption(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    byte_length: usize,
) !?usize {
    if (args.len < 2 or args[1].isUndefined() or !args[1].isObject()) return null;
    const max_key = try ctx.runtime.internAtom("maxByteLength");
    defer ctx.runtime.atoms.free(max_key);
    const max_value = try getValueProperty(ctx, output, global, args[1], max_key, null, null);
    defer max_value.free(ctx.runtime);
    if (max_value.isUndefined()) return null;
    const max_byte_length = try qjsTypedArrayConstructToIndex(ctx, output, global, max_value);
    if (max_byte_length < byte_length) return error.RangeError;
    return max_byte_length;
}

pub fn qjsTypedArrayConstructFromIterable(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 1 or !args[0].isObject()) return null;
    const source_object = objectFromValue(args[0]) orelse return null;
    if (builtins.buffer.isTypedArrayObject(source_object) or source_object.class_id == core.class.ids.array_buffer or source_object.class_id == core.class.ids.shared_array_buffer) return null;
    const iterator_method = try getIteratorMethod(ctx, output, global, args[0]);
    defer iterator_method.free(ctx.runtime);
    if (iterator_method.isUndefined() or iterator_method.isNull()) return null;
    if (!isCallableValue(iterator_method)) return error.TypeError;

    var iterator = core.JSValue.undefinedValue();
    var values_value = core.JSValue.undefinedValue();
    var next_method = core.JSValue.undefinedValue();
    var next = core.JSValue.undefinedValue();
    var done = core.JSValue.undefinedValue();
    var item = core.JSValue.undefinedValue();

    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &iterator },
        .{ .value = &values_value },
        .{ .value = &next_method },
        .{ .value = &next },
        .{ .value = &done },
        .{ .value = &item },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    defer iterator.free(ctx.runtime);
    defer values_value.free(ctx.runtime);
    defer next_method.free(ctx.runtime);
    defer next.free(ctx.runtime);
    defer done.free(ctx.runtime);
    defer item.free(ctx.runtime);

    iterator = try callValueOrBytecode(ctx, output, global, args[0], iterator_method, &.{}, caller_function, caller_frame);

    const values = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
    values_value = values.value();
    const iterator_object = objectFromValue(iterator) orelse return error.TypeError;
    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    next_method = try getValueProperty(ctx, output, global, iterator_object.value(), next_key, caller_function, caller_frame);
    if (!isCallableValue(next_method)) return error.TypeError;
    const done_key = core.atom.predefinedId("done", .string) orelse return error.TypeError;
    const value_key = core.atom.predefinedId("value", .string) orelse return error.TypeError;

    var index: u32 = 0;
    while (true) : (index += 1) {
        next.free(ctx.runtime);
        next = core.JSValue.undefinedValue();
        next = callValueOrBytecode(ctx, output, global, iterator_object.value(), next_method, &.{}, caller_function, caller_frame) catch |err| {
            try qjsIteratorClose(ctx, output, global, iterator_object.value(), caller_function, caller_frame);
            return err;
        };
        const next_object = objectFromValue(next) orelse {
            try qjsIteratorClose(ctx, output, global, iterator_object.value(), caller_function, caller_frame);
            return error.TypeError;
        };

        done.free(ctx.runtime);
        done = core.JSValue.undefinedValue();
        done = getValueProperty(ctx, output, global, next_object.value(), done_key, caller_function, caller_frame) catch |err| {
            try qjsIteratorClose(ctx, output, global, iterator_object.value(), caller_function, caller_frame);
            return err;
        };
        if (valueTruthy(done)) break;

        item.free(ctx.runtime);
        item = core.JSValue.undefinedValue();
        item = getValueProperty(ctx, output, global, next_object.value(), value_key, caller_function, caller_frame) catch |err| {
            try qjsIteratorClose(ctx, output, global, iterator_object.value(), caller_function, caller_frame);
            return err;
        };
        try values.defineOwnProperty(ctx.runtime, core.atom.atomFromUInt32(index), core.Descriptor.data(item, true, true, true));
    }
    values.length = index;
    if (callableObjectFromValue(constructor)) |function_object| {
        if (function_object.typedArrayElementSize() != 0 and function_object.typedArrayKind() != 0) {
            const kind = function_object.typedArrayKind();
            const element = construct_mod.TypedArrayElement{
                .size = function_object.typedArrayElementSize(),
                .kind = kind,
            };
            const prototype = try qjsTypedArrayConstructorPrototypeVm(ctx, output, global, constructor, function_object, caller_function, caller_frame);
            const constructor_global = objectRealmGlobal(function_object) orelse global;
            return try qjsTypedArrayConstructArrayLikeVm(
                ctx,
                output,
                global,
                constructor_global,
                prototype,
                element,
                values_value,
                caller_function,
                caller_frame,
            );
        }
    }
    return try construct_mod.constructValue(ctx.runtime, constructor, &.{values_value}, &.{});
}

pub fn qjsTypedArrayConstructorName(name: []const u8) bool {
    return builtins.typed_array_names.isConcrete(name);
}

pub fn qjsArrayBufferAccessor(ctx: *core.JSContext, receiver: core.JSValue, accessor: []const u8) !core.JSValue {
    const object = objectFromValue(receiver) orelse return error.TypeError;
    if (object.class_id != core.class.ids.array_buffer) return error.TypeError;
    if (std.mem.eql(u8, accessor, "byteLength")) {
        return lengthIndexValue(if (object.arrayBufferDetached()) 0 else object.byteStorage().len);
    }
    if (std.mem.eql(u8, accessor, "detached")) {
        return core.JSValue.boolean(object.arrayBufferDetached());
    }
    if (std.mem.eql(u8, accessor, "maxByteLength")) {
        if (object.arrayBufferDetached()) return lengthIndexValue(0);
        return lengthIndexValue(object.arrayBufferMaxByteLength() orelse object.byteStorage().len);
    }
    if (std.mem.eql(u8, accessor, "resizable")) {
        return core.JSValue.boolean(object.arrayBufferMaxByteLength() != null);
    }
    if (std.mem.eql(u8, accessor, "immutable")) {
        return core.JSValue.boolean(builtins.buffer.arrayBufferIsImmutable(ctx.runtime, object));
    }
    return error.TypeError;
}

pub fn qjsSharedArrayBufferAccessor(ctx: *core.JSContext, receiver: core.JSValue, accessor: []const u8) !core.JSValue {
    const object = objectFromValue(receiver) orelse return error.TypeError;
    if (object.class_id != core.class.ids.shared_array_buffer) return error.TypeError;
    if (std.mem.eql(u8, accessor, "byteLength")) {
        return lengthIndexValue(object.byteStorage().len);
    }
    if (std.mem.eql(u8, accessor, "maxByteLength")) {
        return lengthIndexValue(object.arrayBufferMaxByteLength() orelse object.byteStorage().len);
    }
    if (std.mem.eql(u8, accessor, "growable")) {
        return core.JSValue.boolean(object.arrayBufferMaxByteLength() != null);
    }
    _ = ctx;
    return error.TypeError;
}

pub fn qjsArrayBufferIsView(args: []const core.JSValue) core.JSValue {
    if (args.len < 1) return core.JSValue.boolean(false);
    const object = objectFromValue(args[0]) orelse return core.JSValue.boolean(false);
    return core.JSValue.boolean(builtins.buffer.isTypedArrayObject(object) or object.class_id == core.class.ids.dataview);
}

pub fn qjsArrayBufferPrototypeNativeRecord(ctx: *core.JSContext, receiver: core.JSValue, id: u32, args: []const core.JSValue) !?core.JSValue {
    const object = objectFromValue(receiver) orelse return null;
    if (object.class_id == core.class.ids.shared_array_buffer) {
        return switch (id) {
            @intFromEnum(builtins.buffer.ArrayBufferPrototypeMethod.slice),
            @intFromEnum(builtins.buffer.ArrayBufferPrototypeMethod.resize),
            @intFromEnum(builtins.buffer.ArrayBufferPrototypeMethod.transfer),
            @intFromEnum(builtins.buffer.ArrayBufferPrototypeMethod.transfer_to_fixed_length),
            @intFromEnum(builtins.buffer.ArrayBufferPrototypeMethod.slice_to_immutable),
            @intFromEnum(builtins.buffer.ArrayBufferPrototypeMethod.transfer_to_immutable),
            => error.TypeError,
            @intFromEnum(builtins.buffer.SharedArrayBufferPrototypeMethod.slice) => {
                const start = if (args.len >= 1) args[0] else core.JSValue.int32(0);
                const end = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
                return try qjsArrayBufferSlice(ctx, receiver, object, start, end, true);
            },
            @intFromEnum(builtins.buffer.SharedArrayBufferPrototypeMethod.grow) => {
                const new_length = if (args.len >= 1) args[0] else core.JSValue.int32(0);
                return try qjsSharedArrayBufferGrow(ctx, receiver, new_length);
            },
            else => null,
        };
    }
    if (object.class_id != core.class.ids.array_buffer) return null;
    return switch (id) {
        @intFromEnum(builtins.buffer.SharedArrayBufferPrototypeMethod.slice),
        @intFromEnum(builtins.buffer.SharedArrayBufferPrototypeMethod.grow),
        => error.TypeError,
        @intFromEnum(builtins.buffer.ArrayBufferPrototypeMethod.slice) => {
            const start = if (args.len >= 1) args[0] else core.JSValue.int32(0);
            const end = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
            return try qjsArrayBufferSlice(ctx, receiver, object, start, end, false);
        },
        @intFromEnum(builtins.buffer.ArrayBufferPrototypeMethod.slice_to_immutable) => {
            const start = if (args.len >= 1) args[0] else core.JSValue.int32(0);
            const end = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
            return try qjsArrayBufferSliceToImmutable(ctx, receiver, object, start, end);
        },
        @intFromEnum(builtins.buffer.ArrayBufferPrototypeMethod.resize) => {
            const new_length = if (args.len >= 1) args[0] else core.JSValue.int32(0);
            return try qjsArrayBufferResize(ctx, receiver, new_length);
        },
        @intFromEnum(builtins.buffer.ArrayBufferPrototypeMethod.transfer) => {
            const new_length = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return try qjsArrayBufferTransfer(ctx, receiver, new_length, false);
        },
        @intFromEnum(builtins.buffer.ArrayBufferPrototypeMethod.transfer_to_fixed_length) => {
            const new_length = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return try qjsArrayBufferTransfer(ctx, receiver, new_length, true);
        },
        @intFromEnum(builtins.buffer.ArrayBufferPrototypeMethod.transfer_to_immutable) => {
            const new_length = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return try qjsArrayBufferTransferToImmutable(ctx, receiver, new_length);
        },
        else => null,
    };
}

pub fn qjsArrayBufferSlice(
    ctx: *core.JSContext,
    receiver: core.JSValue,
    object: *core.Object,
    start_value: core.JSValue,
    end_value: core.JSValue,
    shared: bool,
) !core.JSValue {
    const global = ctx.global orelse {
        if (shared) return builtins.buffer.sharedArrayBufferSlice(ctx.runtime, receiver, start_value, end_value);
        return builtins.buffer.arrayBufferSlice(ctx.runtime, receiver, start_value, end_value);
    };
    if (object.arrayBufferDetached()) return error.TypeError;
    if (!shared and builtins.buffer.arrayBufferIsImmutable(ctx.runtime, object)) return error.TypeError;
    const source_length = object.byteStorage().len;
    const start = try qjsRelativeSliceIndex(ctx, null, global, start_value, source_length, false);
    const end = try qjsRelativeSliceIndex(ctx, null, global, end_value, source_length, true);
    const length = if (end > start) end - start else 0;
    const constructor = try qjsArrayBufferSpeciesConstructor(ctx, null, global, receiver, shared);
    defer constructor.free(ctx.runtime);
    const out_value = try constructValueOrBytecode(ctx, null, global, constructor, &.{lengthIndexValue(length)}, null, null);
    errdefer out_value.free(ctx.runtime);
    const out_object = objectFromValue(out_value) orelse return error.TypeError;
    if (shared) {
        if (out_object.class_id != core.class.ids.shared_array_buffer) return error.TypeError;
    } else {
        if (out_object.class_id != core.class.ids.array_buffer) return error.TypeError;
    }
    if (!shared and builtins.buffer.arrayBufferIsImmutable(ctx.runtime, out_object)) return error.TypeError;
    if (builtins.object.sameValue(out_value, receiver)) return error.TypeError;
    if (out_object.arrayBufferDetached()) return error.TypeError;
    if (out_object.byteStorage().len < length) return error.TypeError;
    if (object.arrayBufferDetached() or object.byteStorage().len < start + length) return error.TypeError;
    if (length != 0) @memcpy(out_object.byteStorage()[0..length], object.byteStorage()[start..end]);
    return out_value;
}

pub fn qjsArrayBufferSpeciesConstructor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    shared: bool,
) !core.JSValue {
    const default_name = if (shared) "SharedArrayBuffer" else "ArrayBuffer";
    const default_atom = try ctx.runtime.internAtom(default_name);
    defer ctx.runtime.atoms.free(default_atom);
    const default_constructor = global.getProperty(default_atom);
    var default_owned = true;
    errdefer if (default_owned) default_constructor.free(ctx.runtime);
    const constructor_value = try getValueProperty(ctx, output, global, receiver, core.atom.ids.constructor, null, null);
    defer constructor_value.free(ctx.runtime);
    if (constructor_value.isUndefined()) {
        default_owned = false;
        return default_constructor;
    }
    if (!constructor_value.isObject()) return error.TypeError;
    const species_atom = core.atom.predefinedId("Symbol.species", .symbol) orelse return error.TypeError;
    const species_value = try getValueProperty(ctx, output, global, constructor_value, species_atom, null, null);
    if (species_value.isUndefined() or species_value.isNull()) {
        species_value.free(ctx.runtime);
        default_owned = false;
        return default_constructor;
    }
    default_constructor.free(ctx.runtime);
    default_owned = false;
    if (!isConstructorLike(ctx, species_value)) {
        species_value.free(ctx.runtime);
        return error.TypeError;
    }
    return species_value;
}

pub fn qjsArrayBufferSliceToImmutable(
    ctx: *core.JSContext,
    receiver: core.JSValue,
    object: *core.Object,
    start_value: core.JSValue,
    end_value: core.JSValue,
) !core.JSValue {
    const global = ctx.global orelse return builtins.buffer.arrayBufferSliceToImmutable(ctx.runtime, receiver, start_value, end_value);
    if (object.arrayBufferDetached()) return error.TypeError;
    if (builtins.buffer.arrayBufferIsImmutable(ctx.runtime, object)) return error.TypeError;
    const source_length = object.byteStorage().len;
    const start = try qjsRelativeSliceIndex(ctx, null, global, start_value, source_length, false);
    const end = try qjsRelativeSliceIndex(ctx, null, global, end_value, source_length, true);
    return builtins.buffer.arrayBufferSliceToImmutableRange(ctx.runtime, receiver, start, end);
}

pub fn qjsArrayBufferResize(ctx: *core.JSContext, receiver: core.JSValue, new_length_value: core.JSValue) !core.JSValue {
    const object = objectFromValue(receiver) orelse return error.TypeError;
    if (object.class_id != core.class.ids.array_buffer) return error.TypeError;
    if (builtins.buffer.arrayBufferIsImmutable(ctx.runtime, object)) return error.TypeError;
    const new_length = try qjsArrayBufferLengthArgument(ctx, new_length_value, null);
    if (object.arrayBufferDetached()) return error.TypeError;
    return builtins.buffer.arrayBufferResizeLength(ctx.runtime, receiver, new_length);
}

pub fn qjsSharedArrayBufferGrow(ctx: *core.JSContext, receiver: core.JSValue, new_length_value: core.JSValue) !core.JSValue {
    const new_length = try qjsArrayBufferLengthArgument(ctx, new_length_value, null);
    return builtins.buffer.sharedArrayBufferGrowLength(ctx.runtime, receiver, new_length);
}

pub fn qjsArrayBufferTransfer(ctx: *core.JSContext, receiver: core.JSValue, new_length_value: core.JSValue, fixed_length: bool) !core.JSValue {
    const object = objectFromValue(receiver) orelse return error.TypeError;
    const fallback = if (object.class_id == core.class.ids.array_buffer) object.byteStorage().len else @as(usize, 0);
    const new_length = try qjsArrayBufferLengthArgument(ctx, new_length_value, fallback);
    return builtins.buffer.arrayBufferTransferLength(ctx.runtime, receiver, new_length, fixed_length);
}

pub fn qjsArrayBufferTransferToImmutable(ctx: *core.JSContext, receiver: core.JSValue, new_length_value: core.JSValue) !core.JSValue {
    const object = objectFromValue(receiver) orelse return error.TypeError;
    if (object.class_id != core.class.ids.array_buffer) return error.TypeError;
    const new_length = try qjsArrayBufferLengthArgument(ctx, new_length_value, object.byteStorage().len);
    return builtins.buffer.arrayBufferTransferToImmutableLength(ctx.runtime, receiver, new_length);
}

pub fn qjsArrayBufferLengthArgument(ctx: *core.JSContext, value: core.JSValue, undefined_length: ?usize) !usize {
    if (value.isUndefined()) return undefined_length orelse 0;
    const global = ctx.global orelse return value_ops.toIndexUsize(ctx.runtime, value);
    return qjsTypedArrayConstructToIndex(ctx, null, global, value);
}

pub fn qjsRelativeSliceIndex(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    len: usize,
    undefined_is_len: bool,
) !usize {
    if (undefined_is_len and value.isUndefined()) return len;

    const primitive = try toPrimitiveForNumber(ctx, output, global, value);
    defer primitive.free(ctx.runtime);
    if (primitive.isBigInt()) return error.TypeError;
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    defer number_value.free(ctx.runtime);
    const relative = value_ops.numberValue(number_value) orelse std.math.nan(f64);
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

pub fn qjsTypedArrayAccessor(ctx: *core.JSContext, receiver: core.JSValue, accessor: []const u8) !core.JSValue {
    if (std.mem.eql(u8, accessor, "[Symbol.toStringTag]")) {
        const object = objectFromValue(receiver) orelse return core.JSValue.undefinedValue();
        if (!builtins.buffer.isTypedArrayObject(object)) return core.JSValue.undefinedValue();
        const name = typedArrayNameFromKind(object.typedArrayKind()) orelse return core.JSValue.undefinedValue();
        return value_ops.createStringValue(ctx.runtime, name);
    }
    const object = objectFromValue(receiver) orelse return error.TypeError;
    if (!builtins.buffer.isTypedArrayObject(object)) return error.TypeError;
    if (std.mem.eql(u8, accessor, "buffer")) {
        return (object.typedArrayBuffer() orelse return error.TypeError).dup();
    }
    if (std.mem.eql(u8, accessor, "byteLength")) {
        const byte_length = try builtins.buffer.typedArrayByteLength(ctx.runtime, object);
        return lengthIndexValue(byte_length);
    }
    if (std.mem.eql(u8, accessor, "byteOffset")) {
        return lengthIndexValue(try builtins.buffer.typedArrayByteOffset(object));
    }
    if (std.mem.eql(u8, accessor, "length")) {
        return lengthIndexValue(@intCast(try builtins.buffer.typedArrayLength(ctx.runtime, object)));
    }
    return error.TypeError;
}

pub fn typedArrayNameFromKind(kind: u8) ?[]const u8 {
    return builtins.typed_array_names.nameFromKind(kind);
}

pub fn qjsTypedArraySetCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const is_typed_method = isTypedArrayPrototypeMethod(ctx.runtime, function_object);
    const target = objectFromValue(receiver) orelse return if (is_typed_method) error.TypeError else null;
    if (!builtins.buffer.isTypedArrayObject(target)) return if (is_typed_method) error.TypeError else null;
    if (try builtins.buffer.typedArrayDetached(target)) return error.TypeError;
    if (try builtins.buffer.typedArrayOutOfBounds(target)) return error.TypeError;
    try builtins.buffer.typedArrayRejectImmutableBuffer(ctx.runtime, target);
    const source = if (args.len >= 1) args[0] else return error.TypeError;
    const offset_value = if (args.len >= 2) args[1] else core.JSValue.int32(0);
    const offset_number = try toIntegerOrInfinityForArrayByCopy(ctx, output, global, offset_value);
    if (offset_number < 0 or !std.math.isFinite(offset_number)) return error.RangeError;
    if (offset_number >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.RangeError;
    const offset: usize = @intFromFloat(offset_number);

    // Offset coercion can detach or resize either view, so revalidate after it runs.
    if (try builtins.buffer.typedArrayDetached(target)) return error.TypeError;
    if (try builtins.buffer.typedArrayOutOfBounds(target)) return error.TypeError;
    const target_length: usize = @intCast(try builtins.buffer.typedArrayLength(ctx.runtime, target));

    if (objectFromValue(source)) |source_object| {
        if (builtins.buffer.isTypedArrayObject(source_object)) {
            if (try builtins.buffer.typedArrayDetached(source_object)) return error.TypeError;
            if (try builtins.buffer.typedArrayOutOfBounds(source_object)) return error.TypeError;
            const source_length: usize = @intCast(try builtins.buffer.typedArrayLength(ctx.runtime, source_object));
            if (offset > target_length or source_length > target_length - offset) return error.RangeError;

            const values = try ctx.runtime.memory.alloc(core.JSValue, source_length);
            var rooted_values: []core.JSValue = values[0..0];
            var values_root = ValueSliceRoot{};
            values_root.init(ctx.runtime, &rooted_values);
            defer values_root.deinit();
            var filled: usize = 0;
            defer {
                var free_index: usize = 0;
                while (free_index < filled) : (free_index += 1) {
                    values[free_index].free(ctx.runtime);
                    values[free_index] = core.JSValue.undefinedValue();
                }
                rooted_values = &.{};
                if (values.len != 0) ctx.runtime.memory.free(core.JSValue, values);
            }

            var snapshot_index: usize = 0;
            while (snapshot_index < source_length) : (snapshot_index += 1) {
                values[snapshot_index] = try builtins.buffer.typedArrayGetIndex(ctx.runtime, source_object, @intCast(snapshot_index));
                filled += 1;
                rooted_values = values[0..filled];
            }

            var write_index: usize = 0;
            while (write_index < source_length) : (write_index += 1) {
                _ = try builtins.buffer.typedArraySetIndex(ctx.runtime, target, @intCast(offset + write_index), values[write_index]);
            }
            return core.JSValue.undefinedValue();
        }
    }

    const source_object_value = if (source.isObject()) source.dup() else try primitiveObjectForAccess(ctx.runtime, global, source);
    defer source_object_value.free(ctx.runtime);
    _ = property_ops.expectObject(source_object_value) catch return error.TypeError;

    const length_value = try getValueProperty(ctx, output, global, source_object_value, core.atom.ids.length, caller_function, caller_frame);
    defer length_value.free(ctx.runtime);
    const source_length = try toLengthIndex(ctx, output, global, length_value);
    if (offset > target_length or source_length > target_length - offset) return error.RangeError;

    var index: usize = 0;
    while (index < source_length) : (index += 1) {
        const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
        defer key.deinit(ctx.runtime);
        const value = try getValueProperty(ctx, output, global, source_object_value, key.atom, caller_function, caller_frame);
        defer value.free(ctx.runtime);
        try qjsTypedArraySetElementValue(ctx, output, global, target, offset + index, value);
    }
    return core.JSValue.undefinedValue();
}

test "qjsTypedArraySetCall roots typed array snapshot while reading source" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);

    const element = construct_mod.typedArrayElement("BigInt64Array") orelse return error.TypeError;
    const len_args = [_]core.JSValue{core.JSValue.int32(2)};
    const source_value = try construct_mod.constructTypedArrayValue(rt, null, element, &len_args, global);
    defer source_value.free(rt);
    const source = objectFromValue(source_value) orelse return error.TypeError;
    const target_value = try construct_mod.constructTypedArrayValue(rt, null, element, &len_args, global);
    defer target_value.free(rt);
    const target = objectFromValue(target_value) orelse return error.TypeError;

    const first_big_object = try core.bigint.BigInt.create(rt, @as(i128, 1) << 70);
    const first_big = first_big_object.valueRef();
    defer first_big.free(rt);
    const second_big_object = try core.bigint.BigInt.create(rt, (@as(i128, 1) << 70) + 7);
    const second_big = second_big_object.valueRef();
    defer second_big.free(rt);
    _ = try builtins.buffer.typedArraySetIndex(rt, source, 0, first_big);
    _ = try builtins.buffer.typedArraySetIndex(rt, source, 1, second_big);

    const function_object = try core.Object.create(rt, core.class.ids.object, null);
    defer function_object.value().free(rt);
    const args = [_]core.JSValue{source_value};

    const saved_trigger_fn = rt.memory.trigger_gc_fn;
    const saved_trigger_ctx = rt.memory.trigger_gc_ctx;
    var probe = ActiveRootValueProbe{
        .rt = rt,
        .mode = .heap_bigint,
    };
    rt.memory.trigger_gc_fn = ActiveRootValueProbe.trigger;
    rt.memory.trigger_gc_ctx = &probe;
    defer {
        rt.memory.trigger_gc_fn = saved_trigger_fn;
        rt.memory.trigger_gc_ctx = saved_trigger_ctx;
    }

    const result = (try qjsTypedArraySetCall(ctx, null, global, target_value, function_object, &args, null, null)) orelse return error.TypeError;
    defer result.free(rt);

    try std.testing.expect(!probe.trace_failed);
    try std.testing.expect(probe.match_count >= 1);
    const copied = try builtins.buffer.typedArrayGetIndex(rt, target, 1);
    defer copied.free(rt);
    try std.testing.expect(copied.isBigInt());
}

pub fn qjsTypedArraySetElementValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target: *core.Object,
    index: usize,
    value: core.JSValue,
) !void {
    const coerced = if (value.isObject())
        try toPrimitiveForNumber(ctx, output, global, value)
    else
        value.dup();
    defer coerced.free(ctx.runtime);
    _ = try builtins.buffer.typedArraySetIndex(ctx.runtime, target, @intCast(index), coerced);
}

pub fn addCollectionEntriesFromArray(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    collection_value: core.JSValue,
    kind: u32,
    source: *core.Object,
    adder: core.JSValue,
) !void {
    var index: u32 = 0;
    while (index < source.length) : (index += 1) {
        const entry_value = try getValueProperty(ctx, output, global, source.value(), core.atom.atomFromUInt32(index), null, null);
        defer entry_value.free(ctx.runtime);
        if (kind == 1 or kind == 3) {
            const entry = property_ops.expectObject(entry_value) catch return error.TypeError;
            const key = try getValueProperty(ctx, output, global, entry.value(), core.atom.atomFromUInt32(0), null, null);
            defer key.free(ctx.runtime);
            const value = try getValueProperty(ctx, output, global, entry.value(), core.atom.atomFromUInt32(1), null, null);
            defer value.free(ctx.runtime);
            try callCollectionAdderFromVm(ctx, output, global, collection_value, adder, &.{ key, value });
        } else {
            try callCollectionAdderFromVm(ctx, output, global, collection_value, adder, &.{entry_value});
        }
    }
}

pub fn nativeTypedArraySubclassBase(source: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, source, "class ") == null or std.mem.indexOf(u8, source, " extends ") == null) return null;
    const names = [_][]const u8{
        "Uint8Array",
        "Int8Array",
        "Uint8ClampedArray",
        "Uint16Array",
        "Int16Array",
        "Uint32Array",
        "Int32Array",
        "Float16Array",
        "Float32Array",
        "Float64Array",
        "BigUint64Array",
        "BigInt64Array",
    };
    for (names) |name| {
        var pattern_buf: [32]u8 = undefined;
        const pattern = std.fmt.bufPrint(&pattern_buf, " extends {s}", .{name}) catch unreachable;
        if (std.mem.indexOf(u8, source, pattern) != null) return name;
    }
    return null;
}

pub fn qjsArrayForEachCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
) !?core.JSValue {
    if (args.len < 1 or !isCallableValue(args[0])) return null;
    const object = property_ops.expectObject(receiver) catch return null;
    if (!object.flags.is_array) return null;
    const function_object = callableObjectFromValue(func) orelse return null;
    if (!isArrayPrototypeRecord(function_object, @intFromEnum(builtins.array.PrototypeMethod.for_each))) {
        const name = try call_mod.nativeFunctionNameForVm(ctx.runtime, function_object);
        defer ctx.runtime.memory.allocator.free(name);
        if (!std.mem.eql(u8, name, "forEach")) return null;
    }

    const callback_this = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    var index: u32 = 0;
    while (index < object.length) : (index += 1) {
        const item = object.getProperty(core.atom.atomFromUInt32(index));
        defer item.free(ctx.runtime);
        const index_value = core.JSValue.int32(@intCast(index));
        const callback_result = try callValueOrBytecode(ctx, output, global, callback_this, args[0], &.{ item, index_value, receiver }, null, null);
        callback_result.free(ctx.runtime);
    }
    return core.JSValue.undefinedValue();
}

pub fn qjsArrayAtCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    const typed_array_method = isTypedArrayPrototypeMethod(ctx.runtime, function_object);
    if (!isArrayPrototypeRecord(function_object, @intFromEnum(builtins.array.PrototypeMethod.at))) {
        const name = try call_mod.nativeFunctionNameForVm(ctx.runtime, function_object);
        defer ctx.runtime.memory.allocator.free(name);
        if (!std.mem.eql(u8, name, "at")) return null;
    }

    if (receiver.isNull() or receiver.isUndefined()) {
        return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "Cannot convert undefined or null to object"));
    }
    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver.dup() else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    defer receiver_object_value.free(ctx.runtime);
    const object = objectFromValue(receiver_object_value) orelse return null;
    const is_typed_array = builtins.buffer.isTypedArrayObject(object);
    if (typed_array_method) {
        if (!is_typed_array) return error.TypeError;
        if (try builtins.buffer.typedArrayDetached(object)) return error.TypeError;
        if (try builtins.buffer.typedArrayOutOfBounds(object)) return error.TypeError;
    }
    const length = if (is_typed_array)
        @as(usize, @intCast(try builtins.buffer.typedArrayLength(ctx.runtime, object)))
    else if (object.flags.is_array)
        @as(usize, @intCast(object.length))
    else blk: {
        const length_value = try getValueProperty(ctx, output, global, receiver_object_value, core.atom.ids.length, null, null);
        defer length_value.free(ctx.runtime);
        break :blk try toLengthIndex(ctx, output, global, length_value);
    };

    const index_arg = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const primitive = try toPrimitiveForNumber(ctx, output, global, index_arg);
    defer primitive.free(ctx.runtime);
    const index_number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    defer index_number_value.free(ctx.runtime);
    const index_number = value_ops.numberValue(index_number_value) orelse std.math.nan(f64);
    var relative_index: isize = 0;
    if (!std.math.isNan(index_number)) {
        if (std.math.isNegativeInf(index_number)) {
            return core.JSValue.undefinedValue();
        } else if (std.math.isPositiveInf(index_number)) {
            return core.JSValue.undefinedValue();
        } else {
            relative_index = @intFromFloat(@trunc(index_number));
        }
    }
    const actual_index = if (relative_index >= 0)
        @as(isize, @intCast(relative_index))
    else
        @as(isize, @intCast(length)) + relative_index;
    if (actual_index < 0 or actual_index >= @as(isize, @intCast(length))) return core.JSValue.undefinedValue();

    const key = try propertyAtomFromLengthIndex(ctx.runtime, @intCast(actual_index));
    defer key.deinit(ctx.runtime);
    return try getValueProperty(ctx, output, global, receiver_object_value, key.atom, null, null);
}

pub const ArrayIterationMode = enum {
    for_each,
    map,
    filter,
    some,
    every,
    find,
    find_index,
    find_last,
    find_last_index,
};

pub fn qjsArrayIterationCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    if (collectionMethodOwnerClass(function_object)) |owner_class| {
        if (owner_class == core.class.ids.map or owner_class == core.class.ids.set) return null;
    }
    const mode: ArrayIterationMode = if (arrayPrototypeRecordId(function_object)) |record_id|
        switch (record_id) {
            @intFromEnum(builtins.array.PrototypeMethod.for_each) => .for_each,
            @intFromEnum(builtins.array.PrototypeMethod.map) => .map,
            @intFromEnum(builtins.array.PrototypeMethod.filter) => .filter,
            @intFromEnum(builtins.array.PrototypeMethod.some) => .some,
            @intFromEnum(builtins.array.PrototypeMethod.every) => .every,
            @intFromEnum(builtins.array.PrototypeMethod.find) => .find,
            @intFromEnum(builtins.array.PrototypeMethod.find_index) => .find_index,
            @intFromEnum(builtins.array.PrototypeMethod.find_last) => .find_last,
            @intFromEnum(builtins.array.PrototypeMethod.find_last_index) => .find_last_index,
            else => return null,
        }
    else blk: {
        const name = try call_mod.nativeFunctionNameForVm(ctx.runtime, function_object);
        defer ctx.runtime.memory.allocator.free(name);
        break :blk if (std.mem.eql(u8, name, "forEach"))
            .for_each
        else if (std.mem.eql(u8, name, "map"))
            .map
        else if (std.mem.eql(u8, name, "filter"))
            .filter
        else if (std.mem.eql(u8, name, "some"))
            .some
        else if (std.mem.eql(u8, name, "every"))
            .every
        else if (std.mem.eql(u8, name, "find"))
            .find
        else if (std.mem.eql(u8, name, "findIndex"))
            .find_index
        else if (std.mem.eql(u8, name, "findLast"))
            .find_last
        else if (std.mem.eql(u8, name, "findLastIndex"))
            .find_last_index
        else
            return null;
    };

    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver.dup() else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    defer receiver_object_value.free(ctx.runtime);
    const object = objectFromValue(receiver_object_value) orelse return null;
    const is_typed_method = isTypedArrayPrototypeMethod(ctx.runtime, function_object);
    if (is_typed_method and !builtins.buffer.isTypedArrayObject(object)) return error.TypeError;
    const is_typed_array = builtins.buffer.isTypedArrayObject(object);
    const length = if (is_typed_array)
        try arrayMethodTypedArrayLength(ctx.runtime, object, is_typed_method)
    else if (object.flags.is_array)
        @as(usize, @intCast(object.length))
    else blk: {
        const length_value = try getValueProperty(ctx, output, global, receiver_object_value, core.atom.ids.length, caller_function, caller_frame);
        defer length_value.free(ctx.runtime);
        break :blk try toLengthIndex(ctx, output, global, length_value);
    };
    if (args.len < 1 or !isCallableValue(args[0])) return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "not a function"));
    const callback_this = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    if (mode == .map and length > std.math.maxInt(u32)) return error.RangeError;
    if (is_typed_method and (mode == .map or mode == .filter)) {
        return try qjsTypedArrayMapFilter(ctx, output, global, receiver_object_value, object, length, mode, args[0], callback_this, caller_function, caller_frame);
    }

    var out_value: core.JSValue = core.JSValue.undefinedValue();
    var out: ?*core.Object = null;
    var out_index: usize = 0;
    var dense_map_output = false;
    if (mode == .map or mode == .filter) {
        out_value = try arraySpeciesCreate(ctx, output, global, receiver_object_value, if (mode == .map) length else 0, caller_function, caller_frame);
        errdefer out_value.free(ctx.runtime);
        out = objectFromValue(out_value) orelse return error.TypeError;
        dense_map_output = mode == .map and out.?.canDefineDenseArrayDataPropertiesUnchecked();
    }
    if (mode == .map and !is_typed_array and dense_map_output) {
        if (simpleNumericArg0Callback(args[0])) |simple| {
            if (try qjsDenseArrayMapSimpleNumericArg0(ctx.runtime, object, length, simple, out_value, out.?)) |value| return value;
        }
    }

    var cursor: usize = 0;
    while (cursor < length) : (cursor += 1) {
        const index = switch (mode) {
            .find_last, .find_last_index => length - 1 - cursor,
            else => cursor,
        };
        const is_find_family = mode == .find or mode == .find_index or mode == .find_last or mode == .find_last_index;
        if (!is_typed_array and !is_find_family and index > std.math.maxInt(u32)) break;
        const item = if (is_typed_array) blk: {
            if (!is_typed_method and !is_find_family) {
                const current_length = try arrayMethodTypedArrayLength(ctx.runtime, object, false);
                if (index >= current_length) continue;
            }
            break :blk try builtins.buffer.typedArrayGetIndex(ctx.runtime, object, @intCast(index));
        } else if (object.flags.is_array and object.arrayElementStorageMode() == .dense and index <= std.math.maxInt(u32)) blk: {
            if (object.getDenseArrayElementValue(@intCast(index))) |dense_item| break :blk dense_item;
            const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
            defer key.deinit(ctx.runtime);
            if (!is_find_family and
                !try hasValueProperty(ctx, output, global, receiver_object_value, object, key.atom, null, null))
            {
                continue;
            }
            break :blk try getValueProperty(ctx, output, global, receiver_object_value, key.atom, caller_function, caller_frame);
        } else blk: {
            const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
            defer key.deinit(ctx.runtime);
            if (!is_find_family and
                !try hasValueProperty(ctx, output, global, receiver_object_value, object, key.atom, null, null))
            {
                continue;
            }
            break :blk try getValueProperty(ctx, output, global, receiver_object_value, key.atom, caller_function, caller_frame);
        };
        defer item.free(ctx.runtime);
        const index_value = lengthIndexValue(index);
        const callback_result = try callValueOrBytecode(ctx, output, global, callback_this, args[0], &.{ item, index_value, receiver_object_value }, caller_function, caller_frame);
        defer callback_result.free(ctx.runtime);

        switch (mode) {
            .for_each => {},
            .map => {
                if (dense_map_output and index <= std.math.maxInt(u32) and out.?.canDefineDenseArrayDataPropertiesUnchecked()) {
                    try out.?.defineDenseArrayDataPropertyUnchecked(ctx.runtime, @intCast(index), callback_result);
                    continue;
                }
                dense_map_output = false;
                if (index <= std.math.maxInt(u32) and try out.?.defineDenseArrayDataProperty(ctx.runtime, @intCast(index), callback_result)) {
                    continue;
                }
                const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
                defer key.deinit(ctx.runtime);
                try createDataPropertyOrThrow(ctx, output, global, out_value, out.?, key.atom, callback_result, caller_function, caller_frame);
            },
            .filter => {
                if (valueTruthy(callback_result)) {
                    const out_key = try propertyAtomFromLengthIndex(ctx.runtime, out_index);
                    defer out_key.deinit(ctx.runtime);
                    try createDataPropertyOrThrow(ctx, output, global, out_value, out.?, out_key.atom, item, caller_function, caller_frame);
                    out_index += 1;
                }
            },
            .some => if (valueTruthy(callback_result)) return core.JSValue.boolean(true),
            .every => if (!valueTruthy(callback_result)) return core.JSValue.boolean(false),
            .find => if (valueTruthy(callback_result)) return item.dup(),
            .find_index => if (valueTruthy(callback_result)) return lengthIndexValue(index),
            .find_last => if (valueTruthy(callback_result)) return item.dup(),
            .find_last_index => if (valueTruthy(callback_result)) return lengthIndexValue(index),
        }
    }

    return switch (mode) {
        .for_each => core.JSValue.undefinedValue(),
        .map, .filter => out_value,
        .some => core.JSValue.boolean(false),
        .every => core.JSValue.boolean(true),
        .find, .find_last => core.JSValue.undefinedValue(),
        .find_index => core.JSValue.int32(-1),
        .find_last_index => core.JSValue.int32(-1),
    };
}

pub fn qjsDenseArrayMapSimpleNumericArg0(
    rt: *core.JSRuntime,
    source: *core.Object,
    length: usize,
    simple: SimpleNumericArg0Bytecode,
    out_value: core.JSValue,
    out: *core.Object,
) !?core.JSValue {
    if (!source.flags.is_array or source.arrayElementStorageMode() != .dense) return null;
    if (length > std.math.maxInt(u32)) return null;
    const elements = source.arrayElements();
    if (length > elements.len) return null;

    var index: usize = 0;
    while (index < length) : (index += 1) {
        const item = elements[index] orelse return null;
        if (!item.isNumber()) return null;
    }

    index = 0;
    while (index < length) : (index += 1) {
        const item = elements[index].?;
        const mapped = try simpleNumericBinary(rt, simple.binop, item, core.JSValue.int32(simple.rhs));
        defer mapped.free(rt);
        try out.defineDenseArrayDataPropertyUnchecked(rt, @intCast(index), mapped);
    }
    return out_value;
}

pub fn qjsArrayMapSimpleNumericArg0DefaultSpeciesFastCall(
    rt: *core.JSRuntime,
    global: *core.Object,
    receiver: core.JSValue,
    callback: core.JSValue,
) !?core.JSValue {
    const source = objectFromValue(receiver) orelse return null;
    if (!source.flags.is_array or source.proxyTarget() != null or source.exotic != null) return null;
    if (source.arrayElementStorageMode() != .dense) return null;
    const length: usize = @intCast(source.length);
    if (length > std.math.maxInt(u32)) return null;
    const simple = simpleNumericArg0Callback(callback) orelse return null;

    const elements = source.arrayElements();
    if (length > elements.len) return null;
    var index: usize = 0;
    while (index < length) : (index += 1) {
        const item = elements[index] orelse return null;
        if (!item.isNumber()) return null;
    }

    const out_value = try defaultArraySpeciesCreate(rt, global, source, length) orelse return null;
    errdefer out_value.free(rt);
    const out = objectFromValue(out_value) orelse return error.TypeError;
    if (!out.canDefineDenseArrayDataPropertiesUnchecked()) {
        out_value.free(rt);
        return null;
    }
    if (try qjsDenseArrayMapSimpleNumericArg0(rt, source, length, simple, out_value, out)) |mapped| return mapped;
    out_value.free(rt);
    return null;
}

pub fn qjsTypedArrayMapFilter(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver_value: core.JSValue,
    object: *core.Object,
    length: usize,
    mode: ArrayIterationMode,
    callback: core.JSValue,
    callback_this: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (mode == .map) {
        const constructor_value = try typedArraySpeciesConstructorForObject(ctx, output, global, receiver_value, object, caller_function, caller_frame);
        defer constructor_value.free(ctx.runtime);
        const out_value = try qjsTypedArrayCreateWithLength(ctx, output, global, constructor_value, length, caller_function, caller_frame);
        errdefer out_value.free(ctx.runtime);
        const out = objectFromValue(out_value) orelse return error.TypeError;
        var index: usize = 0;
        while (index < length) : (index += 1) {
            const item = try builtins.buffer.typedArrayGetIndex(ctx.runtime, object, @intCast(index));
            defer item.free(ctx.runtime);
            const mapped = try callValueOrBytecode(ctx, output, global, callback_this, callback, &.{ item, lengthIndexValue(index), receiver_value }, caller_function, caller_frame);
            defer mapped.free(ctx.runtime);
            _ = try builtins.buffer.typedArraySetIndex(ctx.runtime, out, @intCast(index), mapped);
        }
        return out_value;
    }

    const kept = try ctx.runtime.memory.alloc(core.JSValue, length);
    errdefer ctx.runtime.memory.free(core.JSValue, kept);
    var rooted_kept: []core.JSValue = kept[0..0];
    var root_slices = [_]core.runtime.ValueRootSlice{
        .{ .mutable = &rooted_kept },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .slices = &root_slices,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    var kept_count: usize = 0;
    errdefer {
        var free_index: usize = 0;
        while (free_index < kept_count) : (free_index += 1) {
            kept[free_index].free(ctx.runtime);
            kept[free_index] = core.JSValue.undefinedValue();
        }
        rooted_kept = &.{};
    }
    var index: usize = 0;
    while (index < length) : (index += 1) {
        const item = try builtins.buffer.typedArrayGetIndex(ctx.runtime, object, @intCast(index));
        const selected = try callValueOrBytecode(ctx, output, global, callback_this, callback, &.{ item, lengthIndexValue(index), receiver_value }, caller_function, caller_frame);
        defer selected.free(ctx.runtime);
        if (valueTruthy(selected)) {
            kept[kept_count] = item;
            kept_count += 1;
            rooted_kept = kept[0..kept_count];
        } else {
            item.free(ctx.runtime);
        }
    }

    const constructor_value = try typedArraySpeciesConstructorForObject(ctx, output, global, receiver_value, object, caller_function, caller_frame);
    defer constructor_value.free(ctx.runtime);
    const out_value = try qjsTypedArrayCreateWithLength(ctx, output, global, constructor_value, kept_count, caller_function, caller_frame);
    errdefer out_value.free(ctx.runtime);
    const out = objectFromValue(out_value) orelse return error.TypeError;
    index = 0;
    while (index < kept_count) : (index += 1) {
        _ = try builtins.buffer.typedArraySetIndex(ctx.runtime, out, @intCast(index), kept[index]);
        kept[index].free(ctx.runtime);
        kept[index] = core.JSValue.undefinedValue();
    }
    rooted_kept = &.{};
    ctx.runtime.memory.free(core.JSValue, kept);
    return out_value;
}

pub fn qjsTypedArrayCreateWithLength(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    requested_length: usize,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const out_value = try constructValueOrBytecode(ctx, output, global, constructor_value, &.{lengthIndexValue(requested_length)}, caller_function, caller_frame);
    errdefer out_value.free(ctx.runtime);
    const out = objectFromValue(out_value) orelse return error.TypeError;
    if (!builtins.buffer.isTypedArrayObject(out)) return error.TypeError;
    if (@as(usize, @intCast(try builtins.buffer.typedArrayLength(ctx.runtime, out))) < requested_length) return error.TypeError;
    try builtins.buffer.typedArrayRejectImmutableBuffer(ctx.runtime, out);
    return out_value;
}

pub fn qjsArrayReduceCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    from_right: bool,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    const expected_id = if (from_right)
        @intFromEnum(builtins.array.PrototypeMethod.reduce_right)
    else
        @intFromEnum(builtins.array.PrototypeMethod.reduce);
    if (!isArrayPrototypeRecord(function_object, expected_id)) {
        const name = try call_mod.nativeFunctionNameForVm(ctx.runtime, function_object);
        defer ctx.runtime.memory.allocator.free(name);
        if (!std.mem.eql(u8, name, if (from_right) "reduceRight" else "reduce")) return null;
    }

    if (receiver.isNull() or receiver.isUndefined()) {
        return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "Cannot convert undefined or null to object"));
    }
    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver.dup() else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    defer receiver_object_value.free(ctx.runtime);
    const object = objectFromValue(receiver_object_value) orelse return null;
    const is_typed_array = builtins.buffer.isTypedArrayObject(object);
    const is_typed_method = isTypedArrayPrototypeMethod(ctx.runtime, function_object);
    if (is_typed_method and !is_typed_array) return error.TypeError;
    const length = if (is_typed_array)
        try arrayMethodTypedArrayLength(ctx.runtime, object, is_typed_method)
    else if (object.flags.is_array)
        @as(usize, @intCast(object.length))
    else blk: {
        const length_value = try getValueProperty(ctx, output, global, receiver_object_value, core.atom.ids.length, null, null);
        defer length_value.free(ctx.runtime);
        break :blk try toLengthIndex(ctx, output, global, length_value);
    };
    if (args.len < 1 or !isCallableValue(args[0])) return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "not a function"));

    var accumulator: core.JSValue = undefined;
    var accumulator_set = false;
    if (args.len >= 2) {
        accumulator = args[1].dup();
        accumulator_set = true;
    }
    errdefer if (accumulator_set) accumulator.free(ctx.runtime);
    if (from_right and length > std.math.maxInt(u32)) {
        accumulator_set = false;
        return try qjsArrayReduceRightSparseLarge(ctx, output, global, object, receiver_object_value, args[0], args.len >= 2, accumulator, length);
    }

    if (from_right) {
        var cursor = length;
        while (cursor > 0) {
            cursor -= 1;
            const item = if (is_typed_array) blk: {
                if (!is_typed_method and !try builtins.buffer.typedArrayIndexValid(ctx.runtime, object, @intCast(cursor))) continue;
                break :blk try builtins.buffer.typedArrayGetIndex(ctx.runtime, object, @intCast(cursor));
            } else blk: {
                const key = try propertyAtomFromLengthIndex(ctx.runtime, cursor);
                defer key.deinit(ctx.runtime);
                if (!try hasValueProperty(ctx, output, global, receiver_object_value, object, key.atom, null, null)) continue;
                break :blk try getValueProperty(ctx, output, global, receiver_object_value, key.atom, null, null);
            };
            defer item.free(ctx.runtime);
            if (!accumulator_set) {
                accumulator = item.dup();
                accumulator_set = true;
                continue;
            }
            const index_value = lengthIndexValue(cursor);
            const next = try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), args[0], &.{ accumulator, item, index_value, receiver_object_value }, null, null);
            accumulator.free(ctx.runtime);
            accumulator = next;
        }
    } else {
        var cursor: usize = 0;
        while (cursor < length) : (cursor += 1) {
            const item = if (is_typed_array) blk: {
                if (!is_typed_method and !try builtins.buffer.typedArrayIndexValid(ctx.runtime, object, @intCast(cursor))) continue;
                break :blk try builtins.buffer.typedArrayGetIndex(ctx.runtime, object, @intCast(cursor));
            } else blk: {
                const key = try propertyAtomFromLengthIndex(ctx.runtime, cursor);
                defer key.deinit(ctx.runtime);
                if (!try hasValueProperty(ctx, output, global, receiver_object_value, object, key.atom, null, null)) continue;
                break :blk try getValueProperty(ctx, output, global, receiver_object_value, key.atom, null, null);
            };
            defer item.free(ctx.runtime);
            if (!accumulator_set) {
                accumulator = item.dup();
                accumulator_set = true;
                continue;
            }
            const index_value = lengthIndexValue(cursor);
            const next = try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), args[0], &.{ accumulator, item, index_value, receiver_object_value }, null, null);
            accumulator.free(ctx.runtime);
            accumulator = next;
        }
    }

    if (!accumulator_set) return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "empty array"));
    accumulator_set = false;
    return accumulator;
}

pub fn qjsArrayReduceRightSparseLarge(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    receiver: core.JSValue,
    callback: core.JSValue,
    has_initial: bool,
    initial: core.JSValue,
    length: usize,
) !core.JSValue {
    const keys = try object.ownKeys(ctx.runtime);
    defer core.Object.freeKeys(ctx.runtime, keys);
    var indexed = std.ArrayList(SparseIndexKey).empty;
    defer indexed.deinit(ctx.runtime.memory.allocator);
    for (keys) |key| {
        const index = propertyIndexFromLengthKey(ctx.runtime, key) orelse continue;
        if (index >= length) continue;
        try indexed.append(ctx.runtime.memory.allocator, .{ .atom_id = key, .index = index });
    }
    std.mem.sort(SparseIndexKey, indexed.items, {}, struct {
        fn lessThan(_: void, a: SparseIndexKey, b: SparseIndexKey) bool {
            return a.index > b.index;
        }
    }.lessThan);

    var accumulator = if (has_initial) initial else core.JSValue.undefinedValue();
    var accumulator_set = has_initial;
    errdefer if (accumulator_set) accumulator.free(ctx.runtime);
    for (indexed.items) |entry| {
        const item = object.getProperty(entry.atom_id);
        defer item.free(ctx.runtime);
        if (!accumulator_set) {
            accumulator = item.dup();
            accumulator_set = true;
            continue;
        }
        const index_value = lengthIndexValue(entry.index);
        const next = try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), callback, &.{ accumulator, item, index_value, receiver }, null, null);
        accumulator.free(ctx.runtime);
        accumulator = next;
    }
    if (!accumulator_set) return error.TypeError;
    accumulator_set = false;
    return accumulator;
}

pub fn arrayMethodTypedArrayLength(rt: *core.JSRuntime, object: *core.Object, is_typed_method: bool) !usize {
    if (try builtins.buffer.typedArrayDetached(object)) return error.TypeError;
    if (try builtins.buffer.typedArrayOutOfBounds(object)) {
        if (is_typed_method) return error.TypeError;
        return 0;
    }
    return @intCast(try builtins.buffer.typedArrayLength(rt, object));
}

pub fn qjsArrayLastIndexSparseLarge(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
    length: usize,
    search_value: core.JSValue,
) !core.JSValue {
    const start_exclusive = try arrayLastIndexStart(ctx, output, global, args, length);
    const keys = try object.ownKeys(ctx.runtime);
    defer core.Object.freeKeys(ctx.runtime, keys);
    var indexed = std.ArrayList(SparseIndexKey).empty;
    defer indexed.deinit(ctx.runtime.memory.allocator);
    for (keys) |key| {
        const index = propertyIndexFromLengthKey(ctx.runtime, key) orelse continue;
        if (index >= start_exclusive or index >= length) continue;
        try indexed.append(ctx.runtime.memory.allocator, .{ .atom_id = key, .index = index });
    }
    std.mem.sort(SparseIndexKey, indexed.items, {}, struct {
        fn lessThan(_: void, a: SparseIndexKey, b: SparseIndexKey) bool {
            return a.index > b.index;
        }
    }.lessThan);
    for (indexed.items) |entry| {
        const item = try getValueProperty(ctx, output, global, receiver, entry.atom_id, null, null);
        defer item.free(ctx.runtime);
        if (try valuesStrictEqual(ctx.runtime, item, search_value)) return lengthIndexValue(entry.index);
    }
    return core.JSValue.int32(-1);
}

pub fn arrayFirstIndexStart(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    length: usize,
) !usize {
    if (args.len < 2) return 0;
    const n = try toIntegerOrInfinityForArrayByCopy(ctx, output, global, args[1]);
    if (std.math.isNan(n)) return 0;
    if (std.math.isPositiveInf(n)) return length;
    if (std.math.isNegativeInf(n)) return 0;
    if (n >= @as(f64, @floatFromInt(length))) return length;
    if (n >= 0) return @intFromFloat(@trunc(n));
    const offset = @as(f64, @floatFromInt(length)) + @trunc(n);
    if (offset <= 0) return 0;
    return @intFromFloat(offset);
}

pub fn arrayLastIndexStart(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    length: usize,
) !usize {
    if (args.len < 2) return length;
    const n = try toIntegerOrInfinityForArrayByCopy(ctx, output, global, args[1]);
    if (std.math.isNan(n)) return length;
    if (std.math.isNegativeInf(n)) return 0;
    if (std.math.isPositiveInf(n)) return length;
    const upper = @as(f64, @floatFromInt(length - 1));
    if (n >= upper) return length;
    if (n >= 0) return @as(usize, @intFromFloat(@trunc(n))) + 1;
    const offset = @as(f64, @floatFromInt(length)) + @trunc(n);
    if (offset < 0) return 0;
    return @as(usize, @intFromFloat(offset)) + 1;
}

pub fn qjsArraySliceCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    if (getStringPrototypeMethodId(ctx.runtime, function_object) != null) return null;
    if (!isArrayPrototypeRecord(function_object, @intFromEnum(builtins.array.PrototypeMethod.slice))) {
        const name = try call_mod.nativeFunctionNameForVm(ctx.runtime, function_object);
        defer ctx.runtime.memory.allocator.free(name);
        if (!std.mem.eql(u8, name, "slice")) return null;
    }

    if (receiver.isNull() or receiver.isUndefined()) return error.TypeError;
    const primitive_non_string_receiver = !receiver.isObject() and !receiver.isString();
    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver.dup() else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    defer receiver_object_value.free(ctx.runtime);
    const object = objectFromValue(receiver_object_value) orelse return null;
    if (object.class_id == core.class.ids.string) return null;
    if (!primitive_non_string_receiver and
        !object.flags.is_array and
        !object.flags.is_proxy and
        object.class_id != core.class.ids.object and
        object.class_id != core.class.ids.arguments and
        object.class_id != core.class.ids.mapped_arguments and
        !builtins.buffer.isTypedArrayObject(object)) return null;
    const length = if (primitive_non_string_receiver)
        0
    else if (object.flags.is_array and !object.flags.is_proxy)
        @as(usize, @intCast(object.length))
    else blk: {
        const length_value = try getValueProperty(ctx, output, global, receiver_object_value, core.atom.ids.length, null, null);
        defer length_value.free(ctx.runtime);
        break :blk try toLengthIndex(ctx, output, global, length_value);
    };

    const start = try arrayRelativeIndex(ctx, output, global, args, 0, length, 0);
    const end = if (args.len >= 2 and !args[1].isUndefined())
        try arrayRelativeIndex(ctx, output, global, args, 1, length, length)
    else
        length;
    const count = if (end > start) end - start else 0;
    if (count > std.math.maxInt(u32)) return error.RangeError;

    const out_value = try arraySpeciesCreate(ctx, output, global, receiver_object_value, count, null, null);
    errdefer out_value.free(ctx.runtime);
    const out = try property_ops.expectObject(out_value);
    const set_initial_length = try setValueProperty(ctx, output, global, out_value, core.atom.ids.length, lengthIndexValue(count), null, null);
    set_initial_length.free(ctx.runtime);

    var from = start;
    var to: usize = 0;
    while (from < end and to < count) : ({
        from += 1;
        to += 1;
    }) {
        const from_key = try propertyAtomFromLengthIndex(ctx.runtime, from);
        defer from_key.deinit(ctx.runtime);
        if (!try hasValueProperty(ctx, output, global, receiver_object_value, object, from_key.atom, null, null)) continue;
        const item = try getValueProperty(ctx, output, global, receiver_object_value, from_key.atom, null, null);
        defer item.free(ctx.runtime);
        const to_key = try propertyAtomFromLengthIndex(ctx.runtime, to);
        defer to_key.deinit(ctx.runtime);
        try createDataPropertyOrThrow(ctx, output, global, out_value, out, to_key.atom, item, null, null);
    }

    return out_value;
}

pub fn qjsTypedArraySliceSubarrayCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    const name = try call_mod.nativeFunctionNameForVm(ctx.runtime, function_object);
    defer ctx.runtime.memory.allocator.free(name);
    const is_slice = std.mem.eql(u8, name, "slice");
    const is_subarray = std.mem.eql(u8, name, "subarray");
    if (!is_slice and !is_subarray) return null;
    const is_typed_method = isTypedArrayPrototypeMethod(ctx.runtime, function_object);
    const object = objectFromValue(receiver) orelse return if (is_typed_method) error.TypeError else null;
    if (!builtins.buffer.isTypedArrayObject(object)) return if (is_typed_method) error.TypeError else null;
    if (is_slice and (try builtins.buffer.typedArrayDetached(object) or try builtins.buffer.typedArrayOutOfBounds(object))) return error.TypeError;
    const length = @as(usize, @intCast(try builtins.buffer.typedArrayLength(ctx.runtime, object)));
    const start = try arrayRelativeIndex(ctx, output, global, args, 0, length, 0);
    const end = if (args.len >= 2 and !args[1].isUndefined())
        try arrayRelativeIndex(ctx, output, global, args, 1, length, length)
    else
        length;
    const count = if (end > start) end - start else 0;
    if (count > std.math.maxInt(i32)) return error.RangeError;

    const constructor_value = try typedArraySpeciesConstructorForObject(ctx, output, global, receiver, object, null, null);
    defer constructor_value.free(ctx.runtime);

    const result = if (is_subarray) blk: {
        const buffer_value = (object.typedArrayBuffer() orelse return error.TypeError).dup();
        defer buffer_value.free(ctx.runtime);
        const buffer = objectFromValue(buffer_value) orelse return error.TypeError;
        if (buffer.class_id != core.class.ids.array_buffer and buffer.class_id != core.class.ids.shared_array_buffer) {
            return error.TypeError;
        }
        const src_byte_offset = object.typedArrayByteOffset();
        if (!buffer.arrayBufferDetached()) {
            if (src_byte_offset > buffer.byteStorage().len) return error.RangeError;
            if (src_byte_offset == buffer.byteStorage().len and count > 0) return error.RangeError;
        }
        const begin_byte_offset = src_byte_offset + start * object.typedArrayElementSize();
        if (object.typedArrayFixedLength() == null and (args.len < 2 or args[1].isUndefined())) {
            break :blk try constructValueOrBytecode(ctx, output, global, constructor_value, &.{ buffer_value, lengthIndexValue(begin_byte_offset) }, null, null);
        }
        break :blk try constructValueOrBytecode(ctx, output, global, constructor_value, &.{ buffer_value, lengthIndexValue(begin_byte_offset), lengthIndexValue(count) }, null, null);
    } else try qjsTypedArrayCreateWithLength(ctx, output, global, constructor_value, count, null, null);
    errdefer result.free(ctx.runtime);
    const result_object = objectFromValue(result) orelse return error.TypeError;
    if (!builtins.buffer.isTypedArrayObject(result_object)) return error.TypeError;

    if (is_slice and count > 0) {
        if (try builtins.buffer.typedArrayDetached(object) or try builtins.buffer.typedArrayOutOfBounds(object)) return error.TypeError;
        const current_length = @as(usize, @intCast(try builtins.buffer.typedArrayLength(ctx.runtime, object)));
        const copy_count = if (current_length > start)
            @min(count, current_length - start)
        else
            0;
        var index: usize = 0;
        while (index < copy_count) : (index += 1) {
            const item = try builtins.buffer.typedArrayGetIndex(ctx.runtime, object, @intCast(start + index));
            defer item.free(ctx.runtime);
            _ = try builtins.buffer.typedArraySetIndex(ctx.runtime, result_object, @intCast(index), item);
        }
    }
    return result;
}

pub fn typedArrayConstructorForObject(rt: *core.JSRuntime, global: *core.Object, object: *core.Object) !core.JSValue {
    const name = typedArrayNameFromKind(object.typedArrayKind()) orelse return error.TypeError;
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    const constructor = global.getProperty(key);
    if (!constructor.isObject()) {
        constructor.free(rt);
        return error.TypeError;
    }
    return constructor;
}

pub fn typedArraySpeciesConstructorForObject(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const default_constructor = try typedArrayConstructorForObject(ctx.runtime, global, object);
    errdefer default_constructor.free(ctx.runtime);
    const constructor_value = try getValueProperty(ctx, output, global, receiver, core.atom.ids.constructor, caller_function, caller_frame);
    defer constructor_value.free(ctx.runtime);
    if (constructor_value.isUndefined()) return default_constructor;
    if (!constructor_value.isObject()) return error.TypeError;
    const species_atom = core.atom.predefinedId("Symbol.species", .symbol) orelse return error.TypeError;
    const species_value = try getValueProperty(ctx, output, global, constructor_value, species_atom, caller_function, caller_frame);
    if (species_value.isUndefined() or species_value.isNull()) {
        species_value.free(ctx.runtime);
        return default_constructor;
    }
    default_constructor.free(ctx.runtime);
    return species_value;
}

pub fn qjsArraySpliceCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    if (!isArrayPrototypeRecord(function_object, @intFromEnum(builtins.array.PrototypeMethod.splice))) {
        const name = try call_mod.nativeFunctionNameForVm(ctx.runtime, function_object);
        defer ctx.runtime.memory.allocator.free(name);
        if (!std.mem.eql(u8, name, "splice")) return null;
    }

    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver.dup() else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    defer receiver_object_value.free(ctx.runtime);
    const object = objectFromValue(receiver_object_value) orelse return null;
    if (object.class_id == core.class.ids.string) return null;
    var verify_own_length_write = false;
    if (object.getOwnProperty(core.atom.ids.length)) |length_desc| {
        defer length_desc.destroy(ctx.runtime);
        verify_own_length_write = !object.flags.is_array;
        if (length_desc.kind == .accessor and length_desc.setter.isUndefined()) return null;
        if (length_desc.kind == .generic) return null;
        if (length_desc.kind == .data and !object.flags.is_array and isCallableValue(length_desc.value)) return null;
    }
    const length = if (object.flags.is_array)
        @as(usize, @intCast(object.length))
    else blk: {
        const length_value = try getValueProperty(ctx, output, global, receiver_object_value, core.atom.ids.length, null, null);
        defer length_value.free(ctx.runtime);
        if (isCallableValue(length_value)) return null;
        break :blk try toLengthIndex(ctx, output, global, length_value);
    };

    const actual_start = if (args.len >= 1)
        try arrayRelativeIndex(ctx, output, global, args, 0, length, 0)
    else
        0;
    const insert_count = if (args.len > 2) args.len - 2 else 0;
    const actual_delete_count = if (args.len == 0)
        0
    else if (args.len == 1)
        length - actual_start
    else blk: {
        const requested = try toIntegerOrInfinityForArrayMethod(ctx, output, global, args[1]);
        if (std.math.isNan(requested) or requested <= 0) break :blk @as(usize, 0);
        const available = length - actual_start;
        if (std.math.isPositiveInf(requested) or requested >= @as(f64, @floatFromInt(available))) break :blk available;
        break :blk @as(usize, @intFromFloat(@trunc(requested)));
    };
    const max_safe_length: usize = 9007199254740991;
    const new_length = length - actual_delete_count + insert_count;
    if (new_length > max_safe_length) return error.TypeError;

    const removed_value = try arraySpeciesCreate(ctx, output, global, receiver_object_value, actual_delete_count, null, null);
    errdefer removed_value.free(ctx.runtime);
    const removed = try property_ops.expectObject(removed_value);
    var index: usize = 0;
    while (index < actual_delete_count) : (index += 1) {
        const from = actual_start + index;
        const from_key = try propertyAtomFromLengthIndex(ctx.runtime, from);
        defer from_key.deinit(ctx.runtime);
        if (!try hasValueProperty(ctx, output, global, receiver_object_value, object, from_key.atom, null, null)) continue;
        const item = try getValueProperty(ctx, output, global, receiver_object_value, from_key.atom, null, null);
        defer item.free(ctx.runtime);
        const to_key = try propertyAtomFromLengthIndex(ctx.runtime, index);
        defer to_key.deinit(ctx.runtime);
        try createDataPropertyOrThrow(ctx, output, global, removed_value, removed, to_key.atom, item, null, null);
    }
    const set_removed_length = try setValueProperty(ctx, output, global, removed_value, core.atom.ids.length, lengthIndexValue(actual_delete_count), null, null);
    set_removed_length.free(ctx.runtime);

    if (insert_count < actual_delete_count) {
        var from = actual_start + actual_delete_count;
        while (from < length) : (from += 1) {
            const to = from - actual_delete_count + insert_count;
            const from_key = try propertyAtomFromLengthIndex(ctx.runtime, from);
            defer from_key.deinit(ctx.runtime);
            const to_key = try propertyAtomFromLengthIndex(ctx.runtime, to);
            defer to_key.deinit(ctx.runtime);
            if (try hasValueProperty(ctx, output, global, receiver_object_value, object, from_key.atom, null, null)) {
                const item = try getValueProperty(ctx, output, global, receiver_object_value, from_key.atom, null, null);
                defer item.free(ctx.runtime);
                const set_result = try setValueProperty(ctx, output, global, receiver_object_value, to_key.atom, item, null, null);
                set_result.free(ctx.runtime);
            } else {
                try deleteValuePropertyOrThrow(ctx, output, global, receiver_object_value, object, to_key.atom);
            }
        }
        var delete_index = length;
        while (delete_index > new_length) {
            delete_index -= 1;
            const key = try propertyAtomFromLengthIndex(ctx.runtime, delete_index);
            defer key.deinit(ctx.runtime);
            try deleteValuePropertyOrThrow(ctx, output, global, receiver_object_value, object, key.atom);
        }
    } else if (insert_count > actual_delete_count) {
        var from = length;
        while (from > actual_start + actual_delete_count) {
            from -= 1;
            const to = from - actual_delete_count + insert_count;
            const from_key = try propertyAtomFromLengthIndex(ctx.runtime, from);
            defer from_key.deinit(ctx.runtime);
            const to_key = try propertyAtomFromLengthIndex(ctx.runtime, to);
            defer to_key.deinit(ctx.runtime);
            if (try hasValueProperty(ctx, output, global, receiver_object_value, object, from_key.atom, null, null)) {
                const item = try getValueProperty(ctx, output, global, receiver_object_value, from_key.atom, null, null);
                defer item.free(ctx.runtime);
                const set_result = try setValueProperty(ctx, output, global, receiver_object_value, to_key.atom, item, null, null);
                set_result.free(ctx.runtime);
            } else {
                try deleteValuePropertyOrThrow(ctx, output, global, receiver_object_value, object, to_key.atom);
            }
        }
    }

    if (args.len > 2) {
        for (args[2..], 0..) |item, offset| {
            const key = try propertyAtomFromLengthIndex(ctx.runtime, actual_start + offset);
            defer key.deinit(ctx.runtime);
            const set_result = try setValueProperty(ctx, output, global, receiver_object_value, key.atom, item, null, null);
            set_result.free(ctx.runtime);
        }
    }
    try ensureLengthWritableForArrayBuiltin(ctx, object);
    const set_result = try setValueProperty(ctx, output, global, receiver_object_value, core.atom.ids.length, lengthIndexValue(new_length), null, null);
    set_result.free(ctx.runtime);
    if (verify_own_length_write) {
        const final_length = object.getProperty(core.atom.ids.length);
        defer final_length.free(ctx.runtime);
        const final_length_index = try toLengthIndex(ctx, output, global, final_length);
        if (final_length_index != new_length) return error.TypeError;
    }
    return removed_value;
}

pub fn qjsArrayCopyWithinCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    if (!isArrayPrototypeRecord(function_object, @intFromEnum(builtins.array.PrototypeMethod.copy_within))) {
        const name = try call_mod.nativeFunctionNameForVm(ctx.runtime, function_object);
        defer ctx.runtime.memory.allocator.free(name);
        if (!std.mem.eql(u8, name, "copyWithin")) return null;
    }
    const is_typed_method = isTypedArrayPrototypeMethod(ctx.runtime, function_object);

    if (is_typed_method) {
        const object = objectFromValue(receiver) orelse return error.TypeError;
        if (!builtins.buffer.isTypedArrayObject(object)) return error.TypeError;
        if (try builtins.buffer.typedArrayDetached(object)) return error.TypeError;
        if (try builtins.buffer.typedArrayOutOfBounds(object)) return error.TypeError;
        try builtins.buffer.typedArrayRejectImmutableBuffer(ctx.runtime, object);
        const initial_length = @as(usize, @intCast(try builtins.buffer.typedArrayLength(ctx.runtime, object)));

        const target_number = if (args.len >= 1)
            try toIntegerOrInfinityForArrayByCopy(ctx, output, global, args[0])
        else
            @as(f64, 0);
        const start_number = if (args.len >= 2)
            try toIntegerOrInfinityForArrayByCopy(ctx, output, global, args[1])
        else
            @as(f64, 0);
        const end_number = if (args.len >= 3 and !args[2].isUndefined())
            try toIntegerOrInfinityForArrayByCopy(ctx, output, global, args[2])
        else
            null;

        if (try builtins.buffer.typedArrayDetached(object)) return error.TypeError;
        if (try builtins.buffer.typedArrayOutOfBounds(object)) return error.TypeError;

        const current_length = @as(usize, @intCast(try builtins.buffer.typedArrayLength(ctx.runtime, object)));
        const length = @min(initial_length, current_length);
        const to_start = arrayRelativeIndexFromNumber(length, target_number, 0);
        const from_start = arrayRelativeIndexFromNumber(length, start_number, 0);
        const final = if (end_number) |end|
            arrayRelativeIndexFromNumber(length, end, length)
        else
            length;
        const count = @min(final -| from_start, length -| to_start);
        if (count == 0) return receiver.dup();

        const buffer_value = object.typedArrayBuffer() orelse return error.TypeError;
        const buffer = objectFromValue(buffer_value) orelse return error.TypeError;
        const element_size = object.typedArrayElementSize();
        const from_byte = object.typedArrayByteOffset() + from_start * element_size;
        const to_byte = object.typedArrayByteOffset() + to_start * element_size;
        const byte_count = count * element_size;
        const source = buffer.byteStorage()[from_byte .. from_byte + byte_count];
        const dest = buffer.byteStorage()[to_byte .. to_byte + byte_count];
        if (from_byte < to_byte and to_byte < from_byte + byte_count) {
            std.mem.copyBackwards(u8, dest, source);
        } else {
            std.mem.copyForwards(u8, dest, source);
        }
        return receiver.dup();
    }

    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver.dup() else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    defer receiver_object_value.free(ctx.runtime);
    const object = objectFromValue(receiver_object_value) orelse return null;
    if (object.class_id == core.class.ids.string) return null;
    const length = if (builtins.buffer.isTypedArrayObject(object))
        try arrayMethodTypedArrayLength(ctx.runtime, object, false)
    else if (object.flags.is_array)
        @as(usize, @intCast(object.length))
    else blk: {
        const length_value = try getValueProperty(ctx, output, global, receiver_object_value, core.atom.ids.length, null, null);
        defer length_value.free(ctx.runtime);
        break :blk try toLengthIndex(ctx, output, global, length_value);
    };

    const to_start = try arrayRelativeIndex(ctx, output, global, args, 0, length, 0);
    const from_start = try arrayRelativeIndex(ctx, output, global, args, 1, length, 0);
    const final = if (args.len >= 3 and !args[2].isUndefined())
        try arrayRelativeIndex(ctx, output, global, args, 2, length, length)
    else
        length;
    var count = @min(final -| from_start, length -| to_start);
    var from = from_start;
    var to = to_start;
    var direction: isize = 1;
    if (from < to and to < from + count) {
        direction = -1;
        from += count - 1;
        to += count - 1;
    }

    while (count > 0) {
        const from_key = try propertyAtomFromLengthIndex(ctx.runtime, from);
        defer from_key.deinit(ctx.runtime);
        const to_key = try propertyAtomFromLengthIndex(ctx.runtime, to);
        defer to_key.deinit(ctx.runtime);
        if (try hasValueProperty(ctx, output, global, receiver_object_value, object, from_key.atom, null, null)) {
            const item = try getValueProperty(ctx, output, global, receiver_object_value, from_key.atom, null, null);
            defer item.free(ctx.runtime);
            const set_result = try setValueProperty(ctx, output, global, receiver_object_value, to_key.atom, item, null, null);
            set_result.free(ctx.runtime);
        } else {
            try deleteValuePropertyOrThrow(ctx, output, global, receiver_object_value, object, to_key.atom);
        }
        count -= 1;
        if (count == 0) break;
        if (direction > 0) {
            from += 1;
            to += 1;
        } else {
            from -= 1;
            to -= 1;
        }
    }
    return receiver_object_value.dup();
}

pub fn qjsArrayFillCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    if (!isArrayPrototypeRecord(function_object, @intFromEnum(builtins.array.PrototypeMethod.fill))) {
        const name = try call_mod.nativeFunctionNameForVm(ctx.runtime, function_object);
        defer ctx.runtime.memory.allocator.free(name);
        if (!std.mem.eql(u8, name, "fill")) return null;
    }

    const is_typed_method = isTypedArrayPrototypeMethod(ctx.runtime, function_object);
    if (is_typed_method and !receiver.isObject()) return error.TypeError;
    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver.dup() else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    defer receiver_object_value.free(ctx.runtime);
    const object = objectFromValue(receiver_object_value) orelse return null;
    if (object.class_id == core.class.ids.string) return if (is_typed_method) error.TypeError else null;

    if (is_typed_method) {
        if (!builtins.buffer.isTypedArrayObject(object)) return error.TypeError;
        if (try builtins.buffer.typedArrayDetached(object) or try builtins.buffer.typedArrayOutOfBounds(object)) return error.TypeError;
        try builtins.buffer.typedArrayRejectImmutableBuffer(ctx.runtime, object);

        const initial_length = @as(usize, @intCast(try builtins.buffer.typedArrayLength(ctx.runtime, object)));
        const raw_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const value = try qjsTypedArrayByCopyCoerceValue(ctx, output, global, object, raw_value);
        defer value.free(ctx.runtime);

        const start = try arrayRelativeIndex(ctx, output, global, args, 1, initial_length, 0);
        const final = if (args.len >= 3 and !args[2].isUndefined())
            try arrayRelativeIndex(ctx, output, global, args, 2, initial_length, initial_length)
        else
            initial_length;

        if (try builtins.buffer.typedArrayDetached(object) or try builtins.buffer.typedArrayOutOfBounds(object)) return error.TypeError;

        const current_length = @as(usize, @intCast(try builtins.buffer.typedArrayLength(ctx.runtime, object)));
        const capped_final = @min(final, current_length);
        var index = start;
        while (index < capped_final) : (index += 1) {
            _ = try builtins.buffer.typedArraySetIndex(ctx.runtime, object, @intCast(index), value);
        }
        return receiver_object_value.dup();
    }

    const length = if (builtins.buffer.isTypedArrayObject(object))
        try arrayMethodTypedArrayLength(ctx.runtime, object, false)
    else if (object.flags.is_array)
        @as(usize, @intCast(object.length))
    else blk: {
        const length_value = try getValueProperty(ctx, output, global, receiver_object_value, core.atom.ids.length, null, null);
        defer length_value.free(ctx.runtime);
        break :blk try toLengthIndex(ctx, output, global, length_value);
    };

    const start = try arrayRelativeIndex(ctx, output, global, args, 1, length, 0);
    const final = if (args.len >= 3 and !args[2].isUndefined())
        try arrayRelativeIndex(ctx, output, global, args, 2, length, length)
    else
        length;
    const raw_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const value = if (builtins.buffer.isTypedArrayObject(object) and object.typedArrayKind() != 11 and object.typedArrayKind() != 12) blk: {
        const primitive = try toPrimitiveForNumber(ctx, output, global, raw_value);
        defer primitive.free(ctx.runtime);
        break :blk try value_ops.toNumberValue(ctx.runtime, primitive);
    } else raw_value.dup();
    defer value.free(ctx.runtime);

    if (object.flags.is_array and object.exotic == null and object.proxyTarget() == null and object.arrayElementStorageMode() == .dense and object.flags.extensible and arrayPrototypeChainHasNoIndexedProperties(object)) {
        if (final <= @as(usize, @intCast(std.math.maxInt(u32))) + 1) {
            var dense_index = start;
            if (object.canDefineDenseArrayDataPropertiesUnchecked()) {
                while (dense_index < final) : (dense_index += 1) {
                    try object.defineDenseArrayDataPropertyUnchecked(ctx.runtime, @intCast(dense_index), value);
                }
                return receiver_object_value.dup();
            }

            while (dense_index < final) : (dense_index += 1) {
                if (!try object.defineDenseArrayDataProperty(ctx.runtime, @intCast(dense_index), value)) break;
            }
            if (dense_index == final) return receiver_object_value.dup();

            var index = dense_index;
            while (index < final) : (index += 1) {
                const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
                defer key.deinit(ctx.runtime);
                const set_result = try setValueProperty(ctx, output, global, receiver_object_value, key.atom, value, null, null);
                set_result.free(ctx.runtime);
            }
            return receiver_object_value.dup();
        }
    }

    var index = start;
    while (index < final) : (index += 1) {
        const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
        defer key.deinit(ctx.runtime);
        const set_result = try setValueProperty(ctx, output, global, receiver_object_value, key.atom, value, null, null);
        set_result.free(ctx.runtime);
    }
    return receiver_object_value.dup();
}

pub fn arrayPrototypeChainHasNoIndexedProperties(object: *core.Object) bool {
    var cursor = object.getPrototype();
    while (cursor) |candidate| {
        if (candidate.proxyTarget() != null or candidate.exotic != null) return false;
        if (candidate.flags.may_have_indexed_properties) return false;
        cursor = candidate.getPrototype();
    }
    return true;
}

pub fn qjsArrayPushCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    if (!isArrayPrototypeRecord(function_object, @intFromEnum(builtins.array.PrototypeMethod.push))) {
        const name = try call_mod.nativeFunctionNameForVm(ctx.runtime, function_object);
        defer ctx.runtime.memory.allocator.free(name);
        if (!std.mem.eql(u8, name, "push")) return null;
    }

    return qjsArrayPushCallImpl(ctx, output, global, receiver, args, caller_function, caller_frame);
}

fn qjsArrayPushCallImpl(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (receiver.isNull() or receiver.isUndefined()) {
        return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "Cannot convert undefined or null to object"));
    }
    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver.dup() else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    defer receiver_object_value.free(ctx.runtime);
    const object = objectFromValue(receiver_object_value) orelse return null;
    if (object.class_id == core.class.ids.string) return error.TypeError;
    if (args.len == 1 and objectFromValue(receiver) == object and object.flags.is_array and object.exotic == null and object.length < core.array.max_array_length) {
        const index = object.length;
        if (try object.appendDenseArrayIndex(ctx.runtime, index, core.atom.atomFromUInt32(index), args[0])) {
            return lengthIndexValue(index + 1);
        }
    }
    const length_value = try getValueProperty(ctx, output, global, receiver_object_value, core.atom.ids.length, caller_function, caller_frame);
    defer length_value.free(ctx.runtime);
    const length = try toLengthIndex(ctx, output, global, length_value);
    const max_safe_length: usize = 9007199254740991;
    if (args.len > max_safe_length - length) return error.TypeError;

    var index = length;
    for (args) |item| {
        const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
        defer key.deinit(ctx.runtime);
        try ensureSettableForArrayBuiltin(ctx, object, key.atom);
        const set_result = try setValueProperty(ctx, output, global, receiver_object_value, key.atom, item, caller_function, caller_frame);
        set_result.free(ctx.runtime);
        index += 1;
    }
    try ensureLengthWritableForArrayBuiltin(ctx, object);
    const set_length = try setValueProperty(ctx, output, global, receiver_object_value, core.atom.ids.length, lengthIndexValue(index), caller_function, caller_frame);
    set_length.free(ctx.runtime);
    try verifyArrayLikeLengthSet(ctx, output, global, receiver_object_value, index);
    return lengthIndexValue(index);
}

pub fn qjsArrayPopCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    if (!isArrayPrototypeRecord(function_object, @intFromEnum(builtins.array.PrototypeMethod.pop))) {
        const name = try call_mod.nativeFunctionNameForVm(ctx.runtime, function_object);
        defer ctx.runtime.memory.allocator.free(name);
        if (!std.mem.eql(u8, name, "pop")) return null;
    }

    return qjsArrayPopCallImpl(ctx, output, global, receiver, caller_function, caller_frame);
}

fn qjsArrayPopCallImpl(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver.dup() else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    defer receiver_object_value.free(ctx.runtime);
    const object = objectFromValue(receiver_object_value) orelse return null;
    if (object.class_id == core.class.ids.string) return error.TypeError;
    if (qjsFastDenseArrayPop(object)) |value| return value;
    const length_value = try getValueProperty(ctx, output, global, receiver_object_value, core.atom.ids.length, caller_function, caller_frame);
    defer length_value.free(ctx.runtime);
    const length = try toLengthIndex(ctx, output, global, length_value);

    if (length == 0) {
        try ensureLengthWritableForArrayBuiltin(ctx, object);
        const set_length = try setValueProperty(ctx, output, global, receiver_object_value, core.atom.ids.length, core.JSValue.int32(0), caller_function, caller_frame);
        set_length.free(ctx.runtime);
        try verifyArrayLikeLengthSet(ctx, output, global, receiver_object_value, 0);
        return core.JSValue.undefinedValue();
    }

    const index = length - 1;
    const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
    defer key.deinit(ctx.runtime);
    const value = try getValueProperty(ctx, output, global, receiver_object_value, key.atom, caller_function, caller_frame);
    errdefer value.free(ctx.runtime);
    try deleteValuePropertyOrThrow(ctx, output, global, receiver_object_value, object, key.atom);
    const set_length = try setValueProperty(ctx, output, global, receiver_object_value, core.atom.ids.length, lengthIndexValue(index), caller_function, caller_frame);
    set_length.free(ctx.runtime);
    try verifyArrayLikeLengthSet(ctx, output, global, receiver_object_value, index);
    return value;
}

fn qjsFastDenseArrayPop(object: *core.Object) ?core.JSValue {
    if (!object.flags.is_array or !object.flags.length_writable) return null;
    if (object.proxyTarget() != null or object.exotic != null or object.arrayElementStorageMode() != .dense) return null;
    if (object.length == 0) return null;

    const index = object.length - 1;
    const atom_id = core.atom.atomFromUInt32(index);
    if (object.properties.len != 0 and object.findProperty(atom_id) != null) return null;

    const element_index: usize = @intCast(index);
    const elements = object.arrayElementsSlot();
    if (element_index >= elements.*.len) {
        if (!arrayPrototypeChainHasNoIndexedProperties(object)) return null;
        object.length = index;
        return core.JSValue.undefinedValue();
    }

    const value = elements.*[element_index] orelse {
        if (!arrayPrototypeChainHasNoIndexedProperties(object)) return null;
        elements.* = elements.*.ptr[0..element_index];
        object.length = index;
        return core.JSValue.undefinedValue();
    };

    elements.*[element_index] = null;
    elements.* = elements.*.ptr[0..element_index];
    object.length = index;
    return value;
}

pub fn qjsFastDensePrimitiveArrayPop(object: *core.Object) ?core.JSValue {
    if (!object.flags.is_array or !object.flags.length_writable) return null;
    if (object.exotic != null or object.arrayElementStorageMode() != .dense) return null;
    if (object.properties.len != 0) return null;
    if (object.length == 0) return null;

    const index = object.length - 1;
    const elements = object.arrayElementsSlot();
    if (index >= elements.*.len) return null;
    const value = elements.*[@intCast(index)] orelse return null;
    if (!qjsCanFastJoinPrimitive(value)) return null;

    elements.*[@intCast(index)] = null;
    object.length = index;
    return value;
}

pub fn qjsArrayShiftCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    if (!isArrayPrototypeRecord(function_object, @intFromEnum(builtins.array.PrototypeMethod.shift))) {
        const name = try call_mod.nativeFunctionNameForVm(ctx.runtime, function_object);
        defer ctx.runtime.memory.allocator.free(name);
        if (!std.mem.eql(u8, name, "shift")) return null;
    }

    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver.dup() else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    defer receiver_object_value.free(ctx.runtime);
    const object = objectFromValue(receiver_object_value) orelse return null;
    if (object.class_id == core.class.ids.string) return error.TypeError;
    const length = if (object.flags.is_array)
        @as(usize, @intCast(object.length))
    else blk: {
        const length_value = try getValueProperty(ctx, output, global, receiver_object_value, core.atom.ids.length, null, null);
        defer length_value.free(ctx.runtime);
        break :blk try toLengthIndex(ctx, output, global, length_value);
    };

    if (length == 0) {
        try ensureLengthWritableForArrayBuiltin(ctx, object);
        const set_length = try setValueProperty(ctx, output, global, receiver_object_value, core.atom.ids.length, core.JSValue.int32(0), null, null);
        set_length.free(ctx.runtime);
        try verifyArrayLikeLengthSet(ctx, output, global, receiver_object_value, 0);
        return core.JSValue.undefinedValue();
    }

    const first = try getValueProperty(ctx, output, global, receiver_object_value, core.atom.atomFromUInt32(0), null, null);
    errdefer first.free(ctx.runtime);

    var index: usize = 1;
    while (index < length) : (index += 1) {
        const from_key = try propertyAtomFromLengthIndex(ctx.runtime, index);
        defer from_key.deinit(ctx.runtime);
        const to_key = try propertyAtomFromLengthIndex(ctx.runtime, index - 1);
        defer to_key.deinit(ctx.runtime);
        if (object.hasProperty(from_key.atom)) {
            const item = try getValueProperty(ctx, output, global, receiver_object_value, from_key.atom, null, null);
            defer item.free(ctx.runtime);
            const set_result = try setValueProperty(ctx, output, global, receiver_object_value, to_key.atom, item, null, null);
            set_result.free(ctx.runtime);
        } else {
            if (!object.deleteProperty(ctx.runtime, to_key.atom)) return error.TypeError;
        }
    }

    const tail_key = try propertyAtomFromLengthIndex(ctx.runtime, length - 1);
    defer tail_key.deinit(ctx.runtime);
    if (!object.deleteProperty(ctx.runtime, tail_key.atom)) return error.TypeError;
    try ensureLengthWritableForArrayBuiltin(ctx, object);
    const set_length = try setValueProperty(ctx, output, global, receiver_object_value, core.atom.ids.length, lengthIndexValue(length - 1), null, null);
    set_length.free(ctx.runtime);
    try verifyArrayLikeLengthSet(ctx, output, global, receiver_object_value, length - 1);
    return first;
}

pub fn qjsArrayUnshiftCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    if (!isArrayPrototypeRecord(function_object, @intFromEnum(builtins.array.PrototypeMethod.unshift))) {
        const name = try call_mod.nativeFunctionNameForVm(ctx.runtime, function_object);
        defer ctx.runtime.memory.allocator.free(name);
        if (!std.mem.eql(u8, name, "unshift")) return null;
    }

    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver.dup() else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    defer receiver_object_value.free(ctx.runtime);
    const object = objectFromValue(receiver_object_value) orelse return null;
    if (object.class_id == core.class.ids.string) return error.TypeError;

    const length = if (object.flags.is_array)
        @as(usize, @intCast(object.length))
    else blk: {
        const length_value = try getValueProperty(ctx, output, global, receiver_object_value, core.atom.ids.length, null, null);
        defer length_value.free(ctx.runtime);
        break :blk try toLengthIndex(ctx, output, global, length_value);
    };
    const insert_count = args.len;
    const max_safe_length: usize = 9007199254740991;
    if (insert_count > max_safe_length - length) return error.TypeError;
    const new_length = length + insert_count;

    if (insert_count > 0) {
        if (length <= 100000) {
            var k = length;
            while (k > 0) {
                k -= 1;
                try unshiftMoveIndex(ctx, output, global, receiver_object_value, object, k, insert_count);
            }
        } else {
            try qjsArrayUnshiftSparseLarge(ctx, output, global, receiver_object_value, object, length, insert_count);
        }

        for (args, 0..) |item, index| {
            const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
            defer key.deinit(ctx.runtime);
            try ensureSettableForArrayBuiltin(ctx, object, key.atom);
            const set_result = try setValueProperty(ctx, output, global, receiver_object_value, key.atom, item, null, null);
            set_result.free(ctx.runtime);
        }
    }

    try ensureLengthWritableForArrayBuiltin(ctx, object);
    const set_length = try setValueProperty(ctx, output, global, receiver_object_value, core.atom.ids.length, lengthIndexValue(new_length), null, null);
    set_length.free(ctx.runtime);
    try verifyArrayLikeLengthSet(ctx, output, global, receiver_object_value, new_length);
    return lengthIndexValue(new_length);
}

pub fn qjsArrayReverseCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    if (!isArrayPrototypeRecord(function_object, @intFromEnum(builtins.array.PrototypeMethod.reverse))) {
        const name = try call_mod.nativeFunctionNameForVm(ctx.runtime, function_object);
        defer ctx.runtime.memory.allocator.free(name);
        if (!std.mem.eql(u8, name, "reverse")) return null;
    }
    if (receiver.isNull() or receiver.isUndefined()) return error.TypeError;

    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver.dup() else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    errdefer receiver_object_value.free(ctx.runtime);
    const object = objectFromValue(receiver_object_value) orelse return error.TypeError;
    const is_typed_method = isTypedArrayPrototypeMethod(ctx.runtime, function_object);
    if (is_typed_method and !builtins.buffer.isTypedArrayObject(object)) return error.TypeError;
    if (is_typed_method) {
        if (try builtins.buffer.typedArrayDetached(object) or try builtins.buffer.typedArrayOutOfBounds(object)) return error.TypeError;
        try builtins.buffer.typedArrayRejectImmutableBuffer(ctx.runtime, object);
        const length = @as(usize, @intCast(try builtins.buffer.typedArrayLength(ctx.runtime, object)));
        var lower: usize = 0;
        while (lower < length / 2) : (lower += 1) {
            const upper = length - lower - 1;
            const lower_value = try builtins.buffer.typedArrayGetIndex(ctx.runtime, object, @intCast(lower));
            defer lower_value.free(ctx.runtime);
            const upper_value = try builtins.buffer.typedArrayGetIndex(ctx.runtime, object, @intCast(upper));
            defer upper_value.free(ctx.runtime);
            _ = try builtins.buffer.typedArraySetIndex(ctx.runtime, object, @intCast(lower), upper_value);
            _ = try builtins.buffer.typedArraySetIndex(ctx.runtime, object, @intCast(upper), lower_value);
        }
        return receiver_object_value;
    }
    const length = if (builtins.buffer.isTypedArrayObject(object))
        try arrayMethodTypedArrayLength(ctx.runtime, object, false)
    else if (object.flags.is_array)
        @as(usize, @intCast(object.length))
    else if (!receiver.isObject() and !receiver.isString())
        @as(usize, 0)
    else blk: {
        const length_value = try getValueProperty(ctx, output, global, receiver_object_value, core.atom.ids.length, caller_function, caller_frame);
        defer length_value.free(ctx.runtime);
        break :blk try toLengthIndex(ctx, output, global, length_value);
    };

    var lower: usize = 0;
    while (lower < length / 2) : (lower += 1) {
        const upper = length - lower - 1;
        const lower_key = try propertyAtomFromLengthIndex(ctx.runtime, lower);
        defer lower_key.deinit(ctx.runtime);
        const upper_key = try propertyAtomFromLengthIndex(ctx.runtime, upper);
        defer upper_key.deinit(ctx.runtime);

        const lower_exists = try hasValueProperty(ctx, output, global, receiver_object_value, object, lower_key.atom, null, null);
        var lower_value: core.JSValue = core.JSValue.undefinedValue();
        var have_lower_value = false;
        defer if (have_lower_value) lower_value.free(ctx.runtime);
        if (lower_exists) {
            lower_value = try getValueProperty(ctx, output, global, receiver_object_value, lower_key.atom, caller_function, caller_frame);
            have_lower_value = true;
        }

        const upper_exists = try hasValueProperty(ctx, output, global, receiver_object_value, object, upper_key.atom, null, null);
        var upper_value: core.JSValue = core.JSValue.undefinedValue();
        var have_upper_value = false;
        defer if (have_upper_value) upper_value.free(ctx.runtime);
        if (upper_exists) {
            upper_value = try getValueProperty(ctx, output, global, receiver_object_value, upper_key.atom, caller_function, caller_frame);
            have_upper_value = true;
        }

        if (lower_exists and upper_exists) {
            const set_lower = try setValueProperty(ctx, output, global, receiver_object_value, lower_key.atom, upper_value, caller_function, caller_frame);
            set_lower.free(ctx.runtime);
            const set_upper = try setValueProperty(ctx, output, global, receiver_object_value, upper_key.atom, lower_value, caller_function, caller_frame);
            set_upper.free(ctx.runtime);
        } else if (!lower_exists and upper_exists) {
            const set_lower = try setValueProperty(ctx, output, global, receiver_object_value, lower_key.atom, upper_value, caller_function, caller_frame);
            set_lower.free(ctx.runtime);
            try deleteValuePropertyOrThrow(ctx, output, global, receiver_object_value, object, upper_key.atom);
        } else if (lower_exists and !upper_exists) {
            try deleteValuePropertyOrThrow(ctx, output, global, receiver_object_value, object, lower_key.atom);
            const set_upper = try setValueProperty(ctx, output, global, receiver_object_value, upper_key.atom, lower_value, caller_function, caller_frame);
            set_upper.free(ctx.runtime);
        }
    }

    return receiver_object_value;
}

pub fn qjsArrayUnshiftSparseLarge(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    length: usize,
    insert_count: usize,
) !void {
    const keys = try object.ownKeys(ctx.runtime);
    defer core.Object.freeKeys(ctx.runtime, keys);
    var candidates = std.ArrayList(usize).empty;
    defer candidates.deinit(ctx.runtime.memory.allocator);
    for (keys) |key| {
        const index = propertyIndexFromLengthKey(ctx.runtime, key) orelse continue;
        if (index < length) try candidates.append(ctx.runtime.memory.allocator, index);
        if (index >= insert_count and index - insert_count < length) {
            try candidates.append(ctx.runtime.memory.allocator, index - insert_count);
        }
    }
    std.mem.sort(usize, candidates.items, {}, struct {
        fn lessThan(_: void, a: usize, b: usize) bool {
            return a > b;
        }
    }.lessThan);
    var previous: ?usize = null;
    for (candidates.items) |index| {
        if (previous != null and previous.? == index) continue;
        previous = index;
        try unshiftMoveIndex(ctx, output, global, receiver, object, index, insert_count);
    }
}

pub fn unshiftMoveIndex(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    from_index: usize,
    insert_count: usize,
) !void {
    const from_key = try propertyAtomFromLengthIndex(ctx.runtime, from_index);
    defer from_key.deinit(ctx.runtime);
    const to_key = try propertyAtomFromLengthIndex(ctx.runtime, from_index + insert_count);
    defer to_key.deinit(ctx.runtime);
    if (object.hasProperty(from_key.atom)) {
        const item = try getValueProperty(ctx, output, global, receiver, from_key.atom, null, null);
        defer item.free(ctx.runtime);
        try ensureSettableForArrayBuiltin(ctx, object, to_key.atom);
        const set_result = try setValueProperty(ctx, output, global, receiver, to_key.atom, item, null, null);
        set_result.free(ctx.runtime);
    } else {
        if (!object.deleteProperty(ctx.runtime, to_key.atom)) return error.TypeError;
    }
}

pub fn ensureSettableForArrayBuiltin(ctx: *core.JSContext, object: *core.Object, atom_id: core.Atom) !void {
    if (try findPropertyDescriptor(object, atom_id)) |desc| {
        defer desc.destroy(ctx.runtime);
        if (desc.kind == .data and desc.writable == false) return error.TypeError;
        if (desc.kind == .accessor and desc.setter.isUndefined()) return error.TypeError;
    }
}

pub fn ensureLengthWritableForArrayBuiltin(ctx: *core.JSContext, object: *core.Object) !void {
    if (object.getOwnProperty(core.atom.ids.length)) |desc| {
        defer desc.destroy(ctx.runtime);
        if (desc.kind == .data and desc.writable == false) return error.TypeError;
        if (desc.kind == .accessor and desc.setter.isUndefined()) return error.TypeError;
    }
}

pub fn verifyArrayLikeLengthSet(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    expected: usize,
) !void {
    const length_value = try getValueProperty(ctx, output, global, receiver, core.atom.ids.length, null, null);
    defer length_value.free(ctx.runtime);
    const actual = try toLengthIndex(ctx, output, global, length_value);
    if (actual != expected) return error.TypeError;
}

pub fn arrayRelativeIndex(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, arg_index: usize, length: usize, default_value: usize) !usize {
    if (args.len <= arg_index) return default_value;
    const primitive = try toPrimitiveForNumber(ctx, output, global, args[arg_index]);
    defer primitive.free(ctx.runtime);
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    defer number_value.free(ctx.runtime);
    const n = value_ops.numberValue(number_value) orelse std.math.nan(f64);
    return arrayRelativeIndexFromNumber(length, n, default_value);
}

pub fn arrayRelativeIndexFromNumber(length: usize, n: f64, default_value: usize) usize {
    _ = default_value;
    if (std.math.isNan(n)) return 0;
    if (std.math.isNegativeInf(n)) return 0;
    const len_float = @as(f64, @floatFromInt(length));
    if (std.math.isPositiveInf(n)) return length;
    const integer = @trunc(n);
    if (integer < 0) {
        const offset = len_float + integer;
        if (offset <= 0) return 0;
        return @intFromFloat(offset);
    }
    if (integer >= len_float) return length;
    return @intFromFloat(integer);
}

pub fn toIntegerOrInfinityForArrayMethod(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue) !f64 {
    const primitive = try toPrimitiveForNumber(ctx, output, global, value);
    defer primitive.free(ctx.runtime);
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    defer number_value.free(ctx.runtime);
    return value_ops.numberValue(number_value) orelse std.math.nan(f64);
}

pub fn arraySpeciesCreate(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    original: core.JSValue,
    length: usize,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const object = objectFromValue(original) orelse {
        if (length > core.array.max_array_length) return error.RangeError;
        const out = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
        out.length = @intCast(length);
        return out.value();
    };
    if (try defaultArraySpeciesCreate(ctx.runtime, global, object, length)) |value| return value;
    var constructor_value = if (try arraySpeciesOriginalIsArray(object))
        try getValueProperty(ctx, output, global, original, core.atom.ids.constructor, caller_function, caller_frame)
    else
        core.JSValue.undefinedValue();
    defer constructor_value.free(ctx.runtime);
    if (constructor_value.isUndefined()) {
        if (length > core.array.max_array_length) return error.RangeError;
        const out = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
        out.length = @intCast(length);
        return out.value();
    }
    if (!constructor_value.isObject()) return error.TypeError;
    if (try arraySpeciesConstructorIsForeignArray(ctx.runtime, global, constructor_value)) {
        if (length > core.array.max_array_length) return error.RangeError;
        const out = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
        out.length = @intCast(length);
        return out.value();
    }
    const species_atom = core.atom.predefinedId("Symbol.species", .symbol) orelse return error.TypeError;
    var species_value = try getValueProperty(ctx, output, global, constructor_value, species_atom, caller_function, caller_frame);
    defer species_value.free(ctx.runtime);
    if (species_value.isNull()) {
        species_value.free(ctx.runtime);
        species_value = core.JSValue.undefinedValue();
    }
    if (species_value.isUndefined()) {
        if (length > core.array.max_array_length) return error.RangeError;
        const out = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
        out.length = @intCast(length);
        return out.value();
    }
    const length_value = lengthIndexValue(length);
    return constructValueOrBytecode(ctx, output, global, species_value, &.{length_value}, caller_function, caller_frame);
}

pub fn defaultArraySpeciesCreate(rt: *core.JSRuntime, global: *core.Object, original: *core.Object, length: usize) !?core.JSValue {
    if (!original.flags.is_array or original.proxyTarget() != null) return null;
    if (original.getOwnProperty(core.atom.ids.constructor)) |desc| {
        desc.destroy(rt);
        return null;
    }

    const array_proto = arrayPrototypeFromGlobal(rt, global) orelse return null;
    if (original.getPrototype() != array_proto) return null;
    const array_ctor = arrayConstructorFromGlobal(rt, global) orelse return null;
    if (array_ctor.arrayBuiltinMarker() != .constructor) return null;

    const proto_constructor = array_proto.getOwnProperty(core.atom.ids.constructor) orelse return null;
    defer proto_constructor.destroy(rt);
    if (proto_constructor.kind != .data or !proto_constructor.value_present or
        !sameObjectIdentity(proto_constructor.value, array_ctor.value()))
    {
        return null;
    }

    const species_atom = core.atom.predefinedId("Symbol.species", .symbol) orelse return null;
    const species = array_ctor.getOwnProperty(species_atom) orelse return null;
    defer species.destroy(rt);
    if (species.kind != .accessor or !species.getter_present or !species.setter_present or
        !species.setter.isUndefined())
    {
        return null;
    }
    const getter = objectFromValue(species.getter) orelse return null;
    if (getter.arrayBuiltinMarker() != .species_getter) return null;

    if (length > core.array.max_array_length) return error.RangeError;

    const out = try core.Object.createArray(rt, array_proto);
    out.length = @intCast(length);
    return out.value();
}

pub fn arrayConstructorFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object {
    const value = global.getOwnDataPropertyValue(core.atom.predefinedId("Array", .string).?) orelse return null;
    defer value.free(rt);
    return objectFromValue(value);
}

pub fn arraySpeciesOriginalIsArray(object: *core.Object) !bool {
    if (object.flags.is_array) return true;
    if (!object.flags.is_proxy) return false;
    const target_value = object.proxyTarget() orelse return error.TypeError;
    const handler_value = object.proxyHandler() orelse return error.TypeError;
    _ = handler_value;
    const target = objectFromValue(target_value) orelse return false;
    return arraySpeciesOriginalIsArray(target);
}

pub fn arraySpeciesConstructorIsForeignArray(rt: *core.JSRuntime, global: *core.Object, constructor_value: core.JSValue) !bool {
    const constructor_object = objectFromValue(constructor_value) orelse return false;
    if (callableObjectFromValue(constructor_value) == null) return false;
    const name = try call_mod.nativeFunctionNameForVm(rt, constructor_object);
    defer rt.memory.allocator.free(name);
    if (!std.mem.eql(u8, name, "Array")) return false;
    const current_key = try rt.internAtom("Array");
    defer rt.atoms.free(current_key);
    const current_array = global.getProperty(current_key);
    defer current_array.free(rt);
    return !sameObjectIdentity(constructor_value, current_array);
}

pub fn qjsArrayFromCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    if (typedArrayStaticMethodId(ctx.runtime, function_object)) |method_id| {
        if (method_id != 1) return null;
        return try qjsTypedArrayFromStaticCall(ctx, output, global, constructor_value, args, caller_function, caller_frame);
    }
    if (!isArrayStaticRecord(function_object, @intFromEnum(builtins.array.StaticMethod.from))) {
        const name = try call_mod.nativeFunctionNameForVm(ctx.runtime, function_object);
        defer ctx.runtime.memory.allocator.free(name);
        if (!std.mem.eql(u8, name, "from")) return null;
    }
    if (args.len < 1 or args[0].isNull() or args[0].isUndefined()) return error.TypeError;
    const map_fn: ?core.JSValue = if (args.len >= 2 and !args[1].isUndefined()) blk: {
        if (!isCallableValue(args[1])) return error.TypeError;
        break :blk args[1];
    } else null;
    const this_arg = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();

    const source = args[0];
    if (typedArrayConstructorObject(constructor_value) != null) {
        if (objectFromValue(source)) |source_object| {
            if (source_object.flags.is_array) {
                return try qjsArrayFromArrayLike(ctx, output, global, constructor_value, source_object.value(), source_object.length, map_fn, this_arg, caller_function, caller_frame);
            }
        }
    }
    const iterator_method = try getIteratorMethod(ctx, output, global, source);
    defer iterator_method.free(ctx.runtime);
    if (!iterator_method.isUndefined() and !iterator_method.isNull()) {
        if (!isCallableValue(iterator_method)) return error.TypeError;
        const iterator = try callValueOrBytecode(ctx, output, global, source, iterator_method, &.{}, caller_function, caller_frame);
        defer iterator.free(ctx.runtime);
        return try qjsArrayFromIteratorLike(ctx, output, global, constructor_value, iterator, map_fn, this_arg, caller_function, caller_frame);
    }

    if (objectFromValue(source)) |source_object| {
        if (source_object.class_id == core.class.ids.generator or source_object.class_id == core.class.ids.async_generator) {
            return try qjsArrayFromIteratorLike(ctx, output, global, constructor_value, source, map_fn, this_arg, caller_function, caller_frame);
        }
        if (source_object.flags.is_array) {
            return try qjsArrayFromArrayLike(ctx, output, global, constructor_value, source_object.value(), null, map_fn, this_arg, caller_function, caller_frame);
        }
        if (source_object.class_id == core.class.ids.set or source_object.class_id == core.class.ids.map) {
            const iterator = try builtins.collection.methodCall(ctx.runtime, source_object.value(), if (source_object.class_id == core.class.ids.set) 8 else 9, &.{});
            defer iterator.free(ctx.runtime);
            return try qjsArrayFromIteratorLike(ctx, output, global, constructor_value, iterator, map_fn, this_arg, caller_function, caller_frame);
        }
        if (source_object.class_id == core.class.ids.map_iterator or source_object.class_id == core.class.ids.set_iterator) {
            return try qjsArrayFromIteratorLike(ctx, output, global, constructor_value, source, map_fn, this_arg, caller_function, caller_frame);
        }
    }

    const length_value = try getValueProperty(ctx, output, global, source, core.atom.ids.length, caller_function, caller_frame);
    defer length_value.free(ctx.runtime);
    const length = try toLengthIndex(ctx, output, global, length_value);
    if (length > @as(usize, @intCast(std.math.maxInt(u32)))) return error.RangeError;

    var out_value = if (try isConstructorForArrayOf(ctx.runtime, constructor_value))
        try constructValueOrBytecode(ctx, output, global, constructor_value, &.{core.JSValue.int32(@intCast(length))}, caller_function, caller_frame)
    else blk: {
        const out = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
        errdefer core.Object.destroyFromHeader(ctx.runtime, &out.header);
        out.length = @intCast(length);
        break :blk out.value();
    };
    errdefer out_value.free(ctx.runtime);
    const out = objectFromValue(out_value) orelse return error.TypeError;

    var index: usize = 0;
    while (index < length) : (index += 1) {
        const key = core.atom.atomFromUInt32(@intCast(index));
        var item = try getValueProperty(ctx, output, global, source, key, caller_function, caller_frame);
        defer item.free(ctx.runtime);
        if (map_fn) |mapper| {
            const mapped = try callValueOrBytecode(ctx, output, global, this_arg, mapper, &.{ item, core.JSValue.int32(@intCast(index)) }, caller_function, caller_frame);
            item.free(ctx.runtime);
            item = mapped;
        }
        try qjsCreateArrayDataOrTypedArrayElement(ctx.runtime, out, key, item);
    }
    if (!builtins.buffer.isTypedArrayObject(out)) {
        const set_result = try setValueProperty(ctx, output, global, out.value(), core.atom.ids.length, core.JSValue.int32(@intCast(length)), caller_function, caller_frame);
        set_result.free(ctx.runtime);
    }
    return out_value;
}

pub fn qjsTypedArrayFromStaticCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (!try isConstructorForArrayOf(ctx.runtime, constructor_value)) return error.TypeError;
    if (args.len < 1 or args[0].isNull() or args[0].isUndefined()) return error.TypeError;
    const map_fn: ?core.JSValue = if (args.len >= 2 and !args[1].isUndefined()) blk: {
        if (!isCallableValue(args[1])) return error.TypeError;
        break :blk args[1];
    } else null;
    const this_arg = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
    const source = args[0];

    const iterator_method = try getIteratorMethod(ctx, output, global, source);
    defer iterator_method.free(ctx.runtime);
    if (!iterator_method.isUndefined() and !iterator_method.isNull()) {
        if (!isCallableValue(iterator_method)) return error.TypeError;
        const iterator = try callValueOrBytecode(ctx, output, global, source, iterator_method, &.{}, caller_function, caller_frame);
        defer iterator.free(ctx.runtime);
        return try qjsTypedArrayFromIteratorValue(ctx, output, global, constructor_value, iterator, map_fn, this_arg, caller_function, caller_frame);
    }

    if (objectFromValue(source)) |source_object| {
        if (source_object.class_id == core.class.ids.generator or source_object.class_id == core.class.ids.async_generator) {
            return try qjsTypedArrayFromIteratorValue(ctx, output, global, constructor_value, source, map_fn, this_arg, caller_function, caller_frame);
        }
        if (source_object.class_id == core.class.ids.set or source_object.class_id == core.class.ids.map) {
            const iterator = try builtins.collection.methodCall(ctx.runtime, source_object.value(), if (source_object.class_id == core.class.ids.set) 8 else 9, &.{});
            defer iterator.free(ctx.runtime);
            return try qjsTypedArrayFromIteratorValue(ctx, output, global, constructor_value, iterator, map_fn, this_arg, caller_function, caller_frame);
        }
        if (source_object.class_id == core.class.ids.map_iterator or source_object.class_id == core.class.ids.set_iterator) {
            return try qjsTypedArrayFromIteratorValue(ctx, output, global, constructor_value, source, map_fn, this_arg, caller_function, caller_frame);
        }
    }

    return try qjsTypedArrayFromArrayLikeSource(ctx, output, global, constructor_value, source, null, map_fn, this_arg, caller_function, caller_frame);
}

pub fn qjsTypedArrayFromIteratorValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    iterator_value: core.JSValue,
    map_fn: ?core.JSValue,
    this_arg: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const values_value = try qjsCollectIteratorValues(ctx, output, global, iterator_value, caller_function, caller_frame);
    defer values_value.free(ctx.runtime);
    const values = objectFromValue(values_value) orelse return error.TypeError;
    return try qjsTypedArrayFromArrayLikeSource(
        ctx,
        output,
        global,
        constructor_value,
        values_value,
        @intCast(values.length),
        map_fn,
        this_arg,
        caller_function,
        caller_frame,
    );
}

pub fn qjsTypedArrayFromArrayLikeSource(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    source: core.JSValue,
    fixed_length: ?usize,
    map_fn: ?core.JSValue,
    this_arg: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const length = if (fixed_length) |length_value|
        length_value
    else blk: {
        const length_value = try getValueProperty(ctx, output, global, source, core.atom.ids.length, caller_function, caller_frame);
        defer length_value.free(ctx.runtime);
        break :blk try toLengthIndex(ctx, output, global, length_value);
    };
    if (length > std.math.maxInt(u32)) return error.RangeError;

    const out_value = try qjsTypedArrayCreateWithLength(ctx, output, global, constructor_value, length, caller_function, caller_frame);
    errdefer out_value.free(ctx.runtime);
    const out = objectFromValue(out_value) orelse return error.TypeError;

    var index: usize = 0;
    while (index < length) : (index += 1) {
        const key = core.atom.atomFromUInt32(@intCast(index));
        var item = try getValueProperty(ctx, output, global, source, key, caller_function, caller_frame);
        defer item.free(ctx.runtime);
        if (map_fn) |mapper| {
            const mapped = try callValueOrBytecode(ctx, output, global, this_arg, mapper, &.{ item, lengthIndexValue(index) }, caller_function, caller_frame);
            item.free(ctx.runtime);
            item = mapped;
        }
        try qjsTypedArraySetElementValue(ctx, output, global, out, index, item);
    }
    return out_value;
}

pub fn qjsArrayFromArrayLike(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    source: core.JSValue,
    fixed_length: ?usize,
    map_fn: ?core.JSValue,
    this_arg: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const out_value = if (try isConstructorForArrayOf(ctx.runtime, constructor_value)) blk: {
        if (fixed_length) |length| {
            break :blk try constructValueOrBytecode(ctx, output, global, constructor_value, &.{core.JSValue.int32(@intCast(length))}, caller_function, caller_frame);
        }
        break :blk try constructValueOrBytecode(ctx, output, global, constructor_value, &.{}, caller_function, caller_frame);
    } else (try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global))).value();
    errdefer out_value.free(ctx.runtime);
    const out = objectFromValue(out_value) orelse return error.TypeError;
    if (fixed_length) |length| {
        if (length > @as(usize, @intCast(std.math.maxInt(u32)))) return error.RangeError;
        if (out.flags.is_array) out.length = @intCast(length);
    }

    var index: usize = 0;
    while (true) : (index += 1) {
        const length = if (fixed_length) |length_value|
            length_value
        else if (objectFromValue(source)) |source_object|
            @as(usize, @intCast(source_object.length))
        else
            0;
        if (index >= length) break;
        if (index > std.math.maxInt(u32)) return error.RangeError;
        const key = core.atom.atomFromUInt32(@intCast(index));
        var item = try getValueProperty(ctx, output, global, source, key, caller_function, caller_frame);
        defer item.free(ctx.runtime);
        if (map_fn) |mapper| {
            const mapped = try callValueOrBytecode(ctx, output, global, this_arg, mapper, &.{ item, core.JSValue.int32(@intCast(index)) }, caller_function, caller_frame);
            item.free(ctx.runtime);
            item = mapped;
        }
        try qjsCreateArrayDataOrTypedArrayElement(ctx.runtime, out, key, item);
    }
    if (index > @as(usize, @intCast(std.math.maxInt(u32)))) return error.RangeError;
    if (!builtins.buffer.isTypedArrayObject(out)) {
        const set_result = try setValueProperty(ctx, output, global, out.value(), core.atom.ids.length, core.JSValue.int32(@intCast(index)), caller_function, caller_frame);
        set_result.free(ctx.runtime);
    }
    return out_value;
}

pub fn qjsArrayFromIteratorLike(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    iterator_value: core.JSValue,
    map_fn: ?core.JSValue,
    this_arg: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var out_value = if (try isConstructorForArrayOf(ctx.runtime, constructor_value))
        try constructValueOrBytecode(ctx, output, global, constructor_value, &.{}, caller_function, caller_frame)
    else
        (try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global))).value();
    errdefer out_value.free(ctx.runtime);
    const out = objectFromValue(out_value) orelse return error.TypeError;
    const iterator = objectFromValue(iterator_value) orelse return error.TypeError;
    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    const next_method = try getValueProperty(ctx, output, global, iterator.value(), next_key, caller_function, caller_frame);
    defer next_method.free(ctx.runtime);
    if (!isCallableValue(next_method)) return error.TypeError;

    var index: u32 = 0;
    while (true) : (index += 1) {
        const next = callValueOrBytecode(ctx, output, global, iterator.value(), next_method, &.{}, caller_function, caller_frame) catch |err| {
            try qjsIteratorClose(ctx, output, global, iterator.value(), caller_function, caller_frame);
            return err;
        };
        defer next.free(ctx.runtime);
        const next_object = objectFromValue(next) orelse {
            try qjsIteratorClose(ctx, output, global, iterator.value(), caller_function, caller_frame);
            return error.TypeError;
        };
        const done = getValueProperty(ctx, output, global, next_object.value(), core.atom.predefinedId("done", .string).?, caller_function, caller_frame) catch |err| {
            try qjsIteratorClose(ctx, output, global, iterator.value(), caller_function, caller_frame);
            return err;
        };
        defer done.free(ctx.runtime);
        if (done.asBool() == true) break;
        var item = getValueProperty(ctx, output, global, next_object.value(), core.atom.predefinedId("value", .string).?, caller_function, caller_frame) catch |err| {
            try qjsIteratorClose(ctx, output, global, iterator.value(), caller_function, caller_frame);
            return err;
        };
        defer item.free(ctx.runtime);
        if (map_fn) |mapper| {
            const mapped = callValueOrBytecode(ctx, output, global, this_arg, mapper, &.{ item, core.JSValue.int32(@intCast(index)) }, caller_function, caller_frame) catch |err| {
                try qjsIteratorClose(ctx, output, global, iterator.value(), caller_function, caller_frame);
                return err;
            };
            item.free(ctx.runtime);
            item = mapped;
        }
        qjsCreateArrayDataOrTypedArrayElement(ctx.runtime, out, core.atom.atomFromUInt32(index), item) catch |err| {
            try qjsIteratorClose(ctx, output, global, iterator.value(), caller_function, caller_frame);
            return err;
        };
    }
    if (!builtins.buffer.isTypedArrayObject(out)) {
        const set_result = try setValueProperty(ctx, output, global, out.value(), core.atom.ids.length, core.JSValue.int32(@intCast(index)), caller_function, caller_frame);
        set_result.free(ctx.runtime);
    }
    return out_value;
}

pub fn qjsArrayOfCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    if (typedArrayStaticMethodId(ctx.runtime, function_object)) |method_id| {
        if (method_id != 2) return null;
        return try qjsTypedArrayOfStaticCall(ctx, output, global, constructor_value, args, caller_function, caller_frame);
    }
    if (!isArrayStaticRecord(function_object, @intFromEnum(builtins.array.StaticMethod.of))) {
        const name = try call_mod.nativeFunctionNameForVm(ctx.runtime, function_object);
        defer ctx.runtime.memory.allocator.free(name);
        if (!std.mem.eql(u8, name, "of")) return null;
    }
    if (args.len > @as(usize, @intCast(std.math.maxInt(i32)))) return error.RangeError;

    const length_value = core.JSValue.int32(@intCast(args.len));
    var out_value = if (try isConstructorForArrayOf(ctx.runtime, constructor_value))
        try constructValueOrBytecode(ctx, output, global, constructor_value, &.{length_value}, caller_function, caller_frame)
    else blk: {
        const out = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
        errdefer core.Object.destroyFromHeader(ctx.runtime, &out.header);
        out.length = @intCast(args.len);
        break :blk out.value();
    };
    errdefer out_value.free(ctx.runtime);
    const out = objectFromValue(out_value) orelse return error.TypeError;

    for (args, 0..) |arg, index| {
        const key = core.atom.atomFromUInt32(@intCast(index));
        try createDataPropertyOrThrow(ctx, output, global, out.value(), out, key, arg, caller_function, caller_frame);
    }
    if (!builtins.buffer.isTypedArrayObject(out)) {
        const set_result = try setValueProperty(ctx, output, global, out.value(), core.atom.ids.length, length_value, caller_function, caller_frame);
        set_result.free(ctx.runtime);
    }
    return out_value;
}

pub fn isArrayStaticRecord(function_object: *core.Object, method_id: u32) bool {
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionId()) orelse return false;
    return native_ref.domain == .array and native_ref.id == method_id;
}

pub fn arrayPrototypeRecordId(function_object: *core.Object) ?u32 {
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionId()) orelse return null;
    if (native_ref.domain != .array) return null;
    if (builtins.array.decodePrototypeMethodId(native_ref.id) == null and
        native_ref.id != @intFromEnum(builtins.array.PrototypeMethod.to_string) and
        native_ref.id != @intFromEnum(builtins.array.PrototypeMethod.to_locale_string) and
        native_ref.id != @intFromEnum(builtins.array.PrototypeMethod.map) and
        native_ref.id != @intFromEnum(builtins.array.PrototypeMethod.for_each) and
        native_ref.id != @intFromEnum(builtins.array.PrototypeMethod.reduce_right) and
        native_ref.id != @intFromEnum(builtins.array.PrototypeMethod.copy_within) and
        native_ref.id != @intFromEnum(builtins.array.PrototypeMethod.fill) and
        native_ref.id != @intFromEnum(builtins.array.PrototypeMethod.shift) and
        native_ref.id != @intFromEnum(builtins.array.PrototypeMethod.unshift) and
        native_ref.id != @intFromEnum(builtins.array.PrototypeMethod.join) and
        native_ref.id != @intFromEnum(builtins.array.PrototypeMethod.flat) and
        native_ref.id != @intFromEnum(builtins.array.PrototypeMethod.flat_map) and
        native_ref.id != @intFromEnum(builtins.array.PrototypeMethod.to_reversed) and
        native_ref.id != @intFromEnum(builtins.array.PrototypeMethod.to_sorted) and
        native_ref.id != @intFromEnum(builtins.array.PrototypeMethod.to_spliced) and
        native_ref.id != @intFromEnum(builtins.array.PrototypeMethod.with_) and
        native_ref.id != @intFromEnum(builtins.array.PrototypeMethod.find) and
        native_ref.id != @intFromEnum(builtins.array.PrototypeMethod.find_index) and
        native_ref.id != @intFromEnum(builtins.array.PrototypeMethod.find_last) and
        native_ref.id != @intFromEnum(builtins.array.PrototypeMethod.find_last_index))
    {
        return null;
    }
    return native_ref.id;
}

pub fn isArrayPrototypeRecord(function_object: *core.Object, method_id: u32) bool {
    return arrayPrototypeRecordId(function_object) == method_id;
}

pub fn qjsTypedArrayOfStaticCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (!try isConstructorForArrayOf(ctx.runtime, constructor_value)) return error.TypeError;
    if (args.len > std.math.maxInt(u32)) return error.RangeError;

    const out_value = try qjsTypedArrayCreateWithLength(ctx, output, global, constructor_value, args.len, caller_function, caller_frame);
    errdefer out_value.free(ctx.runtime);
    const out = objectFromValue(out_value) orelse return error.TypeError;
    for (args, 0..) |arg, index| {
        try qjsTypedArraySetElementValue(ctx, output, global, out, index, arg);
    }
    return out_value;
}

pub fn qjsCreateArrayDataOrTypedArrayElement(
    rt: *core.JSRuntime,
    object: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
) !void {
    if (builtins.buffer.isTypedArrayObject(object)) {
        const index = core.array.arrayIndexFromAtom(&rt.atoms, atom_id) orelse return error.TypeError;
        const ok = try builtins.buffer.typedArraySetIndex(rt, object, index, value);
        if (!ok) return error.TypeError;
        return;
    }
    if (rt.atoms.kind(atom_id) == .private and object.hasOwnProperty(atom_id)) return error.TypeError;
    if (core.array.arrayIndexFromAtom(&rt.atoms, atom_id)) |index| {
        if (try object.appendDenseArrayIndex(rt, index, atom_id, value)) return;
    }
    object.defineOwnProperty(rt, atom_id, core.Descriptor.data(value, true, true, true)) catch |err| switch (err) {
        error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
        else => return err,
    };
}

pub fn typedArrayConstructorObject(value: core.JSValue) ?*core.Object {
    const object = objectFromValue(value) orelse return null;
    if (object.typedArrayElementSize() == 0 or object.typedArrayKind() == 0) return null;
    return object;
}

pub fn isConstructorForArrayOf(rt: *core.JSRuntime, value: core.JSValue) !bool {
    if (functionBytecodeFromValue(value)) |fb| {
        return !fb.is_arrow_function and fb.has_prototype and fb.func_kind != .generator and fb.func_kind != .async_generator;
    }
    if (functionObjectFromValue(value)) |function_object| {
        const function_value = function_object.functionBytecodeSlot().* orelse return false;
        const fb = functionBytecodeFromValue(function_value) orelse return false;
        return !fb.is_arrow_function and fb.has_prototype and fb.func_kind != .generator and fb.func_kind != .async_generator;
    }
    const object = callableObjectFromValue(value) orelse return false;
    if (object.class_id == core.class.ids.bound_function) {
        const target = object.boundTarget() orelse return false;
        return isConstructorForArrayOf(rt, target);
    }
    if (object.class_id == core.class.ids.c_function) {
        const native_name = try call_mod.nativeFunctionNameForVm(rt, object);
        defer rt.memory.allocator.free(native_name);
        return isBuiltinConstructorName(native_name);
    }
    return object.class_id == core.class.ids.c_closure;
}

pub fn qjsArrayMapCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
) !?core.JSValue {
    if (args.len != 1 or !isCallableValue(args[0])) return null;
    const object = property_ops.expectObject(receiver) catch return null;
    if (!object.flags.is_array) return null;
    const function_object = callableObjectFromValue(func) orelse return null;
    if (!isArrayPrototypeRecord(function_object, @intFromEnum(builtins.array.PrototypeMethod.map))) {
        const name = try call_mod.nativeFunctionNameForVm(ctx.runtime, function_object);
        defer ctx.runtime.memory.allocator.free(name);
        if (!std.mem.eql(u8, name, "map")) return null;
    }

    const mapped = try core.Object.createArray(ctx.runtime, null);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &mapped.header);
    var index: u32 = 0;
    while (index < object.length) : (index += 1) {
        const item = object.getProperty(core.atom.atomFromUInt32(index));
        defer item.free(ctx.runtime);
        const mapped_value = try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), args[0], &.{item}, null, null);
        defer mapped_value.free(ctx.runtime);
        try mapped.defineOwnProperty(ctx.runtime, core.atom.atomFromUInt32(index), core.Descriptor.data(mapped_value, true, true, true));
    }
    return mapped.value();
}

pub const ArraySortEntry = struct {
    value: core.JSValue,
    order: usize,
};

pub fn qjsArraySortCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    if (!isArrayPrototypeRecord(function_object, @intFromEnum(builtins.array.PrototypeMethod.sort))) {
        const name = try call_mod.nativeFunctionNameForVm(ctx.runtime, function_object);
        defer ctx.runtime.memory.allocator.free(name);
        if (!std.mem.eql(u8, name, "sort")) return null;
    }
    const comparator = if (args.len >= 1 and !args[0].isUndefined()) args[0] else core.JSValue.undefinedValue();
    if (!comparator.isUndefined() and !isCallableValue(comparator)) return error.TypeError;

    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver.dup() else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    errdefer receiver_object_value.free(ctx.runtime);
    const object = objectFromValue(receiver_object_value) orelse return error.TypeError;

    const is_typed_method = isTypedArrayPrototypeMethod(ctx.runtime, function_object);
    const is_typed_array = builtins.buffer.isTypedArrayObject(object);
    if (is_typed_method and !is_typed_array) return error.TypeError;
    if (is_typed_method) {
        if (try builtins.buffer.typedArrayDetached(object) or try builtins.buffer.typedArrayOutOfBounds(object)) return error.TypeError;
        try builtins.buffer.typedArrayRejectImmutableBuffer(ctx.runtime, object);
    }
    const length = if (is_typed_array)
        try arrayMethodTypedArrayLength(ctx.runtime, object, is_typed_method)
    else if (object.flags.is_array)
        @as(usize, @intCast(object.length))
    else if (!receiver.isObject() and !receiver.isString())
        @as(usize, 0)
    else blk: {
        const length_value = try getValueProperty(ctx, output, global, receiver_object_value, core.atom.ids.length, caller_function, caller_frame);
        defer length_value.free(ctx.runtime);
        break :blk try toLengthIndex(ctx, output, global, length_value);
    };

    var entries = std.ArrayList(ArraySortEntry).empty;
    defer {
        for (entries.items) |entry| entry.value.free(ctx.runtime);
        entries.deinit(ctx.runtime.memory.allocator);
    }

    var undefined_count: usize = 0;
    var index: usize = 0;
    while (index < length) : (index += 1) {
        const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
        defer key.deinit(ctx.runtime);
        if (!try hasValueProperty(ctx, output, global, receiver_object_value, object, key.atom, null, null)) continue;
        const value = try getValueProperty(ctx, output, global, receiver_object_value, key.atom, caller_function, caller_frame);
        if (value.isUndefined()) {
            value.free(ctx.runtime);
            undefined_count += 1;
            continue;
        }
        var value_owned = true;
        errdefer if (value_owned) value.free(ctx.runtime);
        try entries.append(ctx.runtime.memory.allocator, .{ .value = value, .order = index });
        value_owned = false;
    }

    try stableArraySortEntries(ctx, output, global, is_typed_method, comparator, entries.items, caller_function, caller_frame);

    index = 0;
    for (entries.items, 0..) |entry, sorted_index| {
        const key = try propertyAtomFromLengthIndex(ctx.runtime, sorted_index);
        defer key.deinit(ctx.runtime);
        const result = try setValueProperty(ctx, output, global, receiver_object_value, key.atom, entry.value, caller_function, caller_frame);
        result.free(ctx.runtime);
        index += 1;
    }
    while (index < entries.items.len + undefined_count) : (index += 1) {
        const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
        defer key.deinit(ctx.runtime);
        const result = try setValueProperty(ctx, output, global, receiver_object_value, key.atom, core.JSValue.undefinedValue(), caller_function, caller_frame);
        result.free(ctx.runtime);
    }
    while (index < length) : (index += 1) {
        const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
        defer key.deinit(ctx.runtime);
        try deleteValuePropertyOrThrow(ctx, output, global, receiver_object_value, object, key.atom);
    }
    return receiver_object_value;
}

pub fn arraySortCompare(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    comparator: core.JSValue,
    lhs: ArraySortEntry,
    rhs: ArraySortEntry,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !i32 {
    const result = try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), comparator, &.{ lhs.value, rhs.value }, caller_function, caller_frame);
    defer result.free(ctx.runtime);
    const number_value = try toNumberForDateMethod(ctx, output, global, result, caller_function, caller_frame);
    defer number_value.free(ctx.runtime);
    const number = value_ops.numberValue(number_value) orelse std.math.nan(f64);
    if (std.math.isNan(number) or number == 0) {
        if (lhs.order < rhs.order) return -1;
        if (lhs.order > rhs.order) return 1;
        return 0;
    }
    return if (number < 0) -1 else 1;
}

pub fn stableArraySortEntries(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    typed_numeric_default: bool,
    comparator: core.JSValue,
    entries: []ArraySortEntry,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    if (entries.len < 2) return;
    const temp = try ctx.runtime.memory.allocator.alloc(ArraySortEntry, entries.len);
    defer ctx.runtime.memory.allocator.free(temp);

    var width: usize = 1;
    while (width < entries.len) : (width *= 2) {
        var start: usize = 0;
        while (start < entries.len) : (start += width * 2) {
            const mid = @min(start + width, entries.len);
            const end = @min(start + width * 2, entries.len);
            var left = start;
            var right = mid;
            var out_index = start;
            while (left < mid and right < end) : (out_index += 1) {
                if (try arrayByCopySortCompare(ctx, output, global, typed_numeric_default, comparator, entries[right], entries[left], caller_function, caller_frame) < 0) {
                    temp[out_index] = entries[right];
                    right += 1;
                } else {
                    temp[out_index] = entries[left];
                    left += 1;
                }
            }
            while (left < mid) : ({
                left += 1;
                out_index += 1;
            }) {
                temp[out_index] = entries[left];
            }
            while (right < end) : ({
                right += 1;
                out_index += 1;
            }) {
                temp[out_index] = entries[right];
            }
            @memcpy(entries[start..end], temp[start..end]);
        }
    }
}

pub fn qjsArrayByCopyCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    const mode: enum { to_reversed, to_sorted, to_spliced, with_ } = if (arrayPrototypeRecordId(function_object)) |record_id|
        switch (record_id) {
            @intFromEnum(builtins.array.PrototypeMethod.to_reversed) => .to_reversed,
            @intFromEnum(builtins.array.PrototypeMethod.to_sorted) => .to_sorted,
            @intFromEnum(builtins.array.PrototypeMethod.to_spliced) => .to_spliced,
            @intFromEnum(builtins.array.PrototypeMethod.with_) => .with_,
            else => return null,
        }
    else blk: {
        const name = try call_mod.nativeFunctionNameForVm(ctx.runtime, function_object);
        defer ctx.runtime.memory.allocator.free(name);
        break :blk if (std.mem.eql(u8, name, "toReversed"))
            .to_reversed
        else if (std.mem.eql(u8, name, "toSorted"))
            .to_sorted
        else if (std.mem.eql(u8, name, "toSpliced"))
            .to_spliced
        else if (std.mem.eql(u8, name, "with"))
            .with_
        else
            return null;
    };

    if (mode == .to_sorted and args.len >= 1 and !args[0].isUndefined() and !isCallableValue(args[0])) {
        return error.TypeError;
    }

    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver.dup() else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    defer receiver_object_value.free(ctx.runtime);
    const object = objectFromValue(receiver_object_value) orelse return null;
    if (object.class_id == core.class.ids.string) return null;
    const is_typed_method = isTypedArrayPrototypeMethod(ctx.runtime, function_object);
    if (is_typed_method and !builtins.buffer.isTypedArrayObject(object)) return error.TypeError;
    if (is_typed_method) {
        const name = switch (mode) {
            .to_reversed => "toReversed",
            .to_sorted => "toSorted",
            .to_spliced => "toSpliced",
            .with_ => "with",
        };
        if (try qjsTypedArrayByCopyCall(ctx, output, global, object, name, args, caller_function, caller_frame)) |value| return value;
    }

    const length = if (object.flags.is_array)
        @as(usize, @intCast(object.length))
    else blk: {
        const length_value = try getValueProperty(ctx, output, global, receiver_object_value, core.atom.ids.length, caller_function, caller_frame);
        defer length_value.free(ctx.runtime);
        break :blk try toLengthIndex(ctx, output, global, length_value);
    };
    const is_to_spliced = mode == .to_spliced;
    if (!is_to_spliced and length > core.array.max_array_length) return error.RangeError;

    if (mode == .to_reversed) {
        const out = try createArrayByCopyOutput(ctx.runtime, global, length);
        errdefer out.value().free(ctx.runtime);
        var index: usize = 0;
        while (index < length) : (index += 1) {
            const from_key = try propertyAtomFromLengthIndex(ctx.runtime, length - index - 1);
            defer from_key.deinit(ctx.runtime);
            const item = try getValueProperty(ctx, output, global, receiver_object_value, from_key.atom, caller_function, caller_frame);
            defer item.free(ctx.runtime);
            try defineArrayByCopyElement(ctx.runtime, out, index, item);
        }
        return out.value();
    }

    if (mode == .to_sorted) {
        const comparator = if (args.len >= 1 and !args[0].isUndefined()) args[0] else core.JSValue.undefinedValue();
        const out = try createArrayByCopyOutput(ctx.runtime, global, length);
        errdefer out.value().free(ctx.runtime);
        var entries = std.ArrayList(ArraySortEntry).empty;
        defer {
            for (entries.items) |entry| entry.value.free(ctx.runtime);
            entries.deinit(ctx.runtime.memory.allocator);
        }
        var undefined_count: usize = 0;
        var index: usize = 0;
        while (index < length) : (index += 1) {
            const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
            defer key.deinit(ctx.runtime);
            const item = try getValueProperty(ctx, output, global, receiver_object_value, key.atom, caller_function, caller_frame);
            if (item.isUndefined()) {
                item.free(ctx.runtime);
                undefined_count += 1;
            } else {
                var item_owned = true;
                errdefer if (item_owned) item.free(ctx.runtime);
                try entries.append(ctx.runtime.memory.allocator, .{ .value = item, .order = @intCast(index) });
                item_owned = false;
            }
        }
        try stableArraySortEntries(ctx, output, global, false, comparator, entries.items, caller_function, caller_frame);
        for (entries.items, 0..) |entry, sorted_index| {
            try defineArrayByCopyElement(ctx.runtime, out, sorted_index, entry.value);
        }
        index = entries.items.len;
        while (index < entries.items.len + undefined_count) : (index += 1) {
            try defineArrayByCopyElement(ctx.runtime, out, index, core.JSValue.undefinedValue());
        }
        return out.value();
    }

    if (mode == .with_) {
        const relative_index = try toIntegerOrInfinityForArrayByCopy(ctx, output, global, if (args.len >= 1) args[0] else core.JSValue.undefinedValue());
        const actual_index = if (relative_index < 0) @as(f64, @floatFromInt(length)) + relative_index else relative_index;
        if (actual_index < 0 or actual_index >= @as(f64, @floatFromInt(length)) or !std.math.isFinite(actual_index)) return error.RangeError;
        const replace_index: usize = @intFromFloat(actual_index);
        const replacement = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
        const out = try createArrayByCopyOutput(ctx.runtime, global, length);
        errdefer out.value().free(ctx.runtime);
        var index: usize = 0;
        while (index < length) : (index += 1) {
            if (index == replace_index) {
                try defineArrayByCopyElement(ctx.runtime, out, index, replacement);
                continue;
            }
            const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
            defer key.deinit(ctx.runtime);
            const item = try getValueProperty(ctx, output, global, receiver_object_value, key.atom, caller_function, caller_frame);
            defer item.free(ctx.runtime);
            try defineArrayByCopyElement(ctx.runtime, out, index, item);
        }
        return out.value();
    }

    const actual_start = if (args.len >= 1) try arrayRelativeIndex(ctx, output, global, args, 0, length, 0) else 0;
    const actual_delete_count = if (args.len == 0)
        @as(usize, 0)
    else if (args.len == 1)
        length - actual_start
    else blk: {
        const delete_count_number = try toIntegerOrInfinityForArrayByCopy(ctx, output, global, args[1]);
        if (std.math.isNan(delete_count_number) or delete_count_number <= 0) break :blk @as(usize, 0);
        const remaining = length - actual_start;
        if (std.math.isPositiveInf(delete_count_number) or delete_count_number >= @as(f64, @floatFromInt(remaining))) break :blk remaining;
        break :blk @as(usize, @intFromFloat(@trunc(delete_count_number)));
    };
    const insert_count = if (args.len > 2) args.len - 2 else 0;
    const kept_length = length - actual_delete_count;
    const max_safe_length: usize = 9007199254740991;
    if (insert_count > max_safe_length - kept_length) return error.TypeError;
    const new_length = kept_length + insert_count;
    if (new_length > core.array.max_array_length) return error.RangeError;
    const out = try createArrayByCopyOutput(ctx.runtime, global, new_length);
    errdefer out.value().free(ctx.runtime);
    var write_index: usize = 0;
    while (write_index < actual_start) : (write_index += 1) {
        const key = try propertyAtomFromLengthIndex(ctx.runtime, write_index);
        defer key.deinit(ctx.runtime);
        const item = try getValueProperty(ctx, output, global, receiver_object_value, key.atom, caller_function, caller_frame);
        defer item.free(ctx.runtime);
        try defineArrayByCopyElement(ctx.runtime, out, write_index, item);
    }
    if (args.len > 2) {
        for (args[2..], 0..) |item, item_index| {
            try defineArrayByCopyElement(ctx.runtime, out, actual_start + item_index, item);
        }
    }
    write_index = actual_start + insert_count;
    var read_index = actual_start + actual_delete_count;
    while (read_index < length) : ({
        read_index += 1;
        write_index += 1;
    }) {
        const key = try propertyAtomFromLengthIndex(ctx.runtime, read_index);
        defer key.deinit(ctx.runtime);
        const item = try getValueProperty(ctx, output, global, receiver_object_value, key.atom, caller_function, caller_frame);
        defer item.free(ctx.runtime);
        try defineArrayByCopyElement(ctx.runtime, out, write_index, item);
    }
    return out.value();
}

pub fn qjsTypedArrayByCopyCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    name: []const u8,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (!builtins.buffer.isTypedArrayObject(object)) return null;
    if (try builtins.buffer.typedArrayDetached(object)) return error.TypeError;
    if (try builtins.buffer.typedArrayOutOfBounds(object)) return error.TypeError;

    const length = @as(usize, @intCast(try builtins.buffer.typedArrayLength(ctx.runtime, object)));

    if (std.mem.eql(u8, name, "toReversed")) {
        const out_value = try qjsTypedArrayCreateSameType(ctx, output, global, object, length, caller_function, caller_frame);
        errdefer out_value.free(ctx.runtime);
        const out = objectFromValue(out_value) orelse return error.TypeError;
        var index: usize = 0;
        while (index < length) : (index += 1) {
            const item = try builtins.buffer.typedArrayGetIndex(ctx.runtime, object, @intCast(length - index - 1));
            defer item.free(ctx.runtime);
            _ = try builtins.buffer.typedArraySetIndex(ctx.runtime, out, @intCast(index), item);
        }
        return out_value;
    }

    if (std.mem.eql(u8, name, "toSorted")) {
        const comparator = if (args.len >= 1 and !args[0].isUndefined()) args[0] else core.JSValue.undefinedValue();
        var entries = std.ArrayList(ArraySortEntry).empty;
        defer {
            for (entries.items) |entry| entry.value.free(ctx.runtime);
            entries.deinit(ctx.runtime.memory.allocator);
        }

        var index: usize = 0;
        while (index < length) : (index += 1) {
            const item = try builtins.buffer.typedArrayGetIndex(ctx.runtime, object, @intCast(index));
            var item_owned = true;
            errdefer if (item_owned) item.free(ctx.runtime);
            try entries.append(ctx.runtime.memory.allocator, .{ .value = item, .order = @intCast(index) });
            item_owned = false;
        }
        try stableArraySortEntries(ctx, output, global, true, comparator, entries.items, caller_function, caller_frame);

        const out_value = try qjsTypedArrayCreateSameType(ctx, output, global, object, length, caller_function, caller_frame);
        errdefer out_value.free(ctx.runtime);
        const out = objectFromValue(out_value) orelse return error.TypeError;
        for (entries.items, 0..) |entry, sorted_index| {
            _ = try builtins.buffer.typedArraySetIndex(ctx.runtime, out, @intCast(sorted_index), entry.value);
        }
        return out_value;
    }

    if (std.mem.eql(u8, name, "with")) {
        const relative_index = try toIntegerOrInfinityForArrayByCopy(ctx, output, global, if (args.len >= 1) args[0] else core.JSValue.undefinedValue());
        const actual_index = if (relative_index < 0) @as(f64, @floatFromInt(length)) + relative_index else relative_index;
        const replacement = try qjsTypedArrayByCopyCoerceValue(ctx, output, global, object, if (args.len >= 2) args[1] else core.JSValue.undefinedValue());
        defer replacement.free(ctx.runtime);

        const current_length = @as(usize, @intCast(try builtins.buffer.typedArrayLength(ctx.runtime, object)));
        if (actual_index < 0 or actual_index >= @as(f64, @floatFromInt(current_length)) or !std.math.isFinite(actual_index)) return error.RangeError;
        const replace_index: usize = @intFromFloat(actual_index);

        const out_value = try qjsTypedArrayCreateSameType(ctx, output, global, object, length, caller_function, caller_frame);
        errdefer out_value.free(ctx.runtime);
        const out = objectFromValue(out_value) orelse return error.TypeError;
        var index: usize = 0;
        while (index < length) : (index += 1) {
            const item = if (index == replace_index)
                replacement
            else
                try builtins.buffer.typedArrayGetIndex(ctx.runtime, object, @intCast(index));
            defer if (index != replace_index) item.free(ctx.runtime);
            _ = try builtins.buffer.typedArraySetIndex(ctx.runtime, out, @intCast(index), item);
        }
        return out_value;
    }

    return null;
}

pub fn qjsArrayFlatCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    const is_flat_map = if (arrayPrototypeRecordId(function_object)) |record_id|
        switch (record_id) {
            @intFromEnum(builtins.array.PrototypeMethod.flat_map) => true,
            @intFromEnum(builtins.array.PrototypeMethod.flat) => false,
            else => return null,
        }
    else blk: {
        const name = try call_mod.nativeFunctionNameForVm(ctx.runtime, function_object);
        defer ctx.runtime.memory.allocator.free(name);
        break :blk if (std.mem.eql(u8, name, "flatMap"))
            true
        else if (std.mem.eql(u8, name, "flat"))
            false
        else
            return null;
    };

    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver.dup() else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    defer receiver_object_value.free(ctx.runtime);
    const source = objectFromValue(receiver_object_value) orelse return null;
    const source_length = if (source.flags.is_array)
        @as(usize, @intCast(source.length))
    else blk: {
        const length_value = try getValueProperty(ctx, output, global, receiver_object_value, core.atom.ids.length, caller_function, caller_frame);
        defer length_value.free(ctx.runtime);
        break :blk try toLengthIndex(ctx, output, global, length_value);
    };

    const mapper = if (is_flat_map) blk: {
        const mapper_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        if (!isCallableValue(mapper_value)) return error.TypeError;
        break :blk mapper_value;
    } else core.JSValue.undefinedValue();
    const this_arg = if (is_flat_map and args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const depth: usize = if (is_flat_map)
        1
    else if (args.len >= 1 and !args[0].isUndefined()) blk: {
        const depth_number = try toIntegerOrInfinityForArrayByCopy(ctx, output, global, args[0]);
        if (std.math.isNan(depth_number) or depth_number <= 0) break :blk 0;
        if (std.math.isPositiveInf(depth_number)) break :blk std.math.maxInt(usize);
        break :blk @intFromFloat(@trunc(depth_number));
    } else 1;

    const out_value = try arraySpeciesCreate(ctx, output, global, receiver_object_value, 0, caller_function, caller_frame);
    errdefer out_value.free(ctx.runtime);
    const out = objectFromValue(out_value) orelse return error.TypeError;
    const written = try flattenIntoArray(ctx, output, global, out_value, out, receiver_object_value, source, source_length, 0, depth, mapper, this_arg, caller_function, caller_frame);
    if (out.flags.is_array) {
        const set_length = try setValueProperty(ctx, output, global, out_value, core.atom.ids.length, lengthIndexValue(written), caller_function, caller_frame);
        set_length.free(ctx.runtime);
    }
    return out_value;
}

pub fn flattenIntoArray(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target_value: core.JSValue,
    target: *core.Object,
    source_value: core.JSValue,
    source: *core.Object,
    source_length: usize,
    start: usize,
    depth: usize,
    mapper: core.JSValue,
    this_arg: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !usize {
    var target_index = start;
    var source_index: usize = 0;
    while (source_index < source_length) : (source_index += 1) {
        const source_key = try propertyAtomFromLengthIndex(ctx.runtime, source_index);
        defer source_key.deinit(ctx.runtime);
        if (!try hasValueProperty(ctx, output, global, source_value, source, source_key.atom, null, null)) continue;

        var element = try getValueProperty(ctx, output, global, source_value, source_key.atom, caller_function, caller_frame);
        defer element.free(ctx.runtime);
        if (!mapper.isUndefined()) {
            const index_value = lengthIndexValue(source_index);
            const mapped = try callValueOrBytecode(ctx, output, global, this_arg, mapper, &.{ element, index_value, source_value }, caller_function, caller_frame);
            element.free(ctx.runtime);
            element = mapped;
        }

        const element_object = objectFromValue(element);
        if (depth > 0 and element_object != null and try arraySpeciesOriginalIsArray(element_object.?)) {
            const element_length = if (element_object.?.flags.is_array)
                @as(usize, @intCast(element_object.?.length))
            else blk: {
                const length_value = try getValueProperty(ctx, output, global, element, core.atom.ids.length, caller_function, caller_frame);
                defer length_value.free(ctx.runtime);
                break :blk try toLengthIndex(ctx, output, global, length_value);
            };
            const next_depth = if (depth == std.math.maxInt(usize)) depth else depth - 1;
            target_index = try flattenIntoArray(ctx, output, global, target_value, target, element, element_object.?, element_length, target_index, next_depth, core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), caller_function, caller_frame);
            continue;
        }

        if (target_index > core.array.max_array_length) return error.TypeError;
        const target_key = try propertyAtomFromLengthIndex(ctx.runtime, target_index);
        defer target_key.deinit(ctx.runtime);
        try createDataPropertyOrThrow(ctx, output, global, target_value, target, target_key.atom, element, caller_function, caller_frame);
        target_index += 1;
    }
    return target_index;
}

pub fn createArrayByCopyOutput(rt: *core.JSRuntime, global: *core.Object, length: usize) !*core.Object {
    if (length > core.array.max_array_length) return error.RangeError;
    const out = try core.Object.createArray(rt, arrayPrototypeFromGlobal(rt, global));
    out.length = @intCast(length);
    return out;
}

pub fn qjsTypedArrayCreateSameType(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    length: usize,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const constructor_value = try typedArrayConstructorForObject(ctx.runtime, global, object);
    defer constructor_value.free(ctx.runtime);
    return constructValueOrBytecode(ctx, output, global, constructor_value, &.{lengthIndexValue(length)}, caller_function, caller_frame);
}

pub fn qjsTypedArrayByCopyCoerceValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    value: core.JSValue,
) !core.JSValue {
    const primitive = try toPrimitiveForNumber(ctx, output, global, value);
    defer primitive.free(ctx.runtime);

    if (object.typedArrayKind() == 11 or object.typedArrayKind() == 12) {
        var bigint = try value_ops.toBigIntValue(ctx.runtime, primitive);
        defer bigint.deinit();
        return value_ops.createBigIntValue(ctx.runtime, bigint);
    }

    if (primitive.isBigInt()) return error.TypeError;
    return value_ops.toNumberValue(ctx.runtime, primitive);
}

pub fn defineArrayByCopyElement(rt: *core.JSRuntime, out: *core.Object, index: usize, value: core.JSValue) !void {
    const key = core.atom.atomFromUInt32(@intCast(index));
    try out.defineOwnProperty(rt, key, core.Descriptor.data(value, true, true, true));
}

pub fn toIntegerOrInfinityForArrayByCopy(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !f64 {
    const primitive = try toPrimitiveForNumber(ctx, output, global, value);
    defer primitive.free(ctx.runtime);
    if (primitive.isBigInt()) return error.TypeError;
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    defer number_value.free(ctx.runtime);
    const number = value_ops.numberValue(number_value) orelse std.math.nan(f64);
    if (std.math.isNan(number) or number == 0) return 0;
    if (!std.math.isFinite(number)) return number;
    return @trunc(number);
}

pub fn arrayByCopySortCompare(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    typed_numeric_default: bool,
    comparator: core.JSValue,
    lhs: ArraySortEntry,
    rhs: ArraySortEntry,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !i32 {
    if (!comparator.isUndefined()) {
        return arraySortCompare(ctx, output, global, comparator, lhs, rhs, caller_function, caller_frame);
    }
    if (typed_numeric_default) return typedArrayDefaultSortCompare(ctx.runtime, lhs, rhs);
    const lhs_string = try toStringForAnnexB(ctx, output, global, lhs.value, caller_function, caller_frame);
    defer lhs_string.free(ctx.runtime);
    const rhs_string = try toStringForAnnexB(ctx, output, global, rhs.value, caller_function, caller_frame);
    defer rhs_string.free(ctx.runtime);
    var lhs_bytes = std.ArrayList(u8).empty;
    defer lhs_bytes.deinit(ctx.runtime.memory.allocator);
    try value_ops.appendRawString(ctx.runtime, &lhs_bytes, lhs_string);
    var rhs_bytes = std.ArrayList(u8).empty;
    defer rhs_bytes.deinit(ctx.runtime.memory.allocator);
    try value_ops.appendRawString(ctx.runtime, &rhs_bytes, rhs_string);
    const order = std.mem.order(u8, lhs_bytes.items, rhs_bytes.items);
    if (order == .lt) return -1;
    if (order == .gt) return 1;
    if (lhs.order < rhs.order) return -1;
    if (lhs.order > rhs.order) return 1;
    return 0;
}

pub fn typedArrayDefaultSortCompare(rt: *core.JSRuntime, lhs: ArraySortEntry, rhs: ArraySortEntry) !i32 {
    if (value_ops.numberValue(lhs.value)) |lhs_number| {
        const rhs_number = value_ops.numberValue(rhs.value) orelse return error.TypeError;
        const lhs_nan = std.math.isNan(lhs_number);
        const rhs_nan = std.math.isNan(rhs_number);
        if (lhs_nan or rhs_nan) {
            if (lhs_nan and rhs_nan) return stableSortTieBreak(lhs, rhs);
            return if (lhs_nan) 1 else -1;
        }
        if (lhs_number < rhs_number) return -1;
        if (lhs_number > rhs_number) return 1;
        if (lhs_number == 0 and rhs_number == 0) {
            const lhs_bits: u64 = @bitCast(lhs_number);
            const rhs_bits: u64 = @bitCast(rhs_number);
            if (lhs_bits == 0x8000000000000000 and rhs_bits == 0) return -1;
            if (lhs_bits == 0 and rhs_bits == 0x8000000000000000) return 1;
        }
        return stableSortTieBreak(lhs, rhs);
    }

    const less = try value_ops.compare(rt, bytecode.opcode.op.lt, lhs.value, rhs.value);
    defer less.free(rt);
    if (less.asBool() == true) return -1;
    const greater = try value_ops.compare(rt, bytecode.opcode.op.gt, lhs.value, rhs.value);
    defer greater.free(rt);
    if (greater.asBool() == true) return 1;
    return stableSortTieBreak(lhs, rhs);
}

pub fn stableSortTieBreak(lhs: ArraySortEntry, rhs: ArraySortEntry) i32 {
    if (lhs.order < rhs.order) return -1;
    if (lhs.order > rhs.order) return 1;
    return 0;
}

pub fn typedArrayOwnKeys(rt: *core.JSRuntime, source: *core.Object) ![]core.Atom {
    var keys: []core.Atom = &[_]core.Atom{};
    errdefer core.Object.freeKeys(rt, keys);
    const length = try builtins.buffer.typedArrayLength(rt, source);
    var index: u32 = 0;
    while (index < length) : (index += 1) {
        try appendAtom(rt, &keys, core.atom.atomFromUInt32(index));
    }

    const ordinary = try source.ownKeys(rt);
    defer core.Object.freeKeys(rt, ordinary);
    for (ordinary) |key| {
        if (rt.atoms.kind(key) == .symbol) continue;
        if (try builtins.buffer.typedArrayCanonicalNumericIndex(rt, key) != .none) continue;
        if (isTypedArrayInternalOwnKey(rt, key)) continue;
        if (atomListContains(keys, key)) continue;
        try appendAtom(rt, &keys, key);
    }
    for (ordinary) |key| {
        if (rt.atoms.kind(key) != .symbol) continue;
        if (atomListContains(keys, key)) continue;
        try appendAtom(rt, &keys, key);
    }
    return keys;
}

pub fn isTypedArrayInternalOwnKey(rt: *core.JSRuntime, atom_id: core.Atom) bool {
    _ = rt;
    return atom_id == atom_buffer or
        atom_id == core.atom.ids.length or
        atom_id == atom_byte_length or
        atom_id == atom_byte_offset;
}

pub fn arrayUsesDefaultIterator(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    source_value: core.JSValue,
    source: *core.Object,
) !bool {
    if (!source.flags.is_array) return false;
    const iterator_method = try getIteratorMethod(ctx, output, global, source_value);
    defer iterator_method.free(ctx.runtime);
    if (!isCallableValue(iterator_method)) return error.TypeError;
    const function_object = callableObjectFromValue(iterator_method) orelse return false;
    const name = try call_mod.nativeFunctionNameForVm(ctx.runtime, function_object);
    defer ctx.runtime.memory.allocator.free(name);
    return std.mem.eql(u8, name, "values");
}

pub fn atomicsTypedArray(value: core.JSValue, waitable: bool) !*core.Object {
    const object = property_ops.expectObject(value) catch return error.TypeError;
    if (!builtins.buffer.isTypedArrayObject(object)) return error.TypeError;
    const kind = object.typedArrayKind();
    const ok = if (waitable)
        kind == 6 or kind == 11
    else
        kind == 1 or kind == 2 or kind == 4 or kind == 5 or kind == 6 or kind == 7 or kind == 11 or kind == 12;
    if (!ok) return error.TypeError;
    return object;
}

pub fn atomicsTypedArrayIsBigInt(object: *core.Object) bool {
    return object.typedArrayKind() == 11 or object.typedArrayKind() == 12;
}

pub fn qjsUint8ArrayCodecCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    name: []const u8,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (std.mem.eql(u8, name, "fromHex")) {
        var bytes = try uint8ArrayStringBytes(ctx.runtime, if (args.len >= 1) args[0] else core.JSValue.undefinedValue());
        defer bytes.deinit(ctx.runtime.memory.allocator);
        var decoded = try decodeHexBytes(ctx.runtime, bytes.items, true);
        defer decoded.deinit(ctx.runtime.memory.allocator);
        return try createUint8ArrayFromBytes(ctx.runtime, global, decoded.items);
    }
    if (std.mem.eql(u8, name, "fromBase64")) {
        var bytes = try uint8ArrayStringBytes(ctx.runtime, if (args.len >= 1) args[0] else core.JSValue.undefinedValue());
        defer bytes.deinit(ctx.runtime.memory.allocator);
        const options = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
        const alphabet = try uint8ArrayBase64Alphabet(ctx, output, global, options, caller_function, caller_frame);
        const last_chunk_handling = try uint8ArrayBase64LastChunkHandling(ctx, output, global, options, caller_function, caller_frame);
        var decoded = try decodeBase64Bytes(ctx.runtime, bytes.items, alphabet, last_chunk_handling);
        defer decoded.deinit(ctx.runtime.memory.allocator);
        return try createUint8ArrayFromBytes(ctx.runtime, global, decoded.items);
    }
    if (std.mem.eql(u8, name, "toHex")) {
        const object = try expectUint8ArrayObject(this_value);
        const bytes = try uint8ArrayViewBytes(ctx.runtime, object);
        var encoded = try encodeHexBytes(ctx.runtime, bytes);
        defer encoded.deinit(ctx.runtime.memory.allocator);
        return try value_ops.createStringValue(ctx.runtime, encoded.items);
    }
    if (std.mem.eql(u8, name, "toBase64")) {
        const object = try expectUint8ArrayObject(this_value);
        const options = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const alphabet = try uint8ArrayBase64Alphabet(ctx, output, global, options, caller_function, caller_frame);
        const omit_padding = try uint8ArrayOmitPadding(ctx, output, global, options, caller_function, caller_frame);
        const bytes = try uint8ArrayViewBytes(ctx.runtime, object);
        var encoded = try encodeBase64Bytes(ctx.runtime, bytes, alphabet, omit_padding);
        defer encoded.deinit(ctx.runtime.memory.allocator);
        return try value_ops.createStringValue(ctx.runtime, encoded.items);
    }
    if (std.mem.eql(u8, name, "setFromHex")) {
        const object = try expectUint8ArrayObject(this_value);
        try builtins.buffer.typedArrayRejectImmutableBuffer(ctx.runtime, object);
        var source = try uint8ArrayStringBytes(ctx.runtime, if (args.len >= 1) args[0] else core.JSValue.undefinedValue());
        defer source.deinit(ctx.runtime.memory.allocator);
        const target = try uint8ArrayViewBytes(ctx.runtime, object);
        const result = try decodeHexInto(source.items, target);
        return try uint8ArrayCodecResult(ctx.runtime, result.read, result.written);
    }
    if (std.mem.eql(u8, name, "setFromBase64")) {
        const object = try expectUint8ArrayObject(this_value);
        try builtins.buffer.typedArrayRejectImmutableBuffer(ctx.runtime, object);
        var source = try uint8ArrayStringBytes(ctx.runtime, if (args.len >= 1) args[0] else core.JSValue.undefinedValue());
        defer source.deinit(ctx.runtime.memory.allocator);
        const options = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
        const alphabet = try uint8ArrayBase64Alphabet(ctx, output, global, options, caller_function, caller_frame);
        const last_chunk_handling = try uint8ArrayBase64LastChunkHandling(ctx, output, global, options, caller_function, caller_frame);
        const target = try uint8ArrayViewBytes(ctx.runtime, object);
        const result = try decodeBase64Into(ctx.runtime, source.items, alphabet, last_chunk_handling, target);
        return try uint8ArrayCodecResult(ctx.runtime, result.read, result.written);
    }
    return null;
}

pub const Uint8ArrayBase64Alphabet = enum { base64, base64url };
pub const Uint8ArrayBase64LastChunkHandling = enum { loose, strict, stop_before_partial };
pub const Uint8ArrayCodecProgress = struct { read: usize, written: usize };

pub fn expectUint8ArrayObject(value: core.JSValue) !*core.Object {
    const object = property_ops.expectObject(value) catch return error.TypeError;
    if (!builtins.buffer.isTypedArrayObject(object) or object.typedArrayKind() != 2) return error.TypeError;
    return object;
}

pub fn uint8ArrayBase64Alphabet(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    options: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !Uint8ArrayBase64Alphabet {
    const rt = ctx.runtime;
    if (!options.isObject()) return .base64;
    const key = try rt.internAtom("alphabet");
    defer rt.atoms.free(key);
    const value = try getValueProperty(ctx, output, global, options, key, caller_function, caller_frame);
    defer value.free(rt);
    if (value.isUndefined()) return .base64;
    var text = try uint8ArrayStringBytes(rt, value);
    defer text.deinit(rt.memory.allocator);
    if (std.mem.eql(u8, text.items, "base64")) return .base64;
    if (std.mem.eql(u8, text.items, "base64url")) return .base64url;
    return error.TypeError;
}

pub fn uint8ArrayBase64LastChunkHandling(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    options: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !Uint8ArrayBase64LastChunkHandling {
    const rt = ctx.runtime;
    if (!options.isObject()) return .loose;
    const key = try rt.internAtom("lastChunkHandling");
    defer rt.atoms.free(key);
    const value = try getValueProperty(ctx, output, global, options, key, caller_function, caller_frame);
    defer value.free(rt);
    if (value.isUndefined()) return .loose;
    var text = try uint8ArrayStringBytes(rt, value);
    defer text.deinit(rt.memory.allocator);
    if (std.mem.eql(u8, text.items, "loose")) return .loose;
    if (std.mem.eql(u8, text.items, "strict")) return .strict;
    if (std.mem.eql(u8, text.items, "stop-before-partial")) return .stop_before_partial;
    return error.TypeError;
}

pub fn uint8ArrayOmitPadding(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    options: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    const rt = ctx.runtime;
    if (!options.isObject()) return false;
    const key = try rt.internAtom("omitPadding");
    defer rt.atoms.free(key);
    const value = try getValueProperty(ctx, output, global, options, key, caller_function, caller_frame);
    defer value.free(rt);
    return valueTruthy(value);
}

pub fn createUint8ArrayFromBytes(rt: *core.JSRuntime, global: *core.Object, bytes: []const u8) !core.JSValue {
    const buffer_proto = constructorPrototypeFromGlobalAtom(rt, global, core.atom.predefinedId("ArrayBuffer", .string).?);
    const buffer_value = try builtins.buffer.arrayBufferConstructLength(rt, bytes.len, null, buffer_proto);
    var buffer_owned = true;
    errdefer if (buffer_owned) buffer_value.free(rt);
    const buffer = try property_ops.expectObject(buffer_value);
    if (bytes.len != 0) @memcpy(buffer.byteStorage()[0..bytes.len], bytes);
    const proto = try uint8ArrayConstructorPrototypeObject(rt, global, "Uint8Array");
    buffer_owned = false;
    return try builtins.buffer.typedArrayConstructFullBufferOwned(rt, 1, 2, buffer_value, buffer, proto);
}

pub fn uint8ArrayConstructorPrototypeObject(rt: *core.JSRuntime, global: *core.Object, name: []const u8) !?*core.Object {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    const ctor_value = global.getProperty(key);
    defer ctor_value.free(rt);
    const ctor = property_ops.expectObject(ctor_value) catch return null;
    const proto_value = ctor.getProperty(core.atom.ids.prototype);
    defer proto_value.free(rt);
    return property_ops.expectObject(proto_value) catch null;
}

pub fn uint8ArrayViewBytes(rt: *core.JSRuntime, object: *core.Object) ![]u8 {
    const length = try builtins.buffer.typedArrayLength(rt, object);
    const buffer = try atomicsBufferObject(object);
    if (buffer.arrayBufferDetached()) return error.TypeError;
    const start = object.typedArrayByteOffset();
    return buffer.byteStorage()[start..][0..length];
}

pub fn writeUint8ArrayPrefix(rt: *core.JSRuntime, object: *core.Object, bytes: []const u8) !usize {
    const target = try uint8ArrayViewBytes(rt, object);
    const count = @min(target.len, bytes.len);
    if (count != 0) @memcpy(target[0..count], bytes[0..count]);
    return count;
}

pub fn uint8ArrayCodecResult(rt: *core.JSRuntime, read: usize, written: usize) !core.JSValue {
    const object = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    try defineValueProperty(rt, object, "read", core.JSValue.int32(@intCast(read)));
    try defineValueProperty(rt, object, "written", core.JSValue.int32(@intCast(written)));
    return object.value();
}

pub fn isTypedArrayPrototypeMethod(rt: *core.JSRuntime, function_object: *core.Object) bool {
    _ = rt;
    return function_object.typedArrayBuiltinMarker() == .prototype_method;
}

pub fn typedArrayStaticMethodId(rt: *core.JSRuntime, function_object: *core.Object) ?i32 {
    _ = rt;
    return switch (function_object.typedArrayBuiltinMarker()) {
        .static_from => 1,
        .static_of => 2,
        else => null,
    };
}

pub fn atomListToMemorySlice(rt: *core.JSRuntime, atoms: *std.ArrayList(core.Atom)) ![]core.Atom {
    if (atoms.items.len == 0) return &.{};
    const out = try rt.memory.alloc(core.Atom, atoms.items.len);
    @memcpy(out, atoms.items);
    atoms.clearAndFree(rt.memory.allocator);
    return out;
}

pub fn atomSliceContains(rt: *core.JSRuntime, names: []const core.Atom, atom_id: core.Atom) bool {
    for (names) |name| {
        if (atomIdOrNameEql(rt, name, atom_id)) return true;
    }
    return false;
}

pub fn freeAtomSlice(rt: *core.JSRuntime, atoms: []core.Atom) void {
    for (atoms) |atom_id| rt.atoms.free(atom_id);
    if (atoms.len != 0) rt.memory.free(core.Atom, atoms);
}

pub fn freeValueSlice(rt: *core.JSRuntime, values: []core.JSValue) void {
    for (values) |value| value.free(rt);
    if (values.len != 0) rt.memory.free(core.JSValue, values);
}

pub fn qjsWorkerPopMessage(id: i32, endpoint: WorkerPostTarget) ?WorkerMessage {
    const allocator = workerPageAllocator();
    const io = qjsWorkerIo();
    call_runtime.qjs_workers.mutex.lockUncancelable(io);
    defer call_runtime.qjs_workers.mutex.unlock(io);
    const worker = qjsWorkerByIdLocked(id) orelse return null;
    const queue = switch (endpoint) {
        .worker => &worker.to_worker,
        .parent => &worker.to_parent,
    };
    const capacity = switch (endpoint) {
        .worker => &worker.to_worker_capacity,
        .parent => &worker.to_parent_capacity,
    };
    if (queue.*.len == 0) return null;
    const message = queue.*[0];
    const old_len = queue.*.len;
    if (old_len == 1) {
        const old = queue.*.ptr[0..capacity.*];
        queue.* = &.{};
        capacity.* = 0;
        allocator.free(old);
    } else {
        @memmove(queue.*[0 .. old_len - 1], queue.*[1..old_len]);
        queue.* = queue.*.ptr[0 .. old_len - 1];
    }
    return message;
}

pub fn putDenseArrayElementFast(rt: *core.JSRuntime, object_value: core.JSValue, key: core.JSValue, value: core.JSValue) !bool {
    const object = property_ops.expectObject(object_value) catch return false;
    if (!object.flags.is_array) return false;
    if (key.asInt32()) |index_i32| {
        if (index_i32 >= 0 and index_i32 <= core.array.max_array_index and index_i32 <= core.atom.max_int_atom) {
            const index: u32 = @intCast(index_i32);
            const atom_id = core.atom.atomFromUInt32(index);
            if (index < object.length) {
                if (try object.writeDenseArrayIndex(rt, index, atom_id, value)) return true;
            }
            return try object.appendDenseArrayIndex(rt, index, atom_id, value);
        }
        return false;
    }
    const number = value_ops.numberValue(key) orelse return false;
    if (std.math.isNan(number) or !std.math.isFinite(number) or number < 0 or number > core.array.max_array_index or @trunc(number) != number) return false;
    const index: u32 = @intFromFloat(number);
    if (index > core.atom.max_int_atom) return false;
    const atom_id = core.atom.atomFromUInt32(index);
    if (index < object.length) {
        if (try object.writeDenseArrayIndex(rt, index, atom_id, value)) return true;
    }
    return try object.appendDenseArrayIndex(rt, index, atom_id, value);
}

pub fn argsFromArray(rt: *core.JSRuntime, array_value: core.JSValue) ![]core.JSValue {
    const array = try property_ops.expectObject(array_value);
    if (!array.flags.is_array) return error.TypeError;
    if (array.length == 0) return &.{};
    const args = try rt.memory.alloc(core.JSValue, array.length);
    errdefer rt.memory.free(core.JSValue, args);
    var rooted_args: []core.JSValue = args[0..0];
    var args_root = ValueSliceRoot{};
    args_root.init(rt, &rooted_args);
    defer args_root.deinit();
    var initialized: usize = 0;
    errdefer {
        for (args[0..initialized]) |*value| {
            value.free(rt);
            value.* = core.JSValue.undefinedValue();
        }
        rooted_args = &.{};
    }
    var index: u32 = 0;
    while (index < array.length) : (index += 1) {
        args[index] = array.getProperty(core.atom.atomFromUInt32(index));
        initialized += 1;
        rooted_args = args[0..initialized];
    }
    return args;
}

pub const ValueSliceRoot = struct {
    rt: ?*core.JSRuntime = null,
    slices: [1]core.runtime.ValueRootSlice = undefined,
    frame: core.runtime.ValueRootFrame = .{},

    pub fn init(self: *ValueSliceRoot, rt: *core.JSRuntime, values: *[]core.JSValue) void {
        self.rt = rt;
        self.slices[0] = .{ .mutable = values };
        self.frame = .{
            .previous = rt.active_value_roots,
            .slices = &self.slices,
        };
        rt.active_value_roots = &self.frame;
    }

    pub fn deinit(self: *ValueSliceRoot) void {
        const rt = self.rt orelse return;
        rt.active_value_roots = self.frame.previous;
        self.rt = null;
    }
};

pub fn argsFromArrayLike(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    array_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) ![]core.JSValue {
    const object = objectFromValue(array_value) orelse return error.TypeError;
    if (object.flags.is_array) return argsFromArray(ctx.runtime, array_value);

    const length_value = try getValueProperty(ctx, output, global, array_value, core.atom.ids.length, caller_function, caller_frame);
    defer length_value.free(ctx.runtime);
    const length = try toLengthIndex(ctx, output, global, length_value);
    if (length == 0) return &.{};
    const args = try ctx.runtime.memory.alloc(core.JSValue, length);
    errdefer ctx.runtime.memory.free(core.JSValue, args);
    var rooted_args: []core.JSValue = args[0..0];
    var args_root = ValueSliceRoot{};
    args_root.init(ctx.runtime, &rooted_args);
    defer args_root.deinit();
    var initialized: usize = 0;
    errdefer {
        for (args[0..initialized]) |*value| {
            value.free(ctx.runtime);
            value.* = core.JSValue.undefinedValue();
        }
        rooted_args = &.{};
    }
    var index: usize = 0;
    while (index < length) : (index += 1) {
        const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
        defer key.deinit(ctx.runtime);
        args[index] = try getValueProperty(ctx, output, global, array_value, key.atom, caller_function, caller_frame);
        initialized += 1;
        rooted_args = args[0..initialized];
    }
    return args;
}

pub fn qjsGeneratorSlice(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
) !?core.JSValue {
    if (!receiver.isObject()) return null;
    const object = property_ops.expectObject(receiver) catch return null;
    if (object.class_id != core.class.ids.generator) return null;

    const start = if (args.len > 0) args[0].asInt32() orelse 0 else 0;
    const out = try core.Object.createArray(ctx.runtime, null);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &out.header);
    var skipped: i32 = 0;
    while (true) {
        const next_result = (try qjsGeneratorNext(ctx, output, global, receiver, &.{})) orelse break;
        defer next_result.free(ctx.runtime);
        const next_object = try property_ops.expectObject(next_result);
        const done = next_object.getProperty(core.atom.predefinedId("done", .string).?);
        defer done.free(ctx.runtime);
        if (done.asBool() == true) break;
        const value = next_object.getProperty(core.atom.predefinedId("value", .string).?);
        defer value.free(ctx.runtime);
        if (skipped < start) {
            skipped += 1;
            continue;
        }
        try out.defineOwnProperty(ctx.runtime, core.atom.atomFromUInt32(out.length), core.Descriptor.data(value, true, true, true));
    }
    return out.value();
}

pub fn qjsArrayIteratorMethod(ctx: *core.JSContext, global: *core.Object, receiver: core.JSValue, function_object: *core.Object) !?core.JSValue {
    return iter_vm.arrayIteratorMethod(ctx, global, receiver, function_object);
}

pub fn qjsArrayIteratorMethodRecord(ctx: *core.JSContext, global: *core.Object, receiver: core.JSValue, function_object: *core.Object, method_id: u32) !?core.JSValue {
    const kind: u8 = switch (method_id) {
        @intFromEnum(builtins.array.PrototypeMethod.keys) => 1,
        @intFromEnum(builtins.array.PrototypeMethod.values) => 2,
        @intFromEnum(builtins.array.PrototypeMethod.entries) => 3,
        else => return null,
    };
    if (receiver.isNull() or receiver.isUndefined()) return error.TypeError;
    const object_value = if (receiver.isObject()) receiver.dup() else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    var object_value_owned = true;
    errdefer if (object_value_owned) object_value.free(ctx.runtime);
    const object = property_ops.expectObject(object_value) catch {
        object_value.free(ctx.runtime);
        return null;
    };
    if (isTypedArrayPrototypeMethod(ctx.runtime, function_object)) {
        if (!builtins.buffer.isTypedArrayObject(object)) return error.TypeError;
        if (try builtins.buffer.typedArrayDetached(object)) return error.TypeError;
        if (try builtins.buffer.typedArrayOutOfBounds(object)) return error.TypeError;
    }
    const prototype = try arrayIteratorPrototypeFromContext(ctx, global);
    const iterator = try core.Object.create(ctx.runtime, core.class.ids.array_iterator, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &iterator.header);
    object_value_owned = false;
    try iterator.setOptionalValueSlot(ctx.runtime, iterator.iteratorTargetSlot(), object_value);
    iterator.iteratorIndexSlot().* = 0;
    iterator.iteratorKindSlot().* = kind;
    return iterator.value();
}

pub fn qjsIteratorZipFlattenableRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !IteratorZipRecord {
    return iter_vm.qjsIteratorZipFlattenableRecord(
        ctx,
        output,
        global,
        value,
        caller_function,
        caller_frame,
    );
}

pub fn iteratorFlattenableForIteratorFrom(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    source: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (objectFromValue(source)) |source_object| {
        if (isDirectIteratorClass(source_object.class_id)) {
            try cacheIteratorNextMethod(ctx, output, global, source);
            return source.dup();
        }
    }

    const iterator_method = try getIteratorMethod(ctx, output, global, source);
    defer iterator_method.free(ctx.runtime);
    if (!iterator_method.isUndefined() and !iterator_method.isNull()) {
        if (!isCallableValue(iterator_method)) return error.TypeError;
        const iterator = try callValueOrBytecode(ctx, output, global, source, iterator_method, &.{}, caller_function, caller_frame);
        errdefer iterator.free(ctx.runtime);
        _ = objectFromValue(iterator) orelse return error.TypeError;
        try cacheIteratorNextMethod(ctx, output, global, iterator);
        return iterator;
    }

    const iterator_object = objectFromValue(source) orelse return error.TypeError;
    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    const next_method = try getValueProperty(ctx, output, global, iterator_object.value(), next_key, caller_function, caller_frame);
    defer next_method.free(ctx.runtime);
    if (next_method.isUndefined() or next_method.isNull()) return iterator_object.value().dup();
    if (!isCallableValue(next_method)) return error.TypeError;
    const cached = iterator_object.cachedIteratorNextSlot();
    try iterator_object.setOptionalValueSlot(ctx.runtime, cached, next_method.dup());
    return iterator_object.value().dup();
}

pub fn qjsArrayIteratorNext(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, function_object: *core.Object) !?core.JSValue {
    if (!function_object.isArrayIteratorNextFunction()) return null;
    return iter_vm.arrayIteratorNext(ctx, output, global, receiver);
}

pub fn qjsArrayIteratorValue(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, target: *core.Object, index: u32, kind: u8) !core.JSValue {
    return iter_vm.arrayIteratorValue(ctx, output, global, target, index, kind, getValueProperty);
}

pub fn arrayPrototypeValuesFromGlobal(rt: *core.JSRuntime, global: *core.Object) !?core.JSValue {
    const prototype = arrayPrototypeFromGlobal(rt, global) orelse return null;
    const values_key = try rt.internAtom("values");
    defer rt.atoms.free(values_key);
    return prototype.getProperty(values_key);
}

pub fn createArrayFromArgs(rt: *core.JSRuntime, global: *core.Object, args: []const core.JSValue) !core.JSValue {
    var rooted_args_buffer = try core.runtime.ValueRootBuffer.initCopy(rt, args);
    defer rooted_args_buffer.deinit(rt);
    const rooted_args = rooted_args_buffer.values;
    var root_slices = [_]core.runtime.ValueRootSlice{
        rooted_args_buffer.slice(),
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .slices = &root_slices,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const array = try core.Object.createArray(rt, arrayPrototypeFromGlobal(rt, global));
    errdefer core.Object.destroyFromHeader(rt, &array.header);
    try array.reserveDenseArrayElements(rt, @intCast(rooted_args.len));
    for (rooted_args, 0..) |arg, index| {
        const atom_id = core.atom.atomFromUInt32(@intCast(index));
        if (try array.appendDenseArrayIndex(rt, @intCast(index), atom_id, arg)) continue;
        try array.defineOwnProperty(rt, atom_id, core.Descriptor.data(arg, true, true, true));
    }
    return array.value();
}

test "createArrayFromArgs roots direct function bytecode args while creating array" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);

    const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-create-array-from-args-bytecode-symbol");
    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    fb.cpool[0] = core.JSValue.symbol(symbol_atom);
    fb.cpool_count = 1;

    var arg_value = core.JSValue.functionBytecode(&fb.header);
    var arg_alive = true;
    defer if (arg_alive) arg_value.free(rt);
    const args = [_]core.JSValue{arg_value};

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const array_value = try createArrayFromArgs(rt, global, &args);
    var array_alive = true;
    defer if (array_alive) array_value.free(rt);
    const array = objectFromValue(array_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = array.getProperty(core.atom.atomFromUInt32(0));
    defer stored.free(rt);
    try std.testing.expect(stored.same(arg_value));

    array_value.free(rt);
    array_alive = false;
    arg_value.free(rt);
    arg_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn arrayLengthAssignmentValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (!object.flags.is_array or atom_id != core.atom.ids.length or value.isNumber()) return value;
    const first_primitive = try toPrimitiveForNumber(ctx, output, global, value);
    defer first_primitive.free(ctx.runtime);
    const first_number = try value_ops.toNumberValue(ctx.runtime, first_primitive);
    defer first_number.free(ctx.runtime);
    _ = caller_function;
    _ = caller_frame;
    const second_primitive = try toPrimitiveForNumber(ctx, output, global, value);
    defer second_primitive.free(ctx.runtime);
    return value_ops.toNumberValue(ctx.runtime, second_primitive);
}

pub fn typedArrayReflectSetReceiverOwn(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver_value: core.JSValue,
    receiver_object: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    if (receiver_object.proxyTarget() != null) {
        try proxyDefineValueForReflectSet(ctx, output, global, receiver_value, receiver_object, atom_id, value, caller_function, caller_frame);
        return true;
    }

    if (builtins.buffer.isTypedArrayObject(receiver_object)) {
        const typed_array_desc = core.Descriptor{
            .kind = .data,
            .value = value,
            .value_present = true,
        };
        if (try typedArrayDefineOwnPropertyVm(ctx, output, global, receiver_object, atom_id, typed_array_desc)) |ok| return ok;
    }

    if (receiver_object.getOwnProperty(atom_id)) |current| {
        defer current.destroy(ctx.runtime);
        if (current.kind == .accessor) return false;
        if (current.writable == false) return false;

        const update_desc = core.Descriptor{
            .kind = .data,
            .value = value,
            .value_present = true,
        };
        receiver_object.defineOwnProperty(ctx.runtime, atom_id, update_desc) catch |err| switch (err) {
            error.ReadOnly, error.NotExtensible, error.IncompatibleDescriptor => return false,
            error.InvalidLength => return error.RangeError,
            else => return err,
        };
        return true;
    }

    receiver_object.defineOwnProperty(ctx.runtime, atom_id, core.Descriptor.data(value, true, true, true)) catch |err| switch (err) {
        error.ReadOnly, error.NotExtensible, error.IncompatibleDescriptor => return false,
        error.InvalidLength => return error.RangeError,
        else => return err,
    };
    return true;
}

pub fn typedArrayPrototypeSet(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver_value: core.JSValue,
    receiver_object: *core.Object,
    prototype: ?*core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?bool {
    var current = prototype;
    while (current) |object| : (current = object.getPrototype()) {
        if (!builtins.buffer.isTypedArrayObject(object)) continue;
        switch (try builtins.buffer.typedArrayCanonicalNumericIndex(ctx.runtime, atom_id)) {
            .none => return null,
            .invalid => {
                if (sameObjectIdentity(receiver_value, object.value())) {
                    const coerced = try coerceTypedArrayElementInput(ctx, output, global, value);
                    defer coerced.free(ctx.runtime);
                    try builtins.buffer.typedArrayCoerceElementValue(ctx.runtime, object, coerced);
                }
                return true;
            },
            .index => |index| {
                if (sameObjectIdentity(receiver_value, object.value())) {
                    const coerced = try coerceTypedArrayElementForSet(ctx, output, global, object, value);
                    defer coerced.free(ctx.runtime);
                    if (!try builtins.buffer.typedArrayIndexValid(ctx.runtime, object, index)) return true;
                    if (try builtins.buffer.typedArrayImmutableBuffer(ctx.runtime, object)) return false;
                    _ = try builtins.buffer.typedArraySetElement(ctx.runtime, object, index, coerced);
                    return true;
                }
                if (!try builtins.buffer.typedArrayIndexValid(ctx.runtime, object, index)) return true;
                return try typedArrayReflectSetReceiverOwn(
                    ctx,
                    output,
                    global,
                    receiver_value,
                    receiver_object,
                    atom_id,
                    value,
                    caller_function,
                    caller_frame,
                );
            },
        }
    }
    return null;
}

pub fn qjsArrayJoinCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (this_value.isNull() or this_value.isUndefined()) return error.TypeError;
    const object_value = if (this_value.isObject()) this_value.dup() else try primitiveObjectForAccess(ctx.runtime, global, this_value);
    defer object_value.free(ctx.runtime);
    const object = property_ops.expectObject(object_value) catch return null;
    const is_typed_method = isTypedArrayPrototypeMethod(ctx.runtime, function_object);
    const is_typed_array = builtins.buffer.isTypedArrayObject(object);
    if (is_typed_method and !is_typed_array) return error.TypeError;
    if (!is_typed_method and !is_typed_array) {
        if (try qjsFastDensePrimitiveArrayJoin(ctx.runtime, object, args)) |joined| return joined;
    }
    const length = if (is_typed_array)
        try arrayMethodTypedArrayLength(ctx.runtime, object, is_typed_method)
    else if (object.flags.is_array)
        @as(usize, @intCast(object.length))
    else blk: {
        const length_value = try getValueProperty(ctx, output, global, object_value, core.atom.ids.length, caller_function, caller_frame);
        defer length_value.free(ctx.runtime);
        break :blk try toLengthIndex(ctx, output, global, length_value);
    };
    const separator_value = if (args.len >= 1 and !args[0].isUndefined()) args[0] else try value_ops.createStringValue(ctx.runtime, ",");
    defer if (args.len < 1 or args[0].isUndefined()) separator_value.free(ctx.runtime);
    const separator_string = try toStringForAnnexB(ctx, output, global, separator_value, caller_function, caller_frame);
    defer separator_string.free(ctx.runtime);
    var separator = std.ArrayList(u8).empty;
    defer separator.deinit(ctx.runtime.memory.allocator);
    try value_ops.appendRawString(ctx.runtime, &separator, separator_string);

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(ctx.runtime.memory.allocator);
    var index: usize = 0;
    while (index < length) : (index += 1) {
        if (index != 0) try bytes.appendSlice(ctx.runtime.memory.allocator, separator.items);
        const item = if (is_typed_array) blk: {
            if (!is_typed_method and index >= try arrayMethodTypedArrayLength(ctx.runtime, object, false)) break :blk core.JSValue.undefinedValue();
            break :blk try builtins.buffer.typedArrayGetIndex(ctx.runtime, object, @intCast(index));
        } else blk: {
            const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
            defer key.deinit(ctx.runtime);
            break :blk try getValueProperty(ctx, output, global, object_value, key.atom, caller_function, caller_frame);
        };
        defer item.free(ctx.runtime);
        if (!item.isUndefined() and !item.isNull()) {
            const string_item = try toStringForAnnexB(ctx, output, global, item, caller_function, caller_frame);
            defer string_item.free(ctx.runtime);
            try value_ops.appendRawString(ctx.runtime, &bytes, string_item);
        }
    }
    return try value_ops.createStringValue(ctx.runtime, bytes.items);
}

pub fn qjsFastDensePrimitiveArrayJoin(
    rt: *core.JSRuntime,
    object: *core.Object,
    args: []const core.JSValue,
) !?core.JSValue {
    if (!object.flags.is_array or object.exotic != null or object.arrayElementStorageMode() != .dense) return null;
    if (object.properties.len != 0) return null;

    const length: usize = @intCast(object.length);
    const elements = object.arrayElements();
    if (length > elements.len) return null;

    var separator = std.ArrayList(u8).empty;
    defer separator.deinit(rt.memory.allocator);
    if (args.len == 0 or args[0].isUndefined()) {
        try separator.append(rt.memory.allocator, ',');
    } else if (args[0].isString()) {
        try value_ops.appendRawString(rt, &separator, args[0]);
    } else {
        return null;
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    var index: usize = 0;
    while (index < length) : (index += 1) {
        const item = elements[index] orelse return null;
        if (!qjsCanFastJoinPrimitive(item)) return null;
        if (index != 0) try bytes.appendSlice(rt.memory.allocator, separator.items);
        if (!item.isUndefined() and !item.isNull()) try value_ops.appendValueString(rt, &bytes, item);
    }
    return try value_ops.createStringValue(rt, bytes.items);
}

pub fn qjsCanFastJoinPrimitive(value: core.JSValue) bool {
    return value.isUndefined() or
        value.isNull() or
        value.isString() or
        value.isNumber() or
        value.isBool() or
        value.isBigInt();
}

pub fn qjsObjectEntryArrayValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object_value: core.JSValue,
    key: core.Atom,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var value = core.JSValue.undefinedValue();
    defer value.free(ctx.runtime);
    var entry_value = core.JSValue.undefinedValue();
    errdefer entry_value.free(ctx.runtime);
    var key_value = core.JSValue.undefinedValue();
    defer key_value.free(ctx.runtime);

    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &value },
        .{ .value = &entry_value },
        .{ .value = &key_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    value = try getValueProperty(ctx, output, global, object_value, key, caller_function, caller_frame);

    const entry = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
    entry_value = entry.value();

    key_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, key);

    try createDataPropertyOrThrow(ctx, output, global, entry_value, entry, core.atom.atomFromUInt32(0), key_value, caller_function, caller_frame);
    try createDataPropertyOrThrow(ctx, output, global, entry_value, entry, core.atom.atomFromUInt32(1), value, caller_function, caller_frame);

    return entry_value;
}

test "qjsObjectEntryArrayValue roots direct symbol value while creating entry array" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try zjs_vm.contextGlobal(ctx);

    const source = try core.Object.create(rt, core.class.ids.object, objectPrototypeFromGlobal(rt, global));
    var source_alive = true;
    defer if (source_alive) source.value().free(rt);
    const key = try rt.internAtom("entry");
    defer rt.atoms.free(key);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-qjs-object-entry-symbol");
    try source.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.symbol(symbol_atom), true, true, true));

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const entry_value = try qjsObjectEntryArrayValue(ctx, null, global, source.value(), key, null, null);
    var entry_alive = true;
    defer if (entry_alive) entry_value.free(rt);
    const entry = try property_ops.expectObject(entry_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    {
        const stored = entry.getProperty(core.atom.atomFromUInt32(1));
        defer stored.free(rt);
        try std.testing.expect(stored.same(core.JSValue.symbol(symbol_atom)));
    }

    entry_value.free(rt);
    entry_alive = false;
    source.value().free(rt);
    source_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "qjsObjectEnumerableOwnPropertiesCall roots direct symbol values while creating output array" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try zjs_vm.contextGlobal(ctx);

    const source = try core.Object.create(rt, core.class.ids.object, objectPrototypeFromGlobal(rt, global));
    var source_alive = true;
    defer if (source_alive) source.value().free(rt);
    const key = try rt.internAtom("value");
    defer rt.atoms.free(key);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-qjs-object-values-symbol");
    try source.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.symbol(symbol_atom), true, true, true));

    const args = [_]core.JSValue{source.value()};
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const out_value = (try qjsObjectEnumerableOwnPropertiesCall(ctx, null, global, &args, .values, null, null)) orelse return error.TypeError;
    var out_alive = true;
    defer if (out_alive) out_value.free(rt);
    const out = try property_ops.expectObject(out_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    {
        const stored = out.getProperty(core.atom.atomFromUInt32(0));
        defer stored.free(rt);
        try std.testing.expect(stored.same(core.JSValue.symbol(symbol_atom)));
    }

    out_value.free(rt);
    out_alive = false;
    source.value().free(rt);
    source_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn qjsTypedArrayValidateConstructArgsPreAllocate(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !void {
    if (args.len < 1) return;
    const first = args[0];
    if (!first.isObject()) {
        _ = try qjsTypedArrayConstructToIndex(ctx, output, global, first);
        return;
    }
    const source_object = objectFromValue(first) orelse return error.TypeError;
    if (source_object.class_id != core.class.ids.array_buffer and source_object.class_id != core.class.ids.shared_array_buffer) return;
    if (args.len >= 2 and !args[1].isUndefined()) {
        _ = try qjsTypedArrayConstructToIndex(ctx, output, global, args[1]);
    }
    if (args.len >= 3 and !args[2].isUndefined()) {
        _ = try qjsTypedArrayConstructToIndex(ctx, output, global, args[2]);
    }
}

pub fn arrayLengthDefineValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !core.JSValue {
    const first_primitive = try toPrimitiveForNumber(ctx, output, global, value);
    defer first_primitive.free(ctx.runtime);
    const first_number = try value_ops.toNumberValue(ctx.runtime, first_primitive);
    defer first_number.free(ctx.runtime);
    const second_primitive = try toPrimitiveForNumber(ctx, output, global, value);
    defer second_primitive.free(ctx.runtime);
    return value_ops.toNumberValue(ctx.runtime, second_primitive);
}

pub fn popDuplicateConstructorTarget(rt: *core.JSRuntime, stack: *stack_mod.Stack, func: core.JSValue) !void {
    const top = stack.peek() orelse return;
    defer top.free(rt);
    if (!sameObjectIdentity(top, func)) return;
    const duplicate = try stack.pop();
    duplicate.free(rt);
}

pub fn typedArrayCanonicalGet(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) !?core.JSValue {
    switch (try builtins.buffer.typedArrayCanonicalNumericIndex(rt, atom_id)) {
        .none => return null,
        .invalid => return core.JSValue.undefinedValue(),
        .index => |index| return try builtins.buffer.typedArrayGetIndex(rt, object, index),
    }
}

pub fn typedArrayCanonicalOwnDescriptor(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) !?core.Descriptor {
    if (!builtins.buffer.isTypedArrayObject(object)) return null;
    switch (try builtins.buffer.typedArrayCanonicalNumericIndex(rt, atom_id)) {
        .none => return null,
        .invalid => return null,
        .index => |index| {
            const length = try builtins.buffer.typedArrayLength(rt, object);
            if (index >= length) return null;
            const value = try builtins.buffer.typedArrayGetIndex(rt, object, index);
            return core.Descriptor.data(value, true, true, true);
        },
    }
}

pub fn coerceTypedArrayElementInput(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !core.JSValue {
    return if (value.isObject())
        try toPrimitiveForNumber(ctx, output, global, value)
    else
        value.dup();
}

pub fn coerceTypedArrayElementForSet(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    value: core.JSValue,
) !core.JSValue {
    const coerced = try coerceTypedArrayElementInput(ctx, output, global, value);
    errdefer coerced.free(ctx.runtime);
    try builtins.buffer.typedArrayCoerceElementValue(ctx.runtime, object, coerced);
    return coerced;
}

pub fn typedArrayDefineOwnPropertyVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    atom_id: core.Atom,
    desc: core.Descriptor,
) !?bool {
    if (!builtins.buffer.isTypedArrayObject(object)) return null;
    switch (try builtins.buffer.typedArrayCanonicalNumericIndex(ctx.runtime, atom_id)) {
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
            if (!try builtins.buffer.typedArrayIndexValid(ctx.runtime, object, index)) return false;
            if (desc.value_present) {
                if (try builtins.buffer.typedArrayImmutableBuffer(ctx.runtime, object)) return false;
                const coerced = try coerceTypedArrayElementInput(ctx, output, global, desc.value);
                defer coerced.free(ctx.runtime);
                if (!try builtins.buffer.typedArrayIndexValid(ctx.runtime, object, index)) return true;
                if (try builtins.buffer.typedArrayImmutableBuffer(ctx.runtime, object)) return false;
                _ = try builtins.buffer.typedArraySetElement(ctx.runtime, object, index, coerced);
            }
            return true;
        },
    }
}

pub fn typedArrayCanonicalSet(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
) !bool {
    switch (try builtins.buffer.typedArrayCanonicalNumericIndex(ctx.runtime, atom_id)) {
        .none => return false,
        .invalid => {
            const coerced = try coerceTypedArrayElementInput(ctx, output, global, value);
            defer coerced.free(ctx.runtime);
            try builtins.buffer.typedArrayCoerceElementValue(ctx.runtime, object, coerced);
            return true;
        },
        .index => |index| {
            const coerced = try coerceTypedArrayElementForSet(ctx, output, global, object, value);
            defer coerced.free(ctx.runtime);
            if (!try builtins.buffer.typedArrayIndexValid(ctx.runtime, object, index)) return true;
            if (try builtins.buffer.typedArrayImmutableBuffer(ctx.runtime, object)) return false;
            _ = try builtins.buffer.typedArraySetElement(ctx.runtime, object, index, coerced);
            return true;
        },
    }
}

pub fn typedArrayCanonicalHas(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) ?bool {
    if (!builtins.buffer.isTypedArrayObject(object)) return null;
    switch (builtins.buffer.typedArrayCanonicalNumericIndex(rt, atom_id) catch return false) {
        .none => return null,
        .invalid => return false,
        .index => |index| {
            const length = builtins.buffer.typedArrayLength(rt, object) catch return false;
            return index < length;
        },
    }
}

pub fn typedArrayCanonicalDelete(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) !?bool {
    if (!builtins.buffer.isTypedArrayObject(object)) return null;
    switch (try builtins.buffer.typedArrayCanonicalNumericIndex(rt, atom_id)) {
        .none => return null,
        .invalid => return true,
        .index => |index| {
            const length = builtins.buffer.typedArrayLength(rt, object) catch return true;
            return index >= length;
        },
    }
}

// --- Merged from collection.zig ---

const SetMethodMode = enum {
    difference,
    intersection,
    is_disjoint_from,
    is_subset_of,
    is_superset_of,
    symmetric_difference,
    union_,
};

const SetLikeRecordVm = struct {
    object_value: core.JSValue,
    size: f64,
    has: core.JSValue,
    keys: core.JSValue,
    native_kind: enum { none, set, map },

    fn deinit(self: *const SetLikeRecordVm, rt: *core.JSRuntime) void {
        self.object_value.free(rt);
        self.has.free(rt);
        self.keys.free(rt);
    }
};

const ValueListRoot = struct {
    rt: ?*core.JSRuntime = null,
    slices: [1]core.runtime.ValueRootSlice = undefined,
    frame: core.runtime.ValueRootFrame = .{},

    fn init(self: *ValueListRoot, rt: *core.JSRuntime, values: *[]core.JSValue) void {
        self.rt = rt;
        self.slices[0] = .{ .mutable = values };
        self.frame = .{
            .previous = rt.active_value_roots,
            .slices = &self.slices,
        };
        rt.active_value_roots = &self.frame;
    }

    fn deinit(self: *ValueListRoot) void {
        const rt = self.rt orelse return;
        rt.active_value_roots = self.frame.previous;
        self.rt = null;
    }
};

pub fn qjsCollectionIteratorMethodCall(
    ctx: *core.JSContext,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    name: []const u8,
    args: []const core.JSValue,
) !?core.JSValue {
    _ = args;
    const owner_class = collectionMethodOwnerClass(function_object) orelse return null;
    if (owner_class != core.class.ids.map and owner_class != core.class.ids.set) return null;
    const method_id: u32 = if (std.mem.eql(u8, name, "keys"))
        7
    else if (std.mem.eql(u8, name, "values"))
        8
    else if (std.mem.eql(u8, name, "entries"))
        9
    else
        return null;
    const receiver = object_ops.objectFromValue(this_value) orelse return @as(?core.JSValue, try throwCollectionReceiverTypeError(ctx, global, owner_class));
    if (receiver.class_id != owner_class) return @as(?core.JSValue, try throwCollectionReceiverTypeError(ctx, global, owner_class));
    return try builtins.collection.methodCallWithGlobal(ctx, global, this_value, method_id, &.{}, &.{});
}

pub fn qjsCollectionForEachCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    name: []const u8,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (!std.mem.eql(u8, name, "forEach")) return null;
    const owner_class = collectionMethodOwnerClass(function_object) orelse return null;
    if (owner_class != core.class.ids.map and owner_class != core.class.ids.set) return null;
    const receiver = object_ops.objectFromValue(this_value) orelse return @as(?core.JSValue, try throwCollectionReceiverTypeError(ctx, global, owner_class));
    if (receiver.class_id != owner_class) return @as(?core.JSValue, try throwCollectionReceiverTypeError(ctx, global, owner_class));
    if (args.len < 1 or !call_runtime.isCallableValue(args[0])) return error.TypeError;
    const callback = args[0];
    const this_arg = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    var index: usize = 0;
    while (index < receiver.collectionEntriesSlot().*.len) : (index += 1) {
        const entry = receiver.collectionEntriesSlot().*[index];
        if (!entry.active) continue;
        const callback_args = if (receiver.class_id == core.class.ids.set)
            [_]core.JSValue{ entry.key, entry.key, receiver.value() }
        else
            [_]core.JSValue{ entry.value, entry.key, receiver.value() };
        const result = try call_runtime.callValueOrBytecode(ctx, output, global, this_arg, callback, &callback_args, caller_function, caller_frame);
        result.free(ctx.runtime);
    }
    return core.JSValue.undefinedValue();
}

pub fn qjsSetMethodCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    name: []const u8,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const owner_class = collectionMethodOwnerClass(function_object) orelse return null;
    if (owner_class != core.class.ids.set) return null;
    const mode = qjsSetMethodMode(name) orelse return null;
    const receiver = object_ops.objectFromValue(this_value) orelse return @as(?core.JSValue, try throwCollectionReceiverTypeError(ctx, global, core.class.ids.set));
    if (receiver.class_id != core.class.ids.set) return @as(?core.JSValue, try throwCollectionReceiverTypeError(ctx, global, core.class.ids.set));
    const other_value = if (args.len >= 1) args[0] else return error.TypeError;
    var other_record = try qjsGetSetRecord(ctx, output, global, other_value, caller_function, caller_frame);
    defer other_record.deinit(ctx.runtime);
    return switch (mode) {
        .difference => try qjsSetDifference(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .intersection => try qjsSetIntersection(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .is_disjoint_from => try qjsSetIsDisjointFrom(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .is_subset_of => try qjsSetIsSubsetOf(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .is_superset_of => try qjsSetIsSupersetOf(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .symmetric_difference => try qjsSetSymmetricDifference(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .union_ => try qjsSetUnion(ctx, output, global, receiver, other_record, caller_function, caller_frame),
    };
}

pub fn qjsCollectionNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const receiver = object_ops.objectFromValue(this_value) orelse {
        if (collectionMethodOwnerClass(function_object)) |owner_class| {
            return @as(?core.JSValue, try throwCollectionReceiverTypeError(ctx, global, owner_class));
        }
        return error.TypeError;
    };
    if (collectionMethodOwnerClass(function_object)) |owner_class| {
        if (receiver.class_id != owner_class) return @as(?core.JSValue, try throwCollectionReceiverTypeError(ctx, global, owner_class));
    }

    const method: builtins.collection.PrototypeMethod = switch (id) {
        @intFromEnum(builtins.collection.PrototypeMethod.set) => .set,
        @intFromEnum(builtins.collection.PrototypeMethod.get) => .get,
        @intFromEnum(builtins.collection.PrototypeMethod.has) => .has,
        @intFromEnum(builtins.collection.PrototypeMethod.delete) => .delete,
        @intFromEnum(builtins.collection.PrototypeMethod.clear) => .clear,
        @intFromEnum(builtins.collection.PrototypeMethod.add) => .add,
        @intFromEnum(builtins.collection.PrototypeMethod.keys) => .keys,
        @intFromEnum(builtins.collection.PrototypeMethod.values) => .values,
        @intFromEnum(builtins.collection.PrototypeMethod.entries) => .entries,
        @intFromEnum(builtins.collection.PrototypeMethod.for_each) => .for_each,
        @intFromEnum(builtins.collection.PrototypeMethod.get_or_insert) => .get_or_insert,
        @intFromEnum(builtins.collection.PrototypeMethod.get_or_insert_computed) => .get_or_insert_computed,
        @intFromEnum(builtins.collection.PrototypeMethod.size_getter) => .size_getter,
        @intFromEnum(builtins.collection.PrototypeMethod.difference) => .difference,
        @intFromEnum(builtins.collection.PrototypeMethod.intersection) => .intersection,
        @intFromEnum(builtins.collection.PrototypeMethod.is_disjoint_from) => .is_disjoint_from,
        @intFromEnum(builtins.collection.PrototypeMethod.is_subset_of) => .is_subset_of,
        @intFromEnum(builtins.collection.PrototypeMethod.is_superset_of) => .is_superset_of,
        @intFromEnum(builtins.collection.PrototypeMethod.symmetric_difference) => .symmetric_difference,
        @intFromEnum(builtins.collection.PrototypeMethod.union_) => .union_,
        else => return null,
    };

    if (collectionCallResultIsDropped(caller_function, caller_frame)) {
        const handled = builtins.collection.methodCallDroppedResult(ctx.runtime, receiver, id, args) catch |err| switch (err) {
            error.TypeError => return @as(?core.JSValue, try throwCollectionMethodTypeError(ctx, global, receiver, method, args)),
            else => return err,
        };
        if (handled) return core.JSValue.undefinedValue();
    }

    return switch (method) {
        .set,
        .get,
        .has,
        .delete,
        .clear,
        .add,
        .keys,
        .values,
        .entries,
        .get_or_insert,
        .size_getter,
        => builtins.collection.methodCallObjectWithGlobal(ctx, global, receiver, id, args, &.{}) catch |err| switch (err) {
            error.TypeError => return @as(?core.JSValue, try throwCollectionMethodTypeError(ctx, global, receiver, method, args)),
            else => err,
        },
        .for_each => try qjsCollectionForEachRecord(ctx, output, global, this_value, receiver, args, caller_function, caller_frame),
        .get_or_insert_computed => try qjsMapGetOrInsertComputed(ctx, output, global, this_value, function_object, args, caller_function, caller_frame),
        .difference,
        .intersection,
        .is_disjoint_from,
        .is_subset_of,
        .is_superset_of,
        .symmetric_difference,
        .union_,
        => try qjsSetMethodRecord(ctx, output, global, receiver, method, args, caller_function, caller_frame),
        .iterator_next => return null,
    };
}

fn collectionCallResultIsDropped(caller_function: ?*const bytecode.Bytecode, caller_frame: ?*frame_mod.Frame) bool {
    const function = caller_function orelse return false;
    const frame = caller_frame orelse return false;
    return frame.pc < function.code.len and function.code[frame.pc] == bytecode.opcode.op.drop;
}

fn qjsCollectionForEachRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    receiver: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (receiver.class_id != core.class.ids.map and receiver.class_id != core.class.ids.set) return throwCollectionReceiverTypeError(ctx, global, receiver.class_id);
    if (args.len < 1 or !call_runtime.isCallableValue(args[0])) return error.TypeError;
    const callback = args[0];
    const this_arg = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    var index: usize = 0;
    while (index < receiver.collectionEntriesSlot().*.len) : (index += 1) {
        const entry = receiver.collectionEntriesSlot().*[index];
        if (!entry.active) continue;
        const callback_args = if (receiver.class_id == core.class.ids.set)
            [_]core.JSValue{ entry.key, entry.key, this_value }
        else
            [_]core.JSValue{ entry.value, entry.key, this_value };
        const result = try call_runtime.callValueOrBytecode(ctx, output, global, this_arg, callback, &callback_args, caller_function, caller_frame);
        result.free(ctx.runtime);
    }
    return core.JSValue.undefinedValue();
}

fn qjsSetMethodRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    method: builtins.collection.PrototypeMethod,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (receiver.class_id != core.class.ids.set) return throwCollectionReceiverTypeError(ctx, global, core.class.ids.set);
    const other_value = if (args.len >= 1) args[0] else return error.TypeError;
    var other_record = try qjsGetSetRecord(ctx, output, global, other_value, caller_function, caller_frame);
    defer other_record.deinit(ctx.runtime);
    const mode = qjsSetMethodModeFromRecord(method) orelse return error.TypeError;
    return switch (mode) {
        .difference => try qjsSetDifference(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .intersection => try qjsSetIntersection(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .is_disjoint_from => try qjsSetIsDisjointFrom(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .is_subset_of => try qjsSetIsSubsetOf(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .is_superset_of => try qjsSetIsSupersetOf(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .symmetric_difference => try qjsSetSymmetricDifference(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .union_ => try qjsSetUnion(ctx, output, global, receiver, other_record, caller_function, caller_frame),
    };
}

fn qjsSetMethodMode(name: []const u8) ?SetMethodMode {
    if (std.mem.eql(u8, name, "difference")) return .difference;
    if (std.mem.eql(u8, name, "intersection")) return .intersection;
    if (std.mem.eql(u8, name, "isDisjointFrom")) return .is_disjoint_from;
    if (std.mem.eql(u8, name, "isSubsetOf")) return .is_subset_of;
    if (std.mem.eql(u8, name, "isSupersetOf")) return .is_superset_of;
    if (std.mem.eql(u8, name, "symmetricDifference")) return .symmetric_difference;
    if (std.mem.eql(u8, name, "union")) return .union_;
    return null;
}

fn qjsSetMethodModeFromRecord(method: builtins.collection.PrototypeMethod) ?SetMethodMode {
    return switch (method) {
        .difference => .difference,
        .intersection => .intersection,
        .is_disjoint_from => .is_disjoint_from,
        .is_subset_of => .is_subset_of,
        .is_superset_of => .is_superset_of,
        .symmetric_difference => .symmetric_difference,
        .union_ => .union_,
        else => null,
    };
}

fn qjsGetSetRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    other_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !SetLikeRecordVm {
    const object = object_ops.objectFromValue(other_value) orelse return error.TypeError;
    if (object.class_id == core.class.ids.set or object.class_id == core.class.ids.map) {
        return .{
            .object_value = other_value.dup(),
            .size = @floatFromInt(qjsSetStrongSize(object)),
            .has = core.JSValue.undefinedValue(),
            .keys = core.JSValue.undefinedValue(),
            .native_kind = if (object.class_id == core.class.ids.set) .set else .map,
        };
    }

    const raw_size = try object_ops.getValueProperty(ctx, output, global, other_value, core.atom.predefinedId("size", .string).?, caller_function, caller_frame);
    defer raw_size.free(ctx.runtime);
    const size_value = if (raw_size.isObject())
        try coercion_ops.toPrimitiveForNumber(ctx, output, global, raw_size)
    else
        raw_size.dup();
    defer size_value.free(ctx.runtime);
    const number_value = try value_ops.toNumberValue(ctx.runtime, size_value);
    defer number_value.free(ctx.runtime);
    const size_number = value_ops.numberValue(number_value) orelse return error.TypeError;
    if (std.math.isNan(size_number)) return error.TypeError;

    const has_key = try ctx.runtime.internAtom("has");
    defer ctx.runtime.atoms.free(has_key);
    const has_value = try object_ops.getValueProperty(ctx, output, global, other_value, has_key, caller_function, caller_frame);
    errdefer has_value.free(ctx.runtime);
    if (!call_runtime.isCallableValue(has_value)) return error.TypeError;

    const keys_key = try ctx.runtime.internAtom("keys");
    defer ctx.runtime.atoms.free(keys_key);
    const keys_value = try object_ops.getValueProperty(ctx, output, global, other_value, keys_key, caller_function, caller_frame);
    errdefer keys_value.free(ctx.runtime);
    if (!call_runtime.isCallableValue(keys_value)) return error.TypeError;

    return .{
        .object_value = other_value.dup(),
        .size = size_number,
        .has = has_value,
        .keys = keys_value,
        .native_kind = .none,
    };
}

fn qjsSetStrongSize(object: *core.Object) usize {
    var count: usize = 0;
    for (object.collectionEntriesSlot().*) |entry| {
        if (entry.active) count += 1;
    }
    return count;
}

fn qjsConstructPlainSet(ctx: *core.JSContext, global: *core.Object) !core.JSValue {
    const set_proto = object_ops.constructorPrototypeFromGlobal(ctx.runtime, global, "Set") orelse return error.TypeError;
    return builtins.collection.constructWithPrototype(ctx.runtime, 2, set_proto);
}

fn qjsSetAddValue(rt: *core.JSRuntime, set_value: core.JSValue, key: core.JSValue) !void {
    const out = try builtins.collection.methodCall(rt, set_value, 6, &.{key});
    out.free(rt);
}

fn qjsSetDeleteValue(rt: *core.JSRuntime, set_value: core.JSValue, key: core.JSValue) !void {
    const out = try builtins.collection.methodCall(rt, set_value, 4, &.{key});
    out.free(rt);
}

fn qjsSetHasValue(rt: *core.JSRuntime, set_value: core.JSValue, key: core.JSValue) !bool {
    const out = try builtins.collection.methodCall(rt, set_value, 3, &.{key});
    defer out.free(rt);
    return coercion_ops.valueTruthy(out);
}

fn qjsSetLikeHas(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    record: SetLikeRecordVm,
    key: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    if (record.native_kind != .none) {
        const out = try builtins.collection.methodCall(ctx.runtime, record.object_value, 3, &.{key});
        defer out.free(ctx.runtime);
        return coercion_ops.valueTruthy(out);
    }
    const out = try call_runtime.callValueOrBytecode(ctx, output, global, record.object_value, record.has, &.{key}, caller_function, caller_frame);
    defer out.free(ctx.runtime);
    return coercion_ops.valueTruthy(out);
}

fn qjsSetLikeKeysIterator(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    record: SetLikeRecordVm,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const source = if (record.native_kind != .none)
        try builtins.collection.methodCall(ctx.runtime, record.object_value, 7, &.{})
    else
        try call_runtime.callValueOrBytecode(ctx, output, global, record.object_value, record.keys, &.{}, caller_function, caller_frame);
    errdefer source.free(ctx.runtime);
    const iterator_object = object_ops.objectFromValue(source) orelse return error.TypeError;
    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    const next_method = try object_ops.getValueProperty(ctx, output, global, source, next_key, caller_function, caller_frame);
    defer next_method.free(ctx.runtime);
    if (!call_runtime.isCallableValue(next_method)) return error.TypeError;
    const cached = iterator_object.cachedIteratorNextSlot();
    try iterator_object.setOptionalValueSlot(ctx.runtime, cached, next_method.dup());
    return source;
}

fn qjsSetCloneReceiver(ctx: *core.JSContext, global: *core.Object, receiver: *core.Object) !core.JSValue {
    const result_value = try qjsConstructPlainSet(ctx, global);
    errdefer result_value.free(ctx.runtime);
    var index: usize = 0;
    while (index < receiver.collectionEntriesSlot().*.len) : (index += 1) {
        const entry = receiver.collectionEntriesSlot().*[index];
        if (!entry.active) continue;
        try qjsSetAddValue(ctx.runtime, result_value, entry.key);
    }
    return result_value;
}

fn qjsSetSnapshotKeys(rt: *core.JSRuntime, receiver: *core.Object) ![]core.JSValue {
    const count = qjsSetStrongSize(receiver);
    if (count == 0) return &.{};
    const keys = try rt.memory.alloc(core.JSValue, count);
    errdefer rt.memory.free(core.JSValue, keys);
    var out: usize = 0;
    errdefer {
        for (keys[0..out]) |key| key.free(rt);
    }
    for (receiver.collectionEntriesSlot().*) |entry| {
        if (!entry.active) continue;
        keys[out] = entry.key.dup();
        out += 1;
    }
    return keys;
}

fn qjsFreeValueList(rt: *core.JSRuntime, values: []core.JSValue) void {
    for (values) |value| value.free(rt);
    if (values.len != 0) rt.memory.free(core.JSValue, values);
}

test "set difference snapshot key root exposes dynamic key slice" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const first_atom = try rt.atoms.newValueSymbol("gc-set-difference-snapshot-key");
    var keys = try rt.memory.alloc(core.JSValue, 1);
    keys[0] = core.JSValue.symbol(first_atom);
    defer qjsFreeValueList(rt, keys);

    var keys_root = ValueListRoot{};
    keys_root.init(rt, &keys);
    defer keys_root.deinit();

    const Visitor = struct {
        atom_id: u32,
        saw_key: bool = false,

        fn visitValue(context: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (slot.asSymbolAtom()) |atom_id| {
                if (atom_id == self.atom_id) self.saw_key = true;
            }
        }

        fn visitObject(context: *anyopaque, slot: *?*core.Object) core.runtime.RootTraceError!void {
            _ = context;
            _ = slot;
        }
    };
    var state = Visitor{ .atom_id = first_atom };
    var visitor = core.runtime.RootVisitor{
        .context = &state,
        .visit_value = Visitor.visitValue,
        .visit_object = Visitor.visitObject,
    };
    try rt.traceActiveRoots(&visitor);

    try std.testing.expect(state.saw_key);
}

fn qjsSetDifference(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const result_value = try qjsConstructPlainSet(ctx, global);
    errdefer result_value.free(ctx.runtime);
    if (@as(f64, @floatFromInt(qjsSetStrongSize(receiver))) > other_record.size) {
        var copy_index: usize = 0;
        while (copy_index < receiver.collectionEntriesSlot().*.len) : (copy_index += 1) {
            const entry = receiver.collectionEntriesSlot().*[copy_index];
            if (!entry.active) continue;
            try qjsSetAddValue(ctx.runtime, result_value, entry.key);
        }
        var iterator_value = try qjsSetLikeKeysIterator(ctx, output, global, other_record, caller_function, caller_frame);
        defer iterator_value.free(ctx.runtime);
        var iterator_done = false;
        while (true) {
            const step = call_runtime.iteratorStepValue(ctx, output, global, iterator_value) catch |err| {
                if (!iterator_done) forof_ops.closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
                return err;
            };
            defer step.value.free(ctx.runtime);
            if (step.done) {
                iterator_done = true;
                break;
            }
            try qjsSetDeleteValue(ctx.runtime, result_value, step.value);
        }
    } else {
        var keys = try qjsSetSnapshotKeys(ctx.runtime, receiver);
        defer qjsFreeValueList(ctx.runtime, keys);
        var keys_root = ValueListRoot{};
        keys_root.init(ctx.runtime, &keys);
        defer keys_root.deinit();
        for (keys) |key| {
            if (!try qjsSetLikeHas(ctx, output, global, other_record, key, caller_function, caller_frame)) {
                try qjsSetAddValue(ctx.runtime, result_value, key);
            }
        }
    }
    return result_value;
}

fn qjsSetIntersection(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const result_value = try qjsConstructPlainSet(ctx, global);
    errdefer result_value.free(ctx.runtime);
    if (@as(f64, @floatFromInt(qjsSetStrongSize(receiver))) <= other_record.size) {
        var index: usize = 0;
        while (index < receiver.collectionEntriesSlot().*.len) : (index += 1) {
            const entry = receiver.collectionEntriesSlot().*[index];
            if (!entry.active) continue;
            if (try qjsSetLikeHas(ctx, output, global, other_record, entry.key, caller_function, caller_frame)) {
                try qjsSetAddValue(ctx.runtime, result_value, entry.key);
            }
        }
    } else {
        var iterator_value = try qjsSetLikeKeysIterator(ctx, output, global, other_record, caller_function, caller_frame);
        defer iterator_value.free(ctx.runtime);
        var iterator_done = false;
        while (true) {
            const step = call_runtime.iteratorStepValue(ctx, output, global, iterator_value) catch |err| {
                if (!iterator_done) forof_ops.closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
                return err;
            };
            defer step.value.free(ctx.runtime);
            if (step.done) {
                iterator_done = true;
                break;
            }
            if (try qjsSetHasValue(ctx.runtime, receiver.value(), step.value)) {
                try qjsSetAddValue(ctx.runtime, result_value, step.value);
            }
        }
    }
    return result_value;
}

fn qjsSetUnion(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var iterator_value = try qjsSetLikeKeysIterator(ctx, output, global, other_record, caller_function, caller_frame);
    defer iterator_value.free(ctx.runtime);
    const result_value = try qjsSetCloneReceiver(ctx, global, receiver);
    errdefer result_value.free(ctx.runtime);
    var iterator_done = false;
    while (true) {
        const step = call_runtime.iteratorStepValue(ctx, output, global, iterator_value) catch |err| {
            if (!iterator_done) forof_ops.closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
            return err;
        };
        defer step.value.free(ctx.runtime);
        if (step.done) {
            iterator_done = true;
            break;
        }
        try qjsSetAddValue(ctx.runtime, result_value, step.value);
    }
    return result_value;
}

fn qjsSetSymmetricDifference(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var iterator_value = try qjsSetLikeKeysIterator(ctx, output, global, other_record, caller_function, caller_frame);
    defer iterator_value.free(ctx.runtime);
    const result_value = try qjsSetCloneReceiver(ctx, global, receiver);
    errdefer result_value.free(ctx.runtime);
    var iterator_done = false;
    while (true) {
        const step = call_runtime.iteratorStepValue(ctx, output, global, iterator_value) catch |err| {
            if (!iterator_done) forof_ops.closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
            return err;
        };
        defer step.value.free(ctx.runtime);
        if (step.done) {
            iterator_done = true;
            break;
        }
        if (try qjsSetHasValue(ctx.runtime, receiver.value(), step.value)) {
            try qjsSetDeleteValue(ctx.runtime, result_value, step.value);
        } else if (!try qjsSetHasValue(ctx.runtime, result_value, step.value)) {
            try qjsSetAddValue(ctx.runtime, result_value, step.value);
        }
    }
    return result_value;
}

fn qjsSetIsDisjointFrom(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (@as(f64, @floatFromInt(qjsSetStrongSize(receiver))) <= other_record.size) {
        var index: usize = 0;
        while (index < receiver.collectionEntriesSlot().*.len) : (index += 1) {
            const entry = receiver.collectionEntriesSlot().*[index];
            if (!entry.active) continue;
            if (try qjsSetLikeHas(ctx, output, global, other_record, entry.key, caller_function, caller_frame)) {
                return core.JSValue.boolean(false);
            }
        }
        return core.JSValue.boolean(true);
    }

    var iterator_value = try qjsSetLikeKeysIterator(ctx, output, global, other_record, caller_function, caller_frame);
    defer iterator_value.free(ctx.runtime);
    var iterator_done = false;
    while (true) {
        const step = call_runtime.iteratorStepValue(ctx, output, global, iterator_value) catch |err| {
            if (!iterator_done) forof_ops.closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
            return err;
        };
        defer step.value.free(ctx.runtime);
        if (step.done) {
            iterator_done = true;
            return core.JSValue.boolean(true);
        }
        if (try qjsSetHasValue(ctx.runtime, receiver.value(), step.value)) {
            forof_ops.closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
            iterator_done = true;
            return core.JSValue.boolean(false);
        }
    }
}

fn qjsSetIsSubsetOf(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (@as(f64, @floatFromInt(qjsSetStrongSize(receiver))) > other_record.size) return core.JSValue.boolean(false);
    var index: usize = 0;
    while (index < receiver.collectionEntriesSlot().*.len) : (index += 1) {
        const entry = receiver.collectionEntriesSlot().*[index];
        if (!entry.active) continue;
        if (!try qjsSetLikeHas(ctx, output, global, other_record, entry.key, caller_function, caller_frame)) {
            return core.JSValue.boolean(false);
        }
    }
    return core.JSValue.boolean(true);
}

fn qjsSetIsSupersetOf(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (@as(f64, @floatFromInt(qjsSetStrongSize(receiver))) < other_record.size) return core.JSValue.boolean(false);
    var iterator_value = try qjsSetLikeKeysIterator(ctx, output, global, other_record, caller_function, caller_frame);
    defer iterator_value.free(ctx.runtime);
    var iterator_done = false;
    while (true) {
        const step = call_runtime.iteratorStepValue(ctx, output, global, iterator_value) catch |err| {
            if (!iterator_done) forof_ops.closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
            return err;
        };
        defer step.value.free(ctx.runtime);
        if (step.done) {
            iterator_done = true;
            return core.JSValue.boolean(true);
        }
        if (!try qjsSetHasValue(ctx.runtime, receiver.value(), step.value)) {
            forof_ops.closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
            iterator_done = true;
            return core.JSValue.boolean(false);
        }
    }
}

pub fn qjsMapGroupByCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const map_proto = object_ops.constructorPrototypeFromGlobal(ctx.runtime, global, "Map") orelse return error.TypeError;
    return qjsMapGroupByRecord(ctx, output, global, args, map_proto, caller_function, caller_frame);
}

pub fn qjsMapGroupByRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    prototype: ?*core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 2) return error.TypeError;
    if (!call_runtime.isCallableValue(args[1])) return error.TypeError;

    const map_value = try builtins.collection.constructWithPrototype(ctx.runtime, 1, prototype);
    errdefer map_value.free(ctx.runtime);

    const iterator_value = try call_runtime.iteratorForValue(ctx, output, global, args[0], caller_function, caller_frame);
    defer iterator_value.free(ctx.runtime);

    var index: usize = 0;
    while (true) {
        const max_safe_integer: usize = 9007199254740991;
        if (index >= max_safe_integer) {
            try call_runtime.closeIteratorForFromEntriesAbrupt(ctx, output, global, iterator_value);
            return error.TypeError;
        }

        const step = try call_runtime.iteratorStepValue(ctx, output, global, iterator_value);
        defer step.value.free(ctx.runtime);
        if (step.done) return map_value;

        const index_value = value_ops.numberToValue(@floatFromInt(index));
        const key = call_runtime.callValueOrBytecode(
            ctx,
            output,
            global,
            core.JSValue.undefinedValue(),
            args[1],
            &.{ step.value, index_value },
            caller_function,
            caller_frame,
        ) catch |err| {
            try call_runtime.closeIteratorForFromEntriesAbrupt(ctx, output, global, iterator_value);
            return err;
        };
        defer key.free(ctx.runtime);

        qjsMapAppendGroupByValue(ctx, global, map_value, key, step.value) catch |err| {
            try call_runtime.closeIteratorForFromEntriesAbrupt(ctx, output, global, iterator_value);
            return err;
        };
        index += 1;
    }
}

pub fn qjsMapGetOrInsertComputed(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver_value: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const receiver = property_ops.expectObject(receiver_value) catch return null;
    if (receiver.class_id != core.class.ids.weakmap and receiver.class_id != core.class.ids.map) return null;
    if (collectionMethodOwnerClass(function_object)) |owner_class| {
        if (receiver.class_id != owner_class) return @as(?core.JSValue, try throwCollectionReceiverTypeError(ctx, global, owner_class));
    }
    if (args.len < 2) return error.TypeError;
    if (!call_runtime.isCallableValue(args[1])) return error.TypeError;

    const key = if (receiver.class_id == core.class.ids.map)
        canonicalizeMapKey(args[0])
    else
        args[0].dup();
    defer key.free(ctx.runtime);
    if (receiver.class_id == core.class.ids.weakmap and !builtins.symbol.canBeHeldWeakly(ctx.runtime, key)) {
        return @as(?core.JSValue, try call_runtime.throwTypeErrorMessage(ctx, global, "invalid value used as WeakMap key"));
    }

    const has_value = try builtins.collection.methodCall(ctx.runtime, receiver_value, 3, &.{key});
    defer has_value.free(ctx.runtime);
    if (has_value.asBool() == true) {
        return try builtins.collection.methodCall(ctx.runtime, receiver_value, 2, &.{key});
    }

    const computed = try call_runtime.callValueOrBytecode(
        ctx,
        output,
        global,
        core.JSValue.undefinedValue(),
        args[1],
        &.{key},
        caller_function,
        caller_frame,
    );
    errdefer computed.free(ctx.runtime);
    const set_result = try builtins.collection.methodCall(ctx.runtime, receiver_value, 1, &.{ key, computed });
    set_result.free(ctx.runtime);
    return computed;
}

pub fn collectionMethodOwnerClass(function_object: *core.Object) ?core.ClassId {
    const cached = function_object.collectionMethodOwnerClass();
    if (cached != core.class.invalid_class_id) return cached;
    return null;
}

fn canonicalizeMapKey(key: core.JSValue) core.JSValue {
    if (key.asFloat64()) |number| {
        if (number == 0) return core.JSValue.int32(0);
    }
    return key.dup();
}

fn throwCollectionReceiverTypeError(ctx: *core.JSContext, global: *core.Object, owner_class: core.ClassId) !core.JSValue {
    return call_runtime.throwTypeErrorMessage(ctx, global, collectionReceiverMessage(owner_class));
}

fn throwCollectionMethodTypeError(
    ctx: *core.JSContext,
    global: *core.Object,
    receiver: *core.Object,
    method: builtins.collection.PrototypeMethod,
    args: []const core.JSValue,
) !core.JSValue {
    if (receiver.class_id == core.class.ids.weakmap and
        (method == .set or method == .get_or_insert or method == .get_or_insert_computed) and
        args.len >= 1 and !builtins.symbol.canBeHeldWeakly(ctx.runtime, args[0]))
    {
        return call_runtime.throwTypeErrorMessage(ctx, global, "invalid value used as WeakMap key");
    }
    if (receiver.class_id == core.class.ids.weakset and
        method == .add and
        args.len >= 1 and !builtins.symbol.canBeHeldWeakly(ctx.runtime, args[0]))
    {
        return call_runtime.throwTypeErrorMessage(ctx, global, "invalid value used in weak set");
    }
    return call_runtime.throwTypeErrorMessage(ctx, global, collectionReceiverMessage(receiver.class_id));
}

fn collectionReceiverMessage(owner_class: core.ClassId) []const u8 {
    if (owner_class == core.class.ids.map) return "Map object expected";
    if (owner_class == core.class.ids.set) return "Set object expected";
    if (owner_class == core.class.ids.weakmap) return "WeakMap object expected";
    if (owner_class == core.class.ids.weakset) return "WeakSet object expected";
    return "not an object";
}

fn qjsMapAppendGroupByValue(
    ctx: *core.JSContext,
    global: *core.Object,
    map_value: core.JSValue,
    key: core.JSValue,
    value: core.JSValue,
) !void {
    const existing = try builtins.collection.methodCall(ctx.runtime, map_value, 2, &.{key});
    defer existing.free(ctx.runtime);

    if (!existing.isUndefined()) {
        const group = try property_ops.expectObject(existing);
        if (!group.flags.is_array) return error.TypeError;
        try group.defineOwnProperty(
            ctx.runtime,
            core.atom.atomFromUInt32(group.length),
            core.Descriptor.data(value, true, true, true),
        );
        return;
    }

    const group = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
    errdefer core.Object.destroyFromHeader(ctx.runtime, &group.header);
    try group.defineOwnProperty(
        ctx.runtime,
        core.atom.atomFromUInt32(group.length),
        core.Descriptor.data(value, true, true, true),
    );
    const set_result = try builtins.collection.methodCall(ctx.runtime, map_value, 1, &.{ key, group.value() });
    defer set_result.free(ctx.runtime);
    group.value().free(ctx.runtime);
}

// Uint8Array hex/base64 codecs (moved from the VM call runtime).

pub fn decodeHexBytes(rt: *core.JSRuntime, source: []const u8, reject_odd: bool) !std.ArrayList(u8) {
    if (reject_odd and source.len % 2 != 0) return error.SyntaxError;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(rt.memory.allocator);
    var index: usize = 0;
    while (index + 1 < source.len) : (index += 2) {
        const hi = hexNibble(source[index]) orelse return error.SyntaxError;
        const lo = hexNibble(source[index + 1]) orelse return error.SyntaxError;
        try out.append(rt.memory.allocator, (hi << 4) | lo);
    }
    return out;
}

pub fn decodeHexInto(source: []const u8, target: []u8) !Uint8ArrayCodecProgress {
    if (source.len % 2 != 0) return error.SyntaxError;
    var read: usize = 0;
    var written: usize = 0;
    while (read < source.len and written < target.len) {
        const hi = hexNibble(source[read]) orelse return error.SyntaxError;
        const lo = hexNibble(source[read + 1]) orelse return error.SyntaxError;
        target[written] = (hi << 4) | lo;
        read += 2;
        written += 1;
    }
    return .{ .read = read, .written = written };
}

pub fn encodeHexBytes(rt: *core.JSRuntime, bytes: []const u8) !std.ArrayList(u8) {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(rt.memory.allocator);
    for (bytes) |byte| {
        try out.append(rt.memory.allocator, unicode_lib.asciiLowerHexDigitChar(byte >> 4));
        try out.append(rt.memory.allocator, unicode_lib.asciiLowerHexDigitChar(byte & 0x0f));
    }
    return out;
}

pub fn hexNibble(byte: u8) ?u8 {
    return unicode_lib.asciiHexDigitValueByte(byte);
}

pub const Base64Chunk = struct {
    bytes: [3]u8 = .{ 0, 0, 0 },
    len: usize = 0,
};

pub fn decodeBase64Bytes(
    rt: *core.JSRuntime,
    source: []const u8,
    alphabet: Uint8ArrayBase64Alphabet,
    last_chunk_handling: Uint8ArrayBase64LastChunkHandling,
) !std.ArrayList(u8) {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(rt.memory.allocator);
    _ = try decodeBase64Internal(rt, source, alphabet, last_chunk_handling, &out, null);
    return out;
}

pub fn decodeBase64Into(
    rt: *core.JSRuntime,
    source: []const u8,
    alphabet: Uint8ArrayBase64Alphabet,
    last_chunk_handling: Uint8ArrayBase64LastChunkHandling,
    target: []u8,
) !Uint8ArrayCodecProgress {
    if (target.len == 0) return .{ .read = 0, .written = 0 };
    return decodeBase64Internal(rt, source, alphabet, last_chunk_handling, null, target);
}

pub fn decodeBase64Internal(
    rt: *core.JSRuntime,
    source: []const u8,
    alphabet: Uint8ArrayBase64Alphabet,
    last_chunk_handling: Uint8ArrayBase64LastChunkHandling,
    out: ?*std.ArrayList(u8),
    target: ?[]u8,
) !Uint8ArrayCodecProgress {
    var chunk: [4]u8 = .{ 0, 0, 0, 0 };
    var chunk_len: usize = 0;
    var read_pos: usize = 0;
    var last_read: usize = 0;
    var written: usize = 0;
    var saw_padded_chunk = false;
    var pending_padded_chunk: ?Base64Chunk = null;
    var pending_padded_read: usize = 0;

    for (source, 0..) |byte, index| {
        if (unicode_lib.isAsciiWhitespaceByte(byte)) continue;
        read_pos = index + 1;
        if (saw_padded_chunk) return error.SyntaxError;
        if (byte != '=' and base64Value(byte, alphabet) == null) return error.SyntaxError;
        chunk[chunk_len] = byte;
        chunk_len += 1;
        if (chunk_len == 4) {
            const decoded = try decodeBase64Chunk(chunk, 4, alphabet, last_chunk_handling, false);
            if (chunk[2] == '=' or chunk[3] == '=') {
                pending_padded_chunk = decoded;
                pending_padded_read = read_pos;
                saw_padded_chunk = true;
                chunk_len = 0;
                continue;
            }
            if (target) |bytes| {
                if (decoded.len > bytes.len - written) return .{ .read = last_read, .written = written };
                if (decoded.len != 0) @memcpy(bytes[written..][0..decoded.len], decoded.bytes[0..decoded.len]);
            } else if (out) |list| {
                try list.appendSlice(rt.memory.allocator, decoded.bytes[0..decoded.len]);
            }
            written += decoded.len;
            last_read = read_pos;
            chunk_len = 0;
            if (target) |bytes| {
                if (written == bytes.len) return .{ .read = last_read, .written = written };
            }
        }
    }

    if (pending_padded_chunk) |decoded| {
        if (target) |bytes| {
            if (decoded.len > bytes.len - written) return .{ .read = last_read, .written = written };
            if (decoded.len != 0) @memcpy(bytes[written..][0..decoded.len], decoded.bytes[0..decoded.len]);
        } else if (out) |list| {
            try list.appendSlice(rt.memory.allocator, decoded.bytes[0..decoded.len]);
        }
        written += decoded.len;
        return .{ .read = pending_padded_read, .written = written };
    }
    if (chunk_len == 0) return .{ .read = last_read, .written = written };
    const decoded = try decodeBase64Chunk(chunk, chunk_len, alphabet, last_chunk_handling, true);
    if (decoded.len == 0 and last_chunk_handling == .stop_before_partial) return .{ .read = last_read, .written = written };
    if (target) |bytes| {
        if (decoded.len > bytes.len - written) return .{ .read = last_read, .written = written };
        if (decoded.len != 0) @memcpy(bytes[written..][0..decoded.len], decoded.bytes[0..decoded.len]);
    } else if (out) |list| {
        try list.appendSlice(rt.memory.allocator, decoded.bytes[0..decoded.len]);
    }
    written += decoded.len;
    return .{ .read = read_pos, .written = written };
}

pub fn decodeBase64Chunk(
    chunk: [4]u8,
    chunk_len: usize,
    alphabet: Uint8ArrayBase64Alphabet,
    last_chunk_handling: Uint8ArrayBase64LastChunkHandling,
    is_final: bool,
) !Base64Chunk {
    if (chunk_len == 0) return .{};
    if (chunk_len < 4) {
        var first_padding: ?usize = null;
        var i: usize = 0;
        while (i < chunk_len) : (i += 1) {
            if (chunk[i] == '=') {
                if (first_padding == null) first_padding = i;
            } else if (first_padding != null) {
                return error.SyntaxError;
            }
        }
        if (first_padding) |padding_index| {
            if (padding_index < 2) return error.SyntaxError;
            if (last_chunk_handling == .stop_before_partial and is_final) return .{};
            return error.SyntaxError;
        }
        if (chunk_len == 1) {
            if (last_chunk_handling == .stop_before_partial and is_final) return .{};
            return error.SyntaxError;
        }
        if (last_chunk_handling == .stop_before_partial and is_final) return .{};
        if (last_chunk_handling == .strict) return error.SyntaxError;
        const a = base64Value(chunk[0], alphabet) orelse return error.SyntaxError;
        const b = base64Value(chunk[1], alphabet) orelse return error.SyntaxError;
        var result = Base64Chunk{ .bytes = .{ (a << 2) | (b >> 4), 0, 0 }, .len = 1 };
        if (chunk_len == 3) {
            const c = base64Value(chunk[2], alphabet) orelse return error.SyntaxError;
            result.bytes[1] = ((b & 0x0f) << 4) | (c >> 2);
            result.len = 2;
        }
        return result;
    }

    if (chunk[0] == '=' or chunk[1] == '=') return error.SyntaxError;
    const a = base64Value(chunk[0], alphabet) orelse return error.SyntaxError;
    const b = base64Value(chunk[1], alphabet) orelse return error.SyntaxError;
    if (chunk[2] == '=') {
        if (chunk[3] != '=') return error.SyntaxError;
        if (last_chunk_handling == .strict and (b & 0x0f) != 0) return error.SyntaxError;
        return .{ .bytes = .{ (a << 2) | (b >> 4), 0, 0 }, .len = 1 };
    }
    const c = base64Value(chunk[2], alphabet) orelse return error.SyntaxError;
    if (chunk[3] == '=') {
        if (last_chunk_handling == .strict and (c & 0x03) != 0) return error.SyntaxError;
        return .{ .bytes = .{ (a << 2) | (b >> 4), ((b & 0x0f) << 4) | (c >> 2), 0 }, .len = 2 };
    }
    const d = base64Value(chunk[3], alphabet) orelse return error.SyntaxError;
    return .{ .bytes = .{ (a << 2) | (b >> 4), ((b & 0x0f) << 4) | (c >> 2), ((c & 0x03) << 6) | d }, .len = 3 };
}

pub fn encodeBase64Bytes(rt: *core.JSRuntime, bytes: []const u8, alphabet: Uint8ArrayBase64Alphabet, omit_padding: bool) !std.ArrayList(u8) {
    const table = if (alphabet == .base64) "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" else "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(rt.memory.allocator);
    var index: usize = 0;
    while (index < bytes.len) : (index += 3) {
        const rem = bytes.len - index;
        const b0 = bytes[index];
        const b1 = if (rem > 1) bytes[index + 1] else 0;
        const b2 = if (rem > 2) bytes[index + 2] else 0;
        try out.append(rt.memory.allocator, table[b0 >> 2]);
        try out.append(rt.memory.allocator, table[((b0 & 0x03) << 4) | (b1 >> 4)]);
        if (rem > 1) {
            try out.append(rt.memory.allocator, table[((b1 & 0x0f) << 2) | (b2 >> 6)]);
        } else if (!omit_padding) {
            try out.append(rt.memory.allocator, '=');
        }
        if (rem > 2) {
            try out.append(rt.memory.allocator, table[b2 & 0x3f]);
        } else if (!omit_padding) {
            try out.append(rt.memory.allocator, '=');
        }
    }
    return out;
}

pub fn base64Value(byte: u8, alphabet: Uint8ArrayBase64Alphabet) ?u8 {
    if (byte >= 'A' and byte <= 'Z') return byte - 'A';
    if (byte >= 'a' and byte <= 'z') return byte - 'a' + 26;
    if (byte >= '0' and byte <= '9') return byte - '0' + 52;
    if (alphabet == .base64 and byte == '+') return 62;
    if (alphabet == .base64 and byte == '/') return 63;
    if (alphabet == .base64url and byte == '-') return 62;
    if (alphabet == .base64url and byte == '_') return 63;
    return null;
}

// Array length/index helpers (moved from the VM call runtime).

pub const SparseIndexKey = struct {
    atom_id: core.Atom,
    index: usize,
};

pub fn lengthIndexValue(index: usize) core.JSValue {
    if (index <= @as(usize, @intCast(std.math.maxInt(i32)))) return core.JSValue.int32(@intCast(index));
    return core.JSValue.float64(@floatFromInt(index));
}

pub const LengthIndexAtom = struct {
    atom: core.Atom,
    owned: bool,

    pub fn deinit(self: LengthIndexAtom, rt: *core.JSRuntime) void {
        if (self.owned) rt.atoms.free(self.atom);
    }
};
