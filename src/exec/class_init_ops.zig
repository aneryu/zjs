//! Class instance element initialization and super/arrow lexical-this helpers.

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
const slot_ops = @import("slot_ops.zig");
const string_ops = @import("string_ops.zig");

// Helpers that remain in call_runtime.zig (generic utilities outside the class
// initialization cluster).
const callValueOrBytecode = call_runtime.callValueOrBytecode;
const constructCollectionWithPrototypeFromVm = object_ops.constructCollectionWithPrototypeFromVm;
const constructDynamicFunctionFromSource = call_runtime.constructDynamicFunctionFromSource;
const constructPrimitiveWrapperWithPrototype = object_ops.constructPrimitiveWrapperWithPrototype;
const currentArrowFunctionObject = object_ops.currentArrowFunctionObject;
const defineClassFieldDataProperty = object_ops.defineClassFieldDataProperty;
const functionBytecodeFromValue = call_runtime.functionBytecodeFromValue;
const functionObjectFromValue = object_ops.functionObjectFromValue;
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
const remapPrivateAtomForOperation = call_runtime.remapPrivateAtomForOperation;
const sameObjectIdentity = object_ops.sameObjectIdentity;
const slotValueDup = slot_ops.slotValueDup;
const throwRangeErrorMessage = exception_ops.throwRangeErrorMessage;
const valueTruthy = coercion_ops.valueTruthy;
const varRefCellFromValue = slot_ops.varRefCellFromValue;

pub fn classConstructorNewTarget(func: core.JSValue, caller_frame: ?*frame_mod.Frame) core.JSValue {
    if (caller_frame) |frame| {
        if (!frame.new_target.isUndefined()) return frame.new_target;
    }
    return func;
}

