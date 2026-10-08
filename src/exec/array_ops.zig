//! Array, TypedArray, ArrayBuffer, DataView, and array-iterator builtins.
//!
//! Inputs and operand-stack values are borrowed while frame-rooted; returned
//! values are owned, and `pushOwned` transfers that ownership to the stack.
//! The alias wall preserves names and ownership seams across extracted exec
//! modules rather than joining their implementations. Keep the measured
//! `ctx`/`output`/`global`/caller-function/caller-frame ABI explicit, and keep
//! dense/typed-array hot arms separate from cold generic property paths.

const std = @import("std");
const bytecode = @import("../bytecode.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const core = @import("../core/root.zig");
const array_list_erased = @import("../core/array_list_erased.zig");
const method_ids = core.host_function.builtin_method_ids;
const construct_mod = @import("construct.zig");
const frame_mod = @import("frame.zig");
const iterator_ops = @import("iterator_ops.zig");
const property_ops = @import("property_ops.zig");
const zjs_vm = @import("zjs_vm.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");
const op = bytecode.opcode.op;
const exception_ops = @import("exception_ops.zig");

const call_runtime = @import("call_runtime.zig");
const call_site_mod = @import("call_site.zig");
const builtin_glue = @import("builtin_glue.zig");
const object_ops = @import("object_ops.zig");
const promise_ops = @import("promise_ops.zig");
const regexp_fastpath = @import("regexp_ops.zig");
const string_ops = @import("string_ops.zig");
const ActiveRootValueProbe = call_runtime.ActiveRootValueProbe;
const RegExpMatch = string_ops.RegExpMatch;
const callCollectionAdderFromVm = builtin_glue.callCollectionAdderFromVm;
const callValueOrBytecodeRoot = call_runtime.callValueOrBytecodeRoot;
const CallSite = call_site_mod.CallSite;
const callableObjectFromValue = object_ops.callableObjectFromValue;
const constructValueOrBytecode = call_runtime.constructValueOrBytecode;
const constructorPrototypeObject = object_ops.constructorPrototypeObject;
const createBytecodeFunctionObject = object_ops.createBytecodeFunctionObject;
const createCallSiteObject = object_ops.createCallSiteObject;
const createDataPropertyOrThrow = object_ops.createDataPropertyOrThrow;
const createRegExpIndexPair = regexp_fastpath.createRegExpIndexPair;
const defineRegExpIndicesGroupsProperty = object_ops.defineRegExpIndicesGroupsProperty;
const defineSplitValueElement = string_ops.defineSplitValueElement;
const deleteValuePropertyOrThrow = object_ops.deleteValuePropertyOrThrow;
const errorStackTraceLimit = exception_ops.errorStackTraceLimit;
const getIteratorMethod = call_runtime.getIteratorMethod;
const getStringPrototypeMethodId = string_ops.getStringPrototypeMethodId;
const getValueProperty = object_ops.getValueProperty;
const hasValueProperty = object_ops.hasValueProperty;
const isCallableValue = call_runtime.isCallableValue;
const isConstructorLike = call_runtime.isConstructorLike;
const objectFromValue = object_ops.objectFromValue;
const objectPrototypeFromGlobal = object_ops.objectPrototypeFromGlobal;
const primitiveObjectForAccess = object_ops.primitiveObjectForAccess;
const propertyAtomFromLengthIndex = object_ops.propertyAtomFromLengthIndex;
const propertyIndexFromLengthKey = object_ops.propertyIndexFromLengthKey;
const collectIteratorValues = call_runtime.collectIteratorValues;
const objectToStringIntrinsic = string_ops.objectToStringIntrinsic;
const objectEnumerableOwnPropertiesCall = object_ops.objectEnumerableOwnPropertiesCall;
const readInt = call_runtime.readInt;
const sameObjectIdentity = object_ops.sameObjectIdentity;
const setValueProperty = object_ops.setValueProperty;

/// Receiver element/length write for the array mutator builtins with the qjs
/// JS_PROP_THROW discipline (spec Set(O, P, V, true)): failures throw even for
/// sloppy callers, mirroring qjs JS_SetPropertyInt64 at the js_array_* sites.
fn setValuePropertyOrThrow(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object_value: core.JSValue,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    _ = try object_ops.setValuePropertyWithThrow(ctx, output, global, object_value, atom_id, value, caller_function, caller_frame, true);
}
const stringSliceValue = string_ops.stringSliceValue;
const throwTypeErrorMessage = exception_ops.throwTypeErrorMessage;
const toLengthIndex = value_ops.toLengthIndex;
const toNumberForDateMethod = value_ops.toNumberForDateMethod;
const toPrimitiveForNumber = value_ops.toPrimitiveForNumber;
const toStringForAnnexB = string_ops.toStringForAnnexB;
const valueTruthy = value_ops.valueTruthy;
const valuesStrictEqual = value_ops.valuesStrictEqual;

pub fn popCatchMarker(stack: *stack_mod.Stack) !??usize {
    while (stack.peek()) |marker| {
        if (iterator_ops.isIteratorCatchMarker(marker)) {
            if (stack.len() < 3) return error.StackUnderflow;
            _ = try stack.pop();
            _ = try stack.pop();
            _ = try stack.pop();
            continue;
        }
        const popped = try stack.pop();
        if (marker.is(.catch_offset)) return popped.catchTarget();
    }
    return null;
}

pub fn arrayPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object {
    if (global.cachedRealmValue(rt, .array_prototype)) |stored| {
        return core.value_semantics.objectFromValue(stored);
    }
    if (global.getOwnDataObjectBorrowed(core.atom.ids.Array)) |constructor| {
        if (constructor.getOwnDataObjectBorrowed(core.atom.ids.prototype)) |prototype| return prototype;
    }
    return null;
}

pub fn arrayIteratorPrototypeFromContext(ctx: *core.JSContext, global: *core.Object) !*core.Object {
    return iterator_ops.arrayIteratorPrototypeFromContext(ctx, global);
}

pub fn pushFunctionClosure(
    ctx: *core.JSContext,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    global: *core.Object,
    index: usize,
) !void {
    const value = function.constantAt(index) orelse return error.InvalidBytecode;
    const object_value = try createBytecodeFunctionObject(ctx, frame, global, value);
    try stack.push(object_value);
}

/// Push/pop/splice use dedicated records and never enter this shared hub. Every
/// remaining id needs the materialized function object for TypedArray-vs-Array
/// disambiguation, species, or callbacks; null therefore signals a corrupt
/// dispatch and surfaces TypeError.
/// Every method body it dispatches to is `noinline`: this frame (and the
/// glue above it) stays live under each callback a method makes, so it must
/// not reserve the largest body's locals for all of them.
pub fn arrayPrototypeNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: ?*core.Object,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const array_mod = method_ids.array;
    const function_object_nonnull = function_object orelse return error.TypeError;
    const typed_method = std.enums.fromInt(TypedArrayMethod, id);
    if (typed_method) |method| switch (method) {
        .set => return typedArraySetCall(ctx, output, global, receiver, function_object_nonnull, args, caller_function, caller_frame),
        .slice => return typedArraySliceSubarrayCall(ctx, output, global, receiver, args, false),
        .subarray => return typedArraySliceSubarrayCall(ctx, output, global, receiver, args, true),
        else => {},
    };
    const method_id: u32 = if (typed_method) |method|
        @intFromEnum(typedArraySharedMethod(method) orelse return error.TypeError)
    else
        id;
    if (arrayIterationModeFromRecordId(method_id)) |mode| {
        return arrayIterationModeCall(ctx, output, global, receiver, function_object_nonnull, args, caller_function, caller_frame, mode);
    }
    return switch (method_id) {
        @intFromEnum(array_mod.PrototypeMethod.to_string) => arrayToStringCall(ctx, output, global, receiver, caller_function, caller_frame),
        @intFromEnum(array_mod.PrototypeMethod.to_locale_string) => arrayToLocaleStringCall(ctx, output, global, receiver, function_object_nonnull, caller_function, caller_frame),
        @intFromEnum(array_mod.PrototypeMethod.reduce) => arrayReduceCall(ctx, output, global, receiver, function_object_nonnull.value(), args, false),
        @intFromEnum(array_mod.PrototypeMethod.reduce_right) => arrayReduceCall(ctx, output, global, receiver, function_object_nonnull.value(), args, true),
        @intFromEnum(array_mod.PrototypeMethod.at) => arrayAtCall(ctx, output, global, receiver, function_object_nonnull.value(), args),
        @intFromEnum(array_mod.PrototypeMethod.includes) => arraySearchCall(ctx, output, global, receiver, function_object_nonnull, args, .includes),
        @intFromEnum(array_mod.PrototypeMethod.index_of) => arraySearchCall(ctx, output, global, receiver, function_object_nonnull, args, .index_of),
        @intFromEnum(array_mod.PrototypeMethod.last_index_of) => arraySearchCall(ctx, output, global, receiver, function_object_nonnull, args, .last_index_of),
        @intFromEnum(array_mod.PrototypeMethod.copy_within) => arrayCopyWithinCall(ctx, output, global, receiver, function_object_nonnull.value(), args),
        @intFromEnum(array_mod.PrototypeMethod.fill) => arrayFillCall(ctx, output, global, receiver, function_object_nonnull.value(), args),
        @intFromEnum(array_mod.PrototypeMethod.shift) => arrayShiftCall(ctx, output, global, receiver, function_object_nonnull.value()),
        @intFromEnum(array_mod.PrototypeMethod.unshift) => arrayUnshiftCall(ctx, output, global, receiver, function_object_nonnull.value(), args),
        @intFromEnum(array_mod.PrototypeMethod.reverse) => arrayReverseCall(ctx, output, global, receiver, function_object_nonnull.value(), caller_function, caller_frame),
        @intFromEnum(array_mod.PrototypeMethod.slice) => arraySliceCall(ctx, output, global, receiver, function_object_nonnull.value(), args),
        @intFromEnum(array_mod.PrototypeMethod.join) => arrayJoinCall(ctx, output, global, receiver, function_object_nonnull, args, caller_function, caller_frame),
        @intFromEnum(array_mod.PrototypeMethod.concat) => arrayConcatCall(ctx, output, global, receiver, function_object_nonnull.value(), args, caller_function, caller_frame),
        @intFromEnum(array_mod.PrototypeMethod.sort) => arraySortCall(ctx, output, global, receiver, function_object_nonnull.value(), args, caller_function, caller_frame),
        @intFromEnum(array_mod.PrototypeMethod.flat) => arrayFlatCall(ctx, output, global, receiver, args, false, caller_function, caller_frame),
        @intFromEnum(array_mod.PrototypeMethod.flat_map) => arrayFlatCall(ctx, output, global, receiver, args, true, caller_function, caller_frame),
        @intFromEnum(array_mod.PrototypeMethod.to_reversed) => arrayByCopyCall(ctx, output, global, receiver, function_object_nonnull.value(), args, .to_reversed, caller_function, caller_frame),
        @intFromEnum(array_mod.PrototypeMethod.to_sorted) => arrayByCopyCall(ctx, output, global, receiver, function_object_nonnull.value(), args, .to_sorted, caller_function, caller_frame),
        @intFromEnum(array_mod.PrototypeMethod.to_spliced) => arrayByCopyCall(ctx, output, global, receiver, function_object_nonnull.value(), args, .to_spliced, caller_function, caller_frame),
        @intFromEnum(array_mod.PrototypeMethod.with_) => arrayByCopyCall(ctx, output, global, receiver, function_object_nonnull.value(), args, .with_, caller_function, caller_frame),
        @intFromEnum(array_mod.PrototypeMethod.keys),
        @intFromEnum(array_mod.PrototypeMethod.values),
        @intFromEnum(array_mod.PrototypeMethod.entries),
        => arrayIteratorMethodRecord(ctx, global, receiver, function_object_nonnull, method_id),
        else => null,
    };
}

/// The Array.prototype body a %TypedArray%.prototype method shares. The body
/// applies the typed-array receiver checks for the typed function object.
/// `set`, `slice`, `subarray` and the statics have typed-only bodies.
fn typedArraySharedMethod(method: TypedArrayMethod) ?PrototypeMethod {
    return switch (method) {
        .from, .of, .set, .slice, .subarray => null,
        .to_locale_string => .to_locale_string,
        .map => .map,
        .filter => .filter,
        .reduce => .reduce,
        .reduce_right => .reduce_right,
        .for_each => .for_each,
        .some => .some,
        .every => .every,
        .find => .find,
        .find_index => .find_index,
        .find_last => .find_last,
        .find_last_index => .find_last_index,
        .includes => .includes,
        .index_of => .index_of,
        .last_index_of => .last_index_of,
        .at => .at,
        .copy_within => .copy_within,
        .fill => .fill,
        .join => .join,
        .reverse => .reverse,
        .sort => .sort,
        .to_reversed => .to_reversed,
        .to_sorted => .to_sorted,
        .with_ => .with_,
        .keys => .keys,
        .values => .values,
        .entries => .entries,
    };
}

pub fn buildCallSiteArray(ctx: *core.JSContext, global: *core.Object, skip: exception_ops.StackSkip) !core.JSValue {
    const array = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
    errdefer core.Object.destroyFromHeader(ctx.runtime, array.gcHeader());
    const limit = errorStackTraceLimit(global);
    // Without a frame to skip to, only the `limit` innermost frames print.
    const frames = try ctx.snapshotBacktraceFrames(if (skip.active()) std.math.maxInt(usize) else limit);
    defer ctx.freeBacktraceFrameSnapshot(frames);
    var idx = frames.len;
    var emitted: usize = 0;
    var skipping = skip.active();
    while (idx > 0) {
        idx -= 1;
        if (skipping) {
            if (skip.endsAt(frames[idx])) skipping = false;
            continue;
        }
        // The snapshot is not a root, and a freshly interned name has no other
        // holder until the CallSite stores it.
        const function_name = exception_ops.resolveBacktraceFunctionName(ctx, &frames[idx]);
        ctx.runtime.atoms.pinForHost(function_name);
        defer ctx.runtime.atoms.unpinForHost(function_name);
        if (emitted >= limit) break;
        const site = try createCallSiteObject(ctx, global, frames[idx]);
        try array.defineOwnProperty(ctx.runtime, core.Atom.taggedInt(@intCast(emitted)), core.Descriptor.data(site, .all));
        emitted += 1;
    }
    array.setArrayLength(@intCast(emitted));
    try array.defineOwnProperty(ctx.runtime, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(@intCast(emitted)), .{ .writable = true }));
    return array.value();
}

/// AggregateError step 4: IteratorToList(GetIterator(errors, sync)).
pub fn aggregateErrorsIterableToArray(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterable: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !*core.Object {
    const record = try iterator_ops.getIterator(ctx, output, global, iterable, caller_function, caller_frame);
    const list = try iterator_ops.iteratorToList(ctx, output, global, record);
    return objectFromValue(list).?;
}

pub const RegExpLegacyNoCaptureSlice = enum {
    match,
    left,
    right,
};

pub fn regExpLegacyNoCaptureSliceValue(rt: *core.JSRuntime, legacy: anytype, kind: RegExpLegacyNoCaptureSlice) !?core.JSValue {
    if (!legacy.lazy_no_capture_match) return null;
    const input = legacy.input orelse return null;
    return switch (kind) {
        .match => try stringSliceValue(rt, input, legacy.lazy_match_index, legacy.lazy_match_len),
        .left => if (legacy.lazy_match_index == 0)
            try value_ops.createStringValue(rt, "")
        else
            try stringSliceValue(rt, input, 0, legacy.lazy_match_index),
        .right => blk: {
            const right_start = @min(legacy.lazy_match_index + legacy.lazy_match_len, legacy.lazy_input_len);
            if (right_start >= legacy.lazy_input_len) break :blk try value_ops.createStringValue(rt, "");
            break :blk try stringSliceValue(rt, input, right_start, legacy.lazy_input_len - right_start);
        },
    };
}

pub fn throwRegExpAccessorTypeError(ctx: *core.JSContext, getter_value: core.JSValue) !?core.JSValue {
    const getter_object = objectFromValue(getter_value) orelse return error.InvalidBuiltinRegistry;
    const getter_realm = getter_object.nativeFunctionRealm() orelse return error.InvalidBuiltinRegistry;
    if (ctx != getter_realm) return error.InvalidBuiltinRegistry;
    const error_global = getter_realm.global orelse return error.InvalidBuiltinRegistry;
    const prototype = getter_realm.nativeErrorPrototypeObject(.type_error) orelse return error.InvalidBuiltinRegistry;
    const error_value = try exception_ops.createNamedErrorWithPrototype(ctx, error_global, prototype, "RegExp object expected");
    _ = ctx.throwValue(error_value);
    return error.JSException;
}

pub noinline fn createRegExpIndicesArray(rt: *core.JSRuntime, global: *core.Object, found: *const RegExpMatch) !core.JSValue {
    var values = [_]core.JSValue{ global.value(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    values[1] = (try core.Object.createArray(rt, arrayPrototypeFromGlobal(rt, objectFromValue(values[0]).?))).value();

    values[2] = try createRegExpIndexPair(rt, objectFromValue(values[0]).?, found.index, found.index + found.len);
    try defineSplitValueElement(rt, objectFromValue(values[1]).?, 0, values[2]);

    var capture_index: usize = 0;
    while (capture_index < found.capture_count) : (capture_index += 1) {
        const capture = found.captureAt(capture_index);
        if (capture.undefined) {
            try defineSplitValueElement(rt, objectFromValue(values[1]).?, @intCast(capture_index + 1), core.JSValue.undefinedValue());
        } else {
            values[2] = try createRegExpIndexPair(rt, objectFromValue(values[0]).?, capture.start, capture.start + capture.len);
            try defineSplitValueElement(rt, objectFromValue(values[1]).?, @intCast(capture_index + 1), values[2]);
        }
    }

    try defineRegExpIndicesGroupsProperty(rt, objectFromValue(values[0]).?, objectFromValue(values[1]).?, found);
    return values[1];
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
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionId()) orelse return null;
    if (native_ref.domain != .buffer) return null;
    const shared = switch (native_ref.id) {
        @intFromEnum(method_ids.buffer.ConstructorMethod.array_buffer) => false,
        @intFromEnum(method_ids.buffer.ConstructorMethod.shared_array_buffer) => true,
        else => return null,
    };
    if (!new_target.sameValue(func)) return null;

    const prototype = try constructorPrototypeObject(new_target);
    if (args.len == 0) {
        if (shared) return try core.typed_array.sharedArrayBufferConstructLength(ctx.runtime, 0, null, prototype);
        return try core.typed_array.arrayBufferConstructLength(ctx.runtime, 0, null, prototype);
    }
    if (args.len == 1) {
        if (args[0].as(.int)) |length_i32| {
            if (length_i32 >= 0) {
                const byte_length: usize = @intCast(length_i32);
                if (shared) return try core.typed_array.sharedArrayBufferConstructLength(ctx.runtime, byte_length, null, prototype);
                return try core.typed_array.arrayBufferConstructLength(ctx.runtime, byte_length, null, prototype);
            }
        }
    }
    return try arrayBufferConstructWithPrototype(ctx, output, global, args, prototype, shared);
}

pub fn typedArrayConstructVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const kind = function_object.typedArrayKind();
    const element = construct_mod.TypedArrayElement{
        .size = function_object.typedArrayElementSize(),
        .kind = kind,
    };
    const target_realm = function_object.nativeFunctionRealm() orelse return error.InvalidBuiltinRegistry;
    _ = target_realm.global orelse return error.InvalidBuiltinRegistry;
    const array_buffer_prototype = target_realm.classPrototypeObject(core.class.ids.array_buffer) orelse return error.InvalidBuiltinRegistry;

    if (args.len < 1) {
        const prototype = try typedArrayConstructorPrototypeVm(ctx, output, global, constructor, function_object, caller_function, caller_frame);
        return try typedArrayConstructLengthVm(ctx.runtime, array_buffer_prototype, prototype, element, 0);
    }

    const first = args[0];
    if (!first.is(.object)) {
        const length = try typedArrayConstructToIndex(ctx, output, global, first);
        const prototype = try typedArrayConstructorPrototypeVm(ctx, output, global, constructor, function_object, caller_function, caller_frame);
        return try typedArrayConstructLengthVm(ctx.runtime, array_buffer_prototype, prototype, element, length);
    }

    const source_object = objectFromValue(first) orelse return error.TypeError;
    if (core.object.isTypedArrayObject(source_object)) {
        const prototype = try typedArrayConstructorPrototypeVm(ctx, output, global, constructor, function_object, caller_function, caller_frame);
        return try construct_mod.constructTypedArrayTypedArrayInput(
            ctx.runtime,
            prototype,
            array_buffer_prototype,
            element,
            source_object,
        );
    }
    if (source_object.class_id == core.class.ids.array_buffer or source_object.class_id == core.class.ids.shared_array_buffer) {
        const prototype = try typedArrayConstructorPrototypeVm(ctx, output, global, constructor, function_object, caller_function, caller_frame);
        if (args.len == 1) {
            return try core.typed_array.typedArrayConstructWithOptions(ctx.runtime, element.size, element.kind, first, args, prototype);
        }
        return try typedArrayConstructBufferVm(ctx, output, global, prototype, element, args);
    }
    // AllocateTypedArray reads the prototype before @@iterator is looked up.
    const prototype = try typedArrayConstructorPrototypeVm(ctx, output, global, constructor, function_object, caller_function, caller_frame);
    if (try typedArrayConstructFromIterable(ctx, output, global, array_buffer_prototype, prototype, element, first, caller_function, caller_frame)) |value| {
        return value;
    }
    return try typedArrayConstructArrayLikeVm(ctx, output, global, array_buffer_prototype, prototype, element, first, caller_function, caller_frame);
}

pub fn typedArrayConstructLengthVm(
    rt: *core.JSRuntime,
    array_buffer_prototype: *core.Object,
    prototype: ?*core.Object,
    element: construct_mod.TypedArrayElement,
    length: usize,
) !core.JSValue {
    if (length > @as(usize, @intCast(std.math.maxInt(u32)))) return error.RangeError;
    const byte_length = try std.math.mul(usize, length, element.size);
    const backing_buffer = try core.typed_array.arrayBufferConstructLength(rt, byte_length, null, array_buffer_prototype);
    const backing_buffer_object = objectFromValue(backing_buffer) orelse return error.TypeError;
    return core.typed_array.typedArrayConstructFullBufferOwned(rt, element.size, element.kind, backing_buffer, backing_buffer_object, prototype);
}

pub fn typedArrayConstructBufferVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    prototype: ?*core.Object,
    element: construct_mod.TypedArrayElement,
    args: []const core.JSValue,
) !core.JSValue {
    const byte_offset = if (args.len >= 2 and !args[1].is(.undefined_value))
        try typedArrayConstructToIndex(ctx, output, global, args[1])
    else
        @as(usize, 0);
    // InitializeTypedArrayFromArrayBuffer step 3 precedes ToIndex(length).
    if (byte_offset % element.size != 0) {
        _ = try exception_ops.throwRangeErrorMessage(ctx, global, "invalid offset");
        unreachable;
    }
    const has_length = args.len >= 3 and !args[2].is(.undefined_value);
    const requested_length = if (has_length)
        try typedArrayConstructToIndex(ctx, output, global, args[2])
    else
        @as(usize, 0);

    const offset_value = if (args.len >= 2 and !args[1].is(.undefined_value)) lengthIndexValue(byte_offset) else core.JSValue.undefinedValue();
    const length_value = if (has_length) lengthIndexValue(requested_length) else core.JSValue.undefinedValue();
    const construct_args = [_]core.JSValue{ args[0], offset_value, length_value };
    const used_args = if (has_length)
        construct_args[0..3]
    else if (!offset_value.is(.undefined_value))
        construct_args[0..2]
    else
        construct_args[0..1];
    return core.typed_array.typedArrayConstructWithOptions(ctx.runtime, element.size, element.kind, args[0], used_args, prototype);
}

pub fn typedArrayConstructArrayLikeVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    array_buffer_prototype: *core.Object,
    prototype: ?*core.Object,
    element: construct_mod.TypedArrayElement,
    source_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var result_value = core.JSValue.undefinedValue();
    var item = core.JSValue.undefinedValue();
    var coerced = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{ &result_value, &item, &coerced });
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    const length_value = try getValueProperty(ctx, output, global, source_value, core.atom.ids.length, caller_function, caller_frame);
    const length = try toLengthIndex(ctx, output, global, length_value);

    result_value = try typedArrayConstructLengthVm(ctx.runtime, array_buffer_prototype, prototype, element, length);
    const result_object = objectFromValue(result_value) orelse return error.TypeError;
    if (objectFromValue(source_value)) |source_object| {
        if (try typedArrayConstructArrayLikeOwnDataFast(ctx, output, global, result_object, source_object, length)) {
            return result_value;
        }
    }

    for (0..length) |index| {
        const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
        defer key.deinit(ctx.runtime);

        item = try getValueProperty(ctx, output, global, source_value, key.atom, caller_function, caller_frame);

        coerced = try typedArrayByCopyCoerceValue(ctx, output, global, result_object, item);

        _ = try core.typed_array.typedArraySetIndex(ctx.runtime, result_object, @intCast(index), coerced);

        coerced = core.JSValue.undefinedValue();
        item = core.JSValue.undefinedValue();
    }
    return result_value;
}

pub fn typedArrayConstructArrayLikeOwnDataFast(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    result_object: *core.Object,
    source_object: *core.Object,
    length: usize,
) !bool {
    if (source_object.proxyTarget() != null or source_object.hasExoticMethods()) return false;
    if (length > @as(usize, @intCast(std.math.maxInt(u32)))) return false;

    var first_index_property: ?usize = null;
    for (source_object.shapeProps(), 0..) |prop, property_index| {
        const prop_flags = core.property.Flags.fromBits(prop.flags);
        if (prop_flags.deleted or prop_flags.isAccessor()) continue;
        if (prop.atom_id == core.Atom.taggedInt(0)) {
            first_index_property = property_index;
            break;
        }
    }
    const first_property = first_index_property orelse return length == 0;
    if (!typedArrayArrayLikeOwnDataFastPathUsable(source_object, first_property, length)) return false;

    var item = core.JSValue.undefinedValue();
    var coerced = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{ &item, &coerced });
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    var index: usize = 0;
    while (index < length) : (index += 1) {
        const atom_id = core.Atom.taggedInt(@intCast(index));
        item = source_object.getOwnDataPropertyValueAt(first_property + index, atom_id) orelse return false;

        coerced = try typedArrayByCopyCoerceValue(ctx, output, global, result_object, item);
        _ = try core.typed_array.typedArraySetIndex(ctx.runtime, result_object, @intCast(index), coerced);

        coerced = core.JSValue.undefinedValue();
        item = core.JSValue.undefinedValue();
    }
    return true;
}

pub fn typedArrayArrayLikeOwnDataFastPathUsable(source_object: *core.Object, first_property: usize, length: usize) bool {
    for (0..length) |index| {
        const property_index = first_property + index;
        if (property_index >= source_object.shapeProps().len) return false;
        const prop = source_object.shapeProps()[property_index];
        const prop_flags = core.property.Flags.fromBits(prop.flags);
        if (prop.atom_id != core.Atom.taggedInt(@intCast(index)) or prop_flags.deleted or prop_flags.isAccessor()) return false;
        const stored = source_object.asDataAt(property_index) orelse return false;
        if (stored.is(.object)) return false;
    }
    return true;
}

pub fn typedArrayConstructorPrototypeVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: core.JSValue,
    function_object: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?*core.Object {
    const prototype_value = try getValueProperty(ctx, output, global, constructor, core.atom.ids.prototype, caller_function, caller_frame);
    if (prototype_value.is(.object)) return objectFromValue(prototype_value);
    const constructor_name = typedArrayNameFromKind(function_object.typedArrayKind()) orelse return null;
    // The intrinsic kind comes from the TypedArray constructor, but its
    // fallback prototype belongs to newTarget's Realm (including proxies).
    const realm = try call_runtime.functionRealmContext(ctx, constructor);
    const class_id = object_ops.constructorClassPrototypeId(constructor_name) orelse return null;
    return realm.classPrototypeObject(class_id) orelse return error.InvalidBuiltinRegistry;
}

pub fn typedArrayConstructToIndex(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !usize {
    const primitive = try toPrimitiveForNumber(ctx, output, global, value);
    return value_ops.toIndexUsize(ctx.runtime, primitive);
}

pub fn arrayBufferConstructWithPrototype(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    prototype: ?*core.Object,
    shared: bool,
) !core.JSValue {
    const byte_length = if (args.len >= 1)
        try typedArrayConstructToIndex(ctx, output, global, args[0])
    else
        @as(usize, 0);
    const max_byte_length = try arrayBufferMaxByteLengthOption(ctx, output, global, args, byte_length);
    if (shared) return core.typed_array.sharedArrayBufferConstructLength(ctx.runtime, byte_length, max_byte_length, prototype);
    return core.typed_array.arrayBufferConstructLength(ctx.runtime, byte_length, max_byte_length, prototype);
}

pub fn arrayBufferMaxByteLengthOption(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    byte_length: usize,
) !?usize {
    if (args.len < 2 or args[1].is(.undefined_value) or !args[1].is(.object)) return null;
    const max_key = core.atom.ids.maxByteLength;
    const max_value = try getValueProperty(ctx, output, global, args[1], max_key, null, null);
    if (max_value.is(.undefined_value)) return null;
    const max_byte_length = try typedArrayConstructToIndex(ctx, output, global, max_value);
    if (max_byte_length < byte_length) {
        _ = try exception_ops.throwRangeErrorMessage(ctx, global, "invalid array buffer max length");
        unreachable;
    }
    return max_byte_length;
}

/// The iterable form of the TypedArray constructor: null when `source` has
/// no @@iterator (the caller takes the array-like form).
pub fn typedArrayConstructFromIterable(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    array_buffer_prototype: *core.Object,
    prototype: ?*core.Object,
    element: construct_mod.TypedArrayElement,
    source: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const iterator_method = try getIteratorMethod(ctx, output, global, source);
    if (iterator_method.is(.undefined_value) or iterator_method.is(.null_value)) return null;
    if (!isCallableValue(iterator_method)) return error.NotIterable;

    // GetIteratorFromMethod + IteratorToList: a failing step never closes.
    var values_value = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{&values_value});
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);
    values_value = try callValueOrBytecodeRoot(ctx, output, global, source, iterator_method, &.{}, caller_function, caller_frame);
    const record = try iterator_ops.getIteratorDirect(ctx, output, global, values_value, caller_function, caller_frame);
    values_value = try iterator_ops.iteratorToList(ctx, output, global, record);
    return try typedArrayConstructArrayLikeVm(ctx, output, global, array_buffer_prototype, prototype, element, values_value, caller_function, caller_frame);
}

pub fn arrayBufferAccessor(receiver: core.JSValue, accessor: []const u8) !core.JSValue {
    const object = objectFromValue(receiver) orelse return error.IncompatibleReceiver;
    if (object.class_id != core.class.ids.array_buffer) return error.IncompatibleReceiver;
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
    return error.TypeError;
}

pub fn sharedArrayBufferAccessor(receiver: core.JSValue, accessor: []const u8) !core.JSValue {
    const object = objectFromValue(receiver) orelse return error.IncompatibleReceiver;
    if (object.class_id != core.class.ids.shared_array_buffer) return error.IncompatibleReceiver;
    if (std.mem.eql(u8, accessor, "byteLength")) {
        return lengthIndexValue(object.byteStorage().len);
    }
    if (std.mem.eql(u8, accessor, "maxByteLength")) {
        return lengthIndexValue(object.arrayBufferMaxByteLength() orelse object.byteStorage().len);
    }
    if (std.mem.eql(u8, accessor, "growable")) {
        return core.JSValue.boolean(object.arrayBufferMaxByteLength() != null);
    }
    return error.TypeError;
}

pub fn arrayBufferIsView(args: []const core.JSValue) core.JSValue {
    if (args.len < 1) return core.JSValue.boolean(false);
    const object = objectFromValue(args[0]) orelse return core.JSValue.boolean(false);
    return core.JSValue.boolean(core.object.isTypedArrayObject(object) or object.class_id == core.class.ids.dataview);
}

pub fn arrayBufferPrototypeNativeRecord(ctx: *core.JSContext, output: ?*std.Io.Writer, receiver: core.JSValue, id: u32, args: []const core.JSValue) !?core.JSValue {
    const is_method = std.enums.fromInt(method_ids.buffer.ArrayBufferPrototypeMethod, id) != null or
        std.enums.fromInt(method_ids.buffer.SharedArrayBufferPrototypeMethod, id) != null;
    const object = objectFromValue(receiver) orelse return if (is_method) error.IncompatibleReceiver else null;
    if (object.class_id == core.class.ids.shared_array_buffer) {
        return switch (id) {
            @intFromEnum(method_ids.buffer.ArrayBufferPrototypeMethod.slice),
            @intFromEnum(method_ids.buffer.ArrayBufferPrototypeMethod.resize),
            @intFromEnum(method_ids.buffer.ArrayBufferPrototypeMethod.transfer),
            @intFromEnum(method_ids.buffer.ArrayBufferPrototypeMethod.transfer_to_fixed_length),
            => error.IncompatibleReceiver,
            @intFromEnum(method_ids.buffer.SharedArrayBufferPrototypeMethod.slice) => {
                const start = if (args.len >= 1) args[0] else core.JSValue.int32(0);
                const end = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
                return try arrayBufferSliceCall(ctx, output, receiver, object, start, end, true);
            },
            @intFromEnum(method_ids.buffer.SharedArrayBufferPrototypeMethod.grow) => {
                const new_length = if (args.len >= 1) args[0] else core.JSValue.int32(0);
                return try sharedArrayBufferGrowCall(ctx, output, receiver, new_length);
            },
            else => null,
        };
    }
    if (object.class_id != core.class.ids.array_buffer) return if (is_method) error.IncompatibleReceiver else null;
    return switch (id) {
        @intFromEnum(method_ids.buffer.SharedArrayBufferPrototypeMethod.slice),
        @intFromEnum(method_ids.buffer.SharedArrayBufferPrototypeMethod.grow),
        => error.IncompatibleReceiver,
        @intFromEnum(method_ids.buffer.ArrayBufferPrototypeMethod.slice) => {
            const start = if (args.len >= 1) args[0] else core.JSValue.int32(0);
            const end = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
            return try arrayBufferSliceCall(ctx, output, receiver, object, start, end, false);
        },
        @intFromEnum(method_ids.buffer.ArrayBufferPrototypeMethod.resize) => {
            const new_length = if (args.len >= 1) args[0] else core.JSValue.int32(0);
            return try arrayBufferResizeCall(ctx, output, receiver, new_length);
        },
        @intFromEnum(method_ids.buffer.ArrayBufferPrototypeMethod.transfer) => {
            const new_length = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return try arrayBufferTransferCall(ctx, output, receiver, new_length, false);
        },
        @intFromEnum(method_ids.buffer.ArrayBufferPrototypeMethod.transfer_to_fixed_length) => {
            const new_length = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return try arrayBufferTransferCall(ctx, output, receiver, new_length, true);
        },
        else => null,
    };
}

