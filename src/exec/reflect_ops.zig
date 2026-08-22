//! Reflect.* and Proxy.revocable implementations: the reflective surface of the exec call machinery.

const core = @import("../core/root.zig");
const call_mod = @import("call.zig");
const exception_ops = @import("exception_ops.zig");
const promise_ops = @import("promise_ops.zig");
const reflect_dispatch = core.host_function.builtin_method_ids.reflect;
const frame_mod = @import("frame.zig");
const bytecode = @import("../bytecode.zig");
const std = @import("std");

const array_ops = @import("array_ops.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
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

// `Reflect.construct(Array, ...)` routes through the Array construct record; the
// Array constructor object carries no native id (so the native-id construct
// dispatch above misses it and the name cascade reaches here), hence this
// explicit ref.
const array_construct_ref = core.function.NativeBuiltinRef{
    .domain = .array,
    .id = @intFromEnum(core.host_function.builtin_method_ids.array.ConstructorMethod.construct),
};

// Shared call-runtime helpers that stay with the dispatcher in exec/call.zig.
const activeGlobalObject = call.activeGlobalObject;
const callValueWithThisGlobalsAndGlobal = call.callValueWithThisGlobalsAndGlobal;
const defineObjectProperty = call.defineObjectProperty;
const descriptorFromObjectBare = call.descriptorFromObjectBare;
const expectObjectArg = call.expectObjectArg;
const functionPrototypeFromGlobal = object_ops.functionPrototypeFromGlobal;
const getValuePropertyViaGlobalSlots = call.getValuePropertyViaGlobalSlots;
const isCallableObjectValue = call.isCallableObjectValue;
const nativeFunctionName = call.nativeFunctionName;
const primitiveWrapper = call.primitiveWrapper;
const thisObject = call.thisObject;

pub fn reflectConstruct(ctx: *core.JSContext, args: []const core.JSValue, globals: []globals_mod.Slot) !core.JSValue {
    const rt = ctx.runtime;
    if (args.len < 2) return error.TypeError;
    if (!isConstructorValue(rt, args[0])) return error.TypeError;
    const target = thisObject(args[0]) orelse return error.TypeError;
    const target_name = nativeFunctionName(rt, target) catch null;
    defer if (target_name) |name| rt.memory.allocator.free(name);
    const new_target = if (args.len >= 3) args[2] else args[0];
    if (!isConstructorValue(rt, new_target)) return error.TypeError;
    // Table-dispatched builtin constructors (Date/RegExp/String carry a native
    // builtin id and a construct-capable record): resolve the instance
    // `[[Prototype]]` and run the record's construct branch through the table,
    // matching the `exec/construct.zig` `new X()` path (Phase 6b-3d/6b-3e). This
    // is the null-global `Reflect.construct` fallback (the VM-global path runs
    // through `reflectConstructCall` -> the VM construct dispatcher), so the
    // raw argument-list values are forwarded without VM-context coercion, as
    // before.
    if (core.function.decodeNativeBuiltinId(target.nativeFunctionId())) |native_ref| {
        if (reflectConstructTargetName(native_ref)) |proto_name| {
            var construct_args = ReflectConstructArguments{};
            try construct_args.init(rt, args[1]);
            defer construct_args.deinit();
            var prototype = try reflectConstructPrototype(ctx, proto_name, new_target);
            defer prototype.deinit(rt);
            if (try builtin_dispatch.callConstructRecord(ctx, null, null, globals, target, native_ref, prototype.object(), construct_args.values, null, null)) |value| return value;
        }
    }
    if (target_name) |name| {
        if (std.mem.eql(u8, name, "Array") and target.arrayBuiltinMarker() == .constructor) {
            if (args.len < 2) return error.TypeError;
            var construct_args = ReflectConstructArguments{};
            try construct_args.init(rt, args[1]);
            defer construct_args.deinit();
            var prototype = try reflectConstructPrototype(ctx, name, new_target);
            defer prototype.deinit(rt);
            return (try builtin_dispatch.callConstructRecord(ctx, null, null, globals, target, array_construct_ref, prototype.object(), construct_args.values, null, null)) orelse error.TypeError;
        }
        if (std.mem.eql(u8, name, "Iterator")) {
            if (new_target.sameValue(args[0])) return error.TypeError;
            var prototype = try reflectConstructPrototype(ctx, name, new_target);
            defer prototype.deinit(rt);
            const instance = try core.Object.create(rt, core.class.ids.object, prototype.object());
            errdefer core.Object.destroyFromHeader(rt, &instance.header);
            return instance.value();
        }
        if (std.mem.eql(u8, name, "Number")) {
            var construct_args = ReflectConstructArguments{};
            try construct_args.init(rt, args[1]);
            defer construct_args.deinit();
            const primitive = if (construct_args.values.len >= 1) blk: {
                if (construct_args.values[0].isSymbol()) return error.TypeError;
                // qjs js_number_constructor (quickjs.c:44822-44841): ToNumeric,
                // then a bigint result converts to float64 rather than throwing.
                if (construct_args.values[0].isBigInt()) {
                    break :blk value_ops.numberToValue(try value_ops.bigIntToNumber(rt, construct_args.values[0]));
                }
                break :blk value_ops.numberToValue(try value_ops.toIntegerOrInfinity(rt, construct_args.values[0]));
            } else core.JSValue.int32(0);
            var prototype = try reflectConstructPrototype(ctx, name, new_target);
            defer prototype.deinit(rt);
            return primitiveWrapper(ctx, core.class.ids.number, primitive, prototype.object());
        }
        if (std.mem.eql(u8, name, "FinalizationRegistry")) {
            var construct_args = ReflectConstructArguments{};
            try construct_args.init(rt, args[1]);
            defer construct_args.deinit();
            const cleanup_callback = if (construct_args.values.len >= 1) construct_args.values[0] else return error.TypeError;
            if (!isCallableObjectValue(cleanup_callback)) return error.TypeError;
            var prototype = try reflectConstructPrototype(ctx, name, new_target);
            defer prototype.deinit(rt);
            const instance = try core.Object.createFinalizationRegistry(rt, ctx, prototype.object());
            errdefer core.Object.destroyFromHeader(rt, &instance.header);
            try instance.setOptionalValueSlot(rt, instance.finalizationRegistryCleanupCallbackSlot(), cleanup_callback.dup());
            return instance.value();
        }
        if (std.mem.eql(u8, name, "WeakRef")) {
            var construct_args = ReflectConstructArguments{};
            try construct_args.init(rt, args[1]);
            defer construct_args.deinit();
            const target_value = if (construct_args.values.len >= 1) construct_args.values[0] else return error.TypeError;
            if (!core.symbol.canBeHeldWeakly(rt, target_value)) return error.TypeError;
            var prototype = try reflectConstructPrototype(ctx, name, new_target);
            defer prototype.deinit(rt);
            return construct_mod.weakRefWithPrototype(rt, target_value, prototype.object());
        }
        if (core.host_function.builtin_method_id_lookup.collection.constructorId(name)) |kind| {
            var prototype = try reflectConstructPrototype(ctx, name, new_target);
            defer prototype.deinit(rt);
            const construct_id = core.host_function.builtin_method_id_lookup.collection.constructIdForKind(kind) orelse return error.TypeError;
            const collection_construct_ref = core.function.NativeBuiltinRef{ .domain = .collection, .id = construct_id };
            return (try builtin_dispatch.callConstructRecord(ctx, null, null, globals, target, collection_construct_ref, prototype.object(), &.{}, null, null)) orelse error.TypeError;
        }
        if (construct_mod.typedArrayElement(name)) |element| {
            var construct_args = ReflectConstructArguments{};
            try construct_args.init(rt, args[1]);
            defer construct_args.deinit();
            var prototype = try reflectConstructPrototype(ctx, name, new_target);
            defer prototype.deinit(rt);
            return construct_mod.constructTypedArrayValue(rt, target, prototype.object(), element, construct_args.values);
        }
    }

    {
        var prototype = try reflectConstructPrototype(ctx, target_name orelse "Object", new_target);
        defer prototype.deinit(rt);
        const instance = try core.Object.create(rt, core.class.ids.object, prototype.object());
        errdefer core.Object.destroyFromHeader(rt, &instance.header);
        return instance.value();
    }
}

/// Map a decoded native-builtin id to the intrinsic instance class name used
/// by `reflectConstructPrototype`, for the construct-capable records `Reflect
/// .construct` routes through the table. Returns null for ids that are not
/// table-dispatched construct records here, so they fall through to the
/// name cascade / ordinary-instance fallback below.
fn reflectConstructTargetName(native_ref: core.function.NativeBuiltinRef) ?[]const u8 {
    const ids = core.host_function.builtin_method_ids;
    return switch (native_ref.domain) {
        .date => if (native_ref.id == @intFromEnum(ids.date.ConstructorMethod.construct)) "Date" else null,
        .regexp => if (native_ref.id == @intFromEnum(ids.regexp.ConstructorMethod.construct)) "RegExp" else null,
        .string => if (native_ref.id == @intFromEnum(ids.string.ConstructorMethod.call)) "String" else null,
        else => null,
    };
}

const ReflectConstructArguments = struct {
    rt: ?*core.JSRuntime = null,
    values: []core.JSValue = &.{},
    root: ValueSliceRoot = .{},

    fn init(self: *ReflectConstructArguments, rt: *core.JSRuntime, value: core.JSValue) !void {
        self.values = try reflectConstructArgumentList(rt, value);
        self.rt = rt;
        self.root.init(rt, &self.values);
    }

    fn deinit(self: *ReflectConstructArguments) void {
        const rt = self.rt orelse return;
        self.root.deinit();
        freeReflectConstructArgumentList(rt, self.values);
        self.* = .{};
    }
};

fn reflectConstructArgumentList(rt: *core.JSRuntime, value: core.JSValue) ![]core.JSValue {
    const object = try expectObjectArg(value);
    if (!object.isArray()) return error.TypeError;
    const out = try rt.memory.alloc(core.JSValue, object.arrayLength());
    errdefer rt.memory.free(core.JSValue, out);
    var rooted_out: []core.JSValue = out[0..0];
    var out_root = ValueSliceRoot{};
    out_root.init(rt, &rooted_out);
    defer out_root.deinit();
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |item| item.free(rt);
    }
    var index: u32 = 0;
    while (index < object.arrayLength()) : (index += 1) {
        out[index] = try object.getProperty(core.atom.atomFromUInt32(index));
        initialized += 1;
        rooted_out = out[0..initialized];
    }
    return out;
}

