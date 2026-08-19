//! Class construction and super helpers.

const builtin_dispatch = @import("builtin_dispatch.zig");
const bytecode = @import("../bytecode.zig");
const construct_mod = @import("construct.zig");
const core = @import("../core/root.zig");
const date_ops = @import("date_ops.zig");
const frame_mod = @import("frame.zig");
const property_ops = @import("property_ops.zig");
const std = @import("std");
const value_ops = @import("value_ops.zig");

// `class X extends Array` super-construction routes through the Array construct
// record (Phase 6b-3 STEP 4); the constructor object carries no native id, so
// the record is reached with this explicit ref.
const array_construct_ref = core.function.NativeBuiltinRef{
    .domain = .array,
    .id = @intFromEnum(core.host_function.builtin_method_ids.array.ConstructorMethod.construct),
};

const call_runtime = @import("call_runtime.zig");
const array_ops = @import("array_ops.zig");
const builtin_glue = @import("builtin_glue.zig");
const coercion_ops = @import("coercion_ops.zig");
const exception_ops = @import("exception_ops.zig");
const object_ops = @import("object_ops.zig");
const promise_ops = @import("promise_ops.zig");
const regexp_fastpath = @import("regexp_fastpath.zig");
const string_ops = @import("string_ops.zig");

// Helpers that remain in call_runtime.zig (generic utilities outside the class
// initialization cluster).
const constructCollectionWithPrototypeFromVm = object_ops.constructCollectionWithPrototypeFromVm;
const constructDynamicFunctionFromSource = call_runtime.constructDynamicFunctionFromSource;
const constructPrimitiveWrapperWithPrototype = object_ops.constructPrimitiveWrapperWithPrototype;
const isCallableValue = call_runtime.isCallableValue;
const isErrorConstructorName = exception_ops.isErrorConstructorName;
const objectFromValue = object_ops.objectFromValue;
const objectRealmGlobal = object_ops.objectRealmGlobal;
const aggregateErrorConstructWithPrototype = object_ops.aggregateErrorConstructWithPrototype;
const arrayBufferMaxByteLengthOption = array_ops.arrayBufferMaxByteLengthOption;
const asyncDisposableStackConstructWithPrototype = promise_ops.asyncDisposableStackConstructWithPrototype;
const canBeHeldWeakly = core.symbol.canBeHeldWeakly;
const constructFinalizationRegistryWithPrototype = object_ops.constructFinalizationRegistryWithPrototype;
const constructWeakRefWithPrototype = object_ops.constructWeakRefWithPrototype;
const dataViewConstructWithPrototype = object_ops.dataViewConstructWithPrototype;
const dataViewConstructorArgs = builtin_glue.dataViewConstructorArgs;
const disposableStackConstructWithPrototype = object_ops.disposableStackConstructWithPrototype;
const errorConstructWithPrototype = object_ops.errorConstructWithPrototype;
const promiseConstructWithPrototype = promise_ops.promiseConstructWithPrototype;
const regExpConstructCall = regexp_fastpath.regExpConstructCall;
const stringConstructWithPrototype = string_ops.stringConstructWithPrototype;
const suppressedErrorConstructWithPrototype = object_ops.suppressedErrorConstructWithPrototype;
const typedArrayConstructToIndex = array_ops.typedArrayConstructToIndex;
const reflectConstructPrototypeVm = object_ops.reflectConstructPrototypeVm;
const throwRangeErrorMessage = exception_ops.throwRangeErrorMessage;
const valueTruthy = coercion_ops.valueTruthy;