pub fn arrayBufferSliceCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    receiver: core.JSValue,
    object: *core.Object,
    start_value: core.JSValue,
    end_value: core.JSValue,
    shared: bool,
) !core.JSValue {
    const global = ctx.global orelse return error.InvalidBuiltinRegistry;
    if (object.arrayBufferDetached()) return error.DetachedArrayBuffer;
    const source_length = object.byteStorage().len;
    const start = try relativeSliceIndex(ctx, output, global, start_value, source_length, false);
    const end = try relativeSliceIndex(ctx, output, global, end_value, source_length, true);
    const length = if (end > start) end - start else 0;
    const constructor = try arrayBufferSpeciesConstructor(ctx, output, global, receiver, shared);
    const out_value = try constructValueOrBytecode(ctx, output, global, constructor, &.{lengthIndexValue(length)}, null, null);
    const out_object = objectFromValue(out_value) orelse return error.IncompatibleSpeciesResult;
    if (shared) {
        if (out_object.class_id != core.class.ids.shared_array_buffer) return error.IncompatibleSpeciesResult;
    } else {
        if (out_object.class_id != core.class.ids.array_buffer) return error.IncompatibleSpeciesResult;
    }
    if (out_value.sameValue(receiver)) return error.IncompatibleSpeciesResult;
    if (out_object.arrayBufferDetached()) return error.IncompatibleSpeciesResult;
    if (out_object.byteStorage().len < length) return error.IncompatibleSpeciesResult;
    // Steps 24-28: the species constructor may have detached the source
    // (TypeError) or shrunk it, in which case only what remains is copied.
    if (object.arrayBufferDetached()) return error.DetachedArrayBuffer;
    const current_length = object.byteStorage().len;
    if (start < current_length) {
        const count = @min(length, current_length - start);
        @memcpy(out_object.byteStorage()[0..count], object.byteStorage()[start..][0..count]);
    }
    return out_value;
}

pub fn arrayBufferSpeciesConstructor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    shared: bool,
) !core.JSValue {
    const slot: core.context.RealmValueSlot = if (shared) .shared_array_buffer_constructor else .array_buffer_constructor;
    const default_constructor = global.cachedRealmValue(ctx.runtime, slot) orelse
        try global.getProperty(try ctx.runtime.internAtom(if (shared) "SharedArrayBuffer" else "ArrayBuffer"));
    return object_ops.speciesConstructor(ctx, output, global, receiver, default_constructor, null, null);
}

pub fn arrayBufferResizeCall(ctx: *core.JSContext, output: ?*std.Io.Writer, receiver: core.JSValue, new_length_value: core.JSValue) !core.JSValue {
    const object = objectFromValue(receiver) orelse return error.IncompatibleReceiver;
    if (object.class_id != core.class.ids.array_buffer) return error.IncompatibleReceiver;
    // ArrayBuffer.prototype.resize steps 2-6: not resizable (TypeError)
    // before ToIndex (RangeError) before detached (TypeError) before the
    // maximum (RangeError). QuickJS coerces first.
    const max = object.arrayBufferMaxByteLength() orelse return error.IncompatibleReceiver;
    const number = try arrayBufferLengthNumber(ctx, output, new_length_value);
    if (number < 0 or number > max_safe_integer_f64) return error.InvalidArrayBufferLength;
    if (object.arrayBufferDetached()) return error.DetachedArrayBuffer;
    if (number > @as(f64, @floatFromInt(max))) return error.InvalidArrayBufferLength;
    return core.typed_array.arrayBufferResizeLength(ctx.runtime, receiver, @intFromFloat(number));
}

pub fn sharedArrayBufferGrowCall(ctx: *core.JSContext, output: ?*std.Io.Writer, receiver: core.JSValue, new_length_value: core.JSValue) !core.JSValue {
    const object = objectFromValue(receiver) orelse return error.IncompatibleReceiver;
    if (object.class_id != core.class.ids.shared_array_buffer) return error.IncompatibleReceiver;
    // SharedArrayBuffer.prototype.grow steps 2-4: not growable (TypeError)
    // before ToIndex (RangeError); the range checks follow.
    const max = object.arrayBufferMaxByteLength() orelse return error.IncompatibleReceiver;
    const number = try arrayBufferLengthNumber(ctx, output, new_length_value);
    if (number < 0 or number > @as(f64, @floatFromInt(max))) return error.InvalidArrayBufferLength;
    return core.typed_array.sharedArrayBufferGrowLength(ctx.runtime, receiver, @intFromFloat(number));
}

const max_safe_integer_f64: f64 = 9007199254740991.0;

/// The conversion half of ToIndex for resize/grow: ToNumber (running user
/// valueOf/toPrimitive) truncated to an integer as f64. The caller applies
/// the range checks in its spec order.
fn arrayBufferLengthNumber(ctx: *core.JSContext, output: ?*std.Io.Writer, value: core.JSValue) !f64 {
    if (value.is(.undefined_value)) return 0;
    const global = ctx.global orelse return error.InvalidBuiltinRegistry;
    const primitive = try toPrimitiveForNumber(ctx, output, global, value);
    if (primitive.isBigInt()) return error.BigIntToNumber;
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    const number = value_ops.numberValue(number_value) orelse std.math.nan(f64);
    if (std.math.isNan(number)) return 0;
    return @trunc(number);
}

pub fn arrayBufferTransferCall(ctx: *core.JSContext, output: ?*std.Io.Writer, receiver: core.JSValue, new_length_value: core.JSValue, fixed_length: bool) !core.JSValue {
    const object = objectFromValue(receiver) orelse return error.IncompatibleReceiver;
    const fallback = if (object.class_id == core.class.ids.array_buffer) object.byteStorage().len else @as(usize, 0);
    const new_length = try arrayBufferLengthArgument(ctx, output, new_length_value, fallback);
    return core.typed_array.arrayBufferTransferLength(ctx.runtime, receiver, new_length, fixed_length, ctx.classPrototypeObject(core.class.ids.array_buffer));
}

pub fn arrayBufferLengthArgument(ctx: *core.JSContext, output: ?*std.Io.Writer, value: core.JSValue, undefined_length: usize) !usize {
    if (value.is(.undefined_value)) return undefined_length;
    const global = ctx.global orelse return error.InvalidBuiltinRegistry;
    return typedArrayConstructToIndex(ctx, output, global, value);
}

/// Relative start/end argument of slice-like methods: ToIntegerOrInfinity,
/// then clamp into [0, len] counting negatives from the end.
pub fn relativeSliceIndex(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    len: usize,
    undefined_is_len: bool,
) !usize {
    if (undefined_is_len and value.is(.undefined_value)) return len;
    return arrayRelativeIndexFromNumber(len, try toNumberForArrayMethod(ctx, output, global, value));
}

pub fn typedArrayAccessor(ctx: *core.JSContext, receiver: core.JSValue, accessor: []const u8) !core.JSValue {
    if (std.mem.eql(u8, accessor, "[Symbol.toStringTag]")) {
        const object = objectFromValue(receiver) orelse return core.JSValue.undefinedValue();
        if (!core.object.isTypedArrayObject(object)) return core.JSValue.undefinedValue();
        const name = typedArrayNameFromKind(object.typedArrayKind()) orelse return core.JSValue.undefinedValue();
        return value_ops.createStringValue(ctx.runtime, name);
    }
    const object = objectFromValue(receiver) orelse return error.NotATypedArray;
    if (!core.object.isTypedArrayObject(object)) return error.NotATypedArray;
    if (std.mem.eql(u8, accessor, "buffer")) {
        return (object.typedArrayBuffer() orelse return error.TypeError);
    }
    if (std.mem.eql(u8, accessor, "byteLength")) {
        const byte_length = try core.object.typedArrayByteLength(ctx.runtime, object);
        return lengthIndexValue(byte_length);
    }
    if (std.mem.eql(u8, accessor, "byteOffset")) {
        return lengthIndexValue(try core.object.typedArrayEffectiveByteOffset(object));
    }
    if (std.mem.eql(u8, accessor, "length")) {
        return lengthIndexValue(@intCast(try core.object.typedArrayLength(ctx.runtime, object)));
    }
    return error.TypeError;
}

pub fn typedArrayNameFromKind(kind: core.typed_array_names.Kind) ?[]const u8 {
    return core.typed_array_names.nameFromKind(kind);
}

pub noinline fn typedArraySetCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const is_typed_method = isTypedArrayPrototypeMethod(function_object);
    const target = objectFromValue(receiver) orelse return if (is_typed_method) error.NotATypedArray else null;
    if (!core.object.isTypedArrayObject(target)) return if (is_typed_method) error.NotATypedArray else null;
    const source = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const offset_value = if (args.len >= 2) args[1] else core.JSValue.int32(0);
    const offset_number = try toIntegerOrInfinityForArrayByCopy(ctx, output, global, offset_value);
    if (offset_number < 0) return error.InvalidOffset;
    // +∞ (or anything past usize) fails the range check below, which the spec
    // orders after the bounds checks and the array-like length read.
    const offset: usize = if (offset_number >= @as(f64, @floatFromInt(std.math.maxInt(usize))))
        std.math.maxInt(usize)
    else
        @intFromFloat(offset_number);

    // The offset converts first (%TypedArray%.prototype.set steps 4-5); it
    // can detach or resize either view, so the bounds are checked after it.
    if (try core.object.typedArrayDetached(target)) return error.TypedArrayOutOfBounds;
    if (try core.object.typedArrayOutOfBounds(target)) return error.TypedArrayOutOfBounds;
    const target_length: usize = @intCast(try core.object.typedArrayLength(ctx.runtime, target));

    if (objectFromValue(source)) |source_object| {
        if (core.object.isTypedArrayObject(source_object)) {
            if (try core.object.typedArrayDetached(source_object)) return error.TypedArrayOutOfBounds;
            if (try core.object.typedArrayOutOfBounds(source_object)) return error.TypedArrayOutOfBounds;
            const source_length: usize = @intCast(try core.object.typedArrayLength(ctx.runtime, source_object));
            if (offset > target_length or source_length > target_length - offset) return error.InvalidOffset;
            // SetTypedArrayFromTypedArray: the content types must match even
            // when there is nothing to copy.
            if (source_object.typedArrayKind().isBigInt() != target.typedArrayKind().isBigInt()) return error.TypedArrayContentTypeMismatch;

            // QuickJS js_typed_array_set_internal: when the
            // source and target share the same element class, copy the raw byte
            // ranges with memmove and skip per-element box/unbox + re-bounds-check.
            // memmove handles same-backing-buffer aliasing (overlapping src/dst).
            if (source_object.typedArrayKind() == target.typedArrayKind()) {
                const element_size: usize = target.typedArrayElementSize();
                const byte_count = source_length * element_size;
                if (byte_count != 0) {
                    const target_buffer = try core.typed_array.typedArrayBufferObject(target);
                    const source_buffer = try core.typed_array.typedArrayBufferObject(source_object);
                    const dst_start = target.typedArrayByteOffset() + offset * element_size;
                    const src_start = source_object.typedArrayByteOffset();
                    @memmove(
                        target_buffer.byteStorage()[dst_start..][0..byte_count],
                        source_buffer.byteStorage()[src_start..][0..byte_count],
                    );
                }
                return core.JSValue.undefinedValue();
            }

            // Mismatched element class: convert per element through the value path.
            const values = try ctx.runtime.nativeAllocator().alloc(core.JSValue, source_length);
            var rooted_values: []core.JSValue = values[0..0];
            var values_root = ValueSliceRoot{};
            values_root.init(ctx.runtime, &rooted_values);
            defer values_root.deinit();
            var filled: usize = 0;
            defer {
                rooted_values = &.{};
                if (values.len != 0) ctx.runtime.nativeAllocator().free(values);
            }

            var snapshot_index: usize = 0;
            while (snapshot_index < source_length) : (snapshot_index += 1) {
                try exception_ops.pollNativeLoop(ctx, global);
                values[snapshot_index] = try core.typed_array.typedArrayGetIndex(ctx.runtime, source_object, @intCast(snapshot_index));
                filled += 1;
                rooted_values = values[0..filled];
            }

            var write_index: usize = 0;
            while (write_index < source_length) : (write_index += 1) {
                try exception_ops.pollNativeLoop(ctx, global);
                _ = try core.typed_array.typedArraySetIndex(ctx.runtime, target, @intCast(offset + write_index), values[write_index]);
            }
            return core.JSValue.undefinedValue();
        }
    }

    const source_object_value = if (source.is(.object)) source else try primitiveObjectForAccess(ctx.runtime, global, source);
    _ = try property_ops.expectObject(source_object_value);

    const length_value = try getValueProperty(ctx, output, global, source_object_value, core.atom.ids.length, caller_function, caller_frame);
    const source_length = try toLengthIndex(ctx, output, global, length_value);
    if (offset > target_length or source_length > target_length - offset) return error.InvalidOffset;

    for (0..source_length) |index| {
        try exception_ops.pollNativeLoop(ctx, global);
        const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
        defer key.deinit(ctx.runtime);
        const value = try getValueProperty(ctx, output, global, source_object_value, key.atom, caller_function, caller_frame);
        try typedArraySetElementValue(ctx, output, global, target, offset + index, value);
    }
    return core.JSValue.undefinedValue();
}

test "typedArraySetCall roots typed array snapshot while reading source" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    const array_buffer_prototype = try core.Object.create(rt, core.class.ids.object, null);
    try ctx.setClassPrototype(core.class.ids.array_buffer, array_buffer_prototype);
    const element = construct_mod.typedArrayElement("BigInt64Array") orelse return error.TypeError;
    const source_value = try typedArrayConstructLengthVm(rt, array_buffer_prototype, null, element, 2);
    const source = objectFromValue(source_value) orelse return error.TypeError;
    const target_value = try typedArrayConstructLengthVm(rt, array_buffer_prototype, null, element, 2);
    const target = objectFromValue(target_value) orelse return error.TypeError;

    const first_big_object = try core.bigint.BigInt.create(rt, @as(i128, 1) << 70);
    const first_big = first_big_object.valueRef();
    const second_big_object = try core.bigint.BigInt.create(rt, (@as(i128, 1) << 70) + 7);
    const second_big = second_big_object.valueRef();
    _ = try core.typed_array.typedArraySetIndex(rt, source, 0, first_big);
    _ = try core.typed_array.typedArraySetIndex(rt, source, 1, second_big);

    const function_object = try core.Object.create(rt, core.class.ids.object, null);
    const args = [_]core.JSValue{source_value};

    var probe = ActiveRootValueProbe{
        .rt = rt,
    };
    const saved_trigger_fn = rt.gc.heap_budget.installProbe(.{ .run = ActiveRootValueProbe.trigger, .context = &probe });
    defer rt.gc.heap_budget.restoreProbe(saved_trigger_fn);

    _ = (try typedArraySetCall(ctx, null, global, target_value, function_object, &args, null, null)) orelse return error.TypeError;

    // The probe forced a cycle-removal pass during the typed-array set; the
    // copied heap bigint survives into the target only because the in-flight
    // value was rooted across that GC.
    const copied = try core.typed_array.typedArrayGetIndex(rt, target, 1);
    try std.testing.expect(copied.isBigInt());
}

pub fn typedArraySetElementValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target: *core.Object,
    index: usize,
    value: core.JSValue,
) !void {
    const coerced = if (value.is(.object))
        try toPrimitiveForNumber(ctx, output, global, value)
    else
        value;
    _ = try core.typed_array.typedArraySetIndex(ctx.runtime, target, @intCast(index), coerced);
}

pub fn addCollectionEntriesFromArray(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    collection_value: core.JSValue,
    kind: u32,
    source: *core.Object,
    adder: core.JSValue,
    iterator: *core.Object,
) !void {
    var index: u32 = 0;
    while (index < source.arrayLength()) : (index += 1) {
        // Advance the array iterator as its `next` would, so an IteratorClose
        // after a failed step observes the right position.
        iterator.iteratorIndexSlot().* = index + 1;
        const entry_value = try getValueProperty(ctx, output, global, source.value(), core.Atom.taggedInt(index), null, null);
        if (kind == 1 or kind == 3) {
            const entry = objectFromValue(entry_value) orelse {
                _ = try throwTypeErrorMessage(ctx, global, "iterator value is not an entry object");
                unreachable;
            };
            const key = try getValueProperty(ctx, output, global, entry.value(), core.Atom.taggedInt(0), null, null);
            const value = try getValueProperty(ctx, output, global, entry.value(), core.Atom.taggedInt(1), null, null);
            try callCollectionAdderFromVm(ctx, output, global, collection_value, adder, &.{ key, value });
        } else {
            try callCollectionAdderFromVm(ctx, output, global, collection_value, adder, &.{entry_value});
        }
    }
}

pub noinline fn arrayAtCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    const typed_array_method = isTypedArrayPrototypeMethod(function_object);

    if (receiver.is(.null_value) or receiver.is(.undefined_value)) {
        return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "Cannot convert undefined or null to object"));
    }
    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    const object = objectFromValue(receiver_object_value) orelse return null;
    if (typed_array_method and !core.object.isTypedArrayObject(object)) return error.NotATypedArray;
    const length = try arrayMethodLength(ctx, output, global, receiver_object_value, object, typed_array_method, null, null);

    const index_arg = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const primitive = try toPrimitiveForNumber(ctx, output, global, index_arg);
    const index_number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    const index_number = value_ops.numberValue(index_number_value) orelse std.math.nan(f64);
    // ToIntegerOrInfinity and the relative index stay in f64 (length is at
    // most 2^53 - 1, so exact) until the bounds check has passed.
    const relative_index = if (std.math.isNan(index_number)) 0 else @trunc(index_number);
    const length_number: f64 = @floatFromInt(length);
    const actual_index = if (relative_index >= 0) relative_index else length_number + relative_index;
    if (!(actual_index >= 0 and actual_index < length_number)) return core.JSValue.undefinedValue();

    const key = try propertyAtomFromLengthIndex(ctx.runtime, @intFromFloat(actual_index));
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

inline fn arrayIterationModeFromRecordId(record_id: u32) ?ArrayIterationMode {
    return switch (record_id) {
        @intFromEnum(method_ids.array.PrototypeMethod.for_each) => .for_each,
        @intFromEnum(method_ids.array.PrototypeMethod.map) => .map,
        @intFromEnum(method_ids.array.PrototypeMethod.filter) => .filter,
        @intFromEnum(method_ids.array.PrototypeMethod.some) => .some,
        @intFromEnum(method_ids.array.PrototypeMethod.every) => .every,
        @intFromEnum(method_ids.array.PrototypeMethod.find) => .find,
        @intFromEnum(method_ids.array.PrototypeMethod.find_index) => .find_index,
        @intFromEnum(method_ids.array.PrototypeMethod.find_last) => .find_last,
        @intFromEnum(method_ids.array.PrototypeMethod.find_last_index) => .find_last_index,
        else => null,
    };
}

inline fn arrayIterationModeIsFind(mode: ArrayIterationMode) bool {
    return switch (mode) {
        .find, .find_index, .find_last, .find_last_index => true,
        else => false,
    };
}

noinline fn arrayIterationModeCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    mode: ArrayIterationMode,
) !?core.JSValue {
    const find_family = arrayIterationModeIsFind(mode);
    const receiver_object_value = if (objectFromValue(receiver)) |_|
        receiver
    else if (receiver.is(.null_value) or receiver.is(.undefined_value))
        return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "Cannot convert undefined or null to object"))
    else
        try primitiveObjectForAccess(ctx.runtime, global, receiver);
    const object = objectFromValue(receiver_object_value) orelse return null;
    const is_typed_method = isTypedArrayPrototypeMethod(function_object);
    if (is_typed_method and !core.object.isTypedArrayObject(object)) return error.NotATypedArray;
    const length = try arrayMethodLength(ctx, output, global, receiver_object_value, object, is_typed_method, caller_function, caller_frame);
    if (args.len < 1 or !isCallableValue(args[0])) return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "not a function"));
    const callback_this = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    var callback_call = CallSite.initInternal(
        ctx,
        output,
        global,
        callback_this,
        args[0],
        caller_function,
        caller_frame,
    );
    callback_call.activateRoots();
    defer callback_call.deinit();
    if (is_typed_method and (mode == .map or mode == .filter)) {
        return try typedArrayMapFilter(ctx, output, global, receiver_object_value, object, length, mode, &callback_call, caller_function, caller_frame);
    }

    var out_value: core.JSValue = core.JSValue.undefinedValue();
    var out: ?*core.Object = null;
    var out_index: usize = 0;
    var dense_map_output = false;
    if (mode == .map or mode == .filter) {
        out_value = try arraySpeciesCreate(ctx, output, global, receiver_object_value, if (mode == .map) length else 0, caller_function, caller_frame);
        out = objectFromValue(out_value) orelse return error.TypeError;
        dense_map_output = mode == .map and out.?.canDefineDenseArrayDataPropertiesUnchecked();
    }

    var cursor: usize = 0;
    while (cursor < length) : (cursor += 1) {
        try exception_ops.pollNativeLoop(ctx, global);
        const index = switch (mode) {
            .find_last, .find_last_index => length - 1 - cursor,
            else => cursor,
        };
        const item = if (is_typed_method)
            try core.typed_array.typedArrayGetIndex(ctx.runtime, object, @intCast(index))
        else blk: {
            // Dense hit first; a dense miss falls through to the one generic
            // present-element get (propertyAtom + has except find-family + get).
            if (object.isArray() and object.arrayElementStorageMode() == .dense and index <= std.math.maxInt(u32)) {
                if (object.getDenseArrayElementValue(@intCast(index))) |dense_item| break :blk dense_item;
            }
            const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
            defer key.deinit(ctx.runtime);
            if (!find_family and
                !try hasValueProperty(ctx, output, global, object, key.atom, null, null))
            {
                continue;
            }
            break :blk try getValueProperty(ctx, output, global, receiver_object_value, key.atom, caller_function, caller_frame);
        };
        const index_value = lengthIndexValue(index);
        const callback_result = try callback_call.call3(item, index_value, receiver_object_value);

        switch (mode) {
            .for_each => {},
            .map => {
                // The unchecked dense write only appends at the current count;
                // when the source skipped holes the output index runs ahead of
                // count, so require `index == count` (contiguous append) before
                // taking it. A gap falls through to the index-define path, which
                // materializes the output to sparse and preserves the hole.
                if (dense_map_output and index <= std.math.maxInt(u32) and
                    index == @as(usize, @intCast(out.?.fastArrayCount())) and
                    out.?.canDefineDenseArrayDataPropertiesUnchecked())
                {
                    try out.?.defineDenseArrayDataPropertyUnchecked(ctx.runtime, @intCast(index), callback_result);
                    continue;
                }
                dense_map_output = false;
                if (index <= std.math.maxInt(u32) and try out.?.defineDenseArrayDataProperty(ctx.runtime, @intCast(index), callback_result)) {
                    continue;
                }
                const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
                defer key.deinit(ctx.runtime);
                try createDataPropertyOrThrow(ctx, output, global, out.?, key.atom, callback_result, caller_function, caller_frame);
            },
            .filter => {
                if (valueTruthy(callback_result)) {
                    const out_key = try propertyAtomFromLengthIndex(ctx.runtime, out_index);
                    defer out_key.deinit(ctx.runtime);
                    try createDataPropertyOrThrow(ctx, output, global, out.?, out_key.atom, item, caller_function, caller_frame);
                    out_index += 1;
                }
            },
            .some => if (valueTruthy(callback_result)) return core.JSValue.boolean(true),
            .every => if (!valueTruthy(callback_result)) return core.JSValue.boolean(false),
            .find => if (valueTruthy(callback_result)) return item,
            .find_index => if (valueTruthy(callback_result)) return lengthIndexValue(index),
            .find_last => if (valueTruthy(callback_result)) return item,
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

pub noinline fn typedArrayMapFilter(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver_value: core.JSValue,
    object: *core.Object,
    length: usize,
    mode: ArrayIterationMode,
    callback_call: *CallSite,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (mode == .map) {
        const constructor_value = try typedArraySpeciesConstructorForObject(ctx, output, global, receiver_value, object, caller_function, caller_frame);
        const out_value = try typedArrayCreateWithLength(ctx, output, global, constructor_value, length, caller_function, caller_frame);
        try requireSpeciesContentType(object, out_value);
        // The callback below is arbitrary user JS: it allocates, and until this
        // function returns the result array is reachable from nothing but this
        // frame. A scalar root frame would not do -- production skips those and
        // leaves scalars to conservative capture
        // (`value_root_link_containers_only`) -- so the result is held in a
        // one-element window and rooted as a container, the same shape the
        // filter path below already uses for its kept values.
        var out_window = [_]core.JSValue{out_value};
        var rooted_out: []core.JSValue = out_window[0..1];
        var out_slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &rooted_out }};
        var out_frame = core.runtime.ValueRootFrame{ .slices = &out_slices };
        out_frame.activate(ctx.runtime);
        defer out_frame.deactivate(ctx.runtime);
        const out = objectFromValue(out_window[0]) orelse return error.TypeError;
        for (0..length) |index| {
            const item = try core.typed_array.typedArrayGetIndex(ctx.runtime, object, @intCast(index));
            const mapped = try callback_call.call3(item, lengthIndexValue(index), receiver_value);
            // ? Set(A, Pk, mappedValue, true): converts through valueOf.
            _ = try typedArrayNumericSet(ctx, output, global, out, out_window[0], core.Atom.taggedInt(@intCast(index)), mapped, null, null);
        }
        return out_window[0];
    }

    const kept = try ctx.runtime.nativeAllocator().alloc(core.JSValue, length);
    errdefer ctx.runtime.nativeAllocator().free(kept);
    var rooted_kept: []core.JSValue = kept[0..0];
    var root_slices = [_]core.runtime.ValueRootSlice{
        .{ .mutable = &rooted_kept },
    };
    var root_frame = core.runtime.ValueRootFrame{
        .slices = &root_slices,
    };
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    var kept_count: usize = 0;
    var index: usize = 0;
    while (index < length) : (index += 1) {
        const item = try core.typed_array.typedArrayGetIndex(ctx.runtime, object, @intCast(index));
        const selected = try callback_call.call3(item, lengthIndexValue(index), receiver_value);
        if (valueTruthy(selected)) {
            kept[kept_count] = item;
            kept_count += 1;
            rooted_kept = kept[0..kept_count];
        }
    }

    const constructor_value = try typedArraySpeciesConstructorForObject(ctx, output, global, receiver_value, object, caller_function, caller_frame);
    const out_value = try typedArrayCreateWithLength(ctx, output, global, constructor_value, kept_count, caller_function, caller_frame);
    try requireSpeciesContentType(object, out_value);
    const out = objectFromValue(out_value) orelse return error.TypeError;
    index = 0;
    while (index < kept_count) : (index += 1) {
        _ = try core.typed_array.typedArraySetIndex(ctx.runtime, out, @intCast(index), kept[index]);
    }
    rooted_kept = &.{};
    ctx.runtime.nativeAllocator().free(kept);
    return out_value;
}

/// TypedArraySpeciesCreate's last step (§23.2.4.1): the species result must
/// hold the same content type (Number or BigInt) as the exemplar.
fn requireSpeciesContentType(exemplar: *core.Object, result: core.JSValue) !void {
    const result_object = objectFromValue(result) orelse return error.NotATypedArray;
    if (exemplar.typedArrayKind().isBigInt() != result_object.typedArrayKind().isBigInt())
        return error.TypedArrayContentTypeMismatch;
}

pub fn typedArrayCreateWithLength(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    requested_length: usize,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const out_value = try constructValueOrBytecode(ctx, output, global, constructor_value, &.{lengthIndexValue(requested_length)}, caller_function, caller_frame);
    const out = objectFromValue(out_value) orelse return error.NotATypedArray;
    if (!core.object.isTypedArrayObject(out)) return error.NotATypedArray;
    if (@as(usize, @intCast(try core.object.typedArrayLength(ctx.runtime, out))) < requested_length) return error.IncompatibleSpeciesResult;
    return out_value;
}

pub noinline fn arrayReduceCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    from_right: bool,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;

    if (receiver.is(.null_value) or receiver.is(.undefined_value)) {
        return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "Cannot convert undefined or null to object"));
    }
    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    const object = objectFromValue(receiver_object_value) orelse return null;
    const is_typed_method = isTypedArrayPrototypeMethod(function_object);
    if (is_typed_method and !core.object.isTypedArrayObject(object)) return error.NotATypedArray;
    const length = try arrayMethodLength(ctx, output, global, receiver_object_value, object, is_typed_method, null, null);
    if (args.len < 1 or !isCallableValue(args[0])) return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "not a function"));
    var callback_call = CallSite.initInternal(
        ctx,
        output,
        global,
        core.JSValue.undefinedValue(),
        args[0],
        null,
        null,
    );
    callback_call.activateRoots();
    defer callback_call.deinit();

    var accumulator: core.JSValue = undefined;
    var accumulator_set = false;
    if (args.len >= 2) {
        accumulator = args[1];
        accumulator_set = true;
    }
    var sparse_walk = from_right and !is_typed_method and length >= sparse_walk_min_length;

    // Shared reduce / reduceRight per-element walk; direction is taken at
    // runtime (same shape as arrayIterationModeCall find/findLast).
    var step: usize = 0;
    while (step < length) : (step += 1) {
        var cursor = if (from_right) length - 1 - step else step;
        if (sparse_walk) switch (try previousSparseCandidate(ctx.runtime, object, cursor + 1)) {
            .none => break,
            .index => |index| {
                cursor = index;
                step = length - 1 - index;
            },
            .unknown => sparse_walk = false,
        };
        const item = if (is_typed_method)
            try core.typed_array.typedArrayGetIndex(ctx.runtime, object, @intCast(cursor))
        else if (object.isArray() and object.arrayElementStorageMode() == .dense and cursor <= std.math.maxInt(u32)) blk: {
            // Dense own element: qjs js_array_reduce's fast-array arm
            // (no HasProperty/Get through the generic property path).
            if (object.getDenseArrayElementValue(@intCast(cursor))) |dense_item| break :blk dense_item;
            const key = try propertyAtomFromLengthIndex(ctx.runtime, cursor);
            defer key.deinit(ctx.runtime);
            if (!try hasValueProperty(ctx, output, global, object, key.atom, null, null)) continue;
            break :blk try getValueProperty(ctx, output, global, receiver_object_value, key.atom, null, null);
        } else blk: {
            const key = try propertyAtomFromLengthIndex(ctx.runtime, cursor);
            defer key.deinit(ctx.runtime);
            if (!try hasValueProperty(ctx, output, global, object, key.atom, null, null)) continue;
            break :blk try getValueProperty(ctx, output, global, receiver_object_value, key.atom, null, null);
        };
        if (!accumulator_set) {
            accumulator = item;
            accumulator_set = true;
            continue;
        }
        const index_value = lengthIndexValue(cursor);
        const next = try callback_call.call4(accumulator, item, index_value, receiver_object_value);
        accumulator = next;
    }

    if (!accumulator_set) return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "empty array"));
    return accumulator;
}

/// Backward index walks over a length this large ask for the next possibly
/// present index instead of stepping through every hole.
pub const sparse_walk_min_length: usize = 1 << 20;
const sparse_candidate_limit: usize = 4096;

pub const SparseCandidate = union(enum) { none, index: usize, unknown };

/// Sparse-walk hint: the greatest index below `upper` that is an own key of
/// `object` or of an object on its prototype chain. It is only a hint —
/// callers still do HasProperty/Get at that index — and re-asking after every
/// step keeps the walk exact when user code adds or deletes elements.
/// `.unknown` asks for a full walk: a proxy's keys are only observable
/// through its traps, and past `sparse_candidate_limit` keys the per-step
/// rescan would cost more than it saves.
pub fn previousSparseCandidate(rt: *core.JSRuntime, object: *core.Object, upper: usize) !SparseCandidate {
    return sparseCandidate(rt, object, upper, .before);
}

/// Forward twin of `previousSparseCandidate`: the least index at or above
/// `lower` that is an own key of `object` or of its prototype chain.
pub fn nextSparseCandidate(rt: *core.JSRuntime, object: *core.Object, lower: usize) !SparseCandidate {
    return sparseCandidate(rt, object, lower, .at_or_after);
}

fn sparseCandidate(rt: *core.JSRuntime, object: *core.Object, bound: usize, direction: enum { before, at_or_after }) !SparseCandidate {
    var best: ?usize = null;
    var seen: usize = 0;
    var cursor: ?*core.Object = object;
    while (cursor) |candidate| : (cursor = candidate.getPrototype()) {
        if (candidate.proxyTarget() != null) return .unknown;
        const keys = try candidate.ownKeys(rt);
        defer core.Object.freeKeys(rt, keys);
        for (keys) |key| {
            const index = propertyIndexFromLengthKey(rt, key) orelse continue;
            seen += 1;
            if (seen > sparse_candidate_limit) return .unknown;
            switch (direction) {
                .before => if (index < bound and (best == null or index > best.?)) {
                    best = index;
                },
                .at_or_after => if (index >= bound and (best == null or index < best.?)) {
                    best = index;
                },
            }
        }
    }
    return if (best) |index| .{ .index = index } else .none;
}

