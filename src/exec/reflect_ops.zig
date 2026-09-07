//! Reflect.* and Proxy.revocable implementations: the reflective surface of the exec call machinery.

const core = @import("../core/root.zig");
const call_mod = @import("call.zig");
const exception_ops = @import("exception_ops.zig");
const reflect_dispatch = core.host_function.builtin_method_ids.reflect;
const frame_mod = @import("frame.zig");
const bytecode = @import("../bytecode.zig");
const std = @import("std");

const array_ops = @import("array_ops.zig");
const call = @import("call.zig");
const call_runtime = @import("call_runtime.zig");
const construct_mod = @import("construct.zig");
const exceptions = @import("exceptions.zig");
const globals_mod = core.global_slots;
const object_ops = @import("object_ops.zig");
const property_ops = @import("property_ops.zig");
const value_ops = @import("value_ops.zig");

const HostError = exceptions.HostError;
const ValueSliceRoot = array_ops.ValueSliceRoot;

// Static-method ids stay with the registration data in reflect_proxy_ops.zig.
const StaticMethod = core.host_function.builtin_method_ids.reflect.StaticMethod;

// Shared call-runtime helpers that stay with the dispatcher in exec/call.zig.
const callValueWithThisGlobalsAndGlobal = call.callValueWithThisGlobalsAndGlobal;
const defineObjectProperty = call.defineObjectProperty;
const expectObjectArg = call.expectObjectArg;
const functionPrototypeFromGlobal = object_ops.functionPrototypeFromGlobal;
const getValuePropertyViaGlobalSlots = call.getValuePropertyViaGlobalSlots;
const thisObject = call.thisObject;

pub fn proxyRevocable(rt: *core.JSRuntime, global: ?*core.Object, args: []const core.JSValue) !core.JSValue {
    if (args.len < 2) return error.TypeError;
    const realm_global = global orelse return error.TypeError;
    var rooted_args_buffer = try core.runtime.ValueRootBuffer.initCopy(rt, args);
    defer rooted_args_buffer.deinit(rt);
    const rooted_args = rooted_args_buffer.values;
    var root_slices = [_]core.runtime.ValueRootSlice{
        rooted_args_buffer.slice(),
    };
    var root_frame = core.runtime.ValueRootFrame{
        .slices = &root_slices,
    };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    _ = try expectObjectArg(rooted_args[0]);
    _ = try expectObjectArg(rooted_args[1]);

    const object = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, object.gcHeader());

    const proxy = try core.Object.create(rt, core.class.ids.proxy, null);
    var proxy_raw_owned = true;
    errdefer if (proxy_raw_owned) core.Object.destroyFromHeader(rt, proxy.gcHeader());
    try proxy.ensureProxyPayload(rt);
    try proxy.setOptionalValueSlot(rt, proxy.proxyTargetSlot(), rooted_args[0]);
    try proxy.setOptionalValueSlot(rt, proxy.proxyHandlerSlot(), rooted_args[1]);
    try defineObjectProperty(rt, object, core.atom.ids.proxy, proxy.value());
    proxy_raw_owned = false;
    // QuickJS `js_proxy_revocable` uses JS_NewCFunctionData: the revoker is a
    // captured-data callable and therefore executes in its caller's realm.
    const function_proto = functionPrototypeFromGlobal(rt, realm_global) orelse return error.InvalidBuiltinRegistry;
    const revoke = try core.function.nativeDataFunctionWithPrototype(rt, function_proto, "", 0);
    const revoke_object = thisObject(revoke) orelse return error.TypeError;
    // Data carriers deliberately do not populate the true-C-function record
    // cache; dispatch decodes this stable id in the final caller-data arm.
    revoke_object.nativeFunctionIdSlot().* = core.function.nativeBuiltinId(.reflect, @intFromEnum(StaticMethod.proxy_revoke));
    try revoke_object.setOptionalValueSlot(rt, try revoke_object.functionProxyRevokeTargetSlot(rt), proxy.value());
    try defineObjectProperty(rt, object, core.atom.ids.revoke, revoke);
    return object.value();
}

