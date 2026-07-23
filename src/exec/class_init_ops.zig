//! Class construction and super helpers.

const builtin_dispatch = @import("builtin_dispatch.zig");
const bytecode = @import("../bytecode.zig");
const construct_mod = @import("construct.zig");
const core = @import("../core/root.zig");
const date_vm = @import("date_ops.zig");
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
const exception_ops = @import("vm_exception_ops.zig");
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
const qjsAggregateErrorConstructWithPrototype = object_ops.qjsAggregateErrorConstructWithPrototype;
const qjsArrayBufferMaxByteLengthOption = array_ops.qjsArrayBufferMaxByteLengthOption;
const qjsAsyncDisposableStackConstructWithPrototype = promise_ops.qjsAsyncDisposableStackConstructWithPrototype;
const qjsCanBeHeldWeakly = builtin_glue.qjsCanBeHeldWeakly;
const qjsConstructFinalizationRegistryWithPrototype = object_ops.qjsConstructFinalizationRegistryWithPrototype;
const qjsConstructWeakRefWithPrototype = object_ops.qjsConstructWeakRefWithPrototype;
const qjsDataViewConstructWithPrototype = object_ops.qjsDataViewConstructWithPrototype;
const qjsDataViewConstructorArgs = builtin_glue.qjsDataViewConstructorArgs;
const qjsDisposableStackConstructWithPrototype = object_ops.qjsDisposableStackConstructWithPrototype;
const qjsErrorConstructWithPrototype = object_ops.qjsErrorConstructWithPrototype;
const qjsPromiseConstructWithPrototype = promise_ops.qjsPromiseConstructWithPrototype;
const qjsRegExpConstructCall = regexp_fastpath.qjsRegExpConstructCall;
const qjsStringConstructWithPrototype = string_ops.qjsStringConstructWithPrototype;
const qjsSuppressedErrorConstructWithPrototype = object_ops.qjsSuppressedErrorConstructWithPrototype;
const qjsTypedArrayConstructToIndex = array_ops.qjsTypedArrayConstructToIndex;
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

    if (std.mem.eql(u8, name, "Promise")) {
        const executor = if (args.len >= 1) args[0] else return error.TypeError;
        if (!isCallableValue(executor)) return error.TypeError;
    }
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
            try qjsTypedArrayConstructToIndex(ctx, output, global, args[0])
        else
            @as(usize, 0);
        const max_byte_length = try qjsArrayBufferMaxByteLengthOption(ctx, output, global, args, byte_length);
        var prototype = try reflectConstructPrototypeVm(ctx, output, global, name, new_target, caller_function, caller_frame);
        defer prototype.deinit(ctx.runtime);
        if (std.mem.eql(u8, name, "SharedArrayBuffer")) {
            return try core.typed_array.sharedArrayBufferConstructLength(ctx.runtime, byte_length, max_byte_length, prototype.object());
        }
        return try core.typed_array.arrayBufferConstructLength(ctx.runtime, byte_length, max_byte_length, prototype.object());
    }

    if (std.mem.eql(u8, name, "DataView")) {
        const coerced = try qjsDataViewConstructorArgs(ctx, output, global, args);
        var prototype = try reflectConstructPrototypeVm(ctx, output, global, name, new_target, caller_function, caller_frame);
        defer prototype.deinit(ctx.runtime);
        return try qjsDataViewConstructWithPrototype(ctx.runtime, args[0], coerced, prototype.object());
    }

    if (std.mem.eql(u8, name, "RegExp")) {
        return try qjsRegExpConstructCall(ctx, output, global, object_ops.objectFromValue(constructor), new_target, args, caller_function, caller_frame);
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
    if (std.mem.eql(u8, name, "String")) return try qjsStringConstructWithPrototype(ctx, output, global, prototype.object(), args, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "Number")) {
        if (args.len >= 1 and args[0].isSymbol()) return error.TypeError;
        // qjs js_number_constructor (quickjs.c:44822-44841): ToNumeric, then a
        // bigint result converts to float64 rather than throwing.
        const primitive = if (args.len >= 1)
            (if (args[0].isBigInt())
                value_ops.numberToValue(try value_ops.bigIntToNumber(ctx.runtime, args[0]))
            else
                try value_ops.toNumberValue(ctx.runtime, args[0]))
        else
            core.JSValue.int32(0);
        return try constructPrimitiveWrapperWithPrototype(ctx.runtime, core.class.ids.number, prototype.object(), primitive);
    }
    if (std.mem.eql(u8, name, "Boolean")) {
        return try constructPrimitiveWrapperWithPrototype(ctx.runtime, core.class.ids.boolean, prototype.object(), core.JSValue.boolean(args.len >= 1 and valueTruthy(args[0])));
    }
    if (std.mem.eql(u8, name, "Date")) return try date_vm.qjsDateConstructWithPrototype(ctx, output, global, prototype.object(), args);
    if (std.mem.eql(u8, name, "AggregateError")) {
        const constructor_global = if (objectFromValue(constructor)) |constructor_object|
            objectRealmGlobal(constructor_object) orelse global
        else
            global;
        return try qjsAggregateErrorConstructWithPrototype(ctx, output, constructor_global, prototype.object(), args, caller_function, caller_frame);
    }
    if (std.mem.eql(u8, name, "SuppressedError")) return try qjsSuppressedErrorConstructWithPrototype(ctx, output, global, prototype.object(), args, caller_function, caller_frame);
    if (isErrorConstructorName(name)) return try qjsErrorConstructWithPrototype(ctx, output, global, name, prototype.object(), args, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "Promise")) return try qjsPromiseConstructWithPrototype(ctx, output, global, prototype.object(), args, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "WeakRef")) {
        const target = if (args.len >= 1) args[0] else return error.TypeError;
        if (!qjsCanBeHeldWeakly(ctx.runtime, target)) return error.TypeError;
        return try qjsConstructWeakRefWithPrototype(ctx.runtime, target, prototype.object());
    }
    if (std.mem.eql(u8, name, "FinalizationRegistry")) {
        const cleanup_callback = if (args.len >= 1) args[0] else return error.TypeError;
        if (!isCallableValue(cleanup_callback)) return error.TypeError;
        return try qjsConstructFinalizationRegistryWithPrototype(ctx, cleanup_callback, prototype.object());
    }
    if (std.mem.eql(u8, name, "DisposableStack")) return try qjsDisposableStackConstructWithPrototype(ctx, global, prototype.object());
    if (std.mem.eql(u8, name, "AsyncDisposableStack")) return try qjsAsyncDisposableStackConstructWithPrototype(ctx, global, prototype.object());
    if (core.host_function.builtin_method_id_lookup.collection.constructorId(name)) |kind| return try constructCollectionWithPrototypeFromVm(ctx, output, global, kind, args, prototype.object());
    if (std.mem.eql(u8, name, "DataView")) return try core.typed_array.dataViewConstruct(ctx.runtime, args, prototype.object());
    if (construct_mod.typedArrayElement(name)) |element| {
        const function_object = object_ops.objectFromValue(constructor) orelse return error.InvalidBuiltinRegistry;
        return try construct_mod.constructTypedArrayValue(ctx.runtime, function_object, prototype.object(), element, args);
    }

    return null;
}