/// LengthOfArrayLike (§7.3.18) for a generic Array method. An Array's
/// `length` is its own non-configurable data property, so reading it directly
/// is unobservable; any other object, a TypedArray included (its `length` is
/// an inherited accessor user code can shadow), goes through Get + ToLength.
pub fn lengthOfArrayLike(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    object: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !usize {
    if (object.isArray()) return @intCast(object.arrayLength());
    const length_value = try getValueProperty(ctx, output, global, value, core.atom.ids.length, caller_function, caller_frame);
    return toLengthIndex(ctx, output, global, length_value);
}

/// The length for a method shared by Array.prototype and
/// %TypedArray%.prototype: a validated TypedArrayLength for the latter,
/// LengthOfArrayLike for the former.
pub noinline fn arrayMethodLength(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    object: *core.Object,
    is_typed_method: bool,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !usize {
    if (is_typed_method) return arrayMethodTypedArrayLength(ctx.runtime, object);
    return lengthOfArrayLike(ctx, output, global, value, object, caller_function, caller_frame);
}

/// The length a `%TypedArray%` method sees: a detached or out-of-bounds view
/// is rejected.
pub fn arrayMethodTypedArrayLength(rt: *core.JSRuntime, object: *core.Object) !usize {
    if (try core.object.typedArrayDetached(object) or try core.object.typedArrayOutOfBounds(object)) {
        return error.TypedArrayOutOfBounds;
    }
    return @intCast(try core.object.typedArrayLength(rt, object));
}

pub const TypedSearchMode = enum { index_of, last_index_of, includes };

/// Raw-buffer typed scan for TypedArray indexOf/lastIndexOf/includes — mirrors
/// qjs js_typed_array_indexOf.
/// The search value is normalized ONCE against the element class with an early
/// can't-fit short-circuit; then the backing buffer is scanned per element-kind
/// (memchr for the u8 classes, typed-pointer compare otherwise) without boxing.
///
/// `start` is the already-fromIndex-coerced cursor as the existing zjs Array
/// search produces it: for forward modes the inclusive first index `k`; for
/// lastIndexOf the EXCLUSIVE upper bound (`k + 1`, matching the `cursor`/while
/// loop in arraySearchCall). `original_length` is the length read before the
/// fromIndex coercion ran (which may resize a RAB via valueOf), used only for
/// the qjs includes-undefined-out-of-bounds special case.
pub fn typedArraySearchScan(
    rt: *core.JSRuntime,
    object: *core.Object,
    mode: TypedSearchMode,
    search_value: core.JSValue,
    start: usize,
    original_length: usize,
) !core.JSValue {
    const class_kind = object.typedArrayKind();
    const elem_size = object.typedArrayElementSize();

    // includes reads elements up to the pre-coercion length, so after the
    // fromIndex coercion shrank the buffer an out-of-bounds read yields
    // `undefined` and matches an undefined search value.
    const current_length = @as(usize, @intCast(try core.object.typedArrayLength(rt, object)));
    if (mode == .includes and original_length > current_length and search_value.is(.undefined_value)) {
        if (start < original_length) return core.JSValue.boolean(true);
    }

    // RAB may have been resized by an evil valueOf in the fromIndex coercion;
    // re-clamp the scan window to min(original, live) — qjs reads len ONCE at
    // the top and then does len = min_int(len, p->u.array.count), so a buffer
    // that GREW during coercion is still scanned only over the original window
    const length = @min(original_length, current_length);
    if (length == 0) return searchScanResult(mode, null);

    // Translate the zjs cursor to qjs's k / stop / inc.
    var k: usize = undefined;
    var stop: usize = undefined;
    const forward = mode != .last_index_of;
    if (forward) {
        k = @min(start, length);
        stop = length;
        if (k >= stop) return searchScanResult(mode, null);
    } else {
        // `start` is the exclusive upper bound; the highest index scanned is
        // start - 1, re-clamped to length - 1.
        if (start == 0) return searchScanResult(mode, null);
        k = @min(start - 1, length - 1);
        stop = 0; // inclusive lower bound for the backward loop
    }

    // Normalize the search value ONCE. No coercion is
    // run on the search value itself — only its tag is inspected.
    var is_int = false;
    var is_bigint = false;
    var v64: i64 = 0;
    var d: f64 = 0;
    if (search_value.as(.int)) |int_value| {
        is_int = true;
        v64 = int_value;
        d = @floatFromInt(int_value);
    } else if (search_value.as(.float64)) |float_value| {
        d = float_value;
        if (d >= @as(f64, @floatFromInt(std.math.minInt(i64))) and d < 0x1p63) {
            v64 = @intFromFloat(d);
            is_int = (@as(f64, @floatFromInt(v64)) == d);
        }
    } else if (search_value.isBigInt()) {
        switch (class_kind) {
            .bigint64 => { // BigInt64Array: must fit int64
                v64 = search_value.asInt64() orelse return searchScanResult(mode, null);
            },
            .biguint64 => { // BigUint64Array: non-negative and must fit uint64
                const u = search_value.asUint64() orelse return searchScanResult(mode, null);
                v64 = @bitCast(u);
            },
            else => return searchScanResult(mode, null), // bigint can't match a non-bigint array
        }
        is_bigint = true;
        d = 0;
    } else {
        return searchScanResult(mode, null);
    }

    const buffer = try core.typed_array.typedArrayBufferObject(object);
    const base_offset = object.typedArrayByteOffset();
    const bytes = buffer.byteStorage()[base_offset..][0 .. length * elem_size];

    const res: ?usize = switch (class_kind) {
        .int8 => blk: {
            if (!(is_int and @as(i64, @as(i8, @truncate(v64))) == v64)) break :blk null;
            break :blk scanU8(bytes, k, stop, forward, @bitCast(@as(i8, @truncate(v64))));
        },
        .uint8, .uint8_clamped => blk: {
            if (!(is_int and @as(i64, @as(u8, @truncate(@as(u64, @bitCast(v64))))) == v64)) break :blk null;
            break :blk scanU8(bytes, k, stop, forward, @truncate(@as(u64, @bitCast(v64))));
        },
        .int16 => blk: {
            if (!(is_int and @as(i64, @as(i16, @truncate(v64))) == v64)) break :blk null;
            break :blk scanElem(i16, bytes, k, stop, forward, @truncate(v64));
        },
        .uint16 => blk: {
            if (!(is_int and @as(i64, @as(u16, @truncate(@as(u64, @bitCast(v64))))) == v64)) break :blk null;
            break :blk scanElem(u16, bytes, k, stop, forward, @truncate(@as(u64, @bitCast(v64))));
        },
        .int32 => blk: {
            if (!(is_int and @as(i64, @as(i32, @truncate(v64))) == v64)) break :blk null;
            break :blk scanElem(i32, bytes, k, stop, forward, @truncate(v64));
        },
        .uint32 => blk: {
            if (!(is_int and @as(i64, @as(u32, @truncate(@as(u64, @bitCast(v64))))) == v64)) break :blk null;
            break :blk scanElem(u32, bytes, k, stop, forward, @truncate(@as(u64, @bitCast(v64))));
        },
        .float16 => blk: {
            if (is_bigint) break :blk null;
            break :blk scanFloat(f16, mode, bytes, k, stop, forward, d);
        },
        .float32 => blk: {
            if (is_bigint) break :blk null;
            break :blk scanFloat(f32, mode, bytes, k, stop, forward, d);
        },
        .float64 => blk: {
            if (is_bigint) break :blk null;
            break :blk scanFloat(f64, mode, bytes, k, stop, forward, d);
        },
        .bigint64 => blk: {
            if (!is_bigint) break :blk null;
            break :blk scanElem(i64, bytes, k, stop, forward, v64);
        },
        .biguint64 => blk: {
            if (!is_bigint) break :blk null;
            break :blk scanElem(u64, bytes, k, stop, forward, @bitCast(v64));
        },
        else => null,
    };

    return searchScanResult(mode, res);
}

fn searchScanResult(mode: TypedSearchMode, res: ?usize) core.JSValue {
    if (mode == .includes) return core.JSValue.boolean(res != null);
    return if (res) |index| lengthIndexValue(index) else core.JSValue.int32(-1);
}

fn scanU8(bytes: []const u8, k: usize, stop: usize, forward: bool, v: u8) ?usize {
    if (forward) {
        // qjs uses memchr over [k, len) for the u8 classes.
        const found = std.mem.indexOfScalarPos(u8, bytes[0..stop], k, v) orelse return null;
        return found;
    }
    var i = k;
    while (true) : (i -= 1) {
        if (bytes[i] == v) return i;
        if (i == stop) break;
    }
    return null;
}

fn scanElem(comptime T: type, bytes: []const u8, k: usize, stop: usize, forward: bool, v: T) ?usize {
    const width = @sizeOf(T);
    if (forward) {
        var i = k;
        while (i != stop) : (i += 1) {
            if (std.mem.readInt(T, bytes[i * width ..][0..width], .little) == v) return i;
        }
        return null;
    }
    var i = k;
    while (true) : (i -= 1) {
        if (std.mem.readInt(T, bytes[i * width ..][0..width], .little) == v) return i;
        if (i == stop) break;
    }
    return null;
}

fn readFloat(comptime T: type, bytes: []const u8, index: usize) T {
    const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
    const width = @sizeOf(T);
    return @bitCast(std.mem.readInt(Bits, bytes[index * width ..][0..width], .little));
}

fn scanFloat(comptime T: type, mode: TypedSearchMode, bytes: []const u8, k: usize, stop: usize, forward: bool, d: f64) ?usize {
    if (std.math.isNan(d)) {
        // indexOf returns -1, includes finds NaN.
        if (mode != .includes) return null;
        return scanFloatPredicate(T, bytes, k, stop, forward, struct {
            fn match(e: T) bool {
                return std.math.isNan(e);
            }
        }.match);
    }
    // A narrower element type can only hold `d` if it roundtrips; `==`
    // then also matches +0 against -0.
    const target: T = @floatCast(d);
    if (T != f64 and @as(f64, @floatCast(target)) != d) return null;
    if (forward) {
        var i = k;
        while (i != stop) : (i += 1) {
            if (readFloat(T, bytes, i) == target) return i;
        }
        return null;
    }
    var i = k;
    while (true) : (i -= 1) {
        if (readFloat(T, bytes, i) == target) return i;
        if (i == stop) break;
    }
    return null;
}

fn scanFloatPredicate(comptime T: type, bytes: []const u8, k: usize, stop: usize, forward: bool, comptime match: fn (T) bool) ?usize {
    if (forward) {
        var i = k;
        while (i != stop) : (i += 1) {
            if (match(readFloat(T, bytes, i))) return i;
        }
        return null;
    }
    var i = k;
    while (true) : (i -= 1) {
        if (match(readFloat(T, bytes, i))) return i;
        if (i == stop) break;
    }
    return null;
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

pub noinline fn arraySliceCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    if (getStringPrototypeMethodId(function_object) != null) return null;
    if (!isArrayPrototypeRecord(function_object, @intFromEnum(method_ids.array.PrototypeMethod.slice))) return null;

    // Array.prototype.slice is generic over ToObject(this).
    if (receiver.is(.null_value) or receiver.is(.undefined_value)) return try throwTypeErrorMessage(ctx, global, "cannot convert to object");
    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    const object = objectFromValue(receiver_object_value) orelse return null;
    const length = try lengthOfArrayLike(ctx, output, global, receiver_object_value, object, null, null);

    const start = try arrayRelativeIndex(ctx, output, global, args, 0, length, 0);
    const end = if (args.len >= 2 and !args[1].is(.undefined_value))
        try arrayRelativeIndex(ctx, output, global, args, 1, length, length)
    else
        length;
    const count = if (end > start) end - start else 0;
    if (count > std.math.maxInt(u32)) return error.RangeError;

    // qjs js_array_slice fast case: when the species ctor is
    // the default (JS_IsUndefined) AND the source is a dense fast array AND
    // final <= count32, do ONE bulk dense copy via js_create_array (quickjs.c =
    // JS_NewArray + expand_fast_array + count=len + JS_DupValue loop), skipping the
    // per-element TryGetProperty/CreateDataProperty slow loop entirely.
    // Gate on the dense extent (fastArrayCount), NOT the logical length: the
    // bulk copy slices `arrayElements()` which is count-bounded, so the copied
    // range must lie fully inside `[0, count)`. A holey tail (count < length)
    // falls through to the per-element species path which reads via getProperty.
    if (object.isArray() and !object.isProxy() and
        object.arrayElementStorageMode() == .dense and
        (start + count) <= @as(usize, @intCast(object.fastArrayCount())))
    {
        if (try arrayHasDefaultSpecies(ctx.runtime, global, object)) |array_proto| {
            const out = try core.Object.createArray(ctx.runtime, array_proto);
            var out_value = out.value();

            // memory.alloc can GC; root the fresh array across the allocation
            // (mirror the entries-pair precedent at objectEntryArrayValue).
            var root_frame = core.runtime.rootValues(.{&out_value});
            root_frame.activate(ctx.runtime);
            defer root_frame.deactivate(ctx.runtime);

            if (count > 0) {
                // TGC S4-b spec 2.2: an adopted dense buffer is an
                // `.array_storage` GC cell, minted by the caller.
                const elements = try core.Object.createArrayStorageSlice(ctx.runtime, count);
                const src = object.arrayElements()[start .. start + count];
                for (src, 0..) |v, i| elements[i] = v;
                out.adoptDenseArrayElementsAssumingEmpty(ctx.runtime, elements);
                out.flags.may_have_indexed_properties = true;
            }
            return out_value;
        }
    }

    var out_value = try arraySpeciesCreate(ctx, output, global, receiver_object_value, count, null, null);
    // Rooted: element getters and the species result's setters run below.
    var out_roots = core.runtime.rootValues(.{&out_value});
    out_roots.activate(ctx.runtime);
    defer out_roots.deactivate(ctx.runtime);
    _ = try property_ops.expectObject(out_value);

    var from = start;
    var to: usize = 0;
    while (from < end and to < count) : ({
        try exception_ops.pollNativeLoop(ctx, global);
        from += 1;
        to += 1;
    }) {
        try arrayCopyPresentIndex(
            ctx,
            output,
            global,
            receiver_object_value,
            object,
            from,
            try property_ops.expectObject(out_value),
            to,
            null,
            null,
        );
    }
    // Steps 14-15: the elements are defined first, then `length` is Set.
    try setValuePropertyOrThrow(ctx, output, global, out_value, core.atom.ids.length, lengthIndexValue(count), null, null);
    return out_value;
}

/// %TypedArray%.prototype.slice (`is_subarray == false`) and `subarray`.
pub noinline fn typedArraySliceSubarrayCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
    is_subarray: bool,
) !?core.JSValue {
    const is_slice = !is_subarray;
    const object = objectFromValue(receiver) orelse return error.NotATypedArray;
    if (!core.object.isTypedArrayObject(object)) return error.NotATypedArray;
    if (is_slice and (try core.object.typedArrayDetached(object) or try core.object.typedArrayOutOfBounds(object))) return error.TypedArrayOutOfBounds;
    const length = @as(usize, @intCast(try core.object.typedArrayLength(ctx.runtime, object)));
    const start = try arrayRelativeIndex(ctx, output, global, args, 0, length, 0);
    const end = if (args.len >= 2 and !args[1].is(.undefined_value))
        try arrayRelativeIndex(ctx, output, global, args, 1, length, length)
    else
        length;
    const count = if (end > start) end - start else 0;
    if (count > std.math.maxInt(i32)) return error.RangeError;

    const constructor_value = try typedArraySpeciesConstructorForObject(ctx, output, global, receiver, object, null, null);

    const result = if (is_subarray) blk: {
        const buffer_value = (object.typedArrayBuffer() orelse return error.TypeError);
        const buffer = objectFromValue(buffer_value) orelse return error.TypeError;
        if (buffer.class_id != core.class.ids.array_buffer and buffer.class_id != core.class.ids.shared_array_buffer) {
            return error.TypeError;
        }
        // TypedArraySpeciesCreate validates the (buffer, offset, length)
        // arguments itself; an out-of-bounds source only means length 0.
        const src_byte_offset = object.typedArrayByteOffset();
        const begin_byte_offset = src_byte_offset + start * object.typedArrayElementSize();
        if (object.typedArrayFixedLength() == null and (args.len < 2 or args[1].is(.undefined_value))) {
            break :blk try constructValueOrBytecode(ctx, output, global, constructor_value, &.{ buffer_value, lengthIndexValue(begin_byte_offset) }, null, null);
        }
        break :blk try constructValueOrBytecode(ctx, output, global, constructor_value, &.{ buffer_value, lengthIndexValue(begin_byte_offset), lengthIndexValue(count) }, null, null);
    } else try typedArrayCreateWithLength(ctx, output, global, constructor_value, count, null, null);
    const result_object = objectFromValue(result) orelse return error.TypeError;
    if (!core.object.isTypedArrayObject(result_object)) return error.NotATypedArray;
    try requireSpeciesContentType(object, result);

    if (is_slice and count > 0) {
        if (try core.object.typedArrayDetached(object) or try core.object.typedArrayOutOfBounds(object)) return error.TypedArrayOutOfBounds;
        if (try core.object.typedArrayDetached(result_object) or try core.object.typedArrayOutOfBounds(result_object)) return error.TypedArrayOutOfBounds;
        const current_length = @as(usize, @intCast(try core.object.typedArrayLength(ctx.runtime, object)));
        const copy_count = if (current_length > start)
            @min(count, current_length - start)
        else
            0;
        // Faithful to quickjs.c: when source and dest share class
        // (same element kind => same byte layout), copy the raw byte range in
        // one memcpy instead of per-element get/set. The element loop below
        // handles every case this does not cover (differing class). Both arrays
        // were just re-validated as non-detached / in-bounds, and the result
        // was length-checked to hold >= count >= copy_count elements
        // (typedArrayCreateWithLength), so the byte ranges are valid.
        if (copy_count > 0 and object.typedArrayKind() == result_object.typedArrayKind()) {
            const element_size = object.typedArrayElementSize();
            const src_buffer = objectFromValue(object.typedArrayBuffer() orelse return error.TypeError) orelse return error.TypeError;
            const dst_buffer = objectFromValue(result_object.typedArrayBuffer() orelse return error.TypeError) orelse return error.TypeError;
            const byte_count = copy_count * element_size;
            const src_byte = object.typedArrayByteOffset() + start * element_size;
            const dst_byte = result_object.typedArrayByteOffset();
            const src_bytes = src_buffer.byteStorage()[src_byte .. src_byte + byte_count];
            const dst_bytes = dst_buffer.byteStorage()[dst_byte .. dst_byte + byte_count];
            // Faithful to slice_memcpy: plain memcpy when the
            // ranges cannot overlap, byte-wise forward copy otherwise (a species
            // typed array may alias the source buffer).
            const dst_ptr = dst_bytes.ptr;
            const src_ptr = src_bytes.ptr;
            if (@intFromPtr(dst_ptr) + byte_count <= @intFromPtr(src_ptr) or
                @intFromPtr(dst_ptr) >= @intFromPtr(src_ptr) + byte_count)
            {
                @memcpy(dst_bytes, src_bytes);
            } else {
                std.mem.copyForwards(u8, dst_bytes, src_bytes);
            }
            return result;
        }
        for (0..copy_count) |index| {
            const item = try core.typed_array.typedArrayGetIndex(ctx.runtime, object, @intCast(start + index));
            _ = try core.typed_array.typedArraySetIndex(ctx.runtime, result_object, @intCast(index), item);
        }
    }
    return result;
}

/// The realm's intrinsic constructor for `object`'s element type (the
/// TypedArraySpeciesCreate default and TypedArrayCreateSameType's
/// constructor), not whatever the global binding now holds.
pub fn typedArrayConstructorForObject(rt: *core.JSRuntime, global: *core.Object, object: *core.Object) !core.JSValue {
    const kind = object.typedArrayKind();
    if (!kind.isNumeric() and !kind.isBigInt()) return error.NotATypedArray;
    const table = objectFromValue(global.cachedRealmValue(rt, .typed_array_constructors) orelse return error.InvalidBuiltinRegistry) orelse
        return error.InvalidBuiltinRegistry;
    return table.getOwnDataPropertyValue(core.Atom.taggedInt(@intFromEnum(kind))) orelse error.InvalidBuiltinRegistry;
}

pub fn typedArraySpeciesConstructorForObject(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const default_constructor = try typedArrayConstructorForObject(ctx.runtime, global, object);
    return object_ops.speciesConstructor(ctx, output, global, receiver, default_constructor, caller_function, caller_frame);
}

/// Dense fast path for Array.prototype.splice, mirroring the fast_array case of
/// quickjs js_array_splice: when the species constructor
/// is the default and the receiver is an ordinary dense fast array whose
/// affected range lies inside the dense extent, the removed elements are
/// bulk-copied into a fresh dense array (js_create_array, quickjs.c) and the
/// tail is relocated with one bulk move instead of the
/// spec-literal per-element HasProperty/Get/Set loop.
///
/// Returns the removed array on success, or null to fall through to the generic
/// path for anything not provably an ordinary dense array. Every argument
/// coercion has already run in the caller, so the dense extent is re-read here:
/// a user `valueOf` may have mutated the receiver meanwhile, which is exactly
/// why qjs re-reads p->u.array.count at its own gate.
fn fastDenseArraySplice(
    ctx: *core.JSContext,
    global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    length: usize,
    actual_start: usize,
    actual_delete_count: usize,
    insert_items: []const core.JSValue,
    new_length: usize,
) !?core.JSValue {
    const rt = ctx.runtime;
    // Receiver must BE the array (no primitive wrapper / proxy indirection), and
    // an ordinary, extensible, length-writable dense fast array with no exotic
    // [[Set]]/[[DefineOwnProperty]]/[[Delete]] behaviour.
    if (objectFromValue(receiver) != object) return null;
    if (!object.isArray() or !object.isFastArray()) return null;
    if (object.hasExoticMethods() or object.proxyTarget() != null) return null;
    if (!object.flags.length_writable or !object.flags.extensible) return null;
    // The prototype chain needs no walk here: defining Array.prototype[i] / Object.prototype[i] already clears
    // `is_std_array_prototype`, so the one can_extend test is enough.
    if (!object.canExtendFastArray()) return null;

    // Re-read the dense extent AFTER the coercions. Requiring count == length
    // covers both a holey tail (whose holes the generic path must preserve via
    // per-index HasProperty) and any coercion-time mutation of the receiver:
    // actual_start / actual_delete_count were derived from the pre-coercion
    // length, so they are only in bounds while the extent still agrees with it.
    const count32: usize = @intCast(object.fastArrayCount());
    if (count32 != length) return null;
    if (count32 != @as(usize, @intCast(object.arrayLength()))) return null;
    if (actual_start + actual_delete_count > count32) return null;
    const new_count = count32 - actual_delete_count + insert_items.len;
    if (new_count != new_length) return null;
    const new_count_u32 = std.math.cast(u32, new_count) orelse return null;

    const array_proto = (try arrayHasDefaultSpecies(rt, global, object)) orelse return null;

    // Removed elements, built the same way as the slice fast path above.
    const removed = try core.Object.createArray(rt, array_proto);
    var removed_value = removed.value();

    // memory.alloc and fastArrayEnsureCapacity below can GC; root the fresh
    // array across both.
    var root_frame = core.runtime.rootValues(.{&removed_value});
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    if (actual_delete_count > 0) {
        // TGC S4-b: `.array_storage` GC cell (see the slice fast path).
        const elements = try core.Object.createArrayStorageSlice(rt, actual_delete_count);
        const src = object.arrayElements()[actual_start .. actual_start + actual_delete_count];
        for (src, 0..) |v, i| elements[i] = v;
        removed.adoptDenseArrayElementsAssumingEmpty(rt, elements);
        removed.flags.may_have_indexed_properties = true;
    }

    // From here on only fastArrayEnsureCapacity allocates, before any
    // element moves, so no GC observes the half-moved element window.
    const tail_src = actual_start + actual_delete_count;
    const tail_len = count32 - tail_src;
    const tail_dst = actual_start + insert_items.len;
    if (insert_items.len < actual_delete_count) {
        const values = object.fastArrayValuesMut();
        if (tail_len > 0) {
            std.mem.copyForwards(
                core.JSValue,
                values[tail_dst .. tail_dst + tail_len],
                values[tail_src .. tail_src + tail_len],
            );
        }
        // Slots past the new count are stale copies; the collector traces
        // only the first `count` elements.
        object.setFastArrayCountAssumeCapacity(new_count_u32);
    } else if (insert_items.len > actual_delete_count) {
        try object.fastArrayEnsureCapacity(rt, new_count_u32);
        // Growth may reallocate the backing buffer, so publish the new extent
        // first and only then take the window. Count and length must move together to
        // preserve the `length >= count` invariant that arrayElementsMut
        // asserts; the array was fully dense on entry, so the new dense extent
        // IS the new logical length. This is the idiom fastDenseArrayUnshift
        // already relies on.
        object.setFastArrayCountAssumeCapacity(new_count_u32);
        object.setArrayLength(new_count_u32);
        const values = object.fastArrayValuesMut();
        if (tail_len > 0) {
            std.mem.copyBackwards(
                core.JSValue,
                values[tail_dst .. tail_dst + tail_len],
                values[tail_src .. tail_src + tail_len],
            );
        }
    }

    // Insert loop: every slot in [start, start + inserts) is overwritten,
    // including the stale gap the tail move left behind.
    if (insert_items.len > 0) {
        // The dense-append choke point (`appendInitializedFastArrayValue`)
        // remembers the owner for every ordinary push; this path reaches the
        // storage through `fastArrayValuesMut` instead and so misses it. The
        // tail moves above need nothing -- they relocate references the array
        // already owned -- but these inserts are new edges into an array that
        // may be arbitrarily old, which is what makes `a.splice(i, 1, {..})`
        // free its own fresh elements under a minor.
        rt.gc.rememberOwnerForBulkWrite(object.gcHeader());
        const values = object.fastArrayValuesMut();
        for (insert_items, 0..) |item, offset| {
            const slot = &values[actual_start + offset];
            slot.* = item;
        }
    }

    object.setArrayLength(new_count_u32);
    object.markIndexedProperties(rt);
    return removed_value;
}

pub fn arraySpliceCallImpl(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
) !?core.JSValue {
    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    const object = objectFromValue(receiver_object_value) orelse return null;
    const length = try lengthOfArrayLike(ctx, output, global, receiver_object_value, object, null, null);

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
        const requested = try toNumberForArrayMethod(ctx, output, global, args[1]);
        if (std.math.isNan(requested) or requested <= 0) break :blk @as(usize, 0);
        const available = length - actual_start;
        if (std.math.isPositiveInf(requested) or requested >= @as(f64, @floatFromInt(available))) break :blk available;
        break :blk @as(usize, @intFromFloat(@trunc(requested)));
    };
    const new_length = length - actual_delete_count + insert_count;
    if (new_length > core.array.max_safe_length) return error.ArrayTooLong;

    // qjs js_array_splice takes its fast_array branch here, after every argument
    // coercion and before allocating the result via the species constructor.
    // Placing the arm at the same point keeps the observable
    // order identical: a user `valueOf` in the arguments still runs first, and
    // the arm re-validates the receiver against the post-coercion state.
    if (try fastDenseArraySplice(
        ctx,
        global,
        receiver,
        object,
        length,
        actual_start,
        actual_delete_count,
        if (args.len > 2) args[2..] else &.{},
        new_length,
    )) |removed_fast| {
        return removed_fast;
    }

    const removed_value = try arraySpeciesCreate(ctx, output, global, receiver_object_value, actual_delete_count, null, null);
    const removed = try property_ops.expectObject(removed_value);
    for (0..actual_delete_count) |index| {
        try exception_ops.pollNativeLoop(ctx, global);
        try arrayCopyPresentIndex(
            ctx,
            output,
            global,
            receiver_object_value,
            object,
            actual_start + index,
            removed,
            index,
            null,
            null,
        );
    }
    try setValuePropertyOrThrow(ctx, output, global, removed_value, core.atom.ids.length, lengthIndexValue(actual_delete_count), null, null);

    if (insert_count < actual_delete_count) {
        var from = actual_start + actual_delete_count;
        while (from < length) : (from += 1) {
            try exception_ops.pollNativeLoop(ctx, global);
            const to = from - actual_delete_count + insert_count;
            try arrayMoveIndex(ctx, output, global, receiver_object_value, object, from, to);
        }
        var delete_index = length;
        while (delete_index > new_length) {
            try exception_ops.pollNativeLoop(ctx, global);
            delete_index -= 1;
            const key = try propertyAtomFromLengthIndex(ctx.runtime, delete_index);
            defer key.deinit(ctx.runtime);
            try deleteValuePropertyOrThrow(ctx, output, global, object, key.atom);
        }
    } else if (insert_count > actual_delete_count) {
        var from = length;
        while (from > actual_start + actual_delete_count) {
            try exception_ops.pollNativeLoop(ctx, global);
            from -= 1;
            const to = from - actual_delete_count + insert_count;
            try arrayMoveIndex(ctx, output, global, receiver_object_value, object, from, to);
        }
    }

    if (args.len > 2) {
        for (args[2..], 0..) |item, offset| {
            const key = try propertyAtomFromLengthIndex(ctx.runtime, actual_start + offset);
            defer key.deinit(ctx.runtime);
            try setValuePropertyOrThrow(ctx, output, global, receiver_object_value, key.atom, item, null, null);
        }
    }
    try setValuePropertyOrThrow(ctx, output, global, receiver_object_value, core.atom.ids.length, lengthIndexValue(new_length), null, null);
    return removed_value;
}

pub noinline fn arrayCopyWithinCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    const is_typed_method = isTypedArrayPrototypeMethod(function_object);

    if (is_typed_method) {
        const object = objectFromValue(receiver) orelse return error.NotATypedArray;
        if (!core.object.isTypedArrayObject(object)) return error.NotATypedArray;
        if (try core.object.typedArrayDetached(object)) return error.TypedArrayOutOfBounds;
        if (try core.object.typedArrayOutOfBounds(object)) return error.TypedArrayOutOfBounds;
        const initial_length = @as(usize, @intCast(try core.object.typedArrayLength(ctx.runtime, object)));

        const target_number = if (args.len >= 1)
            try toIntegerOrInfinityForArrayByCopy(ctx, output, global, args[0])
        else
            @as(f64, 0);
        const start_number = if (args.len >= 2)
            try toIntegerOrInfinityForArrayByCopy(ctx, output, global, args[1])
        else
            @as(f64, 0);
        const end_number = if (args.len >= 3 and !args[2].is(.undefined_value))
            try toIntegerOrInfinityForArrayByCopy(ctx, output, global, args[2])
        else
            null;

        // §23.2.3.6: indices are relative to the length read before the
        // coercions. Only a non-empty copy revalidates the buffer (step 17);
        // a buffer shrunk by the coercions then clamps the copied range.
        const to_start = arrayRelativeIndexFromNumber(initial_length, target_number);
        const from_start = arrayRelativeIndexFromNumber(initial_length, start_number);
        const final = if (end_number) |end|
            arrayRelativeIndexFromNumber(initial_length, end)
        else
            initial_length;
        const requested = @min(final -| from_start, initial_length -| to_start);
        if (requested == 0) return receiver;
        if (try core.object.typedArrayDetached(object)) return error.TypedArrayOutOfBounds;
        if (try core.object.typedArrayOutOfBounds(object)) return error.TypedArrayOutOfBounds;
        const current_length = @as(usize, @intCast(try core.object.typedArrayLength(ctx.runtime, object)));
        const count = @min(requested, current_length -| from_start, current_length -| to_start);
        if (count == 0) return receiver;

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
        return receiver;
    }

    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    const object = objectFromValue(receiver_object_value) orelse return null;
    const length = try lengthOfArrayLike(ctx, output, global, receiver_object_value, object, null, null);

    const to_start = try arrayRelativeIndex(ctx, output, global, args, 0, length, 0);
    const from_start = try arrayRelativeIndex(ctx, output, global, args, 1, length, 0);
    const final = if (args.len >= 3 and !args[2].is(.undefined_value))
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
        try exception_ops.pollNativeLoop(ctx, global);
        try arrayMoveIndex(ctx, output, global, receiver_object_value, object, from, to);
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
    return receiver_object_value;
}

/// Elements a TypedArray fill writes between interrupt polls.
const typed_array_fill_slice = 1 << 20;

pub noinline fn arrayFillCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    const is_typed_method = isTypedArrayPrototypeMethod(function_object);
    if (is_typed_method and !receiver.is(.object)) return error.NotATypedArray;
    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    const object = objectFromValue(receiver_object_value) orelse return null;

    if (is_typed_method) {
        if (!core.object.isTypedArrayObject(object)) return error.NotATypedArray;
        if (try core.object.typedArrayDetached(object) or try core.object.typedArrayOutOfBounds(object)) return error.TypedArrayOutOfBounds;

        const initial_length = @as(usize, @intCast(try core.object.typedArrayLength(ctx.runtime, object)));
        const raw_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const value = try typedArrayByCopyCoerceValue(ctx, output, global, object, raw_value);

        const start = try arrayRelativeIndex(ctx, output, global, args, 1, initial_length, 0);
        const final = if (args.len >= 3 and !args[2].is(.undefined_value))
            try arrayRelativeIndex(ctx, output, global, args, 2, initial_length, initial_length)
        else
            initial_length;

        if (try core.object.typedArrayDetached(object) or try core.object.typedArrayOutOfBounds(object)) return error.TypedArrayOutOfBounds;

        const current_length = @as(usize, @intCast(try core.object.typedArrayLength(ctx.runtime, object)));
        const capped_final = @min(final, current_length);
        // Fill in slices so a huge fill polls the interrupt handler.
        var slice_start = start;
        while (slice_start < capped_final) {
            const slice_end = @min(capped_final, slice_start + typed_array_fill_slice);
            try core.typed_array.typedArrayFillRange(ctx.runtime, object, @intCast(slice_start), @intCast(slice_end), value);
            try ctx.runtime.interrupt.pollNativeBulkWork(slice_end - slice_start);
            slice_start = slice_end;
        }
        return receiver_object_value;
    }

    const length = try lengthOfArrayLike(ctx, output, global, receiver_object_value, object, null, null);

    const start = try arrayRelativeIndex(ctx, output, global, args, 1, length, 0);
    const final = if (args.len >= 3 and !args[2].is(.undefined_value))
        try arrayRelativeIndex(ctx, output, global, args, 2, length, length)
    else
        length;
    // Array.prototype.fill on a TypedArray receiver converts at each Set.
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();

    // The dense fast path appends/overwrites contiguously from `start`, so it
    // is only valid when `start` lands within (or exactly at the end of) the
    // dense extent. A holey array whose fill range begins past `array_count`
    // (e.g. `new Array(5).fill(7,2,4)`) would otherwise no-op the leading
    // appends; route those through the generic setValueProperty loop below.
    // The dense path may stop early; it then falls through to the one
    // generic set tail (propertyAtom + setValuePropertyOrThrow).
    var index = start;
    if (object.isArray() and !object.hasExoticMethods() and object.proxyTarget() == null and object.arrayElementStorageMode() == .dense and object.flags.extensible and arrayPrototypeChainHasNoIndexedProperties(object) and start <= @as(usize, @intCast(object.fastArrayCount()))) {
        if (final <= @as(usize, @intCast(std.math.maxInt(u32))) + 1) {
            var dense_index = start;
            if (object.canDefineDenseArrayDataPropertiesUnchecked()) {
                while (dense_index < final) : (dense_index += 1) {
                    try exception_ops.pollNativeLoop(ctx, global);
                    try object.defineDenseArrayDataPropertyUnchecked(ctx.runtime, @intCast(dense_index), value);
                }
                return receiver_object_value;
            }

            while (dense_index < final) : (dense_index += 1) {
                try exception_ops.pollNativeLoop(ctx, global);
                if (!try object.defineDenseArrayDataProperty(ctx.runtime, @intCast(dense_index), value)) break;
            }
            if (dense_index == final) return receiver_object_value;
            index = dense_index;
        }
    }

    while (index < final) : (index += 1) {
        try exception_ops.pollNativeLoop(ctx, global);
        const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
        defer key.deinit(ctx.runtime);
        try setValuePropertyOrThrow(ctx, output, global, receiver_object_value, key.atom, value, null, null);
    }
    return receiver_object_value;
}

pub fn arrayPrototypeChainHasNoIndexedProperties(object: *core.Object) bool {
    var cursor = object.getPrototype();
    while (cursor) |candidate| {
        if (candidate.proxyTarget() != null or candidate.hasExoticMethods()) return false;
        if (candidate.flags.may_have_indexed_properties) return false;
        cursor = candidate.getPrototype();
    }
    return true;
}

