//! Reflect.* and Proxy.revocable implementations: the reflective surface of the exec call machinery.

const core = @import("../core/root.zig");
const call_mod = @import("call.zig");
const exception_ops = @import("exception_ops.zig");
const reflect_dispatch = core.host_function.builtin_method_ids.reflect;
const frame_mod = @import("frame.zig");
const bytecode = @import("../bytecode.zig");
const std = @import("std");

const array_ops = @import("array_ops.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const call = @import("call.zig");
const call_runtime = @import("call_runtime.zig");
const construct_mod = @import("construct.zig");
const exceptions = @import("exception_ops.zig");
const object_ops = @import("object_ops.zig");
const property_ops = @import("property_ops.zig");

const HostError = exceptions.HostError;

// Static-method ids stay with the registration data in this file.
pub const StaticMethod = core.host_function.builtin_method_ids.reflect.StaticMethod;

// Shared call-runtime helpers that stay with the dispatcher in exec/call.zig.
const defineObjectProperty = call.defineObjectProperty;
const expectObjectArg = call.expectObjectArg;
const functionPrototypeFromGlobal = object_ops.functionPrototypeFromGlobal;
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
    const object = try property_ops.expectObject(args[0]);
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
    // `if (unlikely(p != p1)) goto retry2` skips the
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
    if (!args[0].is(.object)) return error.TypeError;
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
            defer ctx.runtime.nativeAllocator().free(target_name);
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
    const object = try property_ops.expectObject(args[0]);
    const keys = try object_ops.objectRestOwnKeys(ctx, output, global, object);
    defer core.Object.freeKeys(ctx.runtime, keys);
    const out = try core.Object.createArray(ctx.runtime, array_ops.arrayPrototypeFromGlobal(ctx.runtime, global));
    errdefer core.Object.destroyFromHeader(ctx.runtime, out.gcHeader());
    for (keys) |key| {
        const key_value = try object_ops.proxyTrapKeyValue(ctx.runtime, key);
        try out.defineOwnProperty(ctx.runtime, core.Atom.taggedInt(out.arrayLength()), core.Descriptor.data(key_value, .all));
    }
    return out.value();
}

// ----- merged from reflect_proxy_ops.zig -----
// Reflect builtin records and the Proxy.revocable dispatch bridge.
//
// Registry ids and native call decoding live here; reflective internal
// operations, proxy traps, and ownership of revocable targets/revoke closures
// remain in `reflect_ops` and the object model. Call inputs are borrowed and
// returned values are owned.
pub fn methodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "defineProperty")) return @intFromEnum(StaticMethod.define_property);
    if (std.mem.eql(u8, name, "getOwnPropertyDescriptor")) return @intFromEnum(StaticMethod.get_own_property_descriptor);
    if (std.mem.eql(u8, name, "deleteProperty")) return @intFromEnum(StaticMethod.delete_property);
    if (std.mem.eql(u8, name, "get")) return @intFromEnum(StaticMethod.get);
    if (std.mem.eql(u8, name, "getPrototypeOf")) return @intFromEnum(StaticMethod.get_prototype_of);
    if (std.mem.eql(u8, name, "set")) return @intFromEnum(StaticMethod.set);
    if (std.mem.eql(u8, name, "setPrototypeOf")) return @intFromEnum(StaticMethod.set_prototype_of);
    if (std.mem.eql(u8, name, "isExtensible")) return @intFromEnum(StaticMethod.is_extensible);
    if (std.mem.eql(u8, name, "preventExtensions")) return @intFromEnum(StaticMethod.prevent_extensions);
    if (std.mem.eql(u8, name, "has")) return @intFromEnum(StaticMethod.has);
    if (std.mem.eql(u8, name, "ownKeys")) return @intFromEnum(StaticMethod.own_keys);
    if (std.mem.eql(u8, name, "construct")) return @intFromEnum(StaticMethod.construct);
    if (std.mem.eql(u8, name, "apply")) return @intFromEnum(StaticMethod.apply);
    return null;
}