pub fn constructBuiltinSuperConstructor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: core.JSValue,
    name: []const u8,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    explicit_new_target: ?core.JSValue,
) !?core.JSValue {
    if (std.mem.eql(u8, name, "Symbol") or std.mem.eql(u8, name, "BigInt")) return error.TypeError;

    const new_target = explicit_new_target orelse classConstructorNewTarget(constructor, caller_frame);

    if (std.mem.eql(u8, name, "Promise")) {
        const executor = if (args.len >= 1) args[0] else return error.TypeError;
        if (!isCallableValue(executor)) return error.TypeError;
    }
    if (std.mem.eql(u8, name, "Iterator")) {
        if (new_target.sameValue(constructor)) return error.TypeError;
        const prototype = try reflectConstructPrototypeVm(ctx, output, global, name, new_target, caller_function, caller_frame);
        const instance = try core.Object.create(ctx.runtime, core.class.ids.object, prototype);
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
        const prototype = try reflectConstructPrototypeVm(ctx, output, global, name, new_target, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "SharedArrayBuffer")) {
            return try core.typed_array.sharedArrayBufferConstructLength(ctx.runtime, byte_length, max_byte_length, prototype);
        }
        return try core.typed_array.arrayBufferConstructLength(ctx.runtime, byte_length, max_byte_length, prototype);
    }

    if (std.mem.eql(u8, name, "DataView")) {
        const coerced = try qjsDataViewConstructorArgs(ctx, output, global, args);
        const prototype = try reflectConstructPrototypeVm(ctx, output, global, name, new_target, caller_function, caller_frame);
        return try qjsDataViewConstructWithPrototype(ctx.runtime, args[0], coerced, prototype);
    }

    if (std.mem.eql(u8, name, "RegExp")) {
        return try qjsRegExpConstructCall(ctx, output, global, new_target, args, caller_function, caller_frame);
    }

    const prototype = try reflectConstructPrototypeVm(ctx, output, global, name, new_target, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "Object")) {
        if (new_target.sameValue(constructor) and args.len >= 1 and args[0].isObject()) return args[0].dup();
        const instance = try core.Object.create(ctx.runtime, core.class.ids.object, prototype);
        return instance.value();
    }
    if (std.mem.eql(u8, name, "Array")) return builtin_dispatch.callConstructRecord(ctx, output, global, &.{}, null, array_construct_ref, prototype, args, caller_function, caller_frame) catch |err| switch (err) {
        error.RangeError => return @as(?core.JSValue, try throwRangeErrorMessage(ctx, global, "invalid array length")),
        else => return err,
    };
    if (std.mem.eql(u8, name, "String")) return try qjsStringConstructWithPrototype(ctx, output, global, prototype, args, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "Number")) {
        if (args.len >= 1 and args[0].isSymbol()) return error.TypeError;
        const primitive = if (args.len >= 1) try value_ops.toNumberValue(ctx.runtime, args[0]) else core.JSValue.int32(0);
        return try constructPrimitiveWrapperWithPrototype(ctx.runtime, core.class.ids.number, prototype, primitive);
    }
    if (std.mem.eql(u8, name, "Boolean")) {
        return try constructPrimitiveWrapperWithPrototype(ctx.runtime, core.class.ids.boolean, prototype, core.JSValue.boolean(args.len >= 1 and valueTruthy(args[0])));
    }
    if (std.mem.eql(u8, name, "Date")) return try date_vm.qjsDateConstructWithPrototype(ctx, output, global, prototype, args);
    if (std.mem.eql(u8, name, "AggregateError")) {
        const constructor_global = if (objectFromValue(constructor)) |constructor_object|
            objectRealmGlobal(constructor_object) orelse global
        else
            global;
        return try qjsAggregateErrorConstructWithPrototype(ctx, output, constructor_global, prototype, args, caller_function, caller_frame);
    }
    if (std.mem.eql(u8, name, "SuppressedError")) return try qjsSuppressedErrorConstructWithPrototype(ctx, output, global, prototype, args, caller_function, caller_frame);
    if (isErrorConstructorName(name)) return try qjsErrorConstructWithPrototype(ctx, output, global, name, prototype, args, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "Promise")) return try qjsPromiseConstructWithPrototype(ctx, output, global, prototype, args, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "WeakRef")) {
        const target = if (args.len >= 1) args[0] else return error.TypeError;
        if (!qjsCanBeHeldWeakly(ctx.runtime, target)) return error.TypeError;
        return try qjsConstructWeakRefWithPrototype(ctx.runtime, target, prototype);
    }
    if (std.mem.eql(u8, name, "FinalizationRegistry")) {
        const cleanup_callback = if (args.len >= 1) args[0] else return error.TypeError;
        if (!isCallableValue(cleanup_callback)) return error.TypeError;
        return try qjsConstructFinalizationRegistryWithPrototype(ctx.runtime, cleanup_callback, prototype);
    }
    if (std.mem.eql(u8, name, "DisposableStack")) return try qjsDisposableStackConstructWithPrototype(ctx, global, prototype);
    if (std.mem.eql(u8, name, "AsyncDisposableStack")) return try qjsAsyncDisposableStackConstructWithPrototype(ctx, global, prototype);
    if (core.host_function.builtin_method_id_lookup.collection.constructorId(name)) |kind| return try constructCollectionWithPrototypeFromVm(ctx, output, global, kind, args, prototype);
    if (std.mem.eql(u8, name, "DataView")) return try core.typed_array.dataViewConstruct(ctx.runtime, args, prototype);
    if (construct_mod.typedArrayElement(name)) |element| return try construct_mod.constructTypedArrayValue(ctx.runtime, prototype, element, args, global);

    return null;
}

pub fn currentArrowLexicalSuperThis(rt: *core.JSRuntime, frame: *frame_mod.Frame) ?core.JSValue {
    const current_object = currentArrowFunctionObject(frame) orelse return null;
    if (current_object.functionLexicalThis()) |this_value| return slotValueDup(this_value);
    _ = rt;
    return null;
}

pub fn currentArrowConstructorThis(rt: *core.JSRuntime, frame: *frame_mod.Frame) ?core.JSValue {
    const current_object = currentArrowFunctionObject(frame) orelse return null;
    _ = rt;
    const stored = current_object.functionArrowConstructorThis() orelse return null;
    return stored.dup();
}