/// qjs `js_array_push` fast case: one admission
/// (`ARRAY && fast_array && can_extend && length==count && writable` and
/// `new_len <= INT32_MAX`), then expand + Dup + write. Returns the new
/// length, or null so the caller can take the generic ToObject/Set path.
pub inline fn tryFastArrayPush(
    rt: *core.JSRuntime,
    receiver: core.JSValue,
    args: []const core.JSValue,
) !?i32 {
    const object = objectFromValue(receiver) orelse return null;
    if (object.class_id != core.class.ids.array) return null;
    if (!object.flags.fast_array) return null;
    if (!object.canExtendFastArray()) return null;
    if (!object.flags.length_writable) return null;
    const count = object.arrayArm().*.count;
    if (object.arrayLength() != count) return null;
    const argc = std.math.cast(u32, args.len) orelse return null;
    const new_len = std.math.add(u32, count, argc) catch return null;
    if (new_len > std.math.maxInt(i32)) return null;
    try object.appendFastArrayPushValues(rt, args);
    return @intCast(new_len);
}

pub fn arrayPushCallImpl(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (receiver.is(.null_value) or receiver.is(.undefined_value)) {
        return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "Cannot convert undefined or null to object"));
    }

    // qjs `js_array_push` checks the direct Array receiver before JS_ToObject
    // and returns from its fast case without a receiver dup/free. Keep the
    // borrowed receiver rooted by the active call frame and do the same here.
    if (try tryFastArrayPush(ctx.runtime, receiver, args)) |new_len| {
        return core.JSValue.int32(new_len);
    }

    const receiver_object_value = if (objectFromValue(receiver) != null) receiver else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    // A String wrapper fails at the spec's Set of `length` (or of an index
    // below it), after the element writes above its length have happened.
    const length_value = try getValueProperty(ctx, output, global, receiver_object_value, core.atom.ids.length, caller_function, caller_frame);
    const length = try toLengthIndex(ctx, output, global, length_value);
    if (args.len > core.array.max_safe_length - length) return error.ArrayTooLong;

    var index = length;
    for (args) |item| {
        const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
        defer key.deinit(ctx.runtime);
        try setValuePropertyOrThrow(ctx, output, global, receiver_object_value, key.atom, item, caller_function, caller_frame);
        index += 1;
    }
    try setValuePropertyOrThrow(ctx, output, global, receiver_object_value, core.atom.ids.length, lengthIndexValue(index), caller_function, caller_frame);
    return lengthIndexValue(index);
}

pub fn arrayPopCallImpl(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    const object = objectFromValue(receiver_object_value) orelse return null;
    if (fastDenseArrayPop(object)) |value| return value;
    if (try fastEmptyArrayPop(ctx, global, object)) |value| return value;
    const length = try lengthOfArrayLike(ctx, output, global, receiver_object_value, object, caller_function, caller_frame);

    if (length == 0) {
        try setValuePropertyOrThrow(ctx, output, global, receiver_object_value, core.atom.ids.length, core.JSValue.int32(0), caller_function, caller_frame);
        return core.JSValue.undefinedValue();
    }

    const index = length - 1;
    const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
    defer key.deinit(ctx.runtime);
    const value = try getValueProperty(ctx, output, global, receiver_object_value, key.atom, caller_function, caller_frame);
    try deleteValuePropertyOrThrow(ctx, output, global, object, key.atom);
    if (object.isArray() and object.arrayLength() <= length) {
        // The last indexed property has already been deleted, so qjs's final
        // JS_SetProperty(length, newLen) can update the actual Array length slot
        // directly while the current length has not grown past the captured
        // length. Preserve ordering: a getter above may have made length
        // non-writable, in which case deletion remains visible before TypeError.
        // If a getter grew the array, use the generic write so shrinking length
        // also removes every newly-added element at or above `index`.
        if (!object.flags.length_writable) {
            return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "'length' is read-only"));
        }
        object.setArrayLength(@intCast(index));
    } else {
        try setValuePropertyOrThrow(ctx, output, global, receiver_object_value, core.atom.ids.length, lengthIndexValue(index), caller_function, caller_frame);
    }
    return value;
}

fn fastDenseArrayPop(object: *core.Object) ?core.JSValue {
    if (!object.isArray() or !object.flags.length_writable) return null;
    if (!object.isFastArray()) return null;
    // Only on a fully-dense array (count == length): pop removes a[length-1],
    // which must be a live dense element. A holey array (length > count) has a
    // hole at the logical end, so it falls back to the generic pop path.
    return object.takeLastFullyDenseFastArrayElement();
}

/// Effective empty-array leg of qjs `js_array_pop`: `js_get_length64` reads the
/// own Array length slot, and the final `JS_SetProperty(..., length, 0)` writes
/// that same slot or throws when it is non-writable. A Proxy/ordinary array-like
/// is not `flags.is_array` and must keep the observable generic Get/Set path.
fn fastEmptyArrayPop(ctx: *core.JSContext, global: *core.Object, object: *core.Object) !?core.JSValue {
    if (!object.isArray() or object.arrayLength() != 0) return null;
    if (!object.flags.length_writable) {
        return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "'length' is read-only"));
    }
    object.setArrayLength(0);
    return core.JSValue.undefinedValue();
}

pub noinline fn arrayShiftCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    if (!isArrayPrototypeRecord(function_object, @intFromEnum(method_ids.array.PrototypeMethod.shift))) return null;

    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    const object = objectFromValue(receiver_object_value) orelse return null;
    // A String wrapper's indices and `length` are read-only, so the first
    // Set(O, …, true) that shift performs throws.
    if (object.class_id == core.class.ids.string) return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "property is read-only"));
    if (fastDenseArrayShift(object)) |value| return value;
    const length = try lengthOfArrayLike(ctx, output, global, receiver_object_value, object, null, null);

    if (length == 0) {
        try setValuePropertyOrThrow(ctx, output, global, receiver_object_value, core.atom.ids.length, core.JSValue.int32(0), null, null);
        return core.JSValue.undefinedValue();
    }

    const first = try getValueProperty(ctx, output, global, receiver_object_value, core.Atom.taggedInt(0), null, null);

    var index: usize = 1;
    while (index < length) : (index += 1) {
        try exception_ops.pollNativeLoop(ctx, global);
        try arrayMoveIndex(ctx, output, global, receiver_object_value, object, index, index - 1);
    }

    const tail_key = try propertyAtomFromLengthIndex(ctx.runtime, length - 1);
    defer tail_key.deinit(ctx.runtime);
    try deleteValuePropertyOrThrow(ctx, output, global, object, tail_key.atom);
    try setValuePropertyOrThrow(ctx, output, global, receiver_object_value, core.atom.ids.length, lengthIndexValue(length - 1), null, null);
    return first;
}

fn fastDenseArrayShift(object: *core.Object) ?core.JSValue {
    if (!object.isArray() or !object.flags.length_writable) return null;
    if (!object.isFastArray()) return null;
    // Shift moves the whole [1, length) range down and lowers .length. Only run
    // on a fully-dense array (count == length); a holey array (length > count)
    // would mishandle the tail holes, so it falls back to the generic path.
    if (object.fastArrayCount() != object.arrayLength()) return null;
    const values = object.fastArrayValuesMut();
    if (values.len == 0) return null;

    const first = values[0];
    if (values.len > 1) {
        std.mem.copyForwards(core.JSValue, values[0 .. values.len - 1], values[1..values.len]);
    }
    values[values.len - 1] = core.JSValue.undefinedValue();
    object.setFastArrayCountAssumeCapacity(@intCast(values.len - 1));
    object.setArrayLength(@intCast(values.len - 1));
    return first;
}

/// Dense fast path for Array.prototype.unshift, mirroring the in-place bulk
/// move of u.array.u.values in quickjs JS_CopySubArray's fast_array branch.
/// qjs's literal condition requires the destination
/// index to already be in bounds, so its in-place branch never fires for the
/// growing unshift shift; this routine performs the structurally identical
/// move after growing capacity. Returns the new length on success, or null to
/// fall through to the generic per-element arrayMoveIndex path for anything
/// not provably an ordinary dense array with no prototype index interactions.
fn fastDenseArrayUnshift(
    rt: *core.JSRuntime,
    receiver: core.JSValue,
    object: *core.Object,
    args: []const core.JSValue,
) !?usize {
    if (args.len == 0) return null;
    // Receiver must BE the array (no primitive wrapper / proxy indirection),
    // and an ordinary, extensible, length-writable dense fast array with no
    // exotic [[Set]]/[[DefineOwnProperty]] behaviour.
    if (objectFromValue(receiver) != object) return null;
    if (!object.isArray() or !object.isFastArray()) return null;
    if (object.hasExoticMethods() or object.proxyTarget() != null) return null;
    if (!object.flags.length_writable or !object.flags.extensible) return null;
    // Any inherited indexed property would make the generic [[Set]] of a
    // shifted slot observe a prototype accessor; the dense move skips the
    // prototype chain, so only proceed when the chain has no indexed props.
    if (!arrayPrototypeChainHasNoIndexedProperties(object)) return null;

    const length: usize = @intCast(object.arrayLength());
    if (length != @as(usize, @intCast(object.fastArrayCount()))) return null;
    const insert_count = args.len;
    const new_length = length + insert_count;
    const new_length_u32 = std.math.cast(u32, new_length) orelse return null;

    // Grow first (may reallocate the backing buffer), then publish the new
    // count so fastArrayValuesMut() exposes the full [0, new_length) range.
    // The array was fully dense (count == length) on entry, so the new dense
    // extent IS the new logical length; keep them in lock-step.
    try object.fastArrayEnsureCapacity(rt, new_length_u32);
    object.setFastArrayCountAssumeCapacity(new_length_u32);
    object.setArrayLength(new_length_u32);
    const values = object.fastArrayValuesMut();
    // Move the existing [0, length) elements up by insert_count. This is a raw
    // bit move (no dup/free); ownership of each original reference travels with
    // it to its new slot, exactly like fastDenseArrayShift's downward move.
    if (length != 0) {
        std.mem.copyBackwards(core.JSValue, values[insert_count..new_length], values[0..length]);
    }
    // Overwrite the now-stale [0, insert_count) head with fresh duplicates of
    // the arguments. The previous bits there are aliases of values that now
    // live in their moved-up slots, so they must NOT be freed here.
    //
    // This grows through `fastArrayEnsureCapacity`, not the remembering
    // `appendInitializedFastArrayValue`, so remember the array explicitly:
    // the new head references may be edges from an old array to young values.
    rt.gc.rememberOwnerForBulkWrite(object.gcHeader());
    for (args, 0..) |item, index| {
        values[index] = item;
    }
    object.markIndexedProperties(rt);
    return new_length;
}

pub noinline fn arrayUnshiftCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    if (!isArrayPrototypeRecord(function_object, @intFromEnum(method_ids.array.PrototypeMethod.unshift))) return null;

    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    const object = objectFromValue(receiver_object_value) orelse return null;

    if (try fastDenseArrayUnshift(ctx.runtime, receiver, object, args)) |new_length_fast| {
        return lengthIndexValue(new_length_fast);
    }

    const length = try lengthOfArrayLike(ctx, output, global, receiver_object_value, object, null, null);
    const insert_count = args.len;
    if (insert_count > core.array.max_safe_length - length) return error.ArrayTooLong;
    const new_length = length + insert_count;

    if (insert_count > 0) {
        var sparse_walk = length >= sparse_walk_min_length;
        var k = length;
        while (k > 0) {
            if (sparse_walk) {
                // Index k-1 matters when its source (k-1) or its
                // destination (k-1 + insert_count) may be present.
                const source = try previousSparseCandidate(ctx.runtime, object, k);
                const destination = try previousSparseCandidate(ctx.runtime, object, k + insert_count);
                if (source == .unknown or destination == .unknown) {
                    sparse_walk = false;
                } else {
                    var next: ?usize = if (source == .index) source.index else null;
                    if (destination == .index and destination.index >= insert_count) {
                        const shifted = destination.index - insert_count;
                        if (next == null or shifted > next.?) next = shifted;
                    }
                    k = (next orelse break) + 1;
                }
            }
            k -= 1;
            try arrayMoveIndex(ctx, output, global, receiver_object_value, object, k, k + insert_count);
        }

        for (args, 0..) |item, index| {
            const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
            defer key.deinit(ctx.runtime);
            try setValuePropertyOrThrow(ctx, output, global, receiver_object_value, key.atom, item, null, null);
        }
    }

    try setValuePropertyOrThrow(ctx, output, global, receiver_object_value, core.atom.ids.length, lengthIndexValue(new_length), null, null);
    return lengthIndexValue(new_length);
}

pub noinline fn arrayReverseCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    if (receiver.is(.null_value) or receiver.is(.undefined_value)) return error.NullishToObject;

    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    const object = objectFromValue(receiver_object_value) orelse return error.TypeError;
    const is_typed_method = isTypedArrayPrototypeMethod(function_object);
    if (is_typed_method and !core.object.isTypedArrayObject(object)) return error.NotATypedArray;
    if (is_typed_method) {
        if (try core.object.typedArrayDetached(object) or try core.object.typedArrayOutOfBounds(object)) return error.TypedArrayOutOfBounds;
        const length = @as(usize, @intCast(try core.object.typedArrayLength(ctx.runtime, object)));
        var lower: usize = 0;
        while (lower < length / 2) : (lower += 1) {
            try exception_ops.pollNativeLoop(ctx, global);
            const upper = length - lower - 1;
            const lower_value = try core.typed_array.typedArrayGetIndex(ctx.runtime, object, @intCast(lower));
            const upper_value = try core.typed_array.typedArrayGetIndex(ctx.runtime, object, @intCast(upper));
            _ = try core.typed_array.typedArraySetIndex(ctx.runtime, object, @intCast(lower), upper_value);
            _ = try core.typed_array.typedArraySetIndex(ctx.runtime, object, @intCast(upper), lower_value);
        }
        return receiver_object_value;
    }
    const length = try lengthOfArrayLike(ctx, output, global, receiver_object_value, object, caller_function, caller_frame);

    // Special case fast arrays (qjs js_array_reverse quickjs.c):
    // js_get_fast_array(ctx, obj, &arrp, &count32) && count32 == len → bare
    // pointer-swap loop, a pure JSValue permutation with no dup/free (matches
    // qjs's set_value-free swap). count32 == len rejects tail holes; non-fast /
    // sparse / proxy / array-like fall through to the generic loop below.
    if (object.flags.extensible and object.isFastArray() and object.fastArrayCount() == length) {
        if (length > 1) {
            const arrp = object.fastArrayValuesMut();
            var ll: usize = 0;
            var hh: usize = length - 1;
            while (ll < hh) : ({
                ll += 1;
                hh -= 1;
            }) {
                const lval = arrp[ll];
                arrp[ll] = arrp[hh];
                arrp[hh] = lval;
            }
        }
        return receiver_object_value;
    }

    var lower: usize = 0;
    while (lower < length / 2) : (lower += 1) {
        try exception_ops.pollNativeLoop(ctx, global);
        const upper = length - lower - 1;
        const lower_key = try propertyAtomFromLengthIndex(ctx.runtime, lower);
        defer lower_key.deinit(ctx.runtime);
        const upper_key = try propertyAtomFromLengthIndex(ctx.runtime, upper);
        defer upper_key.deinit(ctx.runtime);

        const lower_exists = try hasValueProperty(ctx, output, global, object, lower_key.atom, null, null);
        var lower_value: core.JSValue = core.JSValue.undefinedValue();
        if (lower_exists) {
            lower_value = try getValueProperty(ctx, output, global, receiver_object_value, lower_key.atom, caller_function, caller_frame);
        }

        const upper_exists = try hasValueProperty(ctx, output, global, object, upper_key.atom, null, null);
        var upper_value: core.JSValue = core.JSValue.undefinedValue();
        if (upper_exists) {
            upper_value = try getValueProperty(ctx, output, global, receiver_object_value, upper_key.atom, caller_function, caller_frame);
        }

        if (lower_exists and upper_exists) {
            try setValuePropertyOrThrow(ctx, output, global, receiver_object_value, lower_key.atom, upper_value, caller_function, caller_frame);
            try setValuePropertyOrThrow(ctx, output, global, receiver_object_value, upper_key.atom, lower_value, caller_function, caller_frame);
        } else if (!lower_exists and upper_exists) {
            try setValuePropertyOrThrow(ctx, output, global, receiver_object_value, lower_key.atom, upper_value, caller_function, caller_frame);
            try deleteValuePropertyOrThrow(ctx, output, global, object, upper_key.atom);
        } else if (lower_exists and !upper_exists) {
            try deleteValuePropertyOrThrow(ctx, output, global, object, lower_key.atom);
            try setValuePropertyOrThrow(ctx, output, global, receiver_object_value, upper_key.atom, lower_value, caller_function, caller_frame);
        }
    }

    return receiver_object_value;
}

/// Move one index in place: if `from_index` is present, get it and set
/// `to_index`; otherwise delete `to_index`. Shared by shift/unshift/splice/copyWithin.
pub noinline fn arrayMoveIndex(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    from_index: usize,
    to_index: usize,
) !void {
    const from_key = try propertyAtomFromLengthIndex(ctx.runtime, from_index);
    defer from_key.deinit(ctx.runtime);
    const to_key = try propertyAtomFromLengthIndex(ctx.runtime, to_index);
    defer to_key.deinit(ctx.runtime);
    if (try hasValueProperty(ctx, output, global, object, from_key.atom, null, null)) {
        const item = try getValueProperty(ctx, output, global, receiver, from_key.atom, null, null);
        try setValuePropertyOrThrow(ctx, output, global, receiver, to_key.atom, item, null, null);
    } else {
        try deleteValuePropertyOrThrow(ctx, output, global, object, to_key.atom);
    }
}

/// CreateDataPropertyOrThrow `source[from_index]` onto `dest[to_index]` if
/// present; missing source indexes are skipped so holes stay holes. Shared
/// by slice, splice, and concat.
pub noinline fn arrayCopyPresentIndex(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    source_receiver: core.JSValue,
    source: *core.Object,
    from_index: usize,
    dest: *core.Object,
    to_index: usize,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const from_key = try propertyAtomFromLengthIndex(ctx.runtime, from_index);
    defer from_key.deinit(ctx.runtime);
    if (!try hasValueProperty(ctx, output, global, source, from_key.atom, null, null)) {
        return;
    }
    const item = try getValueProperty(ctx, output, global, source_receiver, from_key.atom, caller_function, caller_frame);
    const to_key = try propertyAtomFromLengthIndex(ctx.runtime, to_index);
    defer to_key.deinit(ctx.runtime);
    try createDataPropertyOrThrow(ctx, output, global, dest, to_key.atom, item, caller_function, caller_frame);
}

pub fn arrayRelativeIndex(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, arg_index: usize, length: usize, default_value: usize) !usize {
    if (args.len <= arg_index) return default_value;
    return arrayRelativeIndexFromNumber(length, try toNumberForArrayMethod(ctx, output, global, args[arg_index]));
}

pub fn arrayRelativeIndexFromNumber(length: usize, n: f64) usize {
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

/// ToNumber (via ToPrimitive) of an index argument; callers truncate.
pub fn toNumberForArrayMethod(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue) !f64 {
    const primitive = try toPrimitiveForNumber(ctx, output, global, value);
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    return value_ops.numberValue(number_value) orelse std.math.nan(f64);
}

pub noinline fn arraySpeciesCreate(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    original: core.JSValue,
    length: usize,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const object = objectFromValue(original) orelse {
        if (length > core.array.max_array_length) return error.InvalidArrayLength;
        const out = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
        out.setArrayLength(@intCast(length));
        return out.value();
    };
    if (try defaultArraySpeciesCreate(ctx.runtime, global, object, length)) |value| return value;
    var constructor_value = if (try core.array.isArrayValue(object.value()))
        try getValueProperty(ctx, output, global, original, core.atom.ids.constructor, caller_function, caller_frame)
    else
        core.JSValue.undefinedValue();
    if (constructor_value.is(.undefined_value)) {
        if (length > core.array.max_array_length) return error.InvalidArrayLength;
        const out = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
        out.setArrayLength(@intCast(length));
        return out.value();
    }
    if (!constructor_value.is(.object)) return error.NotAConstructor;
    if (try arraySpeciesConstructorIsForeignIntrinsicArray(ctx, constructor_value)) {
        if (length > core.array.max_array_length) return error.InvalidArrayLength;
        const out = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
        out.setArrayLength(@intCast(length));
        return out.value();
    }
    const species_atom = comptime core.atom.predefinedId("Symbol.species", .symbol).?;
    var species_value = try getValueProperty(ctx, output, global, constructor_value, species_atom, caller_function, caller_frame);
    if (species_value.is(.null_value)) {
        species_value = core.JSValue.undefinedValue();
    }
    // QuickJS performs this second, active-realm comparison after the
    // observable @@species Get. It is distinct from the foreign-intrinsic
    // suppression above: an ordinary constructor, bound function, or Proxy
    // must reach the Get even when FunctionRealm recursively resolves to this
    // realm or another realm's %Array%.
    if (arraySpeciesConstructorIsRealmIntrinsicArray(ctx, species_value)) {
        species_value = core.JSValue.undefinedValue();
    }
    if (species_value.is(.undefined_value)) {
        if (length > core.array.max_array_length) return error.InvalidArrayLength;
        const out = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
        out.setArrayLength(@intCast(length));
        return out.value();
    }
    const length_value = lengthIndexValue(length);
    return constructValueOrBytecode(ctx, output, global, species_value, &.{length_value}, caller_function, caller_frame);
}

// Mirrors qjs JS_ArraySpeciesGetCtor returning JS_UNDEFINED (the default-species
// case at quickjs.c): `original` is a plain non-proxy Array whose
// constructor/prototype/Symbol.species chain is the unmodified builtin. When this
// holds, ArraySpeciesCreate is allowed to produce a fresh plain Array. Returns the
// realm's Array.prototype so callers can build that array.
pub fn arrayHasDefaultSpecies(rt: *core.JSRuntime, global: *core.Object, original: *core.Object) !?*core.Object {
    if (!original.isArray() or original.proxyTarget() != null) return null;
    if (try original.getOwnProperty(rt, core.atom.ids.constructor) != null) return null;

    const array_proto = arrayPrototypeFromGlobal(rt, global) orelse return null;
    if (original.getPrototype() != array_proto) return null;
    const array_ctor = arrayConstructorFromGlobal(global) orelse return null;
    if (array_ctor.nativeConstructorKind() != .array) return null;

    const proto_constructor = (try array_proto.getOwnProperty(rt, core.atom.ids.constructor)) orelse return null;
    defer proto_constructor.destroy(rt);
    if (proto_constructor.kind != .data or !proto_constructor.value_present or
        !sameObjectIdentity(proto_constructor.value, array_ctor.value()))
    {
        return null;
    }

    const species_atom = comptime core.atom.predefinedId("Symbol.species", .symbol).?;
    const species = (try array_ctor.getOwnProperty(rt, species_atom)) orelse return null;
    defer species.destroy(rt);
    if (species.kind != .accessor or !species.getter_present or !species.setter_present or
        !species.setter.is(.undefined_value))
    {
        return null;
    }
    const getter = objectFromValue(species.getter) orelse return null;
    if (getter.arrayBuiltinMarker() != .species_getter) return null;

    return array_proto;
}

pub fn defaultArraySpeciesCreate(rt: *core.JSRuntime, global: *core.Object, original: *core.Object, length: usize) !?core.JSValue {
    const array_proto = (try arrayHasDefaultSpecies(rt, global, original)) orelse return null;

    if (length > core.array.max_array_length) return error.InvalidArrayLength;

    const out = try core.Object.createArray(rt, array_proto);
    out.setArrayLength(@intCast(length));
    return out.value();
}

pub fn arrayConstructorFromGlobal(global: *core.Object) ?*core.Object {
    const value = global.getOwnDataPropertyValue(core.atom.predefinedId("Array", .string).?) orelse return null;
    return objectFromValue(value);
}

/// Implements the first ArraySpeciesCreate legacy-web-compatibility arm.
///
/// `NativeConstructorKind.array` is the engine's non-observable identity
/// brand for the exact intrinsic constructor installed in a realm. Unlike a
/// name check it is not inherited by a bound function or Proxy and cannot be
/// forged by renaming an ordinary constructor. The C_FUNCTION's RealmRef then
/// proves which FunctionRealm owns that exact intrinsic.
fn arraySpeciesConstructorIsForeignIntrinsicArray(ctx: *core.JSContext, constructor_value: core.JSValue) !bool {
    const constructor_object = objectFromValue(constructor_value) orelse return false;
    if (constructor_object.nativeConstructorKind() != .array) return false;
    const constructor_realm = try call_runtime.functionRealmContext(ctx, constructor_value);
    return constructor_realm != ctx and
        arraySpeciesConstructorIsRealmIntrinsicArray(constructor_realm, constructor_value);
}

fn arraySpeciesConstructorIsRealmIntrinsicArray(realm: *core.JSContext, constructor_value: core.JSValue) bool {
    const constructor_object = objectFromValue(constructor_value) orelse return false;
    if (constructor_object.nativeConstructorKind() != .array) return false;
    return (constructor_object.nativeFunctionRealm() orelse return false) == realm;
}

pub noinline fn arrayFromCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    if (!isArrayStaticRecord(function_object, @intFromEnum(method_ids.array.StaticMethod.from))) return null;
    const map_fn: ?core.JSValue = if (args.len >= 2 and !args[1].is(.undefined_value)) blk: {
        if (!isCallableValue(args[1])) return try exception_ops.throwTypeErrorMessage(ctx, global, "not a function");
        break :blk args[1];
    } else null;
    const this_arg = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();

    const source = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (source.is(.null_value) or source.is(.undefined_value)) return try exception_ops.throwTypeErrorMessage(ctx, global, "cannot convert to object");
    const iterator_method = try getIteratorMethod(ctx, output, global, source);
    if (!iterator_method.is(.undefined_value) and !iterator_method.is(.null_value)) {
        if (!isCallableValue(iterator_method)) return try exception_ops.throwTypeErrorMessage(ctx, global, "not a function");
        return try arrayFromIterable(ctx, output, global, constructor_value, source, iterator_method, map_fn, this_arg, caller_function, caller_frame);
    }
    return try arrayFromArrayLike(ctx, output, global, constructor_value, source, map_fn, this_arg, caller_function, caller_frame);
}

/// `Array.from` steps 7-15 over an array-like `source`. Outlined like
/// `arrayFromIterable` so a mapper callback runs under only its own path's
/// frame.
noinline fn arrayFromArrayLike(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    source: core.JSValue,
    map_fn: ?core.JSValue,
    this_arg: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const length_value = try getValueProperty(ctx, output, global, source, core.atom.ids.length, caller_function, caller_frame);
    const length = try toLengthIndex(ctx, output, global, length_value);
    const length_number = core.JSValue.number(@floatFromInt(length));

    // Step 12: A = IsConstructor(C) ? Construct(C, «𝔽(len)») : ArrayCreate(len).
    const out_value = if (call_runtime.isConstructorLike(constructor_value))
        try constructValueOrBytecode(ctx, output, global, constructor_value, &.{length_number}, caller_function, caller_frame)
    else blk: {
        if (length > std.math.maxInt(u32)) {
            return try exception_ops.throwRangeErrorMessage(ctx, global, "invalid array length");
        }
        const out = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
        out.setArrayLength(@intCast(length));
        break :blk out.value();
    };
    const out = objectFromValue(out_value) orelse return error.NotAnObject;
    var mapper_call: ?CallSite = if (map_fn) |mapper|
        CallSite.initInternal(ctx, output, global, this_arg, mapper, caller_function, caller_frame)
    else
        null;
    if (mapper_call) |*site| site.activateRoots();
    defer if (mapper_call) |*site| site.deinit();

    for (0..length) |index| {
        try exception_ops.pollNativeLoop(ctx, global);
        const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
        defer key.deinit(ctx.runtime);
        var item = try getValueProperty(ctx, output, global, source, key.atom, caller_function, caller_frame);
        if (mapper_call) |*call_site| {
            item = try call_site.call2(item, core.JSValue.number(@floatFromInt(index)));
        }
        try createDataPropertyOrThrow(ctx, output, global, out, key.atom, item, caller_function, caller_frame);
    }
    try setValuePropertyOrThrow(ctx, output, global, out.value(), core.atom.ids.length, length_number, caller_function, caller_frame);
    return out_value;
}

// ---------------------------------------------------------------------------
// Array.fromAsync — proposal-array-from-async (ES2026, sec-array.fromasync).
// qjs 04be246 has no fromAsync, so unlike its neighbors this block mirrors the
// spec algorithm directly. The async closure (spec step 3) is a state machine
// driven by promise reactions: every spec `Await(v)` becomes
// PromiseResolve(%Promise%, v) + an internal PerformPromiseThen attach with a
// pair of `.array_from_async_continuation`-tagged native callbacks (the same
// await-shaped reaction model as the AsyncDisposableStack machinery in
// promise_ops.zig; nothing here drains the job queue synchronously). Closure
// state lives on an internal plain object that never escapes to user code.
// ---------------------------------------------------------------------------

/// Await resume points of the fromAsync closure ("phase" state slot).
const from_async_phase_iter_next: i32 = 1; // iterator loop: Await(nextResult)
const from_async_phase_iter_mapped: i32 = 2; // iterator loop: Await(mappedValue)
const from_async_phase_array_value: i32 = 3; // array-like loop: Await(kValue)
const from_async_phase_array_mapped: i32 = 4; // array-like loop: Await(mappedValue)
const from_async_phase_closing: i32 = 5; // AsyncIteratorClose: Await(return() result)

fn fromAsyncStateSet(rt: *core.JSRuntime, state: *core.Object, key: core.Atom, value: core.JSValue) !void {
    try state.defineOwnProperty(rt, key, core.Descriptor.data(value, .all));
}

/// Borrowed read of a state slot; the value stays owned by the state object
/// (under tracing GC there is no retain here and no free at the call site).
fn fromAsyncStateGet(state: *core.Object, key: core.Atom) core.JSValue {
    if (state.getOwnDataPropertyValue(key)) |value| return value;
    std.debug.assert(!state.hasOwnProperty(key));
    return core.JSValue.undefinedValue();
}

fn fromAsyncStateNumber(state: *core.Object, key: core.Atom) f64 {
    const value = fromAsyncStateGet(state, key);
    return value_ops.numberValue(value) orelse 0;
}

/// Spec GetMethod(V, P): undefined/null -> null; non-callable -> TypeError.
fn fromAsyncGetMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    key: core.Atom,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const method = try getValueProperty(ctx, output, global, receiver, key, caller_function, caller_frame);
    if (method.is(.undefined_value) or method.is(.null_value)) {
        return null;
    }
    if (!isCallableValue(method)) {
        _ = try throwTypeErrorMessage(ctx, global, "not a function");
    }
    return method;
}

/// `Array.fromAsync(asyncItems [, mapfn [, thisArg]])` entry. Gated on the
/// `from_async` record id, like `arrayFromCall`. Returns the result promise; only
/// NewPromiseCapability failures surface synchronously — every abrupt
/// completion of the closure body rejects the promise (spec step 3/steps e-k
/// run inside the async closure).
pub noinline fn arrayFromAsyncCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    if (!isArrayStaticRecord(function_object, @intFromEnum(method_ids.array.StaticMethod.from_async))) return null;
    const capability = try promise_ops.defaultPromiseCapability(ctx, output, global, caller_function, caller_frame);
    fromAsyncStart(ctx, output, global, constructor_value, args, capability.resolve, capability.reject, caller_function, caller_frame) catch |err| {
        try promise_ops.promiseRejectCapabilityForError(ctx, output, global, capability.reject, err, caller_function, caller_frame);
    };
    return capability.promise;
}

/// Synchronous prologue of the fromAsync closure: mapping check, iterator
/// acquisition (@@asyncIterator, else @@iterator wrapped
/// AsyncFromSyncIterator-style, else array-like), target construction, and the
/// first step of whichever loop applies. Runs inside the current job; the
/// caller routes any error into the result promise's reject.
fn fromAsyncStart(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    args: []const core.JSValue,
    resolve: core.JSValue,
    reject: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const rt = ctx.runtime;
    const items = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const mapfn = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const this_arg = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();

    // 3.a-c: mapping check happens before any access to asyncItems.
    if (!mapfn.is(.undefined_value) and !isCallableValue(mapfn)) {
        _ = try throwTypeErrorMessage(ctx, global, "not a function");
    }

    const state = try core.Object.create(rt, core.class.ids.object, null);
    var state_val = state.value();
    var root_values = [_]*core.JSValue{&state_val};
    var root_frame = core.runtime.ValueRootFrame{
        .values = &root_values,
    };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    try fromAsyncStateSet(rt, state, core.atom.ids.resolve, resolve);
    try fromAsyncStateSet(rt, state, core.atom.ids.reject, reject);
    try fromAsyncStateSet(rt, state, core.atom.ids.mapfn, mapfn);
    try fromAsyncStateSet(rt, state, core.atom.ids.this_arg, this_arg);
    try fromAsyncStateSet(rt, state, core.atom.ids.k, core.JSValue.number(0));

    // 3.e-f: usingAsyncIterator = GetMethod(asyncItems, @@asyncIterator);
    // fallback usingSyncIterator = GetMethod(asyncItems, @@iterator). Both use
    // the intrinsic well-known symbols (never a Symbol.* global read), and
    // GetMethod on null/undefined asyncItems throws here (GetV -> ToObject).
    const async_iterator_atom = comptime core.atom.predefinedId("Symbol.asyncIterator", .symbol).?;
    const sync_iterator_atom = comptime core.atom.predefinedId("Symbol.iterator", .symbol).?;
    var used_async = true;
    var used_method = try fromAsyncGetMethod(ctx, output, global, items, async_iterator_atom, caller_function, caller_frame);
    if (used_method == null) {
        used_async = false;
        used_method = try fromAsyncGetMethod(ctx, output, global, items, sync_iterator_atom, caller_function, caller_frame);
    }

    if (used_method) |method| {
        // GetIterator: iterator = Call(method, asyncItems); must be an object;
        // then nextMethod = Get(iterator, "next"). The sync branch wraps the
        // sync iterator CreateAsyncFromSyncIterator-style so each value is
        // awaited/unwrapped by the shared machinery.
        const iterator = try callValueOrBytecodeRoot(ctx, output, global, items, method, &.{}, caller_function, caller_frame);
        {
            if (!iterator.is(.object)) {
                _ = try throwTypeErrorMessage(ctx, global, "not an object");
            }
            if (used_async) {
                try fromAsyncStateSet(rt, state, core.atom.ids.iter, iterator);
            } else {
                const wrapper = try iterator_ops.createAsyncFromSyncIterator(ctx, output, global, iterator, caller_function, caller_frame, object_ops.getValueProperty);
                try fromAsyncStateSet(rt, state, core.atom.ids.iter, wrapper);
            }
        }
        {
            const stored_iterator = fromAsyncStateGet(state, core.atom.ids.iter);
            const next_key = core.atom.ids.next;
            const next_method = try getValueProperty(ctx, output, global, stored_iterator, next_key, caller_function, caller_frame);
            try fromAsyncStateSet(rt, state, core.atom.ids.next, next_method);
        }

        // 3.j.i: A = IsConstructor(C) ? Construct(C) : ArrayCreate(0).
        const target = if (call_runtime.isConstructorLike(constructor_value))
            try constructValueOrBytecode(ctx, output, global, constructor_value, &.{}, caller_function, caller_frame)
        else blk: {
            const out = try core.Object.createArray(rt, arrayPrototypeFromGlobal(rt, global));
            break :blk out.value();
        };
        {
            try fromAsyncStateSet(rt, state, core.atom.ids.target, target);
        }
        try fromAsyncIterStep(ctx, output, global, state, caller_function, caller_frame);
        return;
    }

    // 3.k: array-like fallback. len = LengthOfArrayLike(arrayLike); the
    // ToObject boxing of a primitive asyncItems is unobservable, so element
    // reads go through getValueProperty on the raw value.
    const len = blk: {
        const len_value = try getValueProperty(ctx, output, global, items, core.atom.ids.length, caller_function, caller_frame);
        break :blk try value_ops.toLengthNumber(ctx, output, global, len_value);
    };
    try fromAsyncStateSet(rt, state, core.atom.ids.items, items);
    try fromAsyncStateSet(rt, state, core.atom.ids.len, core.JSValue.number(len));

    // 3.k.iv-v: A = IsConstructor(C) ? Construct(C, «𝔽(len)») : ArrayCreate(len).
    const target = if (call_runtime.isConstructorLike(constructor_value))
        try constructValueOrBytecode(ctx, output, global, constructor_value, &.{core.JSValue.number(len)}, caller_function, caller_frame)
    else blk: {
        // ArrayCreate step 1: len > 2^32-1 -> RangeError.
        if (len > 4294967295.0) {
            _ = try exception_ops.throwRangeErrorMessage(ctx, global, "invalid array length");
        }
        const out = try core.Object.createArray(rt, arrayPrototypeFromGlobal(rt, global));
        out.setArrayLength(@intFromFloat(len));
        break :blk out.value();
    };
    {
        try fromAsyncStateSet(rt, state, core.atom.ids.target, target);
    }
    try fromAsyncArrayLikeStep(ctx, output, global, state, caller_function, caller_frame);
}