fn freeReflectConstructArgumentList(rt: *core.JSRuntime, values: []core.JSValue) void {
    for (values) |value| value.free(rt);
    if (values.len != 0) rt.memory.free(core.JSValue, values);
}

fn isConstructorValue(rt: *core.JSRuntime, value: core.JSValue) bool {
    if (!value_ops.isFunctionObject(value)) return false;
    const object = thisObject(value) orelse return false;
    if (object.proxyTarget()) |target| return isConstructorValue(rt, target);
    return switch (object.class_id) {
        core.class.ids.c_function => {
            if (object.hostFunctionKind() == core.host_function.ids.external_host) {
                return object.hasOwnProperty(core.atom.ids.prototype);
            }
            // A construct-capable builtin native id (Date/RegExp/String) marks a
            // constructor regardless of dispatch name (Phase 6b-3e: replaces the
            // `date.isConstructorRecord` short circuit with the generic table
            // probe). Otherwise fall back to the builtin-constructor name set.
            if (core.function.decodeNativeBuiltinId(object.nativeFunctionId())) |native_ref| {
                if (builtin_dispatch.isConstructRecordRef(rt, native_ref)) return true;
            }
            const name = nativeFunctionName(rt, object) catch return false;
            defer rt.memory.allocator.free(name);
            return isBuiltinConstructorName(name);
        },
        core.class.ids.bytecode_function,
        core.class.ids.c_closure,
        core.class.ids.bound_function,
        => true,
        else => false,
    };
}

