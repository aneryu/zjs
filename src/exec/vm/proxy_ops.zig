const std = @import("std");
const bytecode = @import("../../bytecode/root.zig");
const builtins = @import("../../builtins/root.zig");
const core = @import("../../core/root.zig");
const frame_mod = @import("../frame.zig");
const property_ops = @import("../property_ops.zig");
const value_ops = @import("../value_ops.zig");
const HostError = exceptions.HostError;
const exceptions = @import("../exceptions.zig");

const shared_vm = @import("shared.zig");
const atomListContains = shared_vm.atomListContains;
const callValueOrBytecode = shared_vm.callValueOrBytecode;
const callableObjectFromValue = shared_vm.callableObjectFromValue;
const constructValueOrBytecode = shared_vm.constructValueOrBytecode;
const createArrayFromArgs = shared_vm.createArrayFromArgs;
const defineValueProperty = shared_vm.defineValueProperty;
const descriptorObjectFromDescriptor = shared_vm.descriptorObjectFromDescriptor;
const functionObjectFromValue = shared_vm.functionObjectFromValue;
const getValueProperty = shared_vm.getValueProperty;
const getValuePropertyWithReceiver = shared_vm.getValuePropertyWithReceiver;
const isCallableValue = shared_vm.isCallableValue;
const isConstructorLike = shared_vm.isConstructorLike;
const isFunctionLikeClass = shared_vm.isFunctionLikeClass;
const objectFromValue = shared_vm.objectFromValue;
const objectPrototypeFromGlobal = shared_vm.objectPrototypeFromGlobal;
const objectRestOwnKeys = shared_vm.objectRestOwnKeys;
const ordinarySetWithReceiver = shared_vm.ordinarySetWithReceiver;
const qjsDescriptorFromObject = shared_vm.qjsDescriptorFromObject;
const qjsObjectGetPrototypeOfStep = shared_vm.qjsObjectGetPrototypeOfStep;
const qjsReflectConstructGenericCallable = shared_vm.qjsReflectConstructGenericCallable;
const typedArrayCanonicalOwnDescriptor = shared_vm.typedArrayCanonicalOwnDescriptor;
const valueTruthy = shared_vm.valueTruthy;


pub fn proxySetTrapForErrorStackSetter(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver_value: core.JSValue,
    receiver: *core.Object,
    stack_key: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    const target_value = receiver.proxyTarget() orelse return false;
    const handler_value = receiver.proxyHandler() orelse return error.TypeError;
    const set_atom = try ctx.runtime.internAtom("set");
    defer ctx.runtime.atoms.free(set_atom);
    const trap = try getValueProperty(ctx, output, global, handler_value, set_atom, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) return false;
    if (!isCallableValue(trap)) return error.TypeError;

    const key_value = try proxyTrapKeyValue(ctx.runtime, stack_key);
    defer key_value.free(ctx.runtime);
    const result = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{ target_value, key_value, value, receiver_value }, caller_function, caller_frame);
    defer result.free(ctx.runtime);
    if (!valueTruthy(result)) return error.TypeError;
    const target = try property_ops.expectObject(target_value);
    try validateProxySetResult(ctx, output, global, target, stack_key, value, caller_function, caller_frame);
    return true;
}

pub fn isRevokedProxy(object: *core.Object) bool {
    return object.is_proxy and object.proxyHandler() == null;
}

pub fn proxyCreateDataPropertyOrThrow(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver_value: core.JSValue,
    proxy: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const target_value = proxy.proxyTarget() orelse return error.TypeError;
    const target = property_ops.expectObject(target_value) catch return error.TypeError;
    const handler_value = proxy.proxyHandler() orelse return error.TypeError;
    const trap_atom = try ctx.runtime.internAtom("defineProperty");
    defer ctx.runtime.atoms.free(trap_atom);
    const trap = try getValueProperty(ctx, output, global, handler_value, trap_atom, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) {
        target.defineOwnProperty(ctx.runtime, atom_id, core.Descriptor.data(value, true, true, true)) catch |err| switch (err) {
            error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
            else => return err,
        };
        return;
    }
    if (!isCallableValue(trap)) return error.TypeError;

    const key_value = try proxyTrapKeyValue(ctx.runtime, atom_id);
    defer key_value.free(ctx.runtime);
    const desc_object = try core.Object.create(ctx.runtime, core.class.ids.object, objectPrototypeFromGlobal(ctx.runtime, global));
    const desc_value = desc_object.value();
    defer desc_value.free(ctx.runtime);
    try defineValueProperty(ctx.runtime, desc_object, "value", value);
    try defineValueProperty(ctx.runtime, desc_object, "writable", core.JSValue.boolean(true));
    try defineValueProperty(ctx.runtime, desc_object, "enumerable", core.JSValue.boolean(true));
    try defineValueProperty(ctx.runtime, desc_object, "configurable", core.JSValue.boolean(true));
    const result = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{ target_value, key_value, desc_value }, caller_function, caller_frame);
    defer result.free(ctx.runtime);
    if (!value_ops.isTruthy(result)) return error.TypeError;
    _ = receiver_value;
}