/// One spec Await: PromiseResolve(%Promise%, value) + internal
/// PerformPromiseThen attach (never a user-visible `.then` read), with the
/// resume point recorded in the state's "phase" slot.
fn fromAsyncAwait(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    state: *core.Object,
    value: core.JSValue,
    phase: i32,
) !void {
    const rt = ctx.runtime;
    try fromAsyncStateSet(rt, state, core.atom.ids.phase, core.JSValue.int32(phase));
    const promise_constructor = try promise_ops.promiseDefaultConstructor(ctx, global);
    const awaited = try promise_ops.promiseResolveStaticCall(ctx, output, global, promise_constructor, &.{value}, null, null);
    const on_fulfilled = try fromAsyncContinuation(rt, global, state, false);
    const on_rejected = try fromAsyncContinuation(rt, global, state, true);
    try promise_ops.performPromiseThen(ctx, awaited, on_fulfilled, on_rejected, core.JSValue.undefinedValue(), core.JSValue.undefinedValue());
}

fn fromAsyncContinuation(rt: *core.JSRuntime, global: *core.Object, state: *core.Object, rejected: bool) !core.JSValue {
    const callback = try builtin_glue.createDataFunction(rt, global, "", 1);
    const callback_object = objectFromValue(callback) orelse return error.TypeError;
    try callback_object.setInternalCallableTag(rt, .array_from_async_continuation);
    try fromAsyncStateSet(rt, callback_object, core.atom.ids.state, state.value());
    try fromAsyncStateSet(rt, callback_object, core.atom.ids.rejected, core.JSValue.boolean(rejected));
    return callback;
}

/// Reaction entry for `.array_from_async_continuation` callbacks (routed by
/// `call_runtime.callInternalCallableByTag`). Any error escaping the resume
/// body rejects the result promise; the settled promise's own
/// already-resolved latch makes late double-settles no-ops.
pub fn arrayFromAsyncContinuationCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const rt = ctx.runtime;
    var state_val = fromAsyncStateGet(function_object, core.atom.ids.state);
    var root_values = [_]*core.JSValue{&state_val};
    var root_frame = core.runtime.ValueRootFrame{
        .values = &root_values,
    };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);
    const state = objectFromValue(state_val) orelse return error.TypeError;
    const rejected = blk: {
        const rejected_val = fromAsyncStateGet(function_object, core.atom.ids.rejected);
        break :blk valueTruthy(rejected_val);
    };
    const settled = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    fromAsyncResume(ctx, output, global, state, rejected, settled, caller_function, caller_frame) catch |err| {
        const reject = fromAsyncStateGet(state, core.atom.ids.reject);
        try promise_ops.promiseRejectCapabilityForError(ctx, output, global, reject, err, caller_function, caller_frame);
    };
    return core.JSValue.undefinedValue();
}

fn fromAsyncResume(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    state: *core.Object,
    rejected: bool,
    settled: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const rt = ctx.runtime;
    const phase = blk: {
        const phase_val = fromAsyncStateGet(state, core.atom.ids.phase);
        break :blk phase_val.as(.int) orelse return error.TypeError;
    };
    switch (phase) {
        from_async_phase_iter_next => {
            // Await(nextResult) settled. A rejection propagates out of the
            // closure without closing the iterator (spec uses `?`, not
            // IfAbruptCloseAsyncIterator, on this Await).
            if (rejected) return fromAsyncReject(ctx, output, global, state, settled, caller_function, caller_frame);
            try fromAsyncOnNextResult(ctx, output, global, state, settled, caller_function, caller_frame);
        },
        from_async_phase_iter_mapped => {
            // Await(mappedValue) settled: IfAbruptCloseAsyncIterator on
            // rejection, then CreateDataPropertyOrThrow (abrupt -> close).
            if (rejected) return fromAsyncCloseWithValue(ctx, output, global, state, settled, caller_function, caller_frame);
            fromAsyncDefineElement(ctx, output, global, state, settled, caller_function, caller_frame) catch |err| {
                return fromAsyncCloseWithError(ctx, output, global, state, err, caller_function, caller_frame);
            };
            try fromAsyncAdvanceIterIndex(ctx, output, global, state, caller_function, caller_frame);
        },
        from_async_phase_array_value => {
            // Await(kValue) settled. The array-like loop never closes an
            // iterator: every abrupt completion rejects directly.
            if (rejected) return fromAsyncReject(ctx, output, global, state, settled, caller_function, caller_frame);
            const mapfn = fromAsyncStateGet(state, core.atom.ids.mapfn);
            if (!mapfn.is(.undefined_value)) {
                const this_arg = fromAsyncStateGet(state, core.atom.ids.this_arg);
                const k = fromAsyncStateNumber(state, core.atom.ids.k);
                const mapped = try callValueOrBytecodeRoot(ctx, output, global, this_arg, mapfn, &.{ settled, core.JSValue.number(k) }, caller_function, caller_frame);
                try fromAsyncAwait(ctx, output, global, state, mapped, from_async_phase_array_mapped);
                return;
            }
            try fromAsyncDefineElement(ctx, output, global, state, settled, caller_function, caller_frame);
            try fromAsyncStateSet(rt, state, core.atom.ids.k, core.JSValue.number(fromAsyncStateNumber(state, core.atom.ids.k) + 1));
            try fromAsyncArrayLikeStep(ctx, output, global, state, caller_function, caller_frame);
        },
        from_async_phase_array_mapped => {
            if (rejected) return fromAsyncReject(ctx, output, global, state, settled, caller_function, caller_frame);
            try fromAsyncDefineElement(ctx, output, global, state, settled, caller_function, caller_frame);
            try fromAsyncStateSet(rt, state, core.atom.ids.k, core.JSValue.number(fromAsyncStateNumber(state, core.atom.ids.k) + 1));
            try fromAsyncArrayLikeStep(ctx, output, global, state, caller_function, caller_frame);
        },
        from_async_phase_closing => {
            // AsyncIteratorClose steps 4-7 with a throw completion: however
            // the awaited return() result settled, the original error wins.
            const pending = fromAsyncStateGet(state, core.atom.ids.pending);
            try fromAsyncReject(ctx, output, global, state, pending, caller_function, caller_frame);
        },
        else => return error.TypeError,
    }
}

/// Iterator loop body after Await(nextResult) fulfilled (spec 3.j.ii.iv-x):
/// object check, done/value reads, then either finish, map+await, or
/// define+next.
fn fromAsyncOnNextResult(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    state: *core.Object,
    next_result: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    if (!next_result.is(.object)) {
        _ = try throwTypeErrorMessage(ctx, global, "iterator must return an object");
    }
    const done = blk: {
        const done_key = comptime core.atom.predefinedId("done", .string).?;
        const done_value = try getValueProperty(ctx, output, global, next_result, done_key, caller_function, caller_frame);
        break :blk valueTruthy(done_value);
    };
    if (done) {
        try fromAsyncFinish(ctx, output, global, state, fromAsyncStateNumber(state, core.atom.ids.k), caller_function, caller_frame);
        return;
    }
    const value_key = comptime core.atom.predefinedId("value", .string).?;
    const next_value = try getValueProperty(ctx, output, global, next_result, value_key, caller_function, caller_frame);

    const mapfn = fromAsyncStateGet(state, core.atom.ids.mapfn);
    if (!mapfn.is(.undefined_value)) {
        // 3.j.ii.vi: mappedValue = Call(mapfn, thisArg, «nextValue, 𝔽(k)»);
        // IfAbruptCloseAsyncIterator; then Await (phase 2).
        const this_arg = fromAsyncStateGet(state, core.atom.ids.this_arg);
        const k = fromAsyncStateNumber(state, core.atom.ids.k);
        const mapped = callValueOrBytecodeRoot(ctx, output, global, this_arg, mapfn, &.{ next_value, core.JSValue.number(k) }, caller_function, caller_frame) catch |err| {
            return fromAsyncCloseWithError(ctx, output, global, state, err, caller_function, caller_frame);
        };
        try fromAsyncAwait(ctx, output, global, state, mapped, from_async_phase_iter_mapped);
        return;
    }
    // 3.j.ii.viii-ix: CreateDataPropertyOrThrow(A, Pk, nextValue); abrupt ->
    // AsyncIteratorClose(error).
    fromAsyncDefineElement(ctx, output, global, state, next_value, caller_function, caller_frame) catch |err| {
        return fromAsyncCloseWithError(ctx, output, global, state, err, caller_function, caller_frame);
    };
    try fromAsyncAdvanceIterIndex(ctx, output, global, state, caller_function, caller_frame);
}

/// k += 1 plus the spec's 2^53-1 guard (3.j.ii.2: TypeError ->
/// AsyncIteratorClose), then the next iteration's next() call + Await.
fn fromAsyncAdvanceIterIndex(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    state: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const rt = ctx.runtime;
    const k = fromAsyncStateNumber(state, core.atom.ids.k) + 1;
    if (k >= 9007199254740991.0) {
        _ = throwTypeErrorMessage(ctx, global, "too many elements") catch |err| {
            return fromAsyncCloseWithError(ctx, output, global, state, err, caller_function, caller_frame);
        };
        return;
    }
    try fromAsyncStateSet(rt, state, core.atom.ids.k, core.JSValue.number(k));
    try fromAsyncIterStep(ctx, output, global, state, caller_function, caller_frame);
}

/// Iterator loop head (spec 3.j.ii.ii-iii): nextResult = ? Call(next,
/// iterator) — abrupt rejects WITHOUT closing — then Await(nextResult).
fn fromAsyncIterStep(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    state: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const iterator = fromAsyncStateGet(state, core.atom.ids.iter);
    const next_method = fromAsyncStateGet(state, core.atom.ids.next);
    const next_result = try callValueOrBytecodeRoot(ctx, output, global, iterator, next_method, &.{}, caller_function, caller_frame);
    try fromAsyncAwait(ctx, output, global, state, next_result, from_async_phase_iter_next);
}

/// Array-like loop head (spec 3.k.vii): finished -> Set length + resolve;
/// else kValue = ? Get(arrayLike, Pk) then Await(kValue).
fn fromAsyncArrayLikeStep(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    state: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const rt = ctx.runtime;
    const k = fromAsyncStateNumber(state, core.atom.ids.k);
    const len = fromAsyncStateNumber(state, core.atom.ids.len);
    if (k >= len) {
        try fromAsyncFinish(ctx, output, global, state, len, caller_function, caller_frame);
        return;
    }
    const items = fromAsyncStateGet(state, core.atom.ids.items);
    const index_atom = try propertyAtomFromLengthIndex(rt, @intFromFloat(k));
    defer index_atom.deinit(rt);
    const k_value = try getValueProperty(ctx, output, global, items, index_atom.atom, caller_function, caller_frame);
    try fromAsyncAwait(ctx, output, global, state, k_value, from_async_phase_array_value);
}

/// CreateDataPropertyOrThrow(A, ToString(𝔽(k)), value).
fn fromAsyncDefineElement(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    state: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const rt = ctx.runtime;
    const target = fromAsyncStateGet(state, core.atom.ids.target);
    const target_object = objectFromValue(target) orelse return error.TypeError;
    const index_atom = try propertyAtomFromLengthIndex(rt, @intFromFloat(fromAsyncStateNumber(state, core.atom.ids.k)));
    defer index_atom.deinit(rt);
    try createDataPropertyOrThrow(ctx, output, global, target_object, index_atom.atom, value, caller_function, caller_frame);
}

/// Loop epilogue: Set(A, "length", 𝔽(length), true) — throw discipline like
/// the array mutators — then resolve the result promise with A.
fn fromAsyncFinish(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    state: *core.Object,
    length: f64,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const target = fromAsyncStateGet(state, core.atom.ids.target);
    try setValuePropertyOrThrow(ctx, output, global, target, core.atom.ids.length, core.JSValue.number(length), caller_function, caller_frame);
    const resolve = fromAsyncStateGet(state, core.atom.ids.resolve);
    try promise_ops.promiseResolveCapability(ctx, output, global, resolve, target, caller_function, caller_frame);
}

fn fromAsyncReject(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    state: *core.Object,
    reason: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const reject = fromAsyncStateGet(state, core.atom.ids.reject);
    try promise_ops.promiseRejectCapability(ctx, output, global, reject, reason, caller_function, caller_frame);
}

/// Materialize the pending Zig error (or its thrown JS value) and run
/// AsyncIteratorClose with it as a throw completion.
fn fromAsyncCloseWithError(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    state: *core.Object,
    err: core.errors.HostError,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const reason = try exception_ops.promiseErrorValue(ctx, global, err);
    try fromAsyncCloseWithValue(ctx, output, global, state, reason, caller_function, caller_frame);
}

/// AsyncIteratorClose(iteratorRecord, ThrowCompletion(reason)): every abrupt
/// completion inside the close is superseded by the original error, and a
/// successfully awaited return() result still rejects with the original error
/// (phase 5).
fn fromAsyncCloseWithValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    state: *core.Object,
    reason: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const rt = ctx.runtime;
    const iterator = fromAsyncStateGet(state, core.atom.ids.iter);
    const return_key = core.atom.ids.return_;
    const return_method = getValueProperty(ctx, output, global, iterator, return_key, caller_function, caller_frame) catch {
        if (ctx.hasException()) ctx.clearException();
        return fromAsyncReject(ctx, output, global, state, reason, caller_function, caller_frame);
    };
    if (return_method.is(.undefined_value) or return_method.is(.null_value) or !isCallableValue(return_method)) {
        return fromAsyncReject(ctx, output, global, state, reason, caller_function, caller_frame);
    }
    const inner = callValueOrBytecodeRoot(ctx, output, global, iterator, return_method, &.{}, caller_function, caller_frame) catch {
        if (ctx.hasException()) ctx.clearException();
        return fromAsyncReject(ctx, output, global, state, reason, caller_function, caller_frame);
    };
    try fromAsyncStateSet(rt, state, core.atom.ids.pending, reason);
    try fromAsyncAwait(ctx, output, global, state, inner, from_async_phase_closing);
}

pub noinline fn typedArrayFromStaticCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (!call_runtime.isConstructorLike(constructor_value)) return exception_ops.throwTypeErrorMessage(ctx, global, "not a constructor");
    const map_fn: ?core.JSValue = if (args.len >= 2 and !args[1].is(.undefined_value)) blk: {
        if (!isCallableValue(args[1])) return error.NotAFunction;
        break :blk args[1];
    } else null;
    const this_arg = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
    const source = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (source.is(.null_value) or source.is(.undefined_value)) return error.NullishToObject;

    const iterator_method = try getIteratorMethod(ctx, output, global, source);
    if (!iterator_method.is(.undefined_value) and !iterator_method.is(.null_value)) {
        if (!isCallableValue(iterator_method)) return error.NotAFunction;
        const iterator = try callValueOrBytecodeRoot(ctx, output, global, source, iterator_method, &.{}, caller_function, caller_frame);
        return try typedArrayFromIteratorValue(ctx, output, global, constructor_value, iterator, map_fn, this_arg, caller_function, caller_frame);
    }

    return try typedArrayFromArrayLikeSource(ctx, output, global, constructor_value, source, null, map_fn, this_arg, caller_function, caller_frame);
}

pub fn typedArrayFromIteratorValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    iterator_value: core.JSValue,
    map_fn: ?core.JSValue,
    this_arg: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const values_value = try collectIteratorValues(ctx, output, global, iterator_value, caller_function, caller_frame);
    const values = objectFromValue(values_value) orelse return error.TypeError;
    return try typedArrayFromArrayLikeSource(
        ctx,
        output,
        global,
        constructor_value,
        values_value,
        @intCast(values.arrayLength()),
        map_fn,
        this_arg,
        caller_function,
        caller_frame,
    );
}

/// %TypedArray%.from array-like arm (§23.2.2.1 steps 7-13): Get length,
/// TypedArrayCreate, then Get / map / Set each index.
pub noinline fn typedArrayFromArrayLikeSource(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    source: core.JSValue,
    fixed_length: ?usize,
    map_fn: ?core.JSValue,
    this_arg: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const length = fixed_length orelse blk: {
        const length_value = try getValueProperty(ctx, output, global, source, core.atom.ids.length, caller_function, caller_frame);
        break :blk try toLengthIndex(ctx, output, global, length_value);
    };
    if (length > std.math.maxInt(u32)) return error.InvalidArrayLength;

    const out_value = try typedArrayCreateWithLength(ctx, output, global, constructor_value, length, caller_function, caller_frame);
    const out = objectFromValue(out_value) orelse return error.NotAnObject;
    var mapper_call: ?CallSite = if (map_fn) |mapper|
        CallSite.initInternal(ctx, output, global, this_arg, mapper, caller_function, caller_frame)
    else
        null;
    if (mapper_call) |*site| site.activateRoots();
    defer if (mapper_call) |*site| site.deinit();

    for (0..length) |index| {
        const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
        defer key.deinit(ctx.runtime);
        var item = try getValueProperty(ctx, output, global, source, key.atom, caller_function, caller_frame);
        if (mapper_call) |*call_site| item = try call_site.call2(item, lengthIndexValue(index));
        try typedArraySetElementValue(ctx, output, global, out, index, item);
    }
    return out_value;
}

/// Array.from steps 5.a-e: construct the result, then open the iterator
/// (GetIteratorFromMethod). Failures inside IteratorStepValue propagate as is;
/// mapping and element-definition failures close the iterator first.
noinline fn arrayFromIterable(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    items: core.JSValue,
    iterator_method: core.JSValue,
    map_fn: ?core.JSValue,
    this_arg: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    // [0] result, [1] iterator, [2] next, [3] method, [4] items
    var values = [_]core.JSValue{ core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), iterator_method, items };
    var slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);

    values[0] = if (call_runtime.isConstructorLike(constructor_value))
        try constructValueOrBytecode(ctx, output, global, constructor_value, &.{}, caller_function, caller_frame)
    else
        (try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global))).value();
    const out = objectFromValue(values[0]) orelse return error.TypeError;
    const iterator = try callValueOrBytecodeRoot(ctx, output, global, values[4], values[3], &.{}, caller_function, caller_frame);
    const record = try iterator_ops.getIteratorDirect(ctx, output, global, iterator, caller_function, caller_frame);
    values[1] = record.iterator;
    values[2] = record.next;

    var mapper_call: ?CallSite = if (map_fn) |mapper|
        CallSite.initInternal(ctx, output, global, this_arg, mapper, caller_function, caller_frame)
    else
        null;
    if (mapper_call) |*site| site.activateRoots();
    defer if (mapper_call) |*site| site.deinit();

    var index: usize = 0;
    while (true) : (index += 1) {
        const step = try iterator_ops.iteratorStepValue(ctx, output, global, .{ .iterator = values[1], .next = values[2] });
        if (step.done) break;
        var item = step.value;
        if (mapper_call) |*call_site| {
            item = call_site.call2(item, value_ops.numberToValue(@floatFromInt(index))) catch |err| {
                try iterator_ops.iteratorCloseForThrow(ctx, output, global, values[1]);
                return err;
            };
        }
        const key = propertyAtomFromLengthIndex(ctx.runtime, index) catch |err| {
            try iterator_ops.iteratorCloseForThrow(ctx, output, global, values[1]);
            return err;
        };
        defer key.deinit(ctx.runtime);
        createDataPropertyOrThrow(ctx, output, global, out, key.atom, item, caller_function, caller_frame) catch |err| {
            try iterator_ops.iteratorCloseForThrow(ctx, output, global, values[1]);
            return err;
        };
    }
    try setValuePropertyOrThrow(ctx, output, global, out.value(), core.atom.ids.length, value_ops.numberToValue(@floatFromInt(index)), caller_function, caller_frame);
    return values[0];
}

pub noinline fn arrayOfCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    if (!isArrayStaticRecord(function_object, @intFromEnum(method_ids.array.StaticMethod.of))) return null;
    if (args.len > @as(usize, @intCast(std.math.maxInt(i32)))) return error.RangeError;

    const length_value = core.JSValue.int32(@intCast(args.len));
    const out_value = if (call_runtime.isConstructorLike(constructor_value))
        try constructValueOrBytecode(ctx, output, global, constructor_value, &.{length_value}, caller_function, caller_frame)
    else blk: {
        const out = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
        out.setArrayLength(@intCast(args.len));
        break :blk out.value();
    };
    const out = objectFromValue(out_value) orelse return error.TypeError;

    for (args, 0..) |arg, index| {
        const key = core.Atom.taggedInt(@intCast(index));
        try createDataPropertyOrThrow(ctx, output, global, out, key, arg, caller_function, caller_frame);
    }
    try setValuePropertyOrThrow(ctx, output, global, out.value(), core.atom.ids.length, length_value, caller_function, caller_frame);
    return out_value;
}

pub fn isArrayStaticRecord(function_object: *core.Object, method_id: u32) bool {
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionId()) orelse return false;
    return native_ref.domain == .array and native_ref.id == method_id;
}

pub fn arrayPrototypeRecordId(function_object: *core.Object) ?u32 {
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionId()) orelse return null;
    if (native_ref.domain != .array) return null;
    if (core.host_function.builtin_method_id_lookup.array.decodePrototypeMethodId(native_ref.id) == null and
        native_ref.id != @intFromEnum(method_ids.array.PrototypeMethod.to_string) and
        native_ref.id != @intFromEnum(method_ids.array.PrototypeMethod.to_locale_string) and
        native_ref.id != @intFromEnum(method_ids.array.PrototypeMethod.map) and
        native_ref.id != @intFromEnum(method_ids.array.PrototypeMethod.for_each) and
        native_ref.id != @intFromEnum(method_ids.array.PrototypeMethod.reduce_right) and
        native_ref.id != @intFromEnum(method_ids.array.PrototypeMethod.copy_within) and
        native_ref.id != @intFromEnum(method_ids.array.PrototypeMethod.fill) and
        native_ref.id != @intFromEnum(method_ids.array.PrototypeMethod.shift) and
        native_ref.id != @intFromEnum(method_ids.array.PrototypeMethod.unshift) and
        native_ref.id != @intFromEnum(method_ids.array.PrototypeMethod.join) and
        native_ref.id != @intFromEnum(method_ids.array.PrototypeMethod.flat) and
        native_ref.id != @intFromEnum(method_ids.array.PrototypeMethod.flat_map) and
        native_ref.id != @intFromEnum(method_ids.array.PrototypeMethod.to_reversed) and
        native_ref.id != @intFromEnum(method_ids.array.PrototypeMethod.to_sorted) and
        native_ref.id != @intFromEnum(method_ids.array.PrototypeMethod.to_spliced) and
        native_ref.id != @intFromEnum(method_ids.array.PrototypeMethod.with_) and
        native_ref.id != @intFromEnum(method_ids.array.PrototypeMethod.find) and
        native_ref.id != @intFromEnum(method_ids.array.PrototypeMethod.find_index) and
        native_ref.id != @intFromEnum(method_ids.array.PrototypeMethod.find_last) and
        native_ref.id != @intFromEnum(method_ids.array.PrototypeMethod.find_last_index))
    {
        return null;
    }
    return native_ref.id;
}

pub fn isArrayPrototypeRecord(function_object: *core.Object, method_id: u32) bool {
    return arrayPrototypeRecordId(function_object) == method_id;
}

pub noinline fn typedArrayOfStaticCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (!call_runtime.isConstructorLike(constructor_value)) return exception_ops.throwTypeErrorMessage(ctx, global, "not a constructor");
    if (args.len > std.math.maxInt(u32)) return error.RangeError;

    const out_value = try typedArrayCreateWithLength(ctx, output, global, constructor_value, args.len, caller_function, caller_frame);
    const out = objectFromValue(out_value) orelse return error.TypeError;
    for (args, 0..) |arg, index| {
        try typedArraySetElementValue(ctx, output, global, out, index, arg);
    }
    return out_value;
}

pub fn createArrayDataOrTypedArrayElement(
    rt: *core.JSRuntime,
    object: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
) !void {
    if (core.object.isTypedArrayObject(object)) {
        // Only canonical numeric keys are typed-array elements; any other
        // key (a class field `foo`) is an ordinary property.
        switch (try core.object.typedArrayCanonicalNumericIndex(rt, atom_id)) {
            .none => {},
            .invalid => return error.TypeError,
            .index => |index| {
                if (!try core.typed_array.typedArraySetIndex(rt, object, index, value)) return error.TypeError;
                return;
            },
        }
    }
    if (rt.atoms.kind(atom_id) == .private and object.hasOwnProperty(atom_id)) return error.TypeError;
    if (core.array.arrayIndexFromAtom(rt.atoms, atom_id)) |index| {
        // CreateDataProperty defines a fresh own element and never walks the
        // prototype chain for an inherited indexed setter.
        if (try object.appendDenseArrayDefineIndex(rt, index, atom_id, value)) return;
    }
    try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(value, .all));
}

pub const ArraySortEntry = struct {
    value: core.JSValue,
    order: usize,
    /// Faithful to quickjs ValueSlot.str: the default
    /// (no user comparator) string comparator transcodes each element to a
    /// byte key exactly once and caches it here. Owned by the runtime's
    /// allocator; null until lazily computed. Never populated when a user
    /// comparator is supplied (that path never calls ToString).
    key: ?[]u8 = null,

    pub fn freeEntry(self: ArraySortEntry, ctx: *core.JSContext) void {
        if (self.key) |bytes| ctx.runtime.nativeAllocator().free(bytes);
    }
};

/// Sort-lifetime temporary storage. qjs's sort scratch (the `ValueSlot`
/// array, quickjs.c) is one malloc per sort; zjs takes it from the
/// runtime's `VmStackArena` (the alloca-shaped per-call scratch the VM's
/// frames already bump through) so a sort costs no heap round trip at all,
/// falling back to the heap only when the arena cannot serve the request
/// (oversized window or arena exhausted). The caller brackets every acquire
/// with `vm_stack.mark()` / `restore()`; the arena is strictly LIFO, and the
/// comparator's own frames are carved above and released below this window.
fn SortScratch(comptime T: type) type {
    return struct {
        items: []T = &.{},
        heap: bool = false,

        fn acquire(rt: *core.JSRuntime, n: usize) !@This() {
            if (rt.vm_stack.carveTyped(rt, T, n)) |window| return .{ .items = window };
            return .{ .items = try rt.nativeAllocator().alloc(T, n), .heap = true };
        }

        fn release(self: @This(), rt: *core.JSRuntime) void {
            if (self.heap) rt.nativeAllocator().free(self.items);
        }
    };
}

/// `entries` lives in arena or malloc'd storage. Conservative scan sees the
/// buffer pointer, not the values behind it, so CLI STW needs a native window
/// from collection through comparator/writeback. The rooted copy is arena
/// scratch too: the caller must hold a `vm_stack` mark around this window.
const SortEntryRootWindow = struct {
    rooted_values: SortScratch(core.JSValue) = .{},
    slices: [1]core.runtime.ValueRootSlice = undefined,
    frame: core.runtime.ValueRootFrame = .{},

    inline fn activate(self: *@This(), rt: *core.JSRuntime, entries: []const ArraySortEntry) !void {
        if (entries.len == 0) return;
        self.rooted_values = try SortScratch(core.JSValue).acquire(rt, entries.len);
        for (entries, 0..) |entry, i| self.rooted_values.items[i] = entry.value;
        self.slices[0] = .{ .borrowed = self.rooted_values.items };
        self.frame.slices = &self.slices;
        self.frame.activate(rt);
    }

    fn deactivate(self: *@This(), rt: *core.JSRuntime) void {
        // `activate` links nothing for an empty receiver; deactivating a frame
        // that was never pushed is a LIFO violation under the scalar-root
        // linking policy tests use (found on `[].sort()`; production's
        // containers-only policy masked it).
        if (self.rooted_values.items.len == 0) return;
        self.frame.deactivate(rt);
        self.rooted_values.release(rt);
        self.rooted_values = .{};
    }
};

/// Roots values a sort gathers before its entry window exists. The entry
/// list is native memory the stack scan cannot see, and gathering runs user
/// getters, proxy traps and heap allocations (BigInt reads). The frame names
/// the list's `items` header, so growth is followed; capacity is reserved
/// before each read so the value is appended without another allocation.
const SortGatherRoots = struct {
    values: std.ArrayListUnmanaged(core.JSValue) = .empty,
    slices: [1]core.runtime.ValueRootSlice = undefined,
    frame: core.runtime.ValueRootFrame = .{},

    /// Call on the final address; the frame points into `self`.
    fn activate(self: *@This(), rt: *core.JSRuntime) void {
        self.slices[0] = .{ .mutable = &self.values.items };
        self.frame.slices = &self.slices;
        self.frame.activate(rt);
    }

    fn deactivate(self: *@This(), rt: *core.JSRuntime) void {
        self.frame.deactivate(rt);
        self.values.deinit(rt.nativeAllocator());
    }

    fn reserve(self: *@This(), rt: *core.JSRuntime) !void {
        try self.values.ensureUnusedCapacity(rt.nativeAllocator(), 1);
    }

    fn keep(self: *@This(), value: core.JSValue) void {
        self.values.appendAssumeCapacity(value);
    }
};

pub noinline fn arraySortCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    const comparator = if (args.len >= 1 and !args[0].is(.undefined_value)) args[0] else core.JSValue.undefinedValue();
    if (!comparator.is(.undefined_value) and !isCallableValue(comparator)) return error.NotAFunction;

    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    const object = objectFromValue(receiver_object_value) orelse return error.TypeError;

    const is_typed_method = isTypedArrayPrototypeMethod(function_object);
    const is_typed_array = core.object.isTypedArrayObject(object);
    if (is_typed_method and !is_typed_array) return error.NotATypedArray;
    if (is_typed_method) {
        if (try core.object.typedArrayDetached(object) or try core.object.typedArrayOutOfBounds(object)) return error.TypedArrayOutOfBounds;
    }
    const length = try arrayMethodLength(ctx, output, global, receiver_object_value, object, is_typed_method, caller_function, caller_frame);

    const rt = ctx.runtime;
    const scratch_mark = rt.vm_stack.mark();
    defer rt.vm_stack.restore(scratch_mark);

    // Storage for the collected slots. A fully dense ordinary array (the
    // receiver IS the array, every index in [0, length) is an own dense data
    // element, no exotic [[Get]]/[[Set]]) takes one exact-capacity arena
    // window; anything else grows a list through the observable [[HasProperty]]
    // / [[Get]] walk exactly as before.
    var entries_list = std.ArrayList(ArraySortEntry).empty;
    defer entries_list.deinit(rt.nativeAllocator());
    var entries_scratch: SortScratch(ArraySortEntry) = .{};
    defer entries_scratch.release(rt);
    var entries: []ArraySortEntry = &.{};
    defer for (entries) |entry| entry.freeEntry(ctx);

    const dense_receiver = !is_typed_array and
        objectFromValue(receiver) == object and
        object.isFastArray() and
        !object.hasExoticMethods() and
        @as(usize, @intCast(object.fastArrayCount())) == length;

    var undefined_count: usize = 0;
    var index: usize = 0;
    var gather: SortGatherRoots = .{};
    var gather_active = false;
    defer if (gather_active) gather.deactivate(rt);
    if (dense_receiver) {
        // Dense elements are plain writable data properties (any define on an
        // index demotes the array to sparse first), so [[HasProperty]] is true
        // for every index and [[Get]] is the slot read. Values stay reachable
        // through the array until the root window below is active.
        entries_scratch = try SortScratch(ArraySortEntry).acquire(rt, length);
        var filled: usize = 0;
        for (object.fastArrayValues(), 0..) |value, element_index| {
            if (value.is(.undefined_value)) {
                undefined_count += 1;
                continue;
            }
            entries_scratch.items[filled] = .{ .value = value, .order = element_index };
            filled += 1;
        }
        entries = entries_scratch.items[0..filled];
    } else {
        gather.activate(rt);
        gather_active = true;
        var sparse_walk = !is_typed_array and length >= sparse_walk_min_length;
        while (index < length) : (index += 1) {
            try exception_ops.pollNativeLoop(ctx, global);
            if (sparse_walk) switch (try nextSparseCandidate(rt, object, index)) {
                .none => break,
                .index => |candidate| index = candidate,
                .unknown => sparse_walk = false,
            };
            if (index >= length) break;
            const key = try propertyAtomFromLengthIndex(rt, index);
            defer key.deinit(rt);
            if (!try hasValueProperty(ctx, output, global, object, key.atom, null, null)) continue;
            try gather.reserve(rt);
            const value = try getValueProperty(ctx, output, global, receiver_object_value, key.atom, caller_function, caller_frame);
            if (value.is(.undefined_value)) {
                undefined_count += 1;
                continue;
            }
            gather.keep(value);
            try array_list_erased.append(&entries_list, rt.nativeAllocator(), .{ .value = value, .order = index });
        }
        entries = entries_list.items;
    }

    var sort_window: SortEntryRootWindow = .{};
    try sort_window.activate(rt, entries);
    defer sort_window.deactivate(rt);

    try stableArraySortEntries(ctx, output, global, is_typed_method, comparator, entries, caller_function, caller_frame);

    index = 0;
    // The comparator may have reshaped the receiver (length change, define on
    // an index, push). Only when the array is still the same fully dense
    // extent is every write below the in-bounds fast-array arm of qjs
    // JS_SetPropertyInternal (a `set_value` on the slot, quickjs.c):
    // store straight into the slot. Otherwise every index goes through the
    // generic [[Set]] as before.
    if (dense_receiver and
        object.isFastArray() and
        !object.hasExoticMethods() and
        @as(usize, @intCast(object.fastArrayCount())) == length and
        @as(usize, @intCast(object.arrayLength())) == length)
    {
        // Every index is written (SortIndexedProperties is followed by a Set
        // per index): a comparator may have changed an unmoved slot.
        for (entries, 0..) |entry, sorted_index| {
            const stored = object.setFastArrayElement(rt, @intCast(sorted_index), entry.value);
            std.debug.assert(stored);
        }
        index = entries.len;
        while (index < entries.len + undefined_count) : (index += 1) {
            const stored = object.setFastArrayElement(rt, @intCast(index), core.JSValue.undefinedValue());
            std.debug.assert(stored);
        }
        if (length != 0) object.markIndexedProperties(rt);
        // A dense receiver has no holes: entries + undefineds cover [0, length).
        std.debug.assert(index == length);
        return receiver_object_value;
    }
    // Generic write-back: a [[Set]] for every index, sorted values first,
    // then the undefineds, then holes (below). Unlike QuickJS, which skips
    // an element whose sorted position equals its original one, the spec
    // requires the Set: the comparator may have mutated the receiver, and
    // the write is observable through setters, proxies and frozen arrays.
    index = 0;
    const write_end = entries.len + undefined_count;
    while (index < write_end) : (index += 1) {
        const write_value = if (index < entries.len) entries[index].value else core.JSValue.undefinedValue();
        const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
        defer key.deinit(ctx.runtime);
        try setValuePropertyOrThrow(ctx, output, global, receiver_object_value, key.atom, write_value, caller_function, caller_frame);
    }
    // Deleting an absent index is a no-op, so a huge length only visits the
    // indices that may be present.
    var sparse_walk = !is_typed_array and length - index >= sparse_walk_min_length;
    while (index < length) : (index += 1) {
        if (sparse_walk) switch (try nextSparseCandidate(ctx.runtime, object, index)) {
            .none => break,
            .index => |candidate| index = candidate,
            .unknown => sparse_walk = false,
        };
        if (index >= length) break;
        const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
        defer key.deinit(ctx.runtime);
        try deleteValuePropertyOrThrow(ctx, output, global, object, key.atom);
    }
    return receiver_object_value;
}