fn reflectConstructPrototype(ctx: *core.JSContext, target_name: []const u8, new_target: core.JSValue) !object_ops.OwnedPrototype {
    const rt = ctx.runtime;
    const new_target_object = thisObject(new_target) orelse return error.TypeError;
    const prototype_value = try new_target_object.getProperty(core.atom.ids.prototype);
    if (prototype_value.isObject()) return .{ .value = prototype_value };
    prototype_value.free(rt);

    const fallback_realm = try call_runtime.functionRealmContext(ctx, new_target);
    if (object_ops.constructorClassPrototypeId(target_name)) |class_id| {
        return object_ops.OwnedPrototype.fromObject(fallback_realm.classPrototypeObject(class_id) orelse return error.InvalidBuiltinRegistry);
    }

    if (object_ops.nativeErrorKindFromConstructorName(target_name)) |kind| {
        return object_ops.OwnedPrototype.fromObject(fallback_realm.nativeErrorPrototypeObject(kind) orelse return error.InvalidBuiltinRegistry);
    }
    return object_ops.OwnedPrototype.fromObject(null);
}

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
    errdefer core.Object.destroyFromHeader(rt, &object.header);

    const proxy = try core.Object.create(rt, core.class.ids.proxy, null);
    var proxy_raw_owned = true;
    errdefer if (proxy_raw_owned) core.Object.destroyFromHeader(rt, &proxy.header);
    try proxy.ensureProxyPayload(rt);
    try proxy.setOptionalValueSlot(rt, proxy.proxyTargetSlot(), rooted_args[0].dup());
    try proxy.setOptionalValueSlot(rt, proxy.proxyHandlerSlot(), rooted_args[1].dup());
    try defineObjectProperty(rt, object, "proxy", proxy.value());
    proxy_raw_owned = false;
    proxy.value().free(rt);
    // QuickJS `js_proxy_revocable` uses JS_NewCFunctionData: the revoker is a
    // captured-data callable and therefore executes in its caller's realm.
    const function_proto = functionPrototypeFromGlobal(rt, realm_global) orelse return error.InvalidBuiltinRegistry;
    const revoke = try core.function.nativeDataFunctionWithPrototype(rt, function_proto, "", 0);
    defer revoke.free(rt);
    const revoke_object = thisObject(revoke) orelse return error.TypeError;
    // Data carriers deliberately do not populate the true-C-function record
    // cache; dispatch decodes this stable id in the final caller-data arm.
    revoke_object.nativeFunctionIdSlot().* = core.function.nativeBuiltinId(.reflect, @intFromEnum(StaticMethod.proxy_revoke));
    try revoke_object.setOptionalValueSlot(rt, try revoke_object.functionProxyRevokeTargetSlot(rt), proxy.value().dup());
    try defineObjectProperty(rt, object, "revoke", revoke);
    return object.value();
}