pub fn validateProxyOwnKeysResult(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target_value: core.JSValue,
    result_keys: []const core.Atom,
) HostError!void {
    const rt = ctx.runtime;
    const target = try property_ops.expectObject(target_value);
    const target_keys = try objectRestOwnKeys(ctx, output, global, target);
    defer core.Object.freeKeys(rt, target_keys);
    const target_extensible = target.isExtensible();

    for (target_keys) |target_key| {
        const desc = target.getOwnProperty(target_key) orelse continue;
        defer desc.destroy(rt);
        if (desc.configurable == false or !target_extensible) {
            if (!atomListContains(result_keys, target_key)) return error.TypeError;
        }
    }
    if (!target_extensible) {
        for (result_keys) |result_key| {
            if (!atomListContains(target_keys, result_key)) return error.TypeError;
        }
    }
}

pub fn proxyAwareOwnPropertyDescriptor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    source: *core.Object,
    key: core.Atom,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.Descriptor {
    if (source.proxyTarget() == null) {
        if (try typedArrayCanonicalOwnDescriptor(ctx.runtime, source, key)) |desc| return desc;
        if (source.moduleNamespaceOwnBindingValue(key)) |binding_value| {
            defer binding_value.free(ctx.runtime);
            if (binding_value.isUninitialized()) return error.ReferenceError;
        }
        return source.getOwnProperty(key);
    }
    const target_value = source.proxyTarget() orelse return error.TypeError;
    const target = try property_ops.expectObject(target_value);
    const handler_value = source.proxyHandler() orelse return error.TypeError;
    const trap_atom = try ctx.runtime.internAtom("getOwnPropertyDescriptor");
    defer ctx.runtime.atoms.free(trap_atom);
    const trap = try getValueProperty(ctx, output, global, handler_value, trap_atom, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) {
        return try proxyAwareOwnPropertyDescriptor(ctx, output, global, target, key, caller_function, caller_frame);
    }
    if (!isCallableValue(trap)) return error.TypeError;
    const key_value = try proxyTrapKeyValue(ctx.runtime, key);
    defer key_value.free(ctx.runtime);
    const desc_value = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{ target_value, key_value }, caller_function, caller_frame);
    defer desc_value.free(ctx.runtime);
    const target_desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, target, key, caller_function, caller_frame);
    defer if (target_desc) |item| item.destroy(ctx.runtime);
    const target_extensible = try proxyAwareIsExtensible(ctx, output, global, target, caller_function, caller_frame);
    if (desc_value.isUndefined()) {
        if (target_desc) |item| {
            if (item.configurable == false or !target_extensible) return error.TypeError;
        }
        return null;
    }
    const desc_object = property_ops.expectObject(desc_value) catch return error.TypeError;
    var result_desc = try qjsDescriptorFromObject(ctx, output, global, desc_value, desc_object, target, key, caller_function, caller_frame);
    errdefer result_desc.destroy(ctx.runtime);
    var complete_desc = try completeProxyDescriptor(ctx.runtime, result_desc);
    errdefer complete_desc.destroy(ctx.runtime);
    if (!try isCompatibleProxyDescriptor(target_extensible, target_desc, complete_desc)) return error.TypeError;
    if (complete_desc.configurable == false) {
        if (target_desc) |item| {
            if (item.configurable != false) return error.TypeError;
            if (complete_desc.kind == .data and complete_desc.writable == false and item.kind == .data and item.writable == true) return error.TypeError;
        } else {
            return error.TypeError;
        }
    }
    result_desc.destroy(ctx.runtime);
    return complete_desc;
}