pub fn arraySortCompare(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    typed_array: bool,
    comparator_call: *CallSite,
    lhs: ArraySortEntry,
    rhs: ArraySortEntry,
) !i32 {
    // The result is read in place through the error union's payload pointer:
    // copying the 16-byte JSValue into a local goes through a q register and
    // the scalar tag load right after it then waits on store forwarding the
    // core cannot do (vector store -> GPR load), a stall that showed as the
    // hottest instructions of the sort loop.
    // qjs js_array_cmp_generic: bit-identical elements
    // never reach the comparator; they keep their original order. The typed
    // array comparator (js_TA_cmp_generic, quickjs.c) has no such
    // shortcut: it calls comparefn for every pair (test262
    // TypedArray/prototype/sort/comparefn-calls.js).
    if (!typed_array and lhs.value.bits == rhs.value.bits) return stableSortTieBreak(lhs, rhs);
    var call_result = comparator_call.call2(lhs.value, rhs.value);
    const result: *const core.JSValue = if (call_result) |*value| value else |err| return err;
    // qjs js_array_cmp_generic: a JS_TAG_INT result is
    // compared as an integer, no float conversion; everything else goes
    // through JS_ToFloat64Free, whose ToPrimitive(number) + bigint TypeError
    // shape is `toNumberForDateMethod`. The float64 tag is read inline too so
    // `a - b` style comparators past int32 stay off the generic ToNumber call.
    const cmp: i32 = if (result.as(.int)) |int_value|
        @as(i32, @intFromBool(int_value > 0)) - @as(i32, @intFromBool(int_value < 0))
    else blk: {
        const number = result.as(.float64) orelse inner: {
            const number_value = try toNumberForDateMethod(ctx, output, global, result.*);
            break :inner value_ops.numberValue(number_value) orelse std.math.nan(f64);
        };
        // `(val > 0) - (val < 0)`: NaN and both zeros give 0, the stable tie.
        break :blk @as(i32, @intFromBool(number > 0)) - @as(i32, @intFromBool(number < 0));
    };
    if (cmp != 0) return cmp;
    return stableSortTieBreak(lhs, rhs);
}

pub fn stableArraySortEntries(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    typed_numeric_default: bool,
    comparator: core.JSValue,
    entries: []ArraySortEntry,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    if (entries.len < 2) return;
    // Merge scratch from the VM stack arena (heap only when the arena cannot
    // serve it); released with the watermark, never per call.
    const scratch_mark = ctx.runtime.vm_stack.mark();
    defer ctx.runtime.vm_stack.restore(scratch_mark);
    const temp_scratch = try SortScratch(ArraySortEntry).acquire(ctx.runtime, entries.len);
    defer temp_scratch.release(ctx.runtime);
    const temp = temp_scratch.items;
    var comparator_call: ?CallSite = if (!comparator.is(.undefined_value))
        CallSite.initInternal(
            ctx,
            output,
            global,
            core.JSValue.undefinedValue(),
            comparator,
            caller_function,
            caller_frame,
        )
    else
        null;
    if (comparator_call) |*site| site.activateRoots();
    defer if (comparator_call) |*site| site.deinit();

    // Bottom-up merge, ping-ponging between the two buffers: each pass reads
    // `src` and writes `dst` whole, then the roles swap, so a run is copied
    // once per pass instead of once into `temp` and once back. The sequence of
    // comparator calls is exactly the copy-back form's (it depends only on the
    // run structure), so nothing observable changes.
    var src: []ArraySortEntry = entries;
    var dst: []ArraySortEntry = temp;
    // A comparator (or default ToString) exception leaves a pass half written
    // into `dst`; `src` still holds every element, with its cached key, exactly
    // once, and that is what the caller's per-entry cleanup must see.
    errdefer if (src.ptr != entries.ptr) @memcpy(entries, src);
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
                try exception_ops.pollNativeLoop(ctx, global);
                // Faithful to js_array_cmp_generic /
                // js_TA_cmp_generic: the user comparator
                // receives (earlier, later) — argv[0] is the element from the
                // lower original run. Take the right run only on a strictly
                // positive result so equal elements keep the left-first
                // (stable) order, matching qjs's a_idx<b_idx tie-break.
                if (try arrayByCopySortCompare(ctx, output, global, typed_numeric_default, comparator, if (comparator_call) |*call_site| call_site else null, &src[left], &src[right], caller_function, caller_frame) > 0) {
                    dst[out_index] = src[right];
                    right += 1;
                } else {
                    dst[out_index] = src[left];
                    left += 1;
                }
            }
            while (left < mid) : ({
                left += 1;
                out_index += 1;
            }) {
                dst[out_index] = src[left];
            }
            while (right < end) : ({
                right += 1;
                out_index += 1;
            }) {
                dst[out_index] = src[right];
            }
        }
        std.mem.swap([]ArraySortEntry, &src, &dst);
    }
    if (src.ptr != entries.ptr) @memcpy(entries, src);
}

pub const ByCopyMode = enum { to_reversed, to_sorted, to_spliced, with_ };

pub noinline fn arrayByCopyCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    mode: ByCopyMode,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;

    if (mode == .to_sorted and args.len >= 1 and !args[0].is(.undefined_value) and !isCallableValue(args[0])) {
        return error.NotAFunction;
    }

    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    const object = objectFromValue(receiver_object_value) orelse return null;
    const is_typed_method = isTypedArrayPrototypeMethod(function_object);
    if (is_typed_method and !core.object.isTypedArrayObject(object)) return error.NotATypedArray;
    if (is_typed_method) {
        if (try typedArrayByCopyCall(ctx, output, global, object, mode, args, caller_function, caller_frame)) |value| return value;
    }

    const length = try lengthOfArrayLike(ctx, output, global, receiver_object_value, object, caller_function, caller_frame);
    // with/toSpliced convert their arguments first; ArrayCreate rejects the length later.
    if (mode != .to_spliced and mode != .with_ and length > core.array.max_array_length) return error.InvalidArrayLength;

    if (mode == .to_reversed) {
        const out = try createArrayByCopyOutput(ctx.runtime, global, length);
        for (0..length) |index| {
            try exception_ops.pollNativeLoop(ctx, global);
            try arrayCopyIndex(ctx, output, global, receiver_object_value, out, length - index - 1, index, caller_function, caller_frame);
        }
        return out.value();
    }

    if (mode == .to_sorted) {
        const comparator = if (args.len >= 1 and !args[0].is(.undefined_value)) args[0] else core.JSValue.undefinedValue();
        // The output array is the first gathered root: getters run before it
        // is filled.
        var gather: SortGatherRoots = .{};
        gather.activate(ctx.runtime);
        defer gather.deactivate(ctx.runtime);
        try gather.reserve(ctx.runtime);
        const out_value = (try createArrayByCopyOutput(ctx.runtime, global, length)).value();
        gather.keep(out_value);
        // The root window below takes its rooted copy from the VM stack arena.
        const scratch_mark = ctx.runtime.vm_stack.mark();
        defer ctx.runtime.vm_stack.restore(scratch_mark);
        var entries = std.ArrayList(ArraySortEntry).empty;
        defer {
            for (entries.items) |entry| entry.freeEntry(ctx);
            entries.deinit(ctx.runtime.nativeAllocator());
        }
        var undefined_count: usize = 0;
        for (0..length) |index| {
            try exception_ops.pollNativeLoop(ctx, global);
            const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
            defer key.deinit(ctx.runtime);
            try gather.reserve(ctx.runtime);
            const item = try getValueProperty(ctx, output, global, receiver_object_value, key.atom, caller_function, caller_frame);
            if (item.is(.undefined_value)) {
                undefined_count += 1;
            } else {
                gather.keep(item);
                try array_list_erased.append(&entries, ctx.runtime.nativeAllocator(), .{ .value = item, .order = @intCast(index) });
            }
        }
        var sort_window: SortEntryRootWindow = .{};
        try sort_window.activate(ctx.runtime, entries.items);
        defer sort_window.deactivate(ctx.runtime);
        try stableArraySortEntries(ctx, output, global, false, comparator, entries.items, caller_function, caller_frame);
        // Re-read the output from its root at every step: the comparator and
        // element definition can collect.
        for (entries.items, 0..) |entry, sorted_index| {
            try defineArrayByCopyElement(ctx.runtime, objectFromValue(gather.values.items[0]).?, sorted_index, entry.value);
        }
        for (entries.items.len..entries.items.len + undefined_count) |index| {
            try defineArrayByCopyElement(ctx.runtime, objectFromValue(gather.values.items[0]).?, index, core.JSValue.undefinedValue());
        }
        return gather.values.items[0];
    }

    if (mode == .with_) {
        const relative_index = try toIntegerOrInfinityForArrayByCopy(ctx, output, global, if (args.len >= 1) args[0] else core.JSValue.undefinedValue());
        const actual_index = if (relative_index < 0) @as(f64, @floatFromInt(length)) + relative_index else relative_index;
        if (actual_index < 0 or actual_index >= @as(f64, @floatFromInt(length)) or !std.math.isFinite(actual_index)) return error.InvalidArrayIndex;
        const replace_index: usize = @intFromFloat(actual_index);
        const replacement = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
        const out = try createArrayByCopyOutput(ctx.runtime, global, length);
        for (0..length) |index| {
            try exception_ops.pollNativeLoop(ctx, global);
            if (index == replace_index) {
                try defineArrayByCopyElement(ctx.runtime, out, index, replacement);
                continue;
            }
            try arrayCopyIndex(ctx, output, global, receiver_object_value, out, index, index, caller_function, caller_frame);
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
    if (insert_count > core.array.max_safe_length - kept_length) return error.ArrayTooLong;
    const new_length = kept_length + insert_count;
    if (new_length > core.array.max_array_length) return error.InvalidArrayLength;
    const out = try createArrayByCopyOutput(ctx.runtime, global, new_length);
    var write_index: usize = 0;
    while (write_index < actual_start) : (write_index += 1) {
        try exception_ops.pollNativeLoop(ctx, global);
        try arrayCopyIndex(ctx, output, global, receiver_object_value, out, write_index, write_index, caller_function, caller_frame);
    }
    if (args.len > 2) {
        for (args[2..], 0..) |item, item_index| {
            try defineArrayByCopyElement(ctx.runtime, out, actual_start + item_index, item);
        }
    }
    write_index = actual_start + insert_count;
    var read_index = actual_start + actual_delete_count;
    while (read_index < length) : ({
        try exception_ops.pollNativeLoop(ctx, global);
        read_index += 1;
        write_index += 1;
    }) {
        try arrayCopyIndex(ctx, output, global, receiver_object_value, out, read_index, write_index, caller_function, caller_frame);
    }
    return out.value();
}

pub fn typedArrayByCopyCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    mode: ByCopyMode,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (!core.object.isTypedArrayObject(object)) return null;
    if (try core.object.typedArrayDetached(object)) return error.TypedArrayOutOfBounds;
    if (try core.object.typedArrayOutOfBounds(object)) return error.TypedArrayOutOfBounds;

    const length = @as(usize, @intCast(try core.object.typedArrayLength(ctx.runtime, object)));

    if (mode == .to_reversed) {
        const out_value = try typedArrayCreateSameType(ctx, output, global, object, length, caller_function, caller_frame);
        const out = objectFromValue(out_value) orelse return error.TypeError;
        for (0..length) |index| {
            try exception_ops.pollNativeLoop(ctx, global);
            const item = try core.typed_array.typedArrayGetIndex(ctx.runtime, object, @intCast(length - index - 1));
            _ = try core.typed_array.typedArraySetIndex(ctx.runtime, out, @intCast(index), item);
        }
        return out_value;
    }

    if (mode == .to_sorted) {
        const comparator = if (args.len >= 1 and !args[0].is(.undefined_value)) args[0] else core.JSValue.undefinedValue();
        var entries = std.ArrayList(ArraySortEntry).empty;
        defer {
            for (entries.items) |entry| entry.freeEntry(ctx);
            entries.deinit(ctx.runtime.nativeAllocator());
        }
        // BigInt element reads allocate, and the comparator and the result
        // allocation below can collect: keep every read value rooted.
        var gather: SortGatherRoots = .{};
        gather.activate(ctx.runtime);
        defer gather.deactivate(ctx.runtime);

        for (0..length) |index| {
            try exception_ops.pollNativeLoop(ctx, global);
            try gather.reserve(ctx.runtime);
            const item = try core.typed_array.typedArrayGetIndex(ctx.runtime, object, @intCast(index));
            gather.keep(item);
            try array_list_erased.append(&entries, ctx.runtime.nativeAllocator(), .{ .value = item, .order = @intCast(index) });
        }
        try stableArraySortEntries(ctx, output, global, true, comparator, entries.items, caller_function, caller_frame);

        const out_value = try typedArrayCreateSameType(ctx, output, global, object, length, caller_function, caller_frame);
        const out = objectFromValue(out_value) orelse return error.TypeError;
        for (entries.items, 0..) |entry, sorted_index| {
            try exception_ops.pollNativeLoop(ctx, global);
            _ = try core.typed_array.typedArraySetIndex(ctx.runtime, out, @intCast(sorted_index), entry.value);
        }
        return out_value;
    }

    if (mode == .with_) {
        const relative_index = try toIntegerOrInfinityForArrayByCopy(ctx, output, global, if (args.len >= 1) args[0] else core.JSValue.undefinedValue());
        const actual_index = if (relative_index < 0) @as(f64, @floatFromInt(length)) + relative_index else relative_index;
        const replacement = try typedArrayByCopyCoerceValue(ctx, output, global, object, if (args.len >= 2) args[1] else core.JSValue.undefinedValue());

        const current_length = @as(usize, @intCast(try core.object.typedArrayLength(ctx.runtime, object)));
        if (actual_index < 0 or actual_index >= @as(f64, @floatFromInt(current_length)) or !std.math.isFinite(actual_index)) return error.InvalidArrayIndex;
        const replace_index: usize = @intFromFloat(actual_index);

        const out_value = try typedArrayCreateSameType(ctx, output, global, object, length, caller_function, caller_frame);
        const out = objectFromValue(out_value) orelse return error.TypeError;
        for (0..length) |index| {
            try exception_ops.pollNativeLoop(ctx, global);
            const item = if (index == replace_index)
                replacement
            else
                try core.typed_array.typedArrayGetIndex(ctx.runtime, object, @intCast(index));
            _ = try core.typed_array.typedArraySetIndex(ctx.runtime, out, @intCast(index), item);
        }
        return out_value;
    }

    return null;
}

pub noinline fn arrayFlatCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
    is_flat_map: bool,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    const source = objectFromValue(receiver_object_value) orelse return null;
    const source_length = try lengthOfArrayLike(ctx, output, global, receiver_object_value, source, caller_function, caller_frame);

    const mapper = if (is_flat_map) blk: {
        const mapper_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        if (!isCallableValue(mapper_value)) return error.NotAFunction;
        break :blk mapper_value;
    } else core.JSValue.undefinedValue();
    const this_arg = if (is_flat_map and args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const depth: usize = if (is_flat_map)
        1
    else if (args.len >= 1 and !args[0].is(.undefined_value)) blk: {
        const depth_number = try toIntegerOrInfinityForArrayByCopy(ctx, output, global, args[0]);
        if (std.math.isNan(depth_number) or depth_number <= 0) break :blk 0;
        // Any depth past the address space flattens completely.
        if (depth_number >= 0x1p63) break :blk std.math.maxInt(usize);
        break :blk @intFromFloat(@trunc(depth_number));
    } else 1;

    const out_value = try arraySpeciesCreate(ctx, output, global, receiver_object_value, 0, caller_function, caller_frame);
    const out = objectFromValue(out_value) orelse return error.TypeError;
    var mapper_call: ?CallSite = if (is_flat_map)
        CallSite.initInternal(ctx, output, global, this_arg, mapper, caller_function, caller_frame)
    else
        null;
    if (mapper_call) |*site| site.activateRoots();
    defer if (mapper_call) |*site| site.deinit();
    // The spec never Sets `length`: CreateDataPropertyOrThrow grows an
    // array result, and a species result keeps whatever length it has.
    _ = try flattenIntoArray(ctx, output, global, out_value, out, receiver_object_value, source, source_length, 0, depth, if (mapper_call) |*call_site| call_site else null, caller_function, caller_frame);
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
    mapper_call: ?*CallSite,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !usize {
    if (ctx.runtime.stack.checkNativeOverflow(0)) return error.StackOverflow;
    var target_index = start;
    var source_index: usize = 0;
    while (source_index < source_length) : (source_index += 1) {
        try exception_ops.pollNativeLoop(ctx, global);
        const source_key = try propertyAtomFromLengthIndex(ctx.runtime, source_index);
        defer source_key.deinit(ctx.runtime);
        if (!try hasValueProperty(ctx, output, global, source, source_key.atom, null, null)) continue;

        var element = try getValueProperty(ctx, output, global, source_value, source_key.atom, caller_function, caller_frame);
        if (mapper_call) |call_site| {
            const index_value = lengthIndexValue(source_index);
            const mapped = try call_site.call3(element, index_value, source_value);
            element = mapped;
        }

        const element_object = objectFromValue(element);
        if (depth > 0 and element_object != null and try core.array.isArrayValue(element_object.?.value())) {
            const element_length = try lengthOfArrayLike(ctx, output, global, element, element_object.?, caller_function, caller_frame);
            const next_depth = if (depth == std.math.maxInt(usize)) depth else depth - 1;
            target_index = try flattenIntoArray(ctx, output, global, target_value, target, element, element_object.?, element_length, target_index, next_depth, null, caller_function, caller_frame);
            continue;
        }

        // FlattenIntoArray: only the 2^53 - 1 index limit; past 2^32 - 2 the
        // key is an ordinary property, which any target can take.
        if (target_index >= core.array.max_safe_length) {
            _ = try throwTypeErrorMessage(ctx, global, "flattened array exceeds the maximum length");
            unreachable;
        }
        const target_key = try propertyAtomFromLengthIndex(ctx.runtime, target_index);
        defer target_key.deinit(ctx.runtime);
        try createDataPropertyOrThrow(ctx, output, global, target, target_key.atom, element, caller_function, caller_frame);
        target_index += 1;
    }
    return target_index;
}

pub fn createArrayByCopyOutput(rt: *core.JSRuntime, global: *core.Object, length: usize) !*core.Object {
    if (length > core.array.max_array_length) return error.InvalidArrayLength;
    const out = try core.Object.createArray(rt, arrayPrototypeFromGlobal(rt, global));
    out.setArrayLength(@intCast(length));
    return out;
}

pub fn typedArrayCreateSameType(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    length: usize,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const constructor_value = try typedArrayConstructorForObject(ctx.runtime, global, object);
    return constructValueOrBytecode(ctx, output, global, constructor_value, &.{lengthIndexValue(length)}, caller_function, caller_frame);
}

pub fn typedArrayByCopyCoerceValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    value: core.JSValue,
) !core.JSValue {
    const primitive = try toPrimitiveForNumber(ctx, output, global, value);

    if (object.typedArrayKind().isBigInt()) {
        var bigint = try value_ops.toBigIntValue(ctx.runtime, primitive);
        defer bigint.deinit();
        return value_ops.createBigIntValue(ctx.runtime, bigint);
    }

    if (primitive.isBigInt()) return error.BigIntToNumber;
    return value_ops.toNumberValue(ctx.runtime, primitive);
}

pub fn defineArrayByCopyElement(rt: *core.JSRuntime, out: *core.Object, index: usize, value: core.JSValue) !void {
    const key = try propertyAtomFromLengthIndex(rt, index);
    defer key.deinit(rt);
    try out.defineOwnProperty(rt, key.atom, core.Descriptor.data(value, .all));
}

/// Leftover Array.toReversed / with / toSpliced get+define (no has-check).
/// Missing source indexes become `undefined` on the copy. Distinct from
/// outlined `arrayCopyPresentIndex`, which skips missing indexes via
/// createDataPropertyOrThrow.
pub noinline fn arrayCopyIndex(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    source_receiver: core.JSValue,
    dest: *core.Object,
    from_index: usize,
    to_index: usize,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const key = try propertyAtomFromLengthIndex(ctx.runtime, from_index);
    defer key.deinit(ctx.runtime);
    const item = try getValueProperty(ctx, output, global, source_receiver, key.atom, caller_function, caller_frame);
    try defineArrayByCopyElement(ctx.runtime, dest, to_index, item);
}

pub fn toIntegerOrInfinityForArrayByCopy(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !f64 {
    const primitive = try toPrimitiveForNumber(ctx, output, global, value);
    if (primitive.isBigInt()) return error.BigIntToNumber;
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
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
    comparator_call: ?*CallSite,
    lhs: *ArraySortEntry,
    rhs: *ArraySortEntry,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !i32 {
    if (!comparator.is(.undefined_value)) {
        return arraySortCompare(ctx, output, global, typed_numeric_default, comparator_call.?, lhs.*, rhs.*);
    }
    if (typed_numeric_default) return typedArrayDefaultSortCompare(ctx.runtime, lhs.*, rhs.*);
    // Faithful to quickjs js_array_cmp_generic: convert
    // each operand to its byte key exactly once, caching it on the slot, then
    // compare the cached keys. Zero per-compare heap churn after the first
    // ToString of each element.
    const lhs_key = try arraySortStringKey(ctx, output, global, lhs, caller_function, caller_frame);
    const rhs_key = try arraySortStringKey(ctx, output, global, rhs, caller_function, caller_frame);
    const order = orderWtf8ByCodeUnits(lhs_key, rhs_key);
    if (order == .lt) return -1;
    if (order == .gt) return 1;
    return stableSortTieBreak(lhs.*, rhs.*);
}

/// Orders two WTF-8 strings by UTF-16 code units, the order IsLessThan
/// uses. Byte order differs once a supplementary character (a surrogate
/// pair, D800..DBFF first) meets a unit in U+E000..U+FFFF.
pub fn orderWtf8ByCodeUnits(lhs: []const u8, rhs: []const u8) std.math.Order {
    const first_diff = std.mem.indexOfDiff(u8, lhs, rhs) orelse return .eq;
    if (first_diff == lhs.len or first_diff == rhs.len) return std.math.order(lhs.len, rhs.len);
    // The bytes before `first_diff` agree, so both strings start their
    // differing code point at the same offset.
    var start = first_diff;
    while (start > 0 and lhs[start] & 0xC0 == 0x80) start -= 1;
    var lhs_units: Wtf8Units = .{ .bytes = lhs, .index = start };
    var rhs_units: Wtf8Units = .{ .bytes = rhs, .index = start };
    while (true) {
        const lhs_unit = lhs_units.next() orelse return if (rhs_units.next() == null) .eq else .lt;
        const rhs_unit = rhs_units.next() orelse return .gt;
        if (lhs_unit != rhs_unit) return std.math.order(lhs_unit, rhs_unit);
    }
}

/// UTF-16 code units of a WTF-8 string (lone surrogates are 3-byte forms).
const Wtf8Units = struct {
    bytes: []const u8,
    index: usize,
    pending_low: ?u16 = null,

    fn next(self: *Wtf8Units) ?u16 {
        if (self.pending_low) |low| {
            self.pending_low = null;
            return low;
        }
        if (self.index >= self.bytes.len) return null;
        const lead = self.bytes[self.index];
        const len: usize = if (lead < 0x80) 1 else if (lead < 0xE0) 2 else if (lead < 0xF0) 3 else 4;
        var code_point: u21 = if (len == 1) lead else lead & (@as(u8, 0x7F) >> @intCast(len));
        for (self.bytes[self.index + 1 .. self.index + len]) |byte| code_point = (code_point << 6) | (byte & 0x3F);
        self.index += len;
        if (code_point < 0x10000) return @intCast(code_point);
        const offset = code_point - 0x10000;
        self.pending_low = @intCast(0xDC00 + (offset & 0x3FF));
        return @intCast(0xD800 + (offset >> 10));
    }
};

test "orderWtf8ByCodeUnits sorts surrogate pairs before U+E000..U+FFFF" {
    try std.testing.expectEqual(std.math.Order.lt, orderWtf8ByCodeUnits("\u{1F600}", "\u{FF01}"));
    try std.testing.expectEqual(std.math.Order.gt, orderWtf8ByCodeUnits("\u{FF01}", "\u{1F600}"));
    try std.testing.expectEqual(std.math.Order.lt, orderWtf8ByCodeUnits("a", "ab"));
    try std.testing.expectEqual(std.math.Order.eq, orderWtf8ByCodeUnits("x\u{1F600}", "x\u{1F600}"));
    // Lone high surrogate D83D (WTF-8 ED A0 BD) vs U+1F600 = D83D DE00.
    try std.testing.expectEqual(std.math.Order.lt, orderWtf8ByCodeUnits("\xED\xA0\xBD", "\u{1F600}"));
    try std.testing.expectEqual(std.math.Order.lt, orderWtf8ByCodeUnits("\u{E9}", "\u{1F600}"));
}

/// Faithful to quickjs ValueSlot.str caching: lazily compute
/// the transcoded byte key for a sort slot and cache it. Returns the cached
/// bytes (owned by the entry, freed by ArraySortEntry.freeEntry).
fn arraySortStringKey(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    entry: *ArraySortEntry,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) ![]const u8 {
    if (entry.key) |bytes| return bytes;
    const string_value = try toStringForAnnexB(ctx, output, global, entry.value, caller_function, caller_frame);
    var bytes = std.ArrayList(u8).empty;
    errdefer bytes.deinit(ctx.runtime.nativeAllocator());
    try value_ops.appendRawString(ctx.runtime, &bytes, string_value);
    const owned = try bytes.toOwnedSlice(ctx.runtime.nativeAllocator());
    entry.key = owned;
    return owned;
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
    if (less.as(.boolean) == true) return -1;
    const greater = try value_ops.compare(rt, bytecode.opcode.op.gt, lhs.value, rhs.value);
    if (greater.as(.boolean) == true) return 1;
    return stableSortTieBreak(lhs, rhs);
}

pub fn stableSortTieBreak(lhs: ArraySortEntry, rhs: ArraySortEntry) i32 {
    if (lhs.order < rhs.order) return -1;
    if (lhs.order > rhs.order) return 1;
    return 0;
}

pub fn typedArrayOwnKeys(rt: *core.JSRuntime, source: *core.Object) ![]core.Atom {
    var keys: core.atom.AtomListBuilder = .{};
    defer keys.deinit(rt);
    // TGC S3 §4 class B: native []Atom grown across allocating appends.
    var keys_roots = core.runtime.rootAtomList(&keys.items);
    keys_roots.activate(rt);
    defer keys_roots.deactivate(rt);
    const length = try core.object.typedArrayLength(rt, source);
    try keys.ensureTotalCapacity(rt, length);
    var index: u32 = 0;
    while (index < length) : (index += 1) {
        try keys.append(rt, core.Atom.taggedInt(index));
    }

    const ordinary = try source.ownKeys(rt);
    defer core.Object.freeKeys(rt, ordinary);
    var ordinary_roots = core.runtime.rootAtomList(&ordinary);
    ordinary_roots.activate(rt);
    defer ordinary_roots.deactivate(rt);
    // `ordinary` holds no duplicates and none of its string keys is a
    // canonical numeric index once filtered, so no key repeats an index.
    for (ordinary) |key| {
        if (rt.atoms.isPublicSymbol(key)) continue;
        if (try core.object.typedArrayCanonicalNumericIndex(rt, key) != .none) continue;
        try keys.append(rt, key);
    }
    for (ordinary) |key| {
        if (!rt.atoms.isPublicSymbol(key)) continue;
        try keys.append(rt, key);
    }
    return try keys.toOwnedSlice(rt);
}

/// True for a %TypedArray%.prototype method: the shared Array bodies then
/// require a typed-array receiver.
pub fn isTypedArrayPrototypeMethod(function_object: *core.Object) bool {
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionId()) orelse return false;
    if (native_ref.domain != .array) return false;
    const method = std.enums.fromInt(TypedArrayMethod, native_ref.id) orelse return false;
    return method != .from and method != .of;
}

pub const DenseArrayElementFastResult = enum(u8) {
    miss,
    handled,
    out_of_memory,
};

/// QuickJS performs OP_put_array_el's dense overwrite/append window directly
/// in its C interpreter. Keep the same semantic window here, but use the C ABI
/// for this cross-module helper so the compact three-state result is returned in
/// a register instead of Zig's error-union sret storage. The only throwing
/// operation in this window is dense-buffer growth.
pub noinline fn putDenseArrayElementFast(rt: *core.JSRuntime, object_value: core.JSValue, key: core.JSValue, value: core.JSValue) callconv(.c) DenseArrayElementFastResult {
    const object = core.value_semantics.objectFromValue(object_value) orelse return .miss;
    if (!object.isArray()) return .miss;
    if (key.as(.int)) |index_i32| {
        if (index_i32 < 0 or index_i32 > core.array.max_array_index) return .miss;
        const index: u32 = @intCast(index_i32);
        if (object.setFastArrayElement(rt, index, value)) return .handled;
        if (index > core.atom.max_int_atom) return .miss;
        const appended = object.appendDenseArrayIndex(rt, index, core.Atom.taggedInt(index), value) catch |err| switch (err) {
            error.OutOfMemory => return .out_of_memory,
        };
        return if (appended) .handled else .miss;
    }
    const number = value_ops.numberValue(key) orelse return .miss;
    if (std.math.isNan(number) or !std.math.isFinite(number) or number < 0 or number > core.array.max_array_index or @trunc(number) != number) return .miss;
    const index: u32 = @intFromFloat(number);
    if (object.setFastArrayElement(rt, index, value)) return .handled;
    if (index > core.atom.max_int_atom) return .miss;
    const appended = object.appendDenseArrayIndex(rt, index, core.Atom.taggedInt(index), value) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
    };
    return if (appended) .handled else .miss;
}

pub const DenseArrayOverwriteFastResult = enum(u8) {
    miss,
    handled,
    append_candidate,
};

/// Consuming overwrite/reserved-append form for the resident OP_put_array_el
/// handler. QuickJS keeps one exact Array/int-tag/count classification across
/// both arms and moves sp[-1] directly into the selected dense slot.
pub noinline fn putDenseArrayElementOverwriteOwnedFast(rt: *core.JSRuntime, object_value: core.JSValue, key: core.JSValue, value: core.JSValue) callconv(.c) DenseArrayOverwriteFastResult {
    const object = core.value_semantics.objectFromValue(object_value) orelse return .miss;
    if (!object.isArray()) return .miss;
    const index_i32 = key.as(.int) orelse return .miss;
    if (index_i32 < 0 or index_i32 > core.array.max_array_index) return .miss;
    const index: u32 = @intCast(index_i32);
    if (object.setFastArrayElement(rt, index, value)) return .handled;
    if (!object.isFastArray()) return .miss;

    // qjs OP_put_array_el keeps the exact Array/int classification live across
    // its overwrite and reserved-capacity append arms. Preserve the overwrite
    // leaf above, then complete the allocation-free append here without
    // re-reading the JSValue tags through a second helper.
    if (index != object.fastArrayCount() or !object.flags.length_writable) return .miss;
    if (object.hasExoticMethods() or !object.canExtendFastArray()) return .miss;
    if (object.shape_ref.prop_count != 0) return .append_candidate;
    const new_count = index + 1;
    if (new_count > object.fastArrayCapacity()) return .append_candidate;
    object.fastArraySlotAssumeCapacity(index).* = value;
    rt.gc.generationalBarrier(object.gcHeader(), value.cycleMarkHeader());
    rt.gc.auditUnbarrieredStore(object.gcHeader(), value.cycleMarkHeader(), .dense_array_in_capacity_append);
    object.setFastArrayCountAssumeCapacity(new_count);
    if (new_count > object.arrayLength()) object.setArrayLength(new_count);
    object.markIndexedProperties(rt);
    return .handled;
}

