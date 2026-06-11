//! Class instance element initialization and super/arrow lexical-this helpers.

const builtins = @import("../builtins/root.zig");
const bytecode = @import("../bytecode/root.zig");
const construct_mod = @import("construct.zig");
const core = @import("../core/root.zig");
const date_vm = @import("date_ops.zig");
const frame_mod = @import("frame.zig");
const property_ops = @import("property_ops.zig");
const std = @import("std");
const value_ops = @import("value_ops.zig");

const shared_vm = @import("shared.zig");

// Helpers that remain in shared.zig (generic utilities outside the class
// initialization cluster).
const callValueOrBytecode = shared_vm.callValueOrBytecode;
const constructCollectionWithPrototypeFromVm = shared_vm.constructCollectionWithPrototypeFromVm;
const constructDynamicFunctionFromSource = shared_vm.constructDynamicFunctionFromSource;
const constructPrimitiveWrapperWithPrototype = shared_vm.constructPrimitiveWrapperWithPrototype;
const currentArrowFunctionObject = shared_vm.currentArrowFunctionObject;
const defineClassFieldDataProperty = shared_vm.defineClassFieldDataProperty;
const functionBytecodeFromValue = shared_vm.functionBytecodeFromValue;
const functionObjectFromValue = shared_vm.functionObjectFromValue;
const isCallableValue = shared_vm.isCallableValue;
const isErrorConstructorName = shared_vm.isErrorConstructorName;
const objectFromValue = shared_vm.objectFromValue;
const objectRealmGlobal = shared_vm.objectRealmGlobal;
const qjsAggregateErrorConstructWithPrototype = shared_vm.qjsAggregateErrorConstructWithPrototype;
const qjsArrayBufferMaxByteLengthOption = shared_vm.qjsArrayBufferMaxByteLengthOption;
const qjsAsyncDisposableStackConstructWithPrototype = shared_vm.qjsAsyncDisposableStackConstructWithPrototype;
const qjsCanBeHeldWeakly = shared_vm.qjsCanBeHeldWeakly;
const qjsConstructFinalizationRegistryWithPrototype = shared_vm.qjsConstructFinalizationRegistryWithPrototype;
const qjsConstructWeakRefWithPrototype = shared_vm.qjsConstructWeakRefWithPrototype;
const qjsDataViewConstructWithPrototype = shared_vm.qjsDataViewConstructWithPrototype;
const qjsDataViewConstructorArgs = shared_vm.qjsDataViewConstructorArgs;
const qjsDisposableStackConstructWithPrototype = shared_vm.qjsDisposableStackConstructWithPrototype;
const qjsErrorConstructWithPrototype = shared_vm.qjsErrorConstructWithPrototype;
const qjsPromiseConstructWithPrototype = shared_vm.qjsPromiseConstructWithPrototype;
const qjsRegExpConstructCall = shared_vm.qjsRegExpConstructCall;
const qjsStringConstructWithPrototype = shared_vm.qjsStringConstructWithPrototype;
const qjsSuppressedErrorConstructWithPrototype = shared_vm.qjsSuppressedErrorConstructWithPrototype;
const qjsTypedArrayConstructToIndex = shared_vm.qjsTypedArrayConstructToIndex;
const reflectConstructPrototypeVm = shared_vm.reflectConstructPrototypeVm;
const remapPrivateAtomForOperation = shared_vm.remapPrivateAtomForOperation;
const sameObjectIdentity = shared_vm.sameObjectIdentity;
const slotValueDup = shared_vm.slotValueDup;
const throwRangeErrorMessage = shared_vm.throwRangeErrorMessage;
const valueTruthy = shared_vm.valueTruthy;
const varRefCellFromValue = shared_vm.varRefCellFromValue;

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
        if (builtins.object.sameValue(new_target, constructor)) return error.TypeError;
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
            return try builtins.buffer.sharedArrayBufferConstructLength(ctx.runtime, byte_length, max_byte_length, prototype);
        }
        return try builtins.buffer.arrayBufferConstructLength(ctx.runtime, byte_length, max_byte_length, prototype);
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
        if (builtins.object.sameValue(new_target, constructor) and args.len >= 1 and args[0].isObject()) return args[0].dup();
        const instance = try core.Object.create(ctx.runtime, core.class.ids.object, prototype);
        return instance.value();
    }
    if (std.mem.eql(u8, name, "Array")) return builtins.array.constructConstructorWithPrototype(ctx.runtime, args, prototype) catch |err| switch (err) {
        error.RangeError => return @as(?core.JSValue, try throwRangeErrorMessage(ctx, global, "invalid array length")),
        else => err,
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
    if (builtins.collection.constructorId(name)) |kind| return try constructCollectionWithPrototypeFromVm(ctx, output, global, kind, args, prototype);
    if (std.mem.eql(u8, name, "DataView")) return try builtins.buffer.dataViewConstruct(ctx.runtime, args, prototype);
    if (construct_mod.typedArrayElement(name)) |element| return try construct_mod.constructTypedArrayValue(ctx.runtime, prototype, element, args, global);

    return null;
}

pub fn currentArrowLexicalSuperThis(rt: *core.JSRuntime, frame: *frame_mod.Frame) ?core.JSValue {
    const current_object = currentArrowFunctionObject(frame) orelse return null;
    if (current_object.functionLexicalThisSlot().*) |this_value| return slotValueDup(this_value);
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
    if (current_object.functionLexicalThisSlot().*) |slot| {
        if (varRefCellFromValue(slot)) |cell| {
            try cell.setVarRefValue(ctx.runtime, value);
            return;
        }
        try current_object.setOptionalValueSlot(ctx.runtime, current_object.functionLexicalThisSlot(), value);
        return;
    }
    try current_object.setOptionalValueSlot(ctx.runtime, current_object.functionLexicalThisSlot(), value);
}

pub fn isCurrentSuperConstructor(ctx: *core.JSContext, frame: *frame_mod.Frame, func: core.JSValue) bool {
    _ = ctx;
    if (!frame.current_function.isObject()) return false;
    const current_object = property_ops.expectObject(frame.current_function) catch return false;
    const super_constructor = current_object.functionSuperConstructor() orelse return false;
    if (current_object.functionLexicalThisSlot().* == null) {
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
    try initializeClassInstanceFields(ctx.runtime, instance, fb.class_instance_fields, remap_object);
    const init_function = if (constructor_object) |object|
        object.functionClassFieldsInitSlot().*
    else
        fb.class_fields_init;
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
        if (home_object.getOwnProperty(prop.atom_id)) |desc| {
            defer desc.destroy(rt);
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