/// Revoke closure for `Proxy.revocable`: clears the captured proxy's handler
/// so subsequent trap lookups throw. Mirrors QuickJS `js_proxy_revoke`. Stays
/// in exec with the rest of the proxy core; the `.reflect` record handler in
/// reflect_proxy_ops.zig forwards the `proxy_revoke` id here.
pub fn revokeProxy(rt: *core.JSRuntime, function_object: *core.Object) !core.JSValue {
    const proxy_slot = try function_object.functionProxyRevokeTargetSlot(rt);
    const proxy_value = function_object.takeOptionalValueSlot(proxy_slot) orelse return core.JSValue.undefinedValue();
    const proxy = thisObject(proxy_value) orelse return core.JSValue.undefinedValue();
    proxy.clearOptionalValueSlot(rt, proxy.proxyHandlerSlot());
    return core.JSValue.undefinedValue();
}

fn reflectHasProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    object: *core.Object,
    atom_id: core.Atom,
) HostError!bool {
    if (object.proxyTarget() != null) return proxyReflectHasProperty(ctx, output, global, globals, object, atom_id);
    if (try typedArrayReflectHas(ctx.runtime, object, atom_id)) |has| return has;
    if (object.hasOwnProperty(atom_id)) return true;

    var current = object.getPrototype();
    while (current) |proto| : (current = proto.getPrototype()) {
        if (proto.proxyTarget() != null) return proxyReflectHasProperty(ctx, output, global, globals, proto, atom_id);
        if (try typedArrayReflectHas(ctx.runtime, proto, atom_id)) |has| return has;
        if (proto.hasOwnProperty(atom_id)) return true;
    }
    return false;
}

fn proxyReflectHasProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    proxy: *core.Object,
    atom_id: core.Atom,
) !bool {
    const target_value = proxy.proxyTarget() orelse return error.TypeError;
    const target = try expectObjectArg(target_value);
    const handler_value = proxy.proxyHandler() orelse return error.TypeError;
    const has_atom = core.atom.ids.has;
    const trap = try getValuePropertyViaGlobalSlots(ctx, output, global, globals, handler_value, has_atom);
    if (trap.isUndefined() or trap.isNull()) return reflectHasProperty(ctx, output, global, globals, target, atom_id);
    const key_value = try object_ops.proxyTrapKeyValue(ctx.runtime, atom_id);
    const result = try callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, handler_value, trap, &.{ target_value, key_value });
    const trap_result = value_ops.isTruthy(result);
    const global_object = global orelse {
        // Bare-runtime fallback (no realm global): keep the raw target reads;
        // the VM path below mirrors js_proxy_has's exotic-dispatching reads.
        if (trap_result) return true;
        if (try target.getOwnProperty(ctx.runtime, atom_id)) |desc| {
            if (desc.configurable == false or !target.isExtensible()) return error.TypeError;
        }
        return false;
    };
    return try object_ops.validateProxyHasResult(ctx, output, global_object, target, atom_id, trap_result, null, null);
}

fn typedArrayReflectHas(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) !?bool {
    switch (try core.object.typedArrayCanonicalNumericIndex(rt, atom_id)) {
        .none => return null,
        .invalid => return false,
        .index => |index| {
            const length = core.object.typedArrayLength(rt, object) catch return false;
            return index < length;
        },
    }
}

pub fn reflectCallForNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const reflect_mod = reflect_dispatch;
    return switch (id) {
        @intFromEnum(reflect_mod.StaticMethod.define_property) => (try object_ops.definePropertyWithKind(ctx, output, global, args, 2, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.get_own_property_descriptor) => (try object_ops.reflectGetOwnPropertyDescriptorCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.delete_property) => (try object_ops.reflectDeletePropertyCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.get) => (try reflectGetCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.get_prototype_of) => (try object_ops.reflectGetPrototypeOfCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.set) => (try reflectSetCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.set_prototype_of) => (try object_ops.reflectSetPrototypeOfCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.is_extensible) => (try reflectIsExtensibleCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.prevent_extensions) => (try reflectPreventExtensionsCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.has) => (try reflectHasCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.own_keys) => (try reflectOwnKeysCall(ctx, output, global, args)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.construct) => (try reflectConstructCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.apply) => try reflectApplyCall(ctx, output, global, args, caller_function, caller_frame),
        else => error.TypeError,
    };
}