pub fn proxyAwareIsExtensible(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    if (object.proxyTarget() == null) return object.isExtensible();
    const target_value = object.proxyTarget() orelse return error.TypeError;
    const target = try property_ops.expectObject(target_value);
    const handler_value = object.proxyHandler() orelse return error.TypeError;
    const trap_atom = try ctx.runtime.internAtom("isExtensible");
    defer ctx.runtime.atoms.free(trap_atom);
    const trap = try getValueProperty(ctx, output, global, handler_value, trap_atom, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) return try proxyAwareIsExtensible(ctx, output, global, target, caller_function, caller_frame);
    if (!isCallableValue(trap)) return error.TypeError;
    const result = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{target_value}, caller_function, caller_frame);
    defer result.free(ctx.runtime);
    const extensible = valueTruthy(result);
    if (extensible != try proxyAwareIsExtensible(ctx, output, global, target, caller_function, caller_frame)) return error.TypeError;
    return extensible;
}

pub fn proxyAwarePreventExtensions(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    const target_value = object.proxyTarget() orelse {
        object.preventExtensions();
        return true;
    };
    const target = try property_ops.expectObject(target_value);
    const handler_value = object.proxyHandler() orelse return error.TypeError;
    const trap_atom = try ctx.runtime.internAtom("preventExtensions");
    defer ctx.runtime.atoms.free(trap_atom);
    const trap = try getValueProperty(ctx, output, global, handler_value, trap_atom, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) return proxyAwarePreventExtensions(ctx, output, global, target, caller_function, caller_frame);
    if (!isCallableValue(trap)) return error.TypeError;
    const result = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{target_value}, caller_function, caller_frame);
    defer result.free(ctx.runtime);
    if (!valueTruthy(result)) return false;
    if (try proxyAwareIsExtensible(ctx, output, global, target, caller_function, caller_frame)) return error.TypeError;
    return true;
}

pub fn proxyAwareSetPrototypeOf(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    prototype: ?*core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    const target_value = object.proxyTarget() orelse {
        object.setPrototype(ctx.runtime, prototype) catch |err| switch (err) {
            error.PrototypeCycle, error.NotExtensible => return false,
            else => return err,
        };
        return true;
    };
    const target = try property_ops.expectObject(target_value);
    const handler_value = object.proxyHandler() orelse return error.TypeError;
    const trap_atom = try ctx.runtime.internAtom("setPrototypeOf");
    defer ctx.runtime.atoms.free(trap_atom);
    const trap = try getValueProperty(ctx, output, global, handler_value, trap_atom, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    const proto_value = if (prototype) |proto| proto.value() else core.JSValue.nullValue();
    if (trap.isUndefined() or trap.isNull()) return proxyAwareSetPrototypeOf(ctx, output, global, target, prototype, caller_function, caller_frame);
    if (!isCallableValue(trap)) return error.TypeError;
    const result = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{ target_value, proto_value }, caller_function, caller_frame);
    defer result.free(ctx.runtime);
    if (!valueTruthy(result)) return false;
    if (!try proxyAwareIsExtensible(ctx, output, global, target, caller_function, caller_frame)) {
        const target_proto = try qjsObjectGetPrototypeOfStep(ctx, output, global, target, caller_function, caller_frame);
        if (target_proto != prototype) return error.TypeError;
    }
    return true;
}

pub fn completeProxyDescriptor(rt: *core.JSRuntime, desc: core.Descriptor) !core.Descriptor {
    _ = rt;
    return switch (desc.kind) {
        .generic, .data => core.Descriptor.data(
            if (desc.value_present) desc.value.dup() else core.JSValue.undefinedValue(),
            desc.writable orelse false,
            desc.enumerable orelse false,
            desc.configurable orelse false,
        ),
        .accessor => core.Descriptor.accessor(
            if (desc.getter_present) desc.getter.dup() else core.JSValue.undefinedValue(),
            if (desc.setter_present) desc.setter.dup() else core.JSValue.undefinedValue(),
            desc.enumerable orelse false,
            desc.configurable orelse false,
        ),
    };
}