pub fn constructBuiltinSuperConstructor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: core.JSValue,
    name: []const u8,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    new_target: core.JSValue,
) !?core.JSValue {
    if (std.mem.eql(u8, name, "Symbol") or std.mem.eql(u8, name, "BigInt")) return error.TypeError;

    if (std.mem.eql(u8, name, "Iterator")) {
        if (new_target.sameValue(constructor)) return error.TypeError;
        var prototype = try reflectConstructPrototypeVm(ctx, output, global, name, new_target, caller_function, caller_frame);
        defer prototype.deinit(ctx.runtime);
        const instance = try core.Object.create(ctx.runtime, core.class.ids.object, prototype.object());
        return instance.value();
    }

    if (std.mem.eql(u8, name, "Function")) return try constructDynamicFunctionFromSource(ctx, output, global, constructor, new_target, args, .normal, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "AsyncFunction")) return try constructDynamicFunctionFromSource(ctx, output, global, constructor, new_target, args, .async_function, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "GeneratorFunction")) return try constructDynamicFunctionFromSource(ctx, output, global, constructor, new_target, args, .generator, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "AsyncGeneratorFunction")) return try constructDynamicFunctionFromSource(ctx, output, global, constructor, new_target, args, .async_generator, caller_function, caller_frame);

    if (std.mem.eql(u8, name, "ArrayBuffer") or std.mem.eql(u8, name, "SharedArrayBuffer")) {
        const byte_length = if (args.len >= 1)
            try typedArrayConstructToIndex(ctx, output, global, args[0])
        else
            @as(usize, 0);
        const max_byte_length = try arrayBufferMaxByteLengthOption(ctx, output, global, args, byte_length);
        var prototype = try reflectConstructPrototypeVm(ctx, output, global, name, new_target, caller_function, caller_frame);
        defer prototype.deinit(ctx.runtime);
        if (std.mem.eql(u8, name, "SharedArrayBuffer")) {
            return try core.typed_array.sharedArrayBufferConstructLength(ctx.runtime, byte_length, max_byte_length, prototype.object());
        }
        return try core.typed_array.arrayBufferConstructLength(ctx.runtime, byte_length, max_byte_length, prototype.object());
    }

    if (std.mem.eql(u8, name, "DataView")) {
        const coerced = try dataViewConstructorArgs(ctx, output, global, args);
        var prototype = try reflectConstructPrototypeVm(ctx, output, global, name, new_target, caller_function, caller_frame);
        defer prototype.deinit(ctx.runtime);
        return try dataViewConstructWithPrototype(ctx.runtime, args[0], coerced, prototype.object());
    }

    if (std.mem.eql(u8, name, "RegExp")) {
        return try regExpConstructCall(ctx, output, global, object_ops.objectFromValue(constructor), new_target, args, caller_function, caller_frame);
    }
    if (std.mem.eql(u8, name, "Promise")) {
        const function_object = objectFromValue(constructor) orelse return error.InvalidBuiltinRegistry;
        return try constructPromiseBuiltinSuperNativeVm(ctx, output, global, function_object, new_target, args, caller_function, caller_frame);
    }

    var prototype = try reflectConstructPrototypeVm(ctx, output, global, name, new_target, caller_function, caller_frame);
    defer prototype.deinit(ctx.runtime);
    if (std.mem.eql(u8, name, "Object")) {
        if (new_target.sameValue(constructor) and args.len >= 1 and args[0].isObject()) return args[0].dup();
        const instance = try core.Object.create(ctx.runtime, core.class.ids.object, prototype.object());
        return instance.value();
    }
    if (std.mem.eql(u8, name, "Array")) {
        const constructor_object = object_ops.objectFromValue(constructor) orelse return null;
        if (constructor_object.arrayBuiltinMarker() != .constructor) return null;
        return builtin_dispatch.callConstructRecord(ctx, output, global, &.{}, constructor_object, array_construct_ref, prototype.object(), args, caller_function, caller_frame) catch |err| switch (err) {
            error.RangeError => {
                if (exception_ops.pendingExceptionMatchesError(ctx, err)) return err;
                return @as(?core.JSValue, try throwRangeErrorMessage(ctx, global, "invalid array length"));
            },
            else => return err,
        };
    }
    if (std.mem.eql(u8, name, "String")) return try stringConstructWithPrototype(ctx, output, global, prototype.object(), args, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "Number")) {
        if (args.len >= 1 and args[0].isSymbol()) return error.TypeError;
        // qjs js_number_constructor (quickjs.c:44822) uses JS_ToNumeric
        // (qjs:13030 → JS_ToNumberHintFree TON_FLAG_NUMERIC, qjs:12946),
        // which ToPrimitive's objects (qjs:12975-12979) before ToNumber.
        const primitive = if (args.len >= 1) blk: {
            if (args[0].isBigInt())
                break :blk value_ops.numberToValue(try value_ops.bigIntToNumber(ctx.runtime, args[0]));
            const coerced = try coercion_ops.toPrimitiveForNumber(ctx, output, global, args[0]);
            defer coerced.free(ctx.runtime);
            if (coerced.isBigInt())
                break :blk value_ops.numberToValue(try value_ops.bigIntToNumber(ctx.runtime, coerced));
            break :blk try value_ops.toNumberValue(ctx.runtime, coerced);
        } else core.JSValue.int32(0);
        return try constructPrimitiveWrapperWithPrototype(ctx.runtime, core.class.ids.number, prototype.object(), primitive);
    }
    if (std.mem.eql(u8, name, "Boolean")) {
        return try constructPrimitiveWrapperWithPrototype(ctx.runtime, core.class.ids.boolean, prototype.object(), core.JSValue.boolean(args.len >= 1 and valueTruthy(args[0])));
    }
    if (std.mem.eql(u8, name, "Date")) return try date_ops.dateConstructWithPrototype(ctx, output, global, prototype.object(), args);
    if (std.mem.eql(u8, name, "AggregateError")) {
        const constructor_global = if (objectFromValue(constructor)) |constructor_object|
            objectRealmGlobal(constructor_object) orelse global
        else
            global;
        return try aggregateErrorConstructWithPrototype(ctx, output, constructor_global, prototype.object(), args, caller_function, caller_frame);
    }
    if (std.mem.eql(u8, name, "SuppressedError")) return try suppressedErrorConstructWithPrototype(ctx, output, global, prototype.object(), args, caller_function, caller_frame);
    if (isErrorConstructorName(name)) return try errorConstructWithPrototype(ctx, output, global, name, prototype.object(), args, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "WeakRef")) {
        const target = if (args.len >= 1) args[0] else return error.TypeError;
        if (!canBeHeldWeakly(ctx.runtime, target)) return error.TypeError;
        return try constructWeakRefWithPrototype(ctx.runtime, target, prototype.object());
    }
    if (std.mem.eql(u8, name, "FinalizationRegistry")) {
        const cleanup_callback = if (args.len >= 1) args[0] else return error.TypeError;
        if (!isCallableValue(cleanup_callback)) return error.TypeError;
        return try constructFinalizationRegistryWithPrototype(ctx, cleanup_callback, prototype.object());
    }
    if (std.mem.eql(u8, name, "DisposableStack")) return try disposableStackConstructWithPrototype(ctx, global, prototype.object());
    if (std.mem.eql(u8, name, "AsyncDisposableStack")) return try asyncDisposableStackConstructWithPrototype(ctx, global, prototype.object());
    if (core.host_function.builtin_method_id_lookup.collection.constructorId(name)) |kind| return try constructCollectionWithPrototypeFromVm(ctx, output, global, kind, args, prototype.object());
    if (std.mem.eql(u8, name, "DataView")) return try core.typed_array.dataViewConstruct(ctx.runtime, args, prototype.object());
    if (construct_mod.typedArrayElement(name)) |element| {
        const function_object = object_ops.objectFromValue(constructor) orelse return error.InvalidBuiltinRegistry;
        return try construct_mod.constructTypedArrayValue(ctx.runtime, function_object, prototype.object(), element, args);
    }

    return null;
}