pub fn setCurrentArrowLexicalThis(ctx: *core.JSContext, frame: *frame_mod.Frame, value: core.JSValue) !void {
    const current_object = currentArrowFunctionObject(frame) orelse {
        value.free(ctx.runtime);
        return;
    };
    if (current_object.functionLexicalThis()) |slot| {
        if (varRefCellFromValue(slot)) |cell| {
            try cell.setVarRefValue(ctx.runtime, value);
            return;
        }
        try current_object.setOptionalValueSlot(ctx.runtime, try current_object.functionLexicalThisSlot(ctx.runtime), value);
        return;
    }
    try current_object.setOptionalValueSlot(ctx.runtime, try current_object.functionLexicalThisSlot(ctx.runtime), value);
}

pub inline fn isCurrentSuperConstructor(ctx: *core.JSContext, frame: *frame_mod.Frame, func: core.JSValue) bool {
    _ = ctx;
    if (!frame.current_function.isObject()) return false;
    const current_object = property_ops.expectObject(frame.current_function) catch return false;
    const super_constructor = current_object.functionSuperConstructor() orelse return false;
    if (current_object.functionLexicalThis() == null) {
        if (current_object.getPrototype()) |prototype| {
            if (sameObjectIdentity(prototype.value(), func)) return true;
        }
    }
    return sameObjectIdentity(super_constructor, func);
}

pub fn initializeClassInstanceElements(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    instance: core.JSValue,
    fb: *const bytecode.FunctionBytecode,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const constructor_object = objectFromValue(constructor_value);
    const remap_object = if (constructor_object) |object| object.functionHomeObjectSlot().* else null;
    if (remap_object) |home_object| {
        const instance_object = try property_ops.expectObject(instance);
        try initializeClassPrivateMethods(ctx.runtime, instance_object, home_object);
    }
    try initializeClassInstanceFields(ctx.runtime, instance, fb.classInstanceFields(), remap_object);
    const init_function = if (constructor_object) |object|
        object.functionClassFieldsInit()
    else if (fb.class_fields_init) |boxed|
        boxed.*
    else
        null;
    if (init_function) |initializer| {
        const result = try callValueOrBytecode(ctx, output, global, instance, initializer, &.{}, caller_function, caller_frame);
        result.free(ctx.runtime);
    }
}

pub fn initializeCurrentConstructorClassInstanceElements(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: *frame_mod.Frame,
) !void {
    if (caller_frame.this_value.isUninitialized()) return;
    if (functionObjectFromValue(caller_frame.current_function)) |function_object| {
        const function_value = function_object.functionBytecodeSlot().* orelse return;
        const fb = functionBytecodeFromValue(function_value) orelse return;
        try initializeClassInstanceElements(ctx, output, global, caller_frame.current_function, caller_frame.this_value, fb, caller_function, caller_frame);
        return;
    }
    if (functionBytecodeFromValue(caller_frame.current_function)) |fb| {
        try initializeClassInstanceElements(ctx, output, global, caller_frame.current_function, caller_frame.this_value, fb, caller_function, caller_frame);
    }
}

pub fn initializeClassPrivateMethods(rt: *core.JSRuntime, instance: *core.Object, home_object: *core.Object) !void {
    for (home_object.shapeProps()) |prop| {
        if (rt.atoms.kind(prop.atom_id) != .private) continue;
        if (instance.hasOwnProperty(prop.atom_id)) return error.TypeError;
        if (home_object.getOwnProperty(rt, prop.atom_id)) |desc| {
            defer desc.destroy(rt);
            // NO-ALIGN(qjs): qjs brands instances with raw add_property
            // (JS_AddBrand quickjs.c:8464) ignoring extensibility; test262's
            // `nonextensible-applies-to-private` feature mandates the
            // TypeError on non-extensible instances
            // (staging/sm/PrivateName/modify-non-extensible.js), so zjs keeps
            // the NotExtensible -> TypeError behavior.
            instance.defineOwnProperty(rt, prop.atom_id, desc) catch |err| switch (err) {
                error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
                else => return err,
            };
        }
    }
}

pub fn initializeClassInstanceFields(rt: *core.JSRuntime, instance: core.JSValue, fields: []const core.Atom, remap_object: ?*const core.Object) !void {
    if (fields.len == 0) return;
    const object = try property_ops.expectObject(instance);
    for (fields) |atom_id| {
        const effective_atom = remapPrivateAtomForOperation(rt, null, remap_object, atom_id);
        try defineClassFieldDataProperty(rt, object, effective_atom, core.JSValue.undefinedValue());
    }
}