pub fn reflectSetCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 1) return error.TypeError;
    const set_value = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
    const object = property_ops.expectObject(args[0]) catch return error.TypeError;
    const key_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const atom_id = try object_ops.toPropertyKeyAtom(ctx, output, global, key_value, caller_function, caller_frame);
    if (object.class_id == core.class.ids.module_ns) return core.JSValue.boolean(false);
    if (!object.isArray() or atom_id != core.atom.ids.length) {
        const receiver_value = if (args.len >= 4) args[3] else args[0];
        if (object.proxyTarget() != null) {
            const ok = try object_ops.proxySetValueProperty(ctx, output, global, receiver_value, object, atom_id, set_value, caller_function, caller_frame);
            return core.JSValue.boolean(ok);
        }
        if (core.object.isTypedArrayObject(object)) {
            switch (try core.object.typedArrayCanonicalNumericIndex(ctx.runtime, atom_id)) {
                .none => {},
                .invalid => {
                    if (object_ops.sameObjectIdentity(receiver_value, args[0])) {
                        const coerced = try array_ops.coerceTypedArrayElementInput(ctx, output, global, set_value);
                        try core.typed_array.typedArrayCoerceElementValue(ctx.runtime, object, coerced);
                    }
                    return core.JSValue.boolean(true);
                },
                .index => |index| {
                    if (object_ops.sameObjectIdentity(receiver_value, args[0])) {
                        const coerced = try array_ops.coerceTypedArrayElementForSet(ctx, output, global, object, set_value);
                        if (!try core.object.typedArrayIndexValid(ctx.runtime, object, index)) return core.JSValue.boolean(true);
                        if (try core.object.typedArrayImmutableBuffer(ctx.runtime, object)) return core.JSValue.boolean(false);
                        _ = try core.typed_array.typedArraySetElement(ctx.runtime, object, index, coerced);
                        return core.JSValue.boolean(true);
                    }
                    if (!try core.object.typedArrayIndexValid(ctx.runtime, object, index)) return core.JSValue.boolean(true);
                    const receiver_object = object_ops.objectFromValue(receiver_value) orelse return core.JSValue.boolean(false);
                    const ok = try array_ops.typedArrayReflectSetReceiverOwn(ctx, output, global, receiver_value, receiver_object, atom_id, set_value, caller_function, caller_frame);
                    return core.JSValue.boolean(ok);
                },
            }
        }
        if (object_ops.objectFromValue(receiver_value)) |receiver_object| {
            if (try array_ops.typedArrayPrototypeSet(ctx, output, global, receiver_value, receiver_object, object.getPrototype(), atom_id, set_value, caller_function, caller_frame)) |ok| {
                return core.JSValue.boolean(ok);
            }
        }
        const ok = try call_runtime.ordinarySetWithReceiver(ctx, output, global, args[0], object, receiver_value, atom_id, set_value, caller_function, caller_frame);
        return core.JSValue.boolean(ok);
    }
    // qjs JS_SetPropertyInternal: when obj != this_obj (Reflect.set receiver),
    // `if (unlikely(p != p1)) goto retry2` (quickjs.c:9701-9702) skips the
    // own JS_PROP_LENGTH / set_array_length arm (9714-9717) and later takes
    // the generic receiver path (9892-9929). Only the 4-arg form can have a
    // distinct receiver; the 3-arg path is identical to pre-X-02.
    if (args.len >= 4 and !object_ops.sameObjectIdentity(args[3], args[0])) {
        const ok = try call_runtime.ordinarySetWithReceiver(ctx, output, global, args[0], object, args[3], atom_id, set_value, caller_function, caller_frame);
        return core.JSValue.boolean(ok);
    }
    const value_to_set = try array_ops.arrayLengthAssignmentValue(ctx, output, global, object, atom_id, set_value, caller_function, caller_frame);
    object.setProperty(ctx.runtime, atom_id, value_to_set) catch |err| switch (err) {
        error.ReadOnly, error.AccessorWithoutSetter, error.NotExtensible, error.IncompatibleDescriptor => return core.JSValue.boolean(false),
        error.InvalidLength => return error.RangeError,
        else => return err,
    };
    return core.JSValue.boolean(true);
}

pub fn reflectIsExtensibleCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 1) return error.TypeError;
    if (!args[0].isObject()) return error.TypeError;
    return object_ops.objectIsExtensibleCall(ctx, output, global, args, caller_function, caller_frame);
}

pub fn reflectPreventExtensionsCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 1) return error.TypeError;
    const object = object_ops.objectFromValue(args[0]) orelse return error.TypeError;
    if (object.proxyTarget() != null) {
        return core.JSValue.boolean(try object_ops.proxyAwarePreventExtensions(ctx, output, global, object, caller_function, caller_frame));
    }
    object.preventExtensions();
    return core.JSValue.boolean(true);
}