/// Promise construction with a distinct `new.target` must keep the observable
/// VM `[[Get]]` used by GetPrototypeFromConstructor. The direct Promise helper
/// can use its ordinary intrinsic data property, but Reflect.construct and
/// derived `super()` must run an accessor/Proxy `newTarget.prototype` while
/// the Promise native frame is active.
fn constructPromiseBuiltinSuperNativeVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    new_target: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    try builtin_dispatch.preflightCFunctionCall(ctx, global, function_object, 1);
    var native_scope = builtin_dispatch.NativeBacktraceScope.init(ctx, function_object);
    native_scope.push();
    defer native_scope.deinit();

    return constructPromiseBuiltinSuperInScope(ctx, output, global, new_target, args, caller_function, caller_frame) catch |err| {
        try builtin_dispatch.materializeRuntimeError(ctx, global, err);
        return err;
    };
}

fn constructPromiseBuiltinSuperInScope(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    new_target: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const executor = if (args.len >= 1)
        args[0]
    else
        return exception_ops.throwTypeErrorMessage(ctx, global, "not a function");
    if (!isCallableValue(executor)) return exception_ops.throwTypeErrorMessage(ctx, global, "not a function");

    var prototype = try reflectConstructPrototypeVm(ctx, output, global, "Promise", new_target, caller_function, caller_frame);
    defer prototype.deinit(ctx.runtime);
    return promiseConstructWithPrototype(ctx, output, global, prototype.object(), args, caller_function, caller_frame);
}