pub fn isCompatibleProxyDescriptor(extensible: bool, current: ?core.Descriptor, desc: core.Descriptor) !bool {
    const current_desc = current orelse return extensible;
    if (current_desc.configurable orelse false) return true;
    if (desc.configurable orelse false) return false;
    if (desc.enumerable) |enumerable| {
        if (enumerable != (current_desc.enumerable orelse false)) return false;
    }
    if (desc.kind == .generic) return true;

    const current_is_accessor = current_desc.kind == .accessor;
    if ((desc.kind == .accessor) != current_is_accessor) return false;
    if (!current_is_accessor and !(current_desc.writable orelse false)) {
        if (desc.writable orelse false) return false;
        if (desc.kind == .data and desc.value_present and !builtins.object.sameValue(current_desc.value, desc.value)) return false;
    }
    if (current_is_accessor and desc.kind == .accessor) {
        if (desc.getter_present and !builtins.object.sameValue(current_desc.getter, desc.getter)) return false;
        if (desc.setter_present and !builtins.object.sameValue(current_desc.setter, desc.setter)) return false;
    }
    return true;
}

pub fn proxyTargetIsCallable(value: core.JSValue) bool {
    const object = objectFromValue(value) orelse return false;
    const target = object.proxyTarget() orelse return false;
    return target.isFunctionBytecode() or functionObjectFromValue(target) != null or callableObjectFromValue(target) != null or proxyTargetIsCallable(target);
}

pub fn proxyTargetIsConstructor(ctx: *core.JSContext, value: core.JSValue) bool {
    const object = objectFromValue(value) orelse return false;
    const target = object.proxyTarget() orelse return false;
    return isConstructorLike(ctx, target);
}

pub fn callProxyApply(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    proxy_value: core.JSValue,
    proxy: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = proxy_value;
    const target_value = proxy.proxyTarget() orelse return error.TypeError;
    const handler_value = proxy.proxyHandler() orelse return error.TypeError;
    const apply_atom = try ctx.runtime.internAtom("apply");
    defer ctx.runtime.atoms.free(apply_atom);
    const trap = try getValueProperty(ctx, output, global, handler_value, apply_atom, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) {
        return callValueOrBytecode(ctx, output, global, this_value, target_value, args, caller_function, caller_frame);
    }
    if (!isCallableValue(trap)) return error.TypeError;
    const arg_array = try createArrayFromArgs(ctx.runtime, global, args);
    defer arg_array.free(ctx.runtime);
    return callValueOrBytecode(ctx, output, global, handler_value, trap, &.{ target_value, this_value, arg_array }, caller_function, caller_frame);
}

pub fn constructProxy(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    proxy_value: core.JSValue,
    proxy: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    new_target_value: core.JSValue,
) !core.JSValue {
    if (!proxyTargetIsConstructor(ctx, proxy_value)) return error.TypeError;
    const target_value = proxy.proxyTarget() orelse return error.TypeError;
    const handler_value = proxy.proxyHandler() orelse return error.TypeError;
    const construct_atom = try ctx.runtime.internAtom("construct");
    defer ctx.runtime.atoms.free(construct_atom);
    const trap = try getValueProperty(ctx, output, global, handler_value, construct_atom, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) {
        if (try qjsReflectConstructGenericCallable(ctx, output, global, target_value, new_target_value, args, caller_function, caller_frame)) |value| return value;
        return constructValueOrBytecode(ctx, output, global, target_value, args, caller_function, caller_frame);
    }
    if (!isCallableValue(trap)) return error.TypeError;
    const arg_array = try createArrayFromArgs(ctx.runtime, global, args);
    defer arg_array.free(ctx.runtime);
    const result = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{ target_value, arg_array, new_target_value }, caller_function, caller_frame);
    if (!result.isObject()) {
        result.free(ctx.runtime);
        return error.TypeError;
    }
    return result;
}

pub fn getProxyProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver_value: core.JSValue,
    proxy: *core.Object,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!core.JSValue {
    const target_value = (proxy.proxyTarget() orelse return error.TypeError).dup();
    defer target_value.free(ctx.runtime);
    const handler_value = (proxy.proxyHandler() orelse return error.TypeError).dup();
    defer handler_value.free(ctx.runtime);
    const get_atom = try ctx.runtime.internAtom("get");
    defer ctx.runtime.atoms.free(get_atom);
    const trap = try getValueProperty(ctx, output, global, handler_value, get_atom, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    const target = try property_ops.expectObject(target_value);
    if (trap.isUndefined() or trap.isNull()) return getValuePropertyWithReceiver(ctx, output, global, target_value, target, receiver_value, atom_id, caller_function, caller_frame);
    const key_value = try proxyTrapKeyValue(ctx.runtime, atom_id);
    defer key_value.free(ctx.runtime);
    const result = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{ target_value, key_value, receiver_value }, caller_function, caller_frame);
    errdefer result.free(ctx.runtime);
    try validateProxyGetResult(ctx, output, global, target, atom_id, result, caller_function, caller_frame);
    return result;
}