/// Declaration + dispatch table for the `.reflect` native-builtin domain
/// (the `Reflect.*` statics plus the `Proxy.revocable` constructor helper and
/// its revoke closure). One shared record handler `reflectCall` switches on the
/// per-record `magic` (== domain-local `StaticMethod` id) and forwards to the
/// reflective exec VM ops, which stay in exec because the proxy trap core and
/// the object internal ops they call (`object.defineOwnProperty`, proxy trap
/// dispatch, property lookups) are also reached from opcode handlers. `id`
/// doubles as `magic`, so the record carries no extra selector.
///
/// Standard-global bootstrap resolves names/lengths through its Reflect method
/// list and `methodId`; `proxy_revocable` and the dynamically materialized
/// `proxy_revoke` closure bind through `proxyRevocable` directly.
/// This array is consumed by the record-dispatch path (`rt.internal_builtins`).
pub const internal_entries = reflectEntries: {
    const Entry = core.host_function.InternalEntry;
    break :reflectEntries [_]Entry{
        reflectEntry("apply", 3, @intFromEnum(StaticMethod.apply)),
        reflectEntry("construct", 2, @intFromEnum(StaticMethod.construct)),
        reflectEntry("defineProperty", 3, @intFromEnum(StaticMethod.define_property)),
        reflectEntry("deleteProperty", 2, @intFromEnum(StaticMethod.delete_property)),
        reflectEntry("get", 2, @intFromEnum(StaticMethod.get)),
        reflectEntry("getOwnPropertyDescriptor", 2, @intFromEnum(StaticMethod.get_own_property_descriptor)),
        reflectEntry("getPrototypeOf", 1, @intFromEnum(StaticMethod.get_prototype_of)),
        reflectEntry("has", 2, @intFromEnum(StaticMethod.has)),
        reflectEntry("isExtensible", 1, @intFromEnum(StaticMethod.is_extensible)),
        reflectEntry("ownKeys", 1, @intFromEnum(StaticMethod.own_keys)),
        reflectEntry("preventExtensions", 1, @intFromEnum(StaticMethod.prevent_extensions)),
        reflectEntry("set", 3, @intFromEnum(StaticMethod.set)),
        reflectEntry("setPrototypeOf", 2, @intFromEnum(StaticMethod.set_prototype_of)),
        reflectEntry("revocable", 2, @intFromEnum(StaticMethod.proxy_revocable)),
        reflectEntry("revoke", 0, @intFromEnum(StaticMethod.proxy_revoke)),
    };
};
fn reflectEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{
        .name = name,
        .length = length,
        .id = id,
        .magic = @intCast(id),
        .cproto = .generic_magic,
        .native_function = builtin_dispatch.genericMagicFunction(&reflectCall),
    };
}

/// Shared record handler for the `.reflect` domain. Mirrors the retired
/// `call.zig` `callReflectNativeFunctionRecord`: the `Proxy.revocable` helper
/// and its revoke closure run their exec reflect ops, while the 13 `Reflect.*`
/// statics route through `reflectCallForNativeRecord`. These
/// records have no algorithmic func-object-free reuse: every entry is an
/// observable callable and therefore requires its atomic call realm view.
fn reflectCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const ctx = host_call.ctx;
    const output = host_call.output;
    const realm = try builtin_dispatch.callableRealm(host_call);
    std.debug.assert(realm.realm == ctx);
    const global = realm.global;
    const id: u32 = host_call.magic;
    const args = host_call.args;
    const caller_function = builtin_dispatch.callerBytecode(host_call);
    const caller_frame = builtin_dispatch.callerFrame(host_call);

    if (id == @intFromEnum(StaticMethod.proxy_revoke)) {
        const function_object = host_call.func_obj orelse return error.TypeError;
        return revokeProxy(ctx.runtime, function_object);
    }
    if (id == @intFromEnum(StaticMethod.proxy_revocable)) {
        // qjs js_proxy_revocable is a plain JS_CFUNC_DEF that
        // never reads this_val: detached/rebound calls (`const {revocable} =
        // Proxy; revocable(t, h)`) work. No receiver validation.
        return proxyRevocable(ctx.runtime, global, args);
    }
    return try reflectCallForNativeRecord(ctx, output, global, id, args, caller_function, caller_frame);
}