/// Append remainder for a proven Array/int candidate. Revalidate the operands
/// at this public boundary; false/OOM leave the owned stack value untouched.
pub noinline fn putDenseArrayElementAppendOwnedFast(rt: *core.JSRuntime, object_value: core.JSValue, key: core.JSValue, value: core.JSValue) callconv(.c) DenseArrayElementFastResult {
    const object = core.value_semantics.objectFromValue(object_value) orelse return .miss;
    if (!object.isArray()) return .miss;
    const index_i32 = key.as(.int) orelse return .miss;
    if (index_i32 < 0 or index_i32 > core.array.max_array_index) return .miss;
    const index: u32 = @intCast(index_i32);
    if (index > core.atom.max_int_atom) return .miss;
    const appended = object.appendDenseArrayIndexOwned(rt, index, core.Atom.taggedInt(index), value) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
    };
    return if (appended) .handled else .miss;
}

/// qjs `JS_MAX_LOCAL_VARS`: the build_arg_list argument cap.
pub const max_apply_arguments: usize = 65534;

pub fn argsFromArray(rt: *core.JSRuntime, array_value: core.JSValue) ![]core.JSValue {
    const array = try property_ops.expectObject(array_value);
    if (!array.isArray()) return error.TypeError;
    // qjs build_arg_list cap: applies to the fast-array copy
    // path as well (the qjs length check precedes its fast_array branch).
    if (array.arrayLength() > max_apply_arguments) return error.TooManyArguments;
    if (array.arrayLength() == 0) return &.{};
    const args = try rt.nativeAllocator().alloc(core.JSValue, array.arrayLength());
    errdefer rt.nativeAllocator().free(args);
    var rooted_args: []core.JSValue = args[0..0];
    var args_root = ValueSliceRoot{};
    args_root.init(rt, &rooted_args);
    defer args_root.deinit();
    var initialized: usize = 0;
    errdefer {
        for (args[0..initialized]) |*value| {
            value.* = core.JSValue.undefinedValue();
        }
        rooted_args = &.{};
    }
    var index: u32 = 0;
    while (index < array.arrayLength()) : (index += 1) {
        args[index] = try array.getProperty(core.Atom.taggedInt(index));
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
            .slices = &self.slices,
        };
        self.frame.activate(rt);
    }

    pub fn deinit(self: *ValueSliceRoot) void {
        const rt = self.rt orelse return;
        self.frame.deactivate(rt);
        self.rt = null;
    }
};

pub const OwnedArrayLikeArgs = struct {
    const Storage = enum {
        empty,
        arena,
        heap,
    };

    rt: ?*core.JSRuntime = null,
    values: []core.JSValue = &.{},
    storage: Storage = .empty,
    arena_mark: core.VmStackArena.Mark = .{ .chunk = 0, .used = 0 },

    pub fn deinit(self: *OwnedArrayLikeArgs) void {
        const rt = self.rt orelse return;
        for (self.values) |*value| {
            value.* = core.JSValue.undefinedValue();
        }
        switch (self.storage) {
            .empty => {},
            .arena => rt.vm_stack.restore(self.arena_mark),
            .heap => rt.nativeAllocator().free(self.values),
        }
        self.* = .{};
    }

    fn takeHeap(self: *OwnedArrayLikeArgs) []core.JSValue {
        std.debug.assert(self.storage == .empty or self.storage == .heap);
        const values = self.values;
        self.* = .{};
        return values;
    }
};

pub fn argsFromArrayLike(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    array_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) ![]core.JSValue {
    var owned = try materializeArgsFromArrayLike(
        ctx,
        output,
        global,
        array_value,
        caller_function,
        caller_frame,
        false,
    );
    return owned.takeHeap();
}

/// NB2 §5.4 apply arm: the argument list of `array_value` when
/// `materializeArgsFromArrayLike` below would copy it WITHOUT an observable
/// [[Get]] -- exactly its three bulk arms, with the same admission tests: a
/// dense fast Array whose element count is its length (qjs build_arg_list
/// `fast_array && len == p->u.array.count`, quickjs.c), an unmapped
/// arguments object whose own `length` data slot still equals its dense
/// count, and a mapped arguments object with every index still bound. Holes,
/// Proxy / exotic receivers, an accessor or rewritten `length`, a deleted or
/// redefined index, a non-object, and the 65534 cap all answer null so the
/// caller takes the observable path. Borrowed: valid until the next
/// allocation or element write.
pub const FastApplyArgs = union(enum) {
    values: []const core.JSValue,
    cells: []const ?*core.VarRef,

    pub inline fn len(self: FastApplyArgs) usize {
        return switch (self) {
            .values => |values| values.len,
            .cells => |cells| cells.len,
        };
    }

    /// `dest.len == self.len()`; `dest` must not alias the source storage.
    pub inline fn copyTo(self: FastApplyArgs, dest: []core.JSValue) void {
        switch (self) {
            .values => |values| @memcpy(dest, values),
            .cells => |cells| for (cells, dest) |cell, *slot| {
                slot.* = cell.?.pvalue.*;
            },
        }
    }
};

pub fn fastApplyArgs(array_value: core.JSValue) ?FastApplyArgs {
    const object = objectFromValue(array_value) orelse return null;
    if (object.proxyTarget() != null or object.hasExoticMethods()) return null;
    if (object.isArray()) {
        if (!object.isFastArray()) return null;
        const length: usize = object.arrayLength();
        if (@as(usize, object.fastArrayCount()) != length or length > max_apply_arguments) return null;
        return .{ .values = object.fastArrayValues()[0..length] };
    }
    const unmapped = object.unmappedArgumentsDenseValues();
    if (unmapped.len != 0) {
        if (!argumentsLengthSlotMatches(object, unmapped.len)) return null;
        return .{ .values = unmapped };
    }
    const cells = object.fullyBoundMappedArgumentsVarRefs() orelse return null;
    if (!argumentsLengthSlotMatches(object, cells.len)) return null;
    return .{ .cells = cells };
}

/// The generic path reads an arguments object's `length` through the ordinary
/// own-data-slot probe and ToLength; the bulk arms then require it to equal
/// the dense count. The fast view accepts only the unrewritten int32 form of
/// that equality (`arguments.length = "2"` and friends stay generic).
fn argumentsLengthSlotMatches(object: *core.Object, count: usize) bool {
    if (count > max_apply_arguments) return false;
    const probe = object_ops.probePublicNamedDataPropertyFromObject(object, core.atom.ids.length);
    const slot = probe.slot orelse return false;
    const length = slot.as(.int) orelse return false;
    return length >= 0 and @as(usize, @intCast(length)) == count;
}

/// Transactional CreateListFromArrayLike materialization for synchronous
/// native algorithms. Values are snapshotted before call entry, published as
/// a GC root by the caller, and then either moved to a resident Entry or
/// borrowed by the authoritative fallback. The LIFO arena backing avoids a
/// per-call heap allocation while preserving an owned writable list.
pub fn ownedArgsFromArrayLike(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    array_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !OwnedArrayLikeArgs {
    return materializeArgsFromArrayLike(
        ctx,
        output,
        global,
        array_value,
        caller_function,
        caller_frame,
        true,
    );
}

fn materializeArgsFromArrayLike(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    array_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    prefer_arena: bool,
) !OwnedArrayLikeArgs {
    const object = objectFromValue(array_value) orelse return error.InvalidArgumentList;
    // CreateListFromArrayLike performs observable [[Get]] operations even
    // when the source is an Array. A dense bulk copy is only valid after
    // proving that every indexed property is an own dense data property.
    const dense_array_length: ?usize = if (object.isArray() and
        object.proxyTarget() == null and
        !object.hasExoticMethods() and
        object.isFastArray() and
        object.arrayElementStorageMode() == .dense)
        @intCast(object.arrayLength())
    else
        null;
    // An ordinary Array's non-configurable own `length` data property is the
    // same internal value returned by [[Get]]. Reading it directly is
    // unobservable; Proxy/exotic and every non-dense source still use the
    // full VM property path.
    const length = dense_array_length orelse blk: {
        // qjs build_arg_list performs js_get_length64 after the object check
        // (qjs:41171), whose JS_GetProperty starts with find_own_property's
        // ordinary data-slot probe (qjs:8268). Use zjs's same general named
        // property prefix; accessors, proxies, exotics, and misses retain the
        // complete observable resolver.
        const length_probe = object_ops.probePublicNamedDataPropertyFromObject(object, core.atom.ids.length);
        const length_value = if (length_probe.slot) |slot|
            slot.*
        else
            try getValueProperty(ctx, output, global, array_value, core.atom.ids.length, caller_function, caller_frame);
        break :blk try toLengthIndex(ctx, output, global, length_value);
    };
    // qjs build_arg_list cap (quickjs.c, JS_MAX_LOCAL_VARS = 65534):
    // apply/Reflect.apply/Reflect.construct reject huge array-likes up front
    // instead of materializing them.
    if (length > max_apply_arguments) {
        _ = try exception_ops.throwRangeErrorMessage(ctx, global, "too many arguments in function call (only 65534 allowed)");
        return error.RangeError;
    }
    if (length == 0) return .{};

    const rt = ctx.runtime;
    const arena_mark = rt.vm_stack.mark();
    const arena_values = if (prefer_arena)
        rt.vm_stack.carve(rt, length)
    else
        null;
    const storage: OwnedArrayLikeArgs.Storage = if (arena_values != null) .arena else .heap;
    const values = arena_values orelse try rt.nativeAllocator().alloc(core.JSValue, length);
    errdefer switch (storage) {
        .empty => {},
        .arena => rt.vm_stack.restore(arena_mark),
        .heap => rt.nativeAllocator().free(values),
    };
    var rooted_args: []core.JSValue = values[0..0];
    var args_root = ValueSliceRoot{};
    args_root.init(rt, &rooted_args);
    defer args_root.deinit();
    var initialized: usize = 0;
    errdefer {
        for (values[0..initialized]) |*value| {
            value.* = core.JSValue.undefinedValue();
        }
        rooted_args = &.{};
    }

    const dense_values: ?[]const core.JSValue = if (dense_array_length != null and
        @as(usize, @intCast(object.fastArrayCount())) == length)
        object.fastArrayValues()
    else if (object.unmappedArgumentsDenseValues().len == length)
        // qjs build_arg_list admits JS_CLASS_ARGUMENTS alongside JS_CLASS_ARRAY
        //; `len == p->u.array.count` is what keeps a rewritten
        // `arguments.length` on the observable [[Get]] path.
        object.unmappedArgumentsDenseValues()
    else
        null;
    // qjs's third build_arg_list arm: a MAPPED arguments object stores var-refs
    // rather than values, so each element is read through its cell
    // (`*p->u.array.u.var_refs[i]->pvalue`, quickjs.c). Sloppy
    // simple-parameter functions — `f.apply(this, arguments)` forwarding, the
    // RayTrace/Earley shape — produce exactly this class.
    const mapped_cells: ?[]const ?*core.VarRef = if (dense_values == null) blk: {
        const bound = object.fullyBoundMappedArgumentsVarRefs() orelse break :blk null;
        break :blk if (bound.len == length) bound else null;
    } else null;
    if (dense_values) |dense| {
        std.debug.assert(dense.len == length);
        for (dense, 0..) |value, index| {
            values[index] = value;
            initialized += 1;
            rooted_args = values[0..initialized];
        }
    } else if (mapped_cells) |cells| {
        std.debug.assert(cells.len == length);
        for (cells, 0..) |cell, index| {
            values[index] = cell.?.pvalue.*;
            initialized += 1;
            rooted_args = values[0..initialized];
        }
    } else {
        for (0..length) |index| {
            const key = try propertyAtomFromLengthIndex(rt, index);
            defer key.deinit(rt);
            values[index] = try getValueProperty(ctx, output, global, array_value, key.atom, caller_function, caller_frame);
            initialized += 1;
            rooted_args = values[0..initialized];
        }
    }
    return .{
        .rt = rt,
        .values = values,
        .storage = storage,
        .arena_mark = arena_mark,
    };
}

pub noinline fn arrayIteratorMethodRecord(ctx: *core.JSContext, global: *core.Object, receiver: core.JSValue, function_object: *core.Object, method_id: u32) !?core.JSValue {
    const kind: u8 = switch (method_id) {
        @intFromEnum(method_ids.array.PrototypeMethod.keys) => 1,
        @intFromEnum(method_ids.array.PrototypeMethod.values) => 2,
        @intFromEnum(method_ids.array.PrototypeMethod.entries) => 3,
        else => return null,
    };
    if (receiver.is(.null_value) or receiver.is(.undefined_value)) return error.NullishToObject;
    const object_value = if (receiver.is(.object)) receiver else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    const object = core.value_semantics.objectFromValue(object_value) orelse {
        return null;
    };
    if (isTypedArrayPrototypeMethod(function_object)) {
        if (!core.object.isTypedArrayObject(object)) return error.NotATypedArray;
        if (try core.object.typedArrayDetached(object)) return error.TypedArrayOutOfBounds;
        if (try core.object.typedArrayOutOfBounds(object)) return error.TypedArrayOutOfBounds;
    }
    const prototype = try arrayIteratorPrototypeFromContext(ctx, global);
    const iterator = try core.Object.create(ctx.runtime, core.class.ids.array_iterator, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, iterator.gcHeader());
    try iterator.setOptionalValueSlot(ctx.runtime, iterator.iteratorTargetSlot(), object_value);
    iterator.iteratorIndexSlot().* = 0;
    iterator.iteratorKindSlot().* = kind;
    return iterator.value();
}

pub fn arrayPrototypeValuesFromGlobal(rt: *core.JSRuntime, global: *core.Object) !?core.JSValue {
    if (global.cachedRealmValue(rt, .array_prototype_values)) |stored| return stored;
    const prototype = arrayPrototypeFromGlobal(rt, global) orelse return null;
    const values_key = comptime core.atom.predefinedId("values", .string).?;
    return try prototype.getProperty(values_key);
}

pub fn createArrayFromArgs(rt: *core.JSRuntime, global: *core.Object, args: []const core.JSValue) !core.JSValue {
    var rooted_args_buffer = try core.runtime.ValueRootBuffer.initCopy(rt, args);
    defer rooted_args_buffer.deinit();
    const rooted_args = rooted_args_buffer.values();

    const array = try core.Object.createArray(rt, arrayPrototypeFromGlobal(rt, global));
    errdefer core.Object.destroyFromHeader(rt, array.gcHeader());
    try array.reserveDenseArrayElements(rt, @intCast(rooted_args.len));
    for (rooted_args, 0..) |arg, index| {
        const atom_id = core.Atom.taggedInt(@intCast(index));
        // This is a fresh argument-list array, so each item is defined rather
        // than assigned through ordinary Set semantics.
        if (try array.appendDenseArrayDefineIndex(rt, @intCast(index), atom_id, arg)) continue;
        try array.defineOwnProperty(rt, atom_id, core.Descriptor.data(arg, .all));
    }
    return array.value();
}

test "createArrayFromArgs roots direct function bytecode args while creating array" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-create-array-from-args-bytecode-symbol");
    const fb = try bytecode.FunctionBytecode.createPublishedFixture(rt, .{ .cpool_count = 1 }, &.{try rt.symbolValue(symbol_atom)});

    const arg_value = core.JSValue.functionBytecode(&fb.header);
    const args = [_]core.JSValue{arg_value};

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const array_value = try createArrayFromArgs(rt, global, &args);
    const array = objectFromValue(array_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    {
        const stored = try array.getProperty(core.Atom.taggedInt(0));
        try std.testing.expect(stored.same(arg_value));
    }

    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn arrayLengthAssignmentValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
) !core.JSValue {
    if (!object.isArray() or atom_id != core.atom.ids.length or value.isNumber()) return value;
    return arrayLengthDefineValue(ctx, output, global, value);
}

pub fn typedArrayReflectSetReceiverOwn(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver_object: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    if (receiver_object.proxyTarget() != null) {
        // OrdinarySetWithOwnDescriptor steps 2.c-2.e through the receiver's
        // getOwnPropertyDescriptor and defineProperty traps.
        var rooted_value = value;
        var root_frame = core.runtime.rootValues(.{&rooted_value});
        root_frame.activate(ctx.runtime);
        defer root_frame.deactivate(ctx.runtime);
        if (try object_ops.proxyAwareOwnPropertyDescriptor(ctx, output, global, receiver_object, atom_id, caller_function, caller_frame)) |existing| {
            if (existing.kind == .accessor or existing.writable == false) return false;
            const value_desc = core.Descriptor{ .kind = .data, .value = rooted_value, .value_present = true };
            return object_ops.proxyDefineOwnProperty(ctx, output, global, receiver_object, atom_id, value_desc, caller_function, caller_frame);
        }
        return object_ops.proxyDefineOwnProperty(ctx, output, global, receiver_object, atom_id, core.Descriptor.data(rooted_value, .all), caller_function, caller_frame);
    }

    if (core.object.isTypedArrayObject(receiver_object)) {
        const typed_array_desc = core.Descriptor{
            .kind = .data,
            .value = value,
            .value_present = true,
        };
        if (try typedArrayDefineOwnPropertyVm(ctx, output, global, receiver_object, atom_id, typed_array_desc)) |ok| return ok;
    }

    if (try receiver_object.getOwnProperty(ctx.runtime, atom_id)) |current| {
        if (current.kind == .accessor) return false;
        if (current.writable == false) return false;

        const update_desc = core.Descriptor{
            .kind = .data,
            .value = value,
            .value_present = true,
        };
        receiver_object.defineOwnProperty(ctx.runtime, atom_id, update_desc) catch |err| switch (err) {
            error.ReadOnly, error.NotExtensible, error.IncompatibleDescriptor => return false,
            else => return err,
        };
        return true;
    }

    receiver_object.defineOwnProperty(ctx.runtime, atom_id, core.Descriptor.data(value, .all)) catch |err| switch (err) {
        error.ReadOnly, error.NotExtensible, error.IncompatibleDescriptor => return false,
        else => return err,
    };
    return true;
}

/// TypedArray [[Set]] for a canonical numeric key found on the typed array
/// `object`, the target itself or a prototype of the receiver. Null means
/// the key is not numeric and the ordinary [[Set]] owns it.
pub fn typedArrayNumericSet(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    receiver_value: core.JSValue,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?bool {
    const index = switch (try core.object.typedArrayCanonicalNumericIndex(ctx.runtime, atom_id)) {
        .none => return null,
        .invalid => null,
        .index => |index| index,
    };
    if (sameObjectIdentity(receiver_value, object.value())) {
        const coerced = try coerceTypedArrayElementForSet(ctx, output, global, object, value);
        const valid = index orelse return true;
        if (!try core.object.typedArrayIndexValid(ctx.runtime, object, valid)) return true;
        _ = try core.typed_array.typedArraySetElement(ctx.runtime, object, valid, coerced);
        return true;
    }
    const valid = index orelse return true;
    if (!try core.object.typedArrayIndexValid(ctx.runtime, object, valid)) return true;
    const receiver_object = objectFromValue(receiver_value) orelse return false;
    return try typedArrayReflectSetReceiverOwn(ctx, output, global, receiver_object, atom_id, value, caller_function, caller_frame);
}

pub fn typedArrayPrototypeSet(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver_value: core.JSValue,
    prototype: ?*core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?bool {
    var current = prototype;
    while (current) |object| : (current = object.getPrototype()) {
        if (!core.object.isTypedArrayObject(object)) {
            // OrdinarySet stops at the first prototype owning the key (a
            // setter or read-only property) or at a Proxy: that ordinary
            // walk, not the typed array beyond, decides.
            if (object.isProxy() or object.hasOwnProperty(atom_id)) return null;
            continue;
        }
        return try typedArrayNumericSet(ctx, output, global, object, receiver_value, atom_id, value, caller_function, caller_frame);
    }
    return null;
}

pub noinline fn arrayJoinCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    // Native recursion guard: a self-referential array (`a.push(a); a.join()`)
    // recurses join -> element ToString -> join entirely in native frames. QuickJS
    // bounds this at the JS_CallInternal stack guard reached via JS_ToString
    // (InternalError "stack overflow"); zjs's native join loop needs its own check
    // at the entry to match instead of crashing.
    if (ctx.runtime.stack.checkNativeOverflow(0)) return error.StackOverflow;
    if (this_value.is(.null_value) or this_value.is(.undefined_value)) return error.NullishToObject;
    const object_value = if (this_value.is(.object)) this_value else try primitiveObjectForAccess(ctx.runtime, global, this_value);
    const object = core.value_semantics.objectFromValue(object_value) orelse return null;
    const is_typed_method = isTypedArrayPrototypeMethod(function_object);
    if (is_typed_method) {
        if (!core.object.isTypedArrayObject(object)) return error.NotATypedArray;
    } else if (try fastDensePrimitiveArrayJoin(ctx.runtime, object, args)) |joined| return joined;
    const length = try arrayMethodLength(ctx, output, global, object_value, object, is_typed_method, caller_function, caller_frame);
    const separator_value = if (args.len >= 1 and !args[0].is(.undefined_value)) args[0] else try value_ops.createStringValue(ctx.runtime, ",");
    const separator_string = try toStringForAnnexB(ctx, output, global, separator_value, caller_function, caller_frame);
    // The separators alone are a lower bound on the result: fail fast
    // instead of visiting billions of holes toward a string that cannot exist.
    if (length > 1) {
        const separators = std.math.mul(usize, length - 1, core.string.stringValueLen(separator_string)) catch return error.StringTooLong;
        if (separators > core.string.max_length) return error.StringTooLong;
    }
    var separator = std.ArrayList(u8).empty;
    defer separator.deinit(ctx.runtime.nativeAllocator());
    try value_ops.appendRawString(ctx.runtime, &separator, separator_string);

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(ctx.runtime.nativeAllocator());
    for (0..length) |index| {
        try exception_ops.pollNativeLoop(ctx, global);
        if (index != 0) try bytes.appendSlice(ctx.runtime.nativeAllocator(), separator.items);
        const item = if (is_typed_method)
            try core.typed_array.typedArrayGetIndex(ctx.runtime, object, @intCast(index))
        else blk: {
            const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
            defer key.deinit(ctx.runtime);
            break :blk try getValueProperty(ctx, output, global, object_value, key.atom, caller_function, caller_frame);
        };
        if (!item.is(.undefined_value) and !item.is(.null_value)) {
            const string_item = try toStringForAnnexB(ctx, output, global, item, caller_function, caller_frame);
            try value_ops.appendValueString(ctx.runtime, &bytes, string_item);
        }
    }
    return try value_ops.createStringValue(ctx.runtime, bytes.items);
}

pub fn fastDensePrimitiveArrayJoin(
    rt: *core.JSRuntime,
    object: *core.Object,
    args: []const core.JSValue,
) !?core.JSValue {
    if (!object.isArray() or object.hasExoticMethods() or object.arrayElementStorageMode() != .dense) return null;
    if (object.shape_ref.prop_count != 0) return null;

    const length: usize = @intCast(object.arrayLength());
    const elements = object.arrayElements();
    if (length > elements.len) return null;

    var separator = std.ArrayList(u8).empty;
    defer separator.deinit(rt.nativeAllocator());
    if (args.len == 0 or args[0].is(.undefined_value)) {
        try separator.append(rt.nativeAllocator(), ',');
    } else if (args[0].isString()) {
        try value_ops.appendRawString(rt, &separator, args[0]);
    } else {
        return null;
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    for (0..length) |index| {
        try rt.interrupt.pollNativeWork();
        const item = elements[index];
        if (!canFastJoinPrimitive(item)) return null;
        if (index != 0) try bytes.appendSlice(rt.nativeAllocator(), separator.items);
        if (!item.is(.undefined_value) and !item.is(.null_value)) try value_ops.appendValueString(rt, &bytes, item);
    }
    return try value_ops.createStringValue(rt, bytes.items);
}

pub fn canFastJoinPrimitive(value: core.JSValue) bool {
    return value.is(.undefined_value) or
        value.is(.null_value) or
        value.isString() or
        value.isNumber() or
        value.is(.boolean) or
        value.isBigInt();
}

pub fn objectEntryArrayValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object_value: core.JSValue,
    key: core.Atom,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var value = core.JSValue.undefinedValue();
    var entry_value = core.JSValue.undefinedValue();
    var key_value = core.JSValue.undefinedValue();

    var root_values = [_]*core.JSValue{
        &value,
        &entry_value,
        &key_value,
    };
    var root_frame = core.runtime.ValueRootFrame{
        .values = &root_values,
    };
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    value = try getValueProperty(ctx, output, global, object_value, key, caller_function, caller_frame);

    const entry = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
    entry_value = entry.value();

    key_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, key);

    // qjs js_create_array: a pre-sized dense fast array, not two
    // per-element createDataPropertyOrThrow (atomFromUInt32 + Descriptor + define).
    // The slice alloc precedes the dups; key_value/value stay rooted via root_frame.
    // TGC S4-b: `.array_storage` GC cell.
    const elements = try core.Object.createArrayStorageSlice(ctx.runtime, 2);
    elements[0] = key_value;
    elements[1] = value;
    entry.adoptDenseArrayElementsAssumingEmpty(ctx.runtime, elements);
    entry.flags.may_have_indexed_properties = true;

    return entry_value;
}

test "objectEntryArrayValue roots direct symbol value while creating entry array" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try zjs_vm.contextGlobal(ctx);

    const source = try core.Object.create(rt, core.class.ids.object, objectPrototypeFromGlobal(rt, global));
    const key = try rt.internAtom("entry");
    const symbol_atom = try rt.atoms.newValueSymbol("gc-qjs-object-entry-symbol");
    const symbol_value = try rt.symbolValue(symbol_atom);
    try source.defineOwnProperty(rt, key, core.Descriptor.data(symbol_value, .all));

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const entry_value = try objectEntryArrayValue(ctx, null, global, source.value(), key, null, null);
    const entry = try property_ops.expectObject(entry_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    {
        const stored = try entry.getProperty(core.Atom.taggedInt(1));
        try std.testing.expectEqual(@as(?core.Atom, symbol_atom), stored.asSymbolAtom());
    }

    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "objectEnumerableOwnPropertiesCall roots direct symbol values while creating output array" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try zjs_vm.contextGlobal(ctx);

    const source = try core.Object.create(rt, core.class.ids.object, objectPrototypeFromGlobal(rt, global));
    const key = try rt.internAtom("value");
    const symbol_atom = try rt.atoms.newValueSymbol("gc-qjs-object-values-symbol");
    const symbol_value = try rt.symbolValue(symbol_atom);
    try source.defineOwnProperty(rt, key, core.Descriptor.data(symbol_value, .all));

    const args = [_]core.JSValue{source.value()};
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const out_value = (try objectEnumerableOwnPropertiesCall(ctx, null, global, &args, .values, null, null)) orelse return error.TypeError;
    const out = try property_ops.expectObject(out_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    {
        const stored = try out.getProperty(core.Atom.taggedInt(0));
        try std.testing.expectEqual(@as(?core.Atom, symbol_atom), stored.asSymbolAtom());
    }

    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn typedArrayValidateConstructArgsPreAllocate(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !void {
    if (args.len < 1) return;
    const first = args[0];
    if (!first.is(.object)) {
        _ = try typedArrayConstructToIndex(ctx, output, global, first);
        return;
    }
    // A buffer's offset and length convert after the prototype lookup
    // (AllocateTypedArray, then InitializeTypedArrayFromArrayBuffer).
}

pub fn arrayLengthDefineValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !core.JSValue {
    // Each conversion roots its own inputs. The outer operation must also
    // receive relocation repairs before it starts the second conversion.
    var values = [_]core.JSValue{ global.value(), value };
    const live: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &live }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    // ArraySetLength steps 3-5: newLen = ToUint32(value) and
    // numberLen = ToNumber(value) are two conversions; a value whose two
    // conversions disagree (or that is not a uint32) is a RangeError.
    const first_primitive = try toPrimitiveForNumber(ctx, output, objectFromValue(values[0]).?, values[1]);
    const first = (try value_ops.toNumberValue(ctx.runtime, first_primitive)).asNumber().?;
    const new_len = value_ops.toUint32Number(first);
    const second_primitive = try toPrimitiveForNumber(ctx, output, objectFromValue(values[0]).?, values[1]);
    const number_len = (try value_ops.toNumberValue(ctx.runtime, second_primitive)).asNumber().?;
    if (@as(f64, @floatFromInt(new_len)) != number_len) {
        return exception_ops.throwRangeErrorMessage(ctx, objectFromValue(values[0]).?, "invalid array length");
    }
    return core.JSValue.number(number_len);
}

pub fn typedArrayCanonicalGet(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) !?core.JSValue {
    switch (try core.object.typedArrayCanonicalNumericIndex(rt, atom_id)) {
        .none => return null,
        .invalid => return core.JSValue.undefinedValue(),
        .index => |index| return try core.typed_array.typedArrayGetIndex(rt, object, index),
    }
}

pub fn typedArrayCanonicalOwnDescriptor(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) !?core.Descriptor {
    if (!core.object.isTypedArrayObject(object)) return null;
    switch (try core.object.typedArrayCanonicalNumericIndex(rt, atom_id)) {
        .none => return null,
        .invalid => return null,
        .index => |index| {
            const length = try core.object.typedArrayLength(rt, object);
            if (index >= length) return null;
            const value = try core.typed_array.typedArrayGetIndex(rt, object, index);
            return core.Descriptor.data(value, .all);
        },
    }
}

/// Existence-only sibling of `typedArrayCanonicalOwnDescriptor` for the
/// desc==NULL fast-array path. Returns presence
/// (`index < length`) for an in-bounds canonical numeric index WITHOUT
/// materializing the element value. `null` means "this key is not a settled
/// typed-array verdict -- fall through to the ordinary own-property probe",
/// matching `typedArrayCanonicalOwnDescriptor` returning null for the
/// `.none`/`.invalid`/out-of-range cases (those then resolve to FALSE via
/// the regular cascade, exactly as in the descriptor path).
pub fn typedArrayCanonicalIndexExists(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) !?bool {
    if (!core.object.isTypedArrayObject(object)) return null;
    switch (try core.object.typedArrayCanonicalNumericIndex(rt, atom_id)) {
        .none => return null,
        .invalid => return null,
        .index => |index| {
            const length = try core.object.typedArrayLength(rt, object);
            if (index >= length) return null;
            return true;
        },
    }
}

pub fn coerceTypedArrayElementInput(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !core.JSValue {
    return if (value.is(.object))
        try toPrimitiveForNumber(ctx, output, global, value)
    else
        value;
}

pub fn coerceTypedArrayElementForSet(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    value: core.JSValue,
) !core.JSValue {
    const coerced = try coerceTypedArrayElementInput(ctx, output, global, value);
    try core.typed_array.typedArrayCoerceElementValue(ctx.runtime, object, coerced);
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
    if (!core.object.isTypedArrayObject(object)) return null;
    switch (try core.object.typedArrayCanonicalNumericIndex(ctx.runtime, atom_id)) {
        .none => return null,
        .invalid => return false,
        .index => |index| {
            if (desc.kind == .accessor or desc.configurable == false or desc.enumerable == false or desc.writable == false) return false;
            if (!try core.object.typedArrayIndexValid(ctx.runtime, object, index)) return false;
            if (desc.value_present) {
                const coerced = try coerceTypedArrayElementInput(ctx, output, global, desc.value);
                if (!try core.object.typedArrayIndexValid(ctx.runtime, object, index)) return true;
                _ = try core.typed_array.typedArraySetElement(ctx.runtime, object, index, coerced);
            }
            return true;
        },
    }
}

pub fn typedArrayCanonicalHas(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) ?bool {
    if (!core.object.isTypedArrayObject(object)) return null;
    switch (core.object.typedArrayCanonicalNumericIndex(rt, atom_id) catch return false) {
        .none => return null,
        .invalid => return false,
        .index => |index| {
            const length = core.object.typedArrayLength(rt, object) catch return false;
            return index < length;
        },
    }
}

pub fn typedArrayCanonicalDelete(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) !?bool {
    if (!core.object.isTypedArrayObject(object)) return null;
    switch (try core.object.typedArrayCanonicalNumericIndex(rt, atom_id)) {
        .none => return null,
        .invalid => return true,
        .index => |index| {
            const length = core.object.typedArrayLength(rt, object) catch return true;
            return index >= length;
        },
    }
}

// Array length/index helpers (moved from the VM call runtime).

pub fn lengthIndexValue(index: usize) core.JSValue {
    if (index <= @as(usize, @intCast(std.math.maxInt(i32)))) return core.JSValue.int32(@intCast(index));
    return core.JSValue.float64(@floatFromInt(index));
}

/// TGC S3 §2.2 root G: a frame-resident atom box.
///
/// `owned` is true only for an index past `max_int_atom` (>2^31), where the
/// key had to be interned from decimal bytes instead of being a tagged int.
/// The box is returned by value through ~60 call sites and then held across
/// arbitrary JS, so an `AtomRootFrame` would have to be activated at every one
/// of them -- a signature change the spec explicitly prices as too expensive.
/// The owned arm instead takes an explicit pin (the same counter §2.5 gives
/// embedder handles: "a root the tracer cannot see"), released by `deinit`,
/// which every call site already pairs. Cost on the tagged-int path is zero.
pub const LengthIndexAtom = struct {
    atom: core.Atom,
    owned: bool,

    pub fn deinit(self: LengthIndexAtom, rt: *core.JSRuntime) void {
        if (self.owned) {
            rt.atoms.unpinForHost(self.atom);
        }
    }
};

// ----- Array constructor/prototype records and direct builtin bodies -----
//
// Receiver and argument values are borrowed; returned JSValues are owned.
// `RootedValueCopies` copies value bits solely to give the GC stable root
// addresses: it frees its buffers but never frees the caller-owned values.
// TypedArray/ArrayBuffer machinery and VM-generic array algorithms stay behind
// their existing module seams.
const core_array = @import("../core/array.zig");
const HostError = @import("exception_ops.zig").HostError;
/// A native copy of borrowed values, rooted as one `.mutable` slice window.
/// A frame of per-element `.values` pointers would not link in production
/// (scalar frames are left to the stack scan, which cannot see this heap
/// copy).
const RootedValueCopies = struct {
    values: []core.JSValue,

    fn init(rt: *core.JSRuntime, source: []const core.JSValue) !RootedValueCopies {
        const values = try rt.nativeAllocator().alloc(core.JSValue, source.len);
        @memcpy(values, source);
        return .{ .values = values };
    }

    fn deinit(self: RootedValueCopies, rt: *core.JSRuntime) void {
        rt.nativeAllocator().free(self.values);
    }
};
pub const StaticMethod = core.host_function.builtin_method_ids.array.StaticMethod;
pub const PrototypeMethod = core.host_function.builtin_method_ids.array.PrototypeMethod;
pub const ConstructorMethod = core.host_function.builtin_method_ids.array.ConstructorMethod;
pub const TypedArrayMethod = core.host_function.builtin_method_ids.array.TypedArrayMethod;
pub fn staticMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "from")) return @intFromEnum(StaticMethod.from);
    if (std.mem.eql(u8, name, "fromAsync")) return @intFromEnum(StaticMethod.from_async);
    if (std.mem.eql(u8, name, "isArray")) return @intFromEnum(StaticMethod.is_array);
    if (std.mem.eql(u8, name, "of")) return @intFromEnum(StaticMethod.of);
    return null;
}

pub fn prototypeMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "toString")) return @intFromEnum(PrototypeMethod.to_string);
    if (std.mem.eql(u8, name, "toLocaleString")) return @intFromEnum(PrototypeMethod.to_locale_string);
    if (std.mem.eql(u8, name, "map")) return @intFromEnum(PrototypeMethod.map);
    if (std.mem.eql(u8, name, "filter")) return @intFromEnum(PrototypeMethod.filter);
    if (std.mem.eql(u8, name, "reduce")) return @intFromEnum(PrototypeMethod.reduce);
    if (std.mem.eql(u8, name, "reduceRight")) return @intFromEnum(PrototypeMethod.reduce_right);
    if (std.mem.eql(u8, name, "forEach")) return @intFromEnum(PrototypeMethod.for_each);
    if (std.mem.eql(u8, name, "push")) return @intFromEnum(PrototypeMethod.push);
    if (std.mem.eql(u8, name, "pop")) return @intFromEnum(PrototypeMethod.pop);
    if (std.mem.eql(u8, name, "shift")) return @intFromEnum(PrototypeMethod.shift);
    if (std.mem.eql(u8, name, "unshift")) return @intFromEnum(PrototypeMethod.unshift);
    if (std.mem.eql(u8, name, "some")) return @intFromEnum(PrototypeMethod.some);
    if (std.mem.eql(u8, name, "every")) return @intFromEnum(PrototypeMethod.every);
    if (std.mem.eql(u8, name, "find")) return @intFromEnum(PrototypeMethod.find);
    if (std.mem.eql(u8, name, "findIndex")) return @intFromEnum(PrototypeMethod.find_index);
    if (std.mem.eql(u8, name, "findLast")) return @intFromEnum(PrototypeMethod.find_last);
    if (std.mem.eql(u8, name, "findLastIndex")) return @intFromEnum(PrototypeMethod.find_last_index);
    if (std.mem.eql(u8, name, "includes")) return @intFromEnum(PrototypeMethod.includes);
    if (std.mem.eql(u8, name, "indexOf")) return @intFromEnum(PrototypeMethod.index_of);
    if (std.mem.eql(u8, name, "lastIndexOf")) return @intFromEnum(PrototypeMethod.last_index_of);
    if (std.mem.eql(u8, name, "at")) return @intFromEnum(PrototypeMethod.at);
    if (std.mem.eql(u8, name, "copyWithin")) return @intFromEnum(PrototypeMethod.copy_within);
    if (std.mem.eql(u8, name, "fill")) return @intFromEnum(PrototypeMethod.fill);
    if (std.mem.eql(u8, name, "slice")) return @intFromEnum(PrototypeMethod.slice);
    if (std.mem.eql(u8, name, "splice")) return @intFromEnum(PrototypeMethod.splice);
    if (std.mem.eql(u8, name, "join")) return @intFromEnum(PrototypeMethod.join);
    if (std.mem.eql(u8, name, "concat")) return @intFromEnum(PrototypeMethod.concat);
    if (std.mem.eql(u8, name, "reverse")) return @intFromEnum(PrototypeMethod.reverse);
    if (std.mem.eql(u8, name, "sort")) return @intFromEnum(PrototypeMethod.sort);
    if (std.mem.eql(u8, name, "flat")) return @intFromEnum(PrototypeMethod.flat);
    if (std.mem.eql(u8, name, "flatMap")) return @intFromEnum(PrototypeMethod.flat_map);
    if (std.mem.eql(u8, name, "toReversed")) return @intFromEnum(PrototypeMethod.to_reversed);
    if (std.mem.eql(u8, name, "toSorted")) return @intFromEnum(PrototypeMethod.to_sorted);
    if (std.mem.eql(u8, name, "toSpliced")) return @intFromEnum(PrototypeMethod.to_spliced);
    if (std.mem.eql(u8, name, "with")) return @intFromEnum(PrototypeMethod.with_);
    if (std.mem.eql(u8, name, "keys")) return @intFromEnum(PrototypeMethod.keys);
    if (std.mem.eql(u8, name, "values")) return @intFromEnum(PrototypeMethod.values);
    if (std.mem.eql(u8, name, "entries")) return @intFromEnum(PrototypeMethod.entries);
    return null;
}