pub fn validateProxyGetResult(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target: *core.Object,
    atom_id: core.Atom,
    result: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const target_desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, target, atom_id, caller_function, caller_frame) orelse return;
    defer target_desc.destroy(ctx.runtime);
    if (target_desc.configurable != false) return;
    switch (target_desc.kind) {
        .data => {
            if (target_desc.writable == false and !builtins.object.sameValue(result, target_desc.value)) return error.TypeError;
        },
        .accessor => {
            if (target_desc.getter.isUndefined() and !result.isUndefined()) return error.TypeError;
        },
        .generic => {},
    }
}

pub fn firstProxyInPrototypeSetPath(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) !?*core.Object {
    var current = object.getPrototype();
    while (current) |prototype| : (current = prototype.getPrototype()) {
        if (prototype.proxyTarget() != null) return prototype;
        if (prototype.getOwnProperty(atom_id)) |desc| {
            desc.destroy(rt);
            return null;
        }
    }
    return null;
}

pub fn proxySetValueProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver_value: core.JSValue,
    proxy: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!bool {
    const target_value = proxy.proxyTarget() orelse return error.TypeError;
    const handler_value = proxy.proxyHandler() orelse return error.TypeError;
    const set_atom = try ctx.runtime.internAtom("set");
    defer ctx.runtime.atoms.free(set_atom);
    const trap = try getValueProperty(ctx, output, global, handler_value, set_atom, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) {
        const target = try property_ops.expectObject(target_value);
        return ordinarySetWithReceiver(ctx, output, global, target_value, target, receiver_value, atom_id, value, caller_function, caller_frame);
    }
    if (!isCallableValue(trap)) return error.TypeError;
    const key_value = try proxyTrapKeyValue(ctx.runtime, atom_id);
    defer key_value.free(ctx.runtime);
    const result = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{ target_value, key_value, value, receiver_value }, caller_function, caller_frame);
    defer result.free(ctx.runtime);
    if (!valueTruthy(result)) return false;
    const target = try property_ops.expectObject(target_value);
    try validateProxySetResult(ctx, output, global, target, atom_id, value, caller_function, caller_frame);
    return true;
}

pub fn validateProxySetResult(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const target_desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, target, atom_id, caller_function, caller_frame) orelse return;
    defer target_desc.destroy(ctx.runtime);
    if (target_desc.configurable != false) return;
    switch (target_desc.kind) {
        .data => {
            if (target_desc.writable == false and !builtins.object.sameValue(value, target_desc.value)) return error.TypeError;
        },
        .accessor => {
            if (target_desc.setter.isUndefined()) return error.TypeError;
        },
        .generic => {},
    }
}