/// Revoke closure for `Proxy.revocable`: clears the captured proxy's handler
/// so subsequent trap lookups throw. Mirrors QuickJS `js_proxy_revoke`. Stays
/// in exec with the rest of the proxy core; the `.reflect` record handler in
/// reflect_proxy_ops.zig forwards the `proxy_revoke` id here.
pub fn revokeProxy(rt: *core.JSRuntime, function_object: *core.Object) !core.JSValue {
    const proxy_slot = try function_object.functionProxyRevokeTargetSlot(rt);
    const proxy_value = function_object.takeOptionalValueSlot(proxy_slot) orelse return core.JSValue.undefinedValue();
    defer proxy_value.free(rt);
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
    const has_atom = try ctx.runtime.internAtom("has");
    defer ctx.runtime.atoms.free(has_atom);
    const trap = try getValuePropertyViaGlobalSlots(ctx, output, global, globals, handler_value, has_atom);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) return reflectHasProperty(ctx, output, global, globals, target, atom_id);
    const key_value = try object_ops.proxyTrapKeyValue(ctx.runtime, atom_id);
    defer key_value.free(ctx.runtime);
    const result = try callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, handler_value, trap, &.{ target_value, key_value });
    defer result.free(ctx.runtime);
    const trap_result = value_ops.isTruthy(result);
    const global_object = global orelse {
        // Bare-runtime fallback (no realm global): keep the raw target reads;
        // the VM path below mirrors js_proxy_has's exotic-dispatching reads.
        if (trap_result) return true;
        if (try target.getOwnProperty(ctx.runtime, atom_id)) |desc| {
            defer desc.destroy(ctx.runtime);
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

fn isBuiltinConstructorName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Object") or
        std.mem.eql(u8, name, "Function") or
        std.mem.eql(u8, name, "AsyncFunction") or
        std.mem.eql(u8, name, "GeneratorFunction") or
        std.mem.eql(u8, name, "AsyncGeneratorFunction") or
        std.mem.eql(u8, name, "Array") or
        std.mem.eql(u8, name, "String") or
        std.mem.eql(u8, name, "Number") or
        std.mem.eql(u8, name, "Boolean") or
        std.mem.eql(u8, name, "Symbol") or
        std.mem.eql(u8, name, "BigInt") or
        std.mem.eql(u8, name, "Date") or
        std.mem.eql(u8, name, "RegExp") or
        core.error_names.isErrorConstructorName(name) or
        std.mem.eql(u8, name, "Iterator") or
        std.mem.eql(u8, name, "DisposableStack") or
        std.mem.eql(u8, name, "AsyncDisposableStack") or
        std.mem.eql(u8, name, "Promise") or
        std.mem.eql(u8, name, "Map") or
        std.mem.eql(u8, name, "Set") or
        std.mem.eql(u8, name, "WeakMap") or
        std.mem.eql(u8, name, "WeakSet") or
        std.mem.eql(u8, name, "ArrayBuffer") or
        std.mem.eql(u8, name, "DataView");
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
    defer ctx.runtime.atoms.free(atom_id);
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
                        defer coerced.free(ctx.runtime);
                        try core.typed_array.typedArrayCoerceElementValue(ctx.runtime, object, coerced);
                    }
                    return core.JSValue.boolean(true);
                },
                .index => |index| {
                    if (object_ops.sameObjectIdentity(receiver_value, args[0])) {
                        const coerced = try array_ops.coerceTypedArrayElementForSet(ctx, output, global, object, set_value);
                        defer coerced.free(ctx.runtime);
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
    defer if (!value_to_set.same(set_value)) value_to_set.free(ctx.runtime);
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

pub const ReflectConstructResolution = struct {
    target: core.JSValue,
    new_target: core.JSValue,
    args: []const core.JSValue,
    owned_args: []core.JSValue = &.{},
};

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
    defer ctx.runtime.atoms.free(key);
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
    defer ctx.runtime.atoms.free(atom_id);
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
    errdefer core.Object.destroyFromHeader(ctx.runtime, &out.header);
    for (keys) |key| {
        const key_value = try object_ops.proxyTrapKeyValue(ctx.runtime, key);
        defer key_value.free(ctx.runtime);
        try out.defineOwnProperty(ctx.runtime, core.atom.atomFromUInt32(out.arrayLength()), core.Descriptor.data(key_value, true, true, true));
    }
    return out.value();
}