/// Most Array records use `arrayCall`, which switches on the per-record `magic`
/// (== domain-local id) and forwards to `builtin_glue.arrayNativeRecord`.
/// Array.push, Array.pop and Array.splice instead use per-method functions
/// matching their qjs function-list entries. The %TypedArray% statics and
/// prototype methods are records in this domain too (`typed_array_entries`);
/// they run the Array bodies, which apply the typed-array receiver checks when
/// `isTypedArrayPrototypeMethod` holds for the called function. Property
/// installation resolves ids through `staticMethodId` / `prototypeMethodId` /
/// `typedArrayMethodId`.
pub const internal_entries = arrayEntries: {
    const Entry = core.host_function.InternalEntry;
    break :arrayEntries [_]Entry{
        // Array constructor (`new Array(...)` / `Array(...)`). Construct-capable
        // so the construct dispatch path routes through `arrayCall`'s construct
        // branch; the Array constructor object is not installed with this native
        // id (its call-as-function/species recognition stays on the existing
        // name + `arrayBuiltinMarker` paths), so this record is reached only
        // through `builtin_dispatch.callConstructRecord` with an explicit ref.
        arrayConstructorEntry("Array", 1, @intFromEnum(ConstructorMethod.construct)),
        // Array static methods.
        arrayEntry("from", 1, @intFromEnum(StaticMethod.from)),
        arrayEntry("fromAsync", 1, @intFromEnum(StaticMethod.from_async)),
        arrayEntry("isArray", 1, @intFromEnum(StaticMethod.is_array)),
        arrayEntry("of", 0, @intFromEnum(StaticMethod.of)),
        // Array.prototype methods.
        arrayEntry("toString", 0, @intFromEnum(PrototypeMethod.to_string)),
        arrayEntry("toLocaleString", 0, @intFromEnum(PrototypeMethod.to_locale_string)),
        arrayEntry("map", 1, @intFromEnum(PrototypeMethod.map)),
        arrayEntry("filter", 1, @intFromEnum(PrototypeMethod.filter)),
        arrayEntry("reduce", 1, @intFromEnum(PrototypeMethod.reduce)),
        arrayEntry("reduceRight", 1, @intFromEnum(PrototypeMethod.reduce_right)),
        arrayEntry("forEach", 1, @intFromEnum(PrototypeMethod.for_each)),
        arrayPushEntry("push", 1, @intFromEnum(PrototypeMethod.push)),
        arrayPopEntry("pop", 0, @intFromEnum(PrototypeMethod.pop)),
        arrayEntry("shift", 0, @intFromEnum(PrototypeMethod.shift)),
        arrayEntry("unshift", 1, @intFromEnum(PrototypeMethod.unshift)),
        arrayEntry("some", 1, @intFromEnum(PrototypeMethod.some)),
        arrayEntry("every", 1, @intFromEnum(PrototypeMethod.every)),
        arrayEntry("find", 1, @intFromEnum(PrototypeMethod.find)),
        arrayEntry("findIndex", 1, @intFromEnum(PrototypeMethod.find_index)),
        arrayEntry("findLast", 1, @intFromEnum(PrototypeMethod.find_last)),
        arrayEntry("findLastIndex", 1, @intFromEnum(PrototypeMethod.find_last_index)),
        arrayEntry("includes", 1, @intFromEnum(PrototypeMethod.includes)),
        arrayEntry("indexOf", 1, @intFromEnum(PrototypeMethod.index_of)),
        arrayEntry("lastIndexOf", 1, @intFromEnum(PrototypeMethod.last_index_of)),
        arrayEntry("at", 1, @intFromEnum(PrototypeMethod.at)),
        arrayEntry("copyWithin", 2, @intFromEnum(PrototypeMethod.copy_within)),
        arrayEntry("fill", 1, @intFromEnum(PrototypeMethod.fill)),
        arrayEntry("slice", 2, @intFromEnum(PrototypeMethod.slice)),
        arraySpliceEntry("splice", 2, @intFromEnum(PrototypeMethod.splice)),
        arrayEntry("join", 1, @intFromEnum(PrototypeMethod.join)),
        arrayEntry("concat", 1, @intFromEnum(PrototypeMethod.concat)),
        arrayEntry("reverse", 0, @intFromEnum(PrototypeMethod.reverse)),
        arrayEntry("sort", 1, @intFromEnum(PrototypeMethod.sort)),
        arrayEntry("flat", 0, @intFromEnum(PrototypeMethod.flat)),
        arrayEntry("flatMap", 1, @intFromEnum(PrototypeMethod.flat_map)),
        arrayEntry("toReversed", 0, @intFromEnum(PrototypeMethod.to_reversed)),
        arrayEntry("toSorted", 1, @intFromEnum(PrototypeMethod.to_sorted)),
        arrayEntry("toSpliced", 2, @intFromEnum(PrototypeMethod.to_spliced)),
        arrayEntry("with", 2, @intFromEnum(PrototypeMethod.with_)),
        arrayEntry("keys", 0, @intFromEnum(PrototypeMethod.keys)),
        arrayEntry("values", 0, @intFromEnum(PrototypeMethod.values)),
        arrayEntry("entries", 0, @intFromEnum(PrototypeMethod.entries)),
    } ++ typed_array_entries;
};

const typed_array_entries = [_]core.host_function.InternalEntry{
    typedArrayEntry("from", 1, .from),
    typedArrayEntry("of", 0, .of),
    typedArrayEntry("toLocaleString", 0, .to_locale_string),
    typedArrayEntry("map", 1, .map),
    typedArrayEntry("filter", 1, .filter),
    typedArrayEntry("reduce", 1, .reduce),
    typedArrayEntry("reduceRight", 1, .reduce_right),
    typedArrayEntry("forEach", 1, .for_each),
    typedArrayEntry("some", 1, .some),
    typedArrayEntry("every", 1, .every),
    typedArrayEntry("find", 1, .find),
    typedArrayEntry("findIndex", 1, .find_index),
    typedArrayEntry("findLast", 1, .find_last),
    typedArrayEntry("findLastIndex", 1, .find_last_index),
    typedArrayEntry("includes", 1, .includes),
    typedArrayEntry("indexOf", 1, .index_of),
    typedArrayEntry("lastIndexOf", 1, .last_index_of),
    typedArrayEntry("at", 1, .at),
    typedArrayEntry("copyWithin", 2, .copy_within),
    typedArrayEntry("fill", 1, .fill),
    typedArrayEntry("slice", 2, .slice),
    typedArrayEntry("join", 1, .join),
    typedArrayEntry("reverse", 0, .reverse),
    typedArrayEntry("sort", 1, .sort),
    typedArrayEntry("toReversed", 0, .to_reversed),
    typedArrayEntry("toSorted", 1, .to_sorted),
    typedArrayEntry("with", 2, .with_),
    typedArrayEntry("keys", 0, .keys),
    typedArrayEntry("values", 0, .values),
    typedArrayEntry("entries", 0, .entries),
    typedArrayEntry("set", 1, .set),
    typedArrayEntry("subarray", 2, .subarray),
};

fn typedArrayEntry(comptime name: []const u8, comptime length: u8, comptime method: TypedArrayMethod) core.host_function.InternalEntry {
    return arrayEntry(name, length, @intFromEnum(method));
}

/// Record id of the %TypedArray% static (`is_static`) or prototype method
/// named `name`.
pub fn typedArrayMethodId(name: []const u8, is_static: bool) ?u32 {
    for (typed_array_entries) |entry| {
        const method: TypedArrayMethod = @enumFromInt(entry.id);
        const entry_is_static = method == .from or method == .of;
        if (entry_is_static == is_static and std.mem.eql(u8, entry.name, name)) return entry.id;
    }
    return null;
}
fn arrayEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return arrayEntryWithHandler(name, length, id, &arrayCall);
}

fn arrayPushEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    var entry = arrayEntryWithHandler(name, length, id, &arrayPushCallNative);
    // exec_direct: js_call_c_function has no env
    // side-channel. The NMFD assume terminal then blr's this ABI and
    // skips TLS / typed-cproto / arrayPushCallNative (charCodeAt/apply shape).
    entry.managed = &arrayPushDirect;
    return entry;
}

fn arrayPopEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return arrayEntryWithHandler(name, length, id, &arrayPopCallNative);
}

fn arraySpliceEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    var entry = arrayEntryWithHandler(name, length, id, &arraySpliceCallNative);
    entry.managed = &arraySpliceDirect;
    return entry;
}

const arrayEntryWithHandler = builtin_dispatch.entryWithHandler;

test "Array.push has a dedicated native record handler" {
    var found = false;
    for (internal_entries) |entry| {
        if (entry.id != @intFromEnum(PrototypeMethod.push)) continue;
        found = true;
        try std.testing.expect(core.host_function.genericMagicHandler(entry).? == &arrayPushCallNative);
        try std.testing.expect(entry.managed != null);
        try std.testing.expect(entry.managed.? == &arrayPushDirect);
        try std.testing.expect(!entry.forwards_call);
    }
    try std.testing.expect(found);
}

test "Array.splice has a dedicated native record handler" {
    var found = false;
    for (internal_entries) |entry| {
        if (entry.id != @intFromEnum(PrototypeMethod.splice)) continue;
        found = true;
        try std.testing.expect(core.host_function.genericMagicHandler(entry).? == &arraySpliceCallNative);
        try std.testing.expect(entry.managed != null);
        try std.testing.expect(entry.managed.? == &arraySpliceDirect);
        try std.testing.expect(!entry.forwards_call);
    }
    try std.testing.expect(found);
}

test "Array.pop has a dedicated native record handler" {
    var pop_call: ?core.host_function.NativeGenericMagicFn = null;
    for (internal_entries) |entry| {
        if (entry.id == @intFromEnum(PrototypeMethod.pop)) pop_call = core.host_function.genericMagicHandler(entry);
    }
    try std.testing.expect(pop_call != null);
    try std.testing.expect(pop_call.? == &arrayPopCallNative);
}

/// The Array constructor record: construct-capable so `new Array(...)` (and
/// `Array(...)` called as a function, routed with `is_constructor == false`)
/// reach `arrayCall`'s construct branch.
fn arrayConstructorEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{
        .name = name,
        .length = length,
        .id = id,
        .magic = @intCast(id),
        .cproto = .constructor_or_func_magic,
        .native_function = builtin_dispatch.constructorOrFunctionMagic(&arrayCall),
    };
}

/// Native entry for the Array constructor and statics, the prototype methods
/// other than push/pop/splice, and the %TypedArray% records, dispatched on
/// the builtin id in `native_magic`.
fn arrayCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    // Observable functions take their global only from the atomic call view.
    // A null function object is the explicit synthetic constructor/body reuse
    // used by the construct and fast algorithm paths.
    const call_global: ?*core.Object = if (host_call.func_obj != null) blk: {
        const realm = try builtin_dispatch.callableRealm(host_call);
        std.debug.assert(realm.realm == host_call.ctx);
        break :blk realm.global;
    } else host_call.global;
    const id: u32 = host_call.magic;
    if (id == @intFromEnum(ConstructorMethod.construct)) {
        // `new Array(...)` arrives through the construct record path with
        // `is_constructor` set and the resolved instance prototype in
        // `new_target`. `Array(...)` called as a function behaves identically
        // (per spec) and dispatches on the constructor kind instead of this
        // id; the `is_constructor == false` branch falls back to the realm's
        // default Array.prototype (null when no realm global is threaded — e.g.
        // a bare `Reflect.construct` against an unwired native function — which
        // yields the engine default prototype). The construct branch runs before
        // the `global` requirement below because it needs no realm global, just
        // like the Date/RegExp/String construct records. RangeError surfaces
        // unchanged for an invalid `new Array(length)`.
        const prototype = if (host_call.is_constructor)
            host_call.new_target
        else if (call_global) |global|
            arrayPrototypeFromGlobal(host_call.ctx.runtime, global)
        else
            null;
        return constructConstructorWithPrototype(host_call.ctx.runtime, host_call.args, prototype) catch |err| switch (err) {
            error.RangeError => if (call_global) |global|
                exception_ops.throwRangeErrorMessage(host_call.ctx, global, "invalid array length")
            else
                error.RangeError,
            else => return err,
        };
    }
    const global = call_global orelse return error.TypeError;
    if (try builtin_glue.arrayNativeRecord(
        host_call.ctx,
        host_call.output,
        global,
        host_call.this_value,
        host_call.func_obj,
        host_call.magic,
        host_call.args,
        builtin_dispatch.callerBytecode(host_call),
        builtin_dispatch.callerFrame(host_call),
    )) |value| return value;
    return error.TypeError;
}

/// Per-method function pointer for Array.prototype.push. This is the same
/// full-context ABI as the shared array record handler, so proxy/accessor and
/// cross-realm behavior keep their existing output/global/caller threading;
/// only the magic-switch and redundant function-object recognition disappear.
fn arrayPushCallNative(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const realm = try builtin_dispatch.callableRealm(host_call);
    std.debug.assert(realm.realm == host_call.ctx);
    return (try arrayPushCallImpl(
        host_call.ctx,
        host_call.output,
        realm.global,
        host_call.this_value,
        host_call.args,
        builtin_dispatch.callerBytecode(host_call),
        builtin_dispatch.callerFrame(host_call),
    )) orelse error.TypeError;
}

fn arrayPushDirect(
    ctx: *core.JSContext,
    this_value: core.JSValue,
    argv: [*]const core.JSValue,
    argc: u32,
    _: *const core.NativeEntry,
    _: ?*core.Object,
) callconv(.c) core.JSValue {
    const args = argv[0..argc];
    const global = ctx.global orelse return builtin_dispatch.hostErrorToValue(ctx, null, error.InvalidBuiltinRegistry);
    const caller = builtin_dispatch.vmCallerView(ctx);
    const output = caller.output;
    const caller_function = caller.caller_function;
    const caller_frame = caller.caller_frame;
    // Hot arm returns NativeBits (x0+x1) like qjs JS_NewInt32. Miss/OOM
    // falls through to the existing impl (ToObject + generic Set).
    if (tryFastArrayPush(ctx.runtime, this_value, args)) |maybe_len| {
        if (maybe_len) |new_len| return (core.JSValue.int32(new_len));
    } else |err| {
        return builtin_dispatch.hostErrorToValue(ctx, global, err);
    }
    return builtin_dispatch.hostResultToValue(ctx, arrayPushDirectHost(
        ctx,
        output,
        global,
        this_value,
        args,
        caller_function,
        caller_frame,
    ));
}

fn arrayPushDirectHost(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) HostError!core.JSValue {
    return (try arrayPushCallImpl(
        ctx,
        output,
        global,
        this_value,
        args,
        caller_function,
        caller_frame,
    )) orelse error.TypeError;
}

fn arraySpliceCallNative(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const realm = try builtin_dispatch.callableRealm(host_call);
    std.debug.assert(realm.realm == host_call.ctx);
    return (try arraySpliceCallImpl(
        host_call.ctx,
        host_call.output,
        realm.global,
        host_call.this_value,
        host_call.args,
    )) orelse error.TypeError;
}

fn arraySpliceDirect(
    ctx: *core.JSContext,
    this_value: core.JSValue,
    argv: [*]const core.JSValue,
    argc: u32,
    _: *const core.NativeEntry,
    _: ?*core.Object,
) callconv(.c) core.JSValue {
    const args = argv[0..argc];
    const global = ctx.global orelse return builtin_dispatch.hostErrorToValue(ctx, null, error.InvalidBuiltinRegistry);
    const caller = builtin_dispatch.vmCallerView(ctx);
    const output = caller.output;
    return builtin_dispatch.hostResultToValue(ctx, arraySpliceDirectHost(
        ctx,
        output,
        global,
        this_value,
        args,
    ));
}

fn arraySpliceDirectHost(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
) HostError!core.JSValue {
    return (try arraySpliceCallImpl(
        ctx,
        output,
        global,
        this_value,
        args,
    )) orelse error.TypeError;
}

/// Per-method function pointer for Array.prototype.pop. Like qjs
/// `js_array_pop(..., shift = 0)`, it enters the complete pop body directly;
/// the body itself retains the dense-array arm and the observable generic
/// length/property/delete fallback.
fn arrayPopCallNative(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const realm = try builtin_dispatch.callableRealm(host_call);
    std.debug.assert(realm.realm == host_call.ctx);
    return (try arrayPopCallImpl(
        host_call.ctx,
        host_call.output,
        realm.global,
        host_call.this_value,
        builtin_dispatch.callerBytecode(host_call),
        builtin_dispatch.callerFrame(host_call),
    )) orelse error.TypeError;
}

/// Proxy-aware `Array.isArray` (IsArray, §7.2.2), owned by `core/array.zig`.
pub fn construct(rt: *core.JSRuntime, values: []const core.JSValue) !core.JSValue {
    return constructWithPrototype(rt, values, null);
}

pub fn constructConstructorWithPrototype(rt: *core.JSRuntime, args: []const core.JSValue, prototype: ?*core.Object) !core.JSValue {
    if (args.len == 1 and args[0].isNumber()) {
        const length = arrayLengthFromNumber(args[0]) orelse return error.RangeError;
        const object = try core.Object.createArray(rt, prototype);
        errdefer core.Object.destroyFromHeader(rt, object.gcHeader());
        // new Array(n): fast array with count=0, length=n, slots [0,n) holes.
        // Faithful to js_array_constructor -> set_array_length;
        // no sparse conversion. This is the holey-prealloc unblock.
        object.setArrayLength(length);
        return object.value();
    }
    return constructWithPrototype(rt, args, prototype);
}

/// Shared body of `construct` / `constructConstructorWithPrototype`. Reached
/// from production only through the latter; the direct entry point is exercised
/// by the GC-reentrancy integration tests in `tests/exec.zig`.
pub fn constructWithPrototype(rt: *core.JSRuntime, values: []const core.JSValue, prototype: ?*core.Object) !core.JSValue {
    const rooted = try RootedValueCopies.init(rt, values);
    defer rooted.deinit(rt);
    const root_slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &rooted.values }};
    var root_frame = core.runtime.ValueRootFrame{
        .slices = &root_slices,
    };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const object = try core.Object.createArray(rt, prototype);
    errdefer core.Object.destroyFromHeader(rt, object.gcHeader());

    try object.reserveDenseArrayElements(rt, @intCast(rooted.values.len));
    for (rooted.values, 0..) |value, index| {
        const atom_id = core.Atom.taggedInt(@intCast(index));
        // Array constructor arguments are fresh own data properties;
        // inherited indexed setters do not participate.
        if (try object.appendDenseArrayDefineIndex(rt, @intCast(index), atom_id, value)) continue;
        try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(value, .all));
    }
    return object.value();
}

fn arrayLengthFromNumber(value: core.JSValue) ?u32 {
    const number: f64 = if (value.as(.int)) |int_value|
        @floatFromInt(int_value)
    else
        value.as(.float64) orelse return null;
    if (!std.math.isFinite(number)) return null;
    if (number < 0 or number > @as(f64, @floatFromInt(core_array.max_array_length))) return null;
    const truncated = @trunc(number);
    if (truncated != number) return null;
    return @intFromFloat(truncated);
}

test "array iteratorResult roots direct function bytecode value while creating result" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-array-iterator-result-bytecode-symbol");
    const fb = try core.FunctionBytecode.createPublishedFixture(rt, .{ .cpool_count = 1 }, &.{try rt.symbolValue(symbol_atom)});

    const result_value = core.JSValue.functionBytecode(&fb.header);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const iterator_result_value = try iterator_ops.createIteratorResult(rt, null, result_value, false);
    const iterator_result = objectFromValue(iterator_result_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    {
        const stored = try iterator_result.getProperty(core.atom.predefinedId("value", .string).?);
        try std.testing.expect(stored.same(result_value));
    }

    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "array constructWithPrototype roots direct function bytecode elements while creating array" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-array-construct-bytecode-symbol");
    const fb = try core.FunctionBytecode.createPublishedFixture(rt, .{ .cpool_count = 1 }, &.{try rt.symbolValue(symbol_atom)});

    const element_value = core.JSValue.functionBytecode(&fb.header);
    const values = [_]core.JSValue{element_value};

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const array_value = try constructWithPrototype(rt, &values, null);
    const array = try expectArray(array_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    {
        const stored = try array.getProperty(core.Atom.taggedInt(0));
        try std.testing.expect(stored.same(element_value));
    }

    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub const expectArray = core_array.expectArray;

pub noinline fn arraySearchCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    mode: TypedSearchMode,
) !?core.JSValue {
    if (receiver.is(.null_value) or receiver.is(.undefined_value)) {
        return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "Cannot convert undefined or null to object"));
    }
    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    const object = objectFromValue(receiver_object_value) orelse return null;
    const is_typed_method = isTypedArrayPrototypeMethod(function_object);
    if (is_typed_method and !core.object.isTypedArrayObject(object)) return error.NotATypedArray;
    const length = try arrayMethodLength(ctx, output, global, receiver_object_value, object, is_typed_method, null, null);
    if (length == 0) return if (mode == .includes) core.JSValue.boolean(false) else core.JSValue.int32(-1);

    const search_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    // Typed arrays: raw-buffer per-class scan (qjs js_typed_array_indexOf,
    // quickjs.c). Normalize the search value once with an
    // early can't-fit short-circuit, then scan the backing buffer per element
    // kind instead of boxing each element through typedArrayGetIndex. The
    // fromIndex coercion below mirrors what the generic loop already ran.
    const from_right = mode == .last_index_of;
    var cursor = if (from_right)
        try arrayLastIndexStart(ctx, output, global, args, length)
    else
        try arrayFirstIndexStart(ctx, output, global, args, length);
    if (is_typed_method) {
        return try typedArraySearchScan(ctx.runtime, object, mode, search_value, cursor, length);
    }
    // Unique dense paths stay separate. lastIndexOf requires a full-density
    // fast array and returns -1 if the dense scan misses. indexOf/includes
    // scan the dense PREFIX then fall through to the generic tail (qjs
    // js_array_indexOf/includes, quickjs.c).
    if (from_right) {
        if (object.isFastArray() and @as(usize, @intCast(object.arrayLength())) == length and object.arrayElements().len == length) {
            const elements = object.arrayElements();
            if (cursor > elements.len) cursor = elements.len;
            while (cursor > 0) {
                cursor -= 1;
                if (try valuesStrictEqual(ctx.runtime, elements[cursor], search_value)) return lengthIndexValue(cursor);
            }
            return core.JSValue.int32(-1);
        }
    } else if (object.isFastArray()) {
        const elements = object.arrayElements();
        const dense_end = @min(elements.len, length);
        while (cursor < dense_end) : (cursor += 1) {
            const item = elements[cursor];
            if (mode == .includes) {
                if (item.sameValueZero(search_value)) return core.JSValue.boolean(true);
            } else {
                if (try valuesStrictEqual(ctx.runtime, item, search_value)) return lengthIndexValue(cursor);
            }
        }
    }

    // Generic present-element search: propertyAtom + has (except includes)
    // + get + sameValueZero / valuesStrictEqual; direction taken at runtime.
    // Typed arrays returned early above.
    // Over a huge length, jump between possibly present indices. A hole
    // reads as undefined, so `includes(undefined)` must visit every index.
    var sparse_walk = length >= sparse_walk_min_length and
        (mode != .includes or !search_value.is(.undefined_value));
    var remaining: usize = if (from_right) cursor else length - cursor;
    while (remaining > 0) : ({
        remaining -= 1;
        if (!from_right) cursor += 1;
    }) {
        if (sparse_walk) {
            const candidate = if (from_right)
                try previousSparseCandidate(ctx.runtime, object, cursor)
            else
                try nextSparseCandidate(ctx.runtime, object, cursor);
            switch (candidate) {
                .none => break,
                .index => |index| if (from_right) {
                    cursor = index + 1;
                    remaining = index + 1;
                } else {
                    if (index >= length) break;
                    cursor = index;
                    remaining = length - index;
                },
                .unknown => sparse_walk = false,
            }
        }
        if (from_right) cursor -= 1;
        const key = try propertyAtomFromLengthIndex(ctx.runtime, cursor);
        defer key.deinit(ctx.runtime);
        if (mode != .includes and !try hasValueProperty(ctx, output, global, object, key.atom, null, null)) continue;
        const item = try getValueProperty(ctx, output, global, receiver_object_value, key.atom, null, null);
        if (mode == .includes) {
            if (item.sameValueZero(search_value)) return core.JSValue.boolean(true);
        } else {
            if (try valuesStrictEqual(ctx.runtime, item, search_value)) return lengthIndexValue(cursor);
        }
    }
    return if (mode == .includes) core.JSValue.boolean(false) else core.JSValue.int32(-1);
}

pub noinline fn arrayConcatCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    if (!isArrayPrototypeRecord(function_object, @intFromEnum(method_ids.array.PrototypeMethod.concat))) return null;

    if (receiver.is(.null_value) or receiver.is(.undefined_value)) return error.NullishToObject;
    const receiver_object_value = if (receiver.is(.object)) receiver else try primitiveObjectForAccess(ctx.runtime, global, receiver);

    const out_value = try arraySpeciesCreate(ctx, output, global, receiver_object_value, 0, caller_function, caller_frame);
    const out = try property_ops.expectObject(out_value);
    var next_index: usize = 0;
    try concatAppendValue(ctx, output, global, out, &next_index, receiver_object_value, caller_function, caller_frame);
    for (args) |arg| try concatAppendValue(ctx, output, global, out, &next_index, arg, caller_function, caller_frame);
    // Set(A, "length", n, true): a failed write throws, and an Array rejects
    // a length above 2^32 - 1 with a RangeError.
    _ = try object_ops.setValuePropertyWithThrow(ctx, output, global, out_value, core.atom.ids.length, lengthIndexValue(next_index), caller_function, caller_frame, true);
    return out_value;
}

pub fn concatAppendValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    out: *core.Object,
    next_index: *usize,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    if (objectFromValue(value)) |object| {
        if (try isConcatSpreadable(ctx, output, global, value, object, caller_function, caller_frame)) {
            const length_value = try concatSpreadLengthValue(ctx, output, global, value, object, caller_function, caller_frame);
            const length = try toLengthIndex(ctx, output, global, length_value);
            if (next_index.* > core.array.max_safe_length or length > core.array.max_safe_length - next_index.*) return error.ArrayTooLong;
            // A hole only advances n, so a huge length visits just the
            // indices that may be present.
            const start = next_index.*;
            var sparse_walk = length >= sparse_walk_min_length and !core.object.isTypedArrayObject(object);
            var index: usize = 0;
            while (index < length) : (index += 1) {
                try exception_ops.pollNativeLoop(ctx, global);
                if (sparse_walk) switch (try nextSparseCandidate(ctx.runtime, object, index)) {
                    .none => break,
                    .index => |candidate| index = candidate,
                    .unknown => sparse_walk = false,
                };
                if (index >= length) break;
                try arrayCopyPresentIndex(ctx, output, global, value, object, index, out, start + index, caller_function, caller_frame);
            }
            next_index.* = start + length;
            return;
        }
    }
    if (next_index.* >= core.array.max_safe_length) return error.ArrayTooLong;
    const key = try propertyAtomFromLengthIndex(ctx.runtime, next_index.*);
    defer key.deinit(ctx.runtime);
    try createDataPropertyOrThrow(ctx, output, global, out, key.atom, value, caller_function, caller_frame);
    next_index.* += 1;
}

pub fn concatSpreadLengthValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    object: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const dynamic = try getValueProperty(ctx, output, global, value, core.atom.ids.length, caller_function, caller_frame);
    if (!core.object.isTypedArrayObject(object) or object.typedArrayFixedLength() == null) return dynamic;
    if (try core.object.typedArrayOutOfBounds(object)) return dynamic;
    const own = (try object.getOwnProperty(ctx.runtime, core.atom.ids.length)) orelse return dynamic;
    if (own.kind != .data or !own.value.isNumber() or !dynamic.isNumber()) return dynamic;
    const own_number = value_ops.numberValue(own.value) orelse return dynamic;
    const dynamic_number = value_ops.numberValue(dynamic) orelse return dynamic;
    if (own_number > dynamic_number) {
        return own.value;
    }
    return dynamic;
}

pub fn isConcatSpreadable(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    object: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    const spreadable_atom = comptime core.atom.predefinedId("Symbol.isConcatSpreadable", .symbol).?;
    const spreadable = try getValueProperty(ctx, output, global, value, spreadable_atom, caller_function, caller_frame);
    if (!spreadable.is(.undefined_value)) return valueTruthy(spreadable);
    return core.array.isArrayValue(object.value());
}

pub noinline fn arrayToStringCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (this_value.is(.null_value) or this_value.is(.undefined_value)) return error.NullishToObject;
    const object_value = if (this_value.is(.object)) this_value else try primitiveObjectForAccess(ctx.runtime, global, this_value);
    const join_atom = core.atom.ids.join;
    const join_value = try getValueProperty(ctx, output, global, object_value, join_atom, caller_function, caller_frame);
    if (isCallableValue(join_value)) {
        return try callValueOrBytecodeRoot(ctx, output, global, object_value, join_value, &.{}, caller_function, caller_frame);
    }
    return try objectToStringIntrinsic(ctx, output, global, object_value, caller_function, caller_frame);
}

pub noinline fn arrayToLocaleStringCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (this_value.is(.null_value) or this_value.is(.undefined_value)) return error.NullishToObject;
    const object_value = if (this_value.is(.object)) this_value else try primitiveObjectForAccess(ctx.runtime, global, this_value);
    const object = core.value_semantics.objectFromValue(object_value) orelse return null;
    const is_typed_method = isTypedArrayPrototypeMethod(function_object);
    if (is_typed_method and !core.object.isTypedArrayObject(object)) return error.NotATypedArray;
    const length = try arrayMethodLength(ctx, output, global, object_value, object, is_typed_method, caller_function, caller_frame);
    const to_locale_key = core.atom.ids.toLocaleString;

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(ctx.runtime.nativeAllocator());
    for (0..length) |index| {
        if (index != 0) try bytes.append(ctx.runtime.nativeAllocator(), ',');
        const item = if (is_typed_method)
            try core.typed_array.typedArrayGetIndex(ctx.runtime, object, @intCast(index))
        else blk: {
            const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
            defer key.deinit(ctx.runtime);
            break :blk try getValueProperty(ctx, output, global, object_value, key.atom, caller_function, caller_frame);
        };
        if (!item.is(.undefined_value) and !item.is(.null_value)) {
            const method = try getValueProperty(ctx, output, global, item, to_locale_key, caller_function, caller_frame);
            const locale_value = try callValueOrBytecodeRoot(ctx, output, global, item, method, &.{}, caller_function, caller_frame);
            const locale_string = try toStringForAnnexB(ctx, output, global, locale_value, caller_function, caller_frame);
            try value_ops.appendRawString(ctx.runtime, &bytes, locale_string);
        }
    }
    return try value_ops.createStringValue(ctx.runtime, bytes.items);
}