pub fn proxyDefineValueForReflectSet(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver_value: core.JSValue,
    proxy: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    var rooted_value = value;
    var key_value = core.JSValue.undefinedValue();
    var desc_value = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
        .{ .value = &key_value },
        .{ .value = &desc_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    const target_value = proxy.proxyTarget() orelse return error.TypeError;
    const handler_value = proxy.proxyHandler() orelse return error.TypeError;
    key_value = try proxyTrapKeyValue(ctx.runtime, atom_id);
    defer key_value.free(ctx.runtime);

    const get_desc_atom = try ctx.runtime.internAtom("getOwnPropertyDescriptor");
    defer ctx.runtime.atoms.free(get_desc_atom);
    const get_desc = try getValueProperty(ctx, output, global, handler_value, get_desc_atom, caller_function, caller_frame);
    defer get_desc.free(ctx.runtime);
    if (!get_desc.isUndefined() and !get_desc.isNull()) {
        if (!isCallableValue(get_desc)) return error.TypeError;
        const result = try callValueOrBytecode(ctx, output, global, handler_value, get_desc, &.{ target_value, key_value }, caller_function, caller_frame);
        result.free(ctx.runtime);
    }

    const define_atom = try ctx.runtime.internAtom("defineProperty");
    defer ctx.runtime.atoms.free(define_atom);
    const define = try getValueProperty(ctx, output, global, handler_value, define_atom, caller_function, caller_frame);
    defer define.free(ctx.runtime);
    if (define.isUndefined() or define.isNull()) {
        const target = try property_ops.expectObject(target_value);
        target.defineOwnProperty(ctx.runtime, atom_id, core.Descriptor.data(rooted_value, true, true, true)) catch |err| switch (err) {
            error.InvalidLength => return error.RangeError,
            error.ReadOnly, error.NotExtensible, error.IncompatibleDescriptor => return error.TypeError,
            else => return err,
        };
        return;
    }
    if (!isCallableValue(define)) return error.TypeError;
    const desc_object = try core.Object.create(ctx.runtime, core.class.ids.object, objectPrototypeFromGlobal(ctx.runtime, global));
    desc_value = desc_object.value();
    defer desc_value.free(ctx.runtime);
    try defineValueProperty(ctx.runtime, desc_object, "value", rooted_value);
    const result = try callValueOrBytecode(ctx, output, global, handler_value, define, &.{ target_value, key_value, desc_value }, caller_function, caller_frame);
    defer result.free(ctx.runtime);
    if (!valueTruthy(result)) return error.TypeError;
    _ = receiver_value;
}

pub fn proxyTargetIsCallableObject(object: *core.Object) bool {
    if (isFunctionLikeClass(object.class_id)) return true;
    if (!object.is_proxy) return false;
    const target = object.proxyTarget() orelse return false;
    return target.isFunctionBytecode() or functionObjectFromValue(target) != null or callableObjectFromValue(target) != null or proxyTargetIsCallable(target);
}

pub fn proxyDefineOwnProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    proxy: *core.Object,
    atom_id: core.Atom,
    desc: core.Descriptor,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    const target_value = proxy.proxyTarget() orelse return error.TypeError;
    const target = property_ops.expectObject(target_value) catch return error.TypeError;
    const handler_value = proxy.proxyHandler() orelse return error.TypeError;
    const trap_atom = try ctx.runtime.internAtom("defineProperty");
    defer ctx.runtime.atoms.free(trap_atom);
    const trap = try getValueProperty(ctx, output, global, handler_value, trap_atom, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) {
        if (target.proxyTarget() != null) return try proxyDefineOwnProperty(ctx, output, global, target, atom_id, desc, caller_function, caller_frame);
        target.defineOwnProperty(ctx.runtime, atom_id, desc) catch |err| switch (err) {
            error.ReadOnly, error.NotExtensible, error.IncompatibleDescriptor => return false,
            error.InvalidLength => return error.RangeError,
            else => return err,
        };
        return true;
    }
    if (!isCallableValue(trap)) return error.TypeError;
    const key_value = try proxyTrapKeyValue(ctx.runtime, atom_id);
    defer key_value.free(ctx.runtime);
    const desc_value = try descriptorObjectFromDescriptor(ctx.runtime, global, desc);
    defer desc_value.free(ctx.runtime);
    const result = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{ target_value, key_value, desc_value }, caller_function, caller_frame);
    defer result.free(ctx.runtime);
    if (!valueTruthy(result)) return false;
    const target_desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, target, atom_id, caller_function, caller_frame);
    defer if (target_desc) |item| item.destroy(ctx.runtime);
    const target_extensible = try proxyAwareIsExtensible(ctx, output, global, target, caller_function, caller_frame);
    if (!try isCompatibleProxyDescriptor(target_extensible, target_desc, desc)) return error.TypeError;
    const setting_config_false = desc.configurable == false;
    if (setting_config_false) {
        if (target_desc) |item| {
            if (item.configurable != false) return error.TypeError;
        } else {
            return error.TypeError;
        }
    }
    if (target_desc) |item| {
        if (item.configurable == false and item.kind == .data and item.writable == true and desc.kind == .data and desc.writable == false) return error.TypeError;
    }
    return true;
}

pub fn validateProxyHasResult(rt: *core.JSRuntime, target: *core.Object, atom_id: core.Atom, result: bool) !bool {
    if (result) return true;
    if (target.getOwnProperty(atom_id)) |desc| {
        defer desc.destroy(rt);
        if (desc.configurable == false) return error.TypeError;
        if (!target.isExtensible()) return error.TypeError;
    }
    return false;
}

pub fn proxyTrapKeyValue(rt: *core.JSRuntime, atom_id: core.Atom) !core.JSValue {
    if (rt.atoms.kind(atom_id) == .symbol) return core.JSValue.symbol(atom_id);
    return rt.atoms.toStringValue(rt, atom_id);
}