pub fn reflectConstructCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 2 or !(try call_runtime.isConstructorLike(ctx, args[0]))) return error.TypeError;
    const new_target = if (args.len >= 3) args[2] else args[0];
    if (!(try call_runtime.isConstructorLike(ctx, new_target))) return error.TypeError;
    var construct_args = try array_ops.argsFromArrayLike(ctx, output, global, args[1], caller_function, caller_frame);
    defer call_runtime.freeArgs(ctx.runtime, construct_args);
    var construct_args_root = array_ops.ValueSliceRoot{};
    construct_args_root.init(ctx.runtime, &construct_args);
    defer construct_args_root.deinit();
    if (object_ops.objectFromValue(args[0])) |target| {
        if (target.proxyTarget() == null) {
            const target_name = try call_mod.nativeFunctionNameForVm(ctx.runtime, target);
            defer ctx.runtime.memory.allocator.free(target_name);
            if (construct_mod.typedArrayElement(target_name) != null) {
                try array_ops.typedArrayValidateConstructArgsPreAllocate(ctx, output, global, construct_args);
            }
        }
    }
    return try call_runtime.constructValueOrBytecodeWithNewTarget(ctx, output, global, args[0], construct_args, caller_function, caller_frame, new_target);
}

pub fn reflectHasCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 2) return error.TypeError;
    const object = object_ops.objectFromValue(args[0]) orelse return error.TypeError;
    const key = try object_ops.toPropertyKeyAtom(ctx, output, global, args[1], caller_function, caller_frame);
    const found = if (object.proxyTarget() != null)
        try object_ops.hasValueProperty(ctx, output, global, args[0], object, key, caller_function, caller_frame)
    else
        try object_ops.ordinaryHasValueProperty(ctx, output, global, object, key, false, caller_function, caller_frame);
    return core.JSValue.boolean(found);
}

pub fn reflectApplyCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (args.len < 1 or !call_runtime.isCallableValue(args[0])) return exception_ops.throwTypeErrorMessage(ctx, global, "not a function");
    if (args.len < 3) return error.TypeError;
    var owned_args = try array_ops.ownedArgsFromArrayLike(
        ctx,
        output,
        global,
        args[2],
        caller_function,
        caller_frame,
    );
    defer owned_args.deinit();
    var apply_args = owned_args.values;
    if (apply_args.len == 0) {
        return call_runtime.callValueOrBytecodeSyncInternal(ctx, output, global, args[1], args[0], &.{}, caller_function, caller_frame);
    }
    var apply_args_root = array_ops.ValueSliceRoot{};
    apply_args_root.init(ctx.runtime, &apply_args);
    defer apply_args_root.deinit();
    return call_runtime.callOwnedArgsValueOrBytecodeSyncInternal(
        ctx,
        output,
        global,
        args[1],
        args[0],
        apply_args,
        caller_function,
        caller_frame,
    );
}

pub fn reflectGetCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 2) return error.TypeError;
    const object = object_ops.objectFromValue(args[0]) orelse return error.TypeError;
    const atom_id = try object_ops.toPropertyKeyAtom(ctx, output, global, args[1], caller_function, caller_frame);
    const receiver = if (args.len >= 3) args[2] else args[0];
    return try object_ops.getValuePropertyWithReceiver(ctx, output, global, args[0], object, receiver, atom_id, caller_function, caller_frame);
}

pub fn reflectOwnKeysCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !?core.JSValue {
    if (args.len < 1) return error.TypeError;
    const object = property_ops.expectObject(args[0]) catch return error.TypeError;
    const keys = try object_ops.objectRestOwnKeys(ctx, output, global, object);
    defer core.Object.freeKeys(ctx.runtime, keys);
    const out = try core.Object.createArray(ctx.runtime, array_ops.arrayPrototypeFromGlobal(ctx.runtime, global));
    errdefer core.Object.destroyFromHeader(ctx.runtime, out.gcHeader());
    for (keys) |key| {
        const key_value = try object_ops.proxyTrapKeyValue(ctx.runtime, key);
        try out.defineOwnProperty(ctx.runtime, core.atom.atomFromUInt32(out.arrayLength()), core.Descriptor.data(key_value, true, true, true));
    }
    return out.value();
}
