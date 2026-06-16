//! Reflect.* and Proxy.revocable implementations: the reflective surface of the exec call machinery.

const core = @import("../core/root.zig");
const std = @import("std");

const array_ops = @import("array_ops.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const call = @import("call.zig");
const call_runtime = @import("call_runtime.zig");
const construct_mod = @import("construct.zig");
const exceptions = @import("exceptions.zig");
const globals_mod = @import("globals.zig");
const object_ops = @import("object_ops.zig");
const property_ops = @import("property_ops.zig");
const value_ops = @import("value_ops.zig");

const HostError = exceptions.HostError;
const ValueSliceRoot = array_ops.ValueSliceRoot;

// Static-method ids stay with the registration data in builtins/reflect_proxy.zig.
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
const constructorPrototype = call.constructorPrototype;
const defineObjectProperty = call.defineObjectProperty;
const descriptorFromObject = call.descriptorFromObject;
const expectCallableObject = call.expectCallableObject;
const expectObjectArg = call.expectObjectArg;
const functionPrototypeFromGlobal = call.functionPrototypeFromGlobal;
const getValueProperty = call.getValueProperty;
const isCallableObjectValue = call.isCallableObjectValue;
const nativeFunctionName = call.nativeFunctionName;
const primitiveWrapper = call.primitiveWrapper;
const realmPrototypeKey = call.realmPrototypeKey;
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
    // through `qjsReflectConstructCall` -> the VM construct dispatcher), so the
    // raw argument-list values are forwarded without VM-context coercion, as
    // before.
    if (core.function.decodeNativeBuiltinId(target.nativeFunctionIdSlot().*)) |native_ref| {
        if (reflectConstructTargetName(native_ref)) |proto_name| {
            var construct_args = ReflectConstructArguments{};
            try construct_args.init(rt, args[1]);
            defer construct_args.deinit();
            const prototype = try reflectConstructPrototype(rt, proto_name, new_target, args[0]);
            if (try builtin_dispatch.callConstructRecord(ctx, null, null, globals, target, native_ref, prototype, construct_args.values, null, null)) |value| return value;
        }
    }
    if (target_name) |name| {
        if (std.mem.eql(u8, name, "Array")) {
            if (args.len < 2) return error.TypeError;
            var construct_args = ReflectConstructArguments{};
            try construct_args.init(rt, args[1]);
            defer construct_args.deinit();
            const prototype = try reflectConstructPrototype(rt, name, new_target, args[0]);
            return (try builtin_dispatch.callConstructRecord(ctx, null, null, globals, target, array_construct_ref, prototype, construct_args.values, null, null)) orelse error.TypeError;
        }
        if (std.mem.eql(u8, name, "Iterator")) {
            if (new_target.sameValue(args[0])) return error.TypeError;
            const prototype = try reflectConstructPrototype(rt, name, new_target, args[0]);
            const instance = try core.Object.create(rt, core.class.ids.object, prototype);
            errdefer core.Object.destroyFromHeader(rt, &instance.header);
            return instance.value();
        }
        if (std.mem.eql(u8, name, "Number")) {
            var construct_args = ReflectConstructArguments{};
            try construct_args.init(rt, args[1]);
            defer construct_args.deinit();
            const primitive = if (construct_args.values.len >= 1) blk: {
                if (construct_args.values[0].isSymbol()) return error.TypeError;
                break :blk value_ops.numberToValue(try value_ops.toIntegerOrInfinity(rt, construct_args.values[0]));
            } else core.JSValue.int32(0);
            const prototype = try reflectConstructPrototype(rt, name, new_target, args[0]);
            return primitiveWrapper(ctx, core.class.ids.number, primitive, prototype);
        }
        if (std.mem.eql(u8, name, "FinalizationRegistry")) {
            var construct_args = ReflectConstructArguments{};
            try construct_args.init(rt, args[1]);
            defer construct_args.deinit();
            const cleanup_callback = if (construct_args.values.len >= 1) construct_args.values[0] else return error.TypeError;
            if (!isCallableObjectValue(cleanup_callback)) return error.TypeError;
            const prototype = try reflectConstructPrototype(rt, name, new_target, args[0]);
            const instance = try core.Object.create(rt, core.class.ids.finalization_registry, prototype);
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
            const prototype = try reflectConstructPrototype(rt, name, new_target, args[0]);
            return construct_mod.weakRefWithPrototype(rt, target_value, prototype);
        }
        if (core.host_function.builtin_method_id_lookup.collection.constructorId(name)) |kind| {
            const prototype = try reflectConstructPrototype(rt, name, new_target, args[0]);
            const construct_id = core.host_function.builtin_method_id_lookup.collection.constructIdForKind(kind) orelse return error.TypeError;
            const collection_construct_ref = core.function.NativeBuiltinRef{ .domain = .collection, .id = construct_id };
            return (try builtin_dispatch.callConstructRecord(ctx, null, null, globals, target, collection_construct_ref, prototype, &.{}, null, null)) orelse error.TypeError;
        }
        if (construct_mod.typedArrayElement(name)) |element| {
            var construct_args = ReflectConstructArguments{};
            try construct_args.init(rt, args[1]);
            defer construct_args.deinit();
            const prototype = try reflectConstructPrototype(rt, name, new_target, args[0]);
            const global_object = try activeGlobalObject(rt, null, globals);
            return construct_mod.constructTypedArrayValue(rt, prototype, element, construct_args.values, global_object);
        }
    }

    {
        const prototype = try reflectConstructPrototype(rt, target_name orelse "Object", new_target, args[0]);
        const instance = try core.Object.create(rt, core.class.ids.object, prototype);
        errdefer core.Object.destroyFromHeader(rt, &instance.header);
        return instance.value();
    }
}

/// Map a decoded native-builtin id to the realm-prototype-key name used by
/// `reflectConstructPrototype`, for the construct-capable records `Reflect
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

pub fn reflectApply(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 3) return error.TypeError;
    if (!call_runtime.isCallableValue(args[0])) return error.TypeError;
    var apply_args = ReflectConstructArguments{};
    try apply_args.init(ctx.runtime, args[2]);
    defer apply_args.deinit();
    return callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, args[1], args[0], apply_args.values);
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
    if (!object.flags.is_array) return error.TypeError;
    const out = try rt.memory.alloc(core.JSValue, object.length);
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
    while (index < object.length) : (index += 1) {
        out[index] = object.getProperty(core.atom.atomFromUInt32(index));
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
            if (object.hostFunctionKindSlot().* == core.host_function.ids.external_host) {
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

fn reflectConstructPrototype(rt: *core.JSRuntime, target_name: []const u8, new_target: core.JSValue, target: core.JSValue) !?*core.Object {
    if (thisObject(new_target)) |new_target_object| {
        const prototype_value = new_target_object.getProperty(core.atom.ids.prototype);
        defer prototype_value.free(rt);
        if (prototype_value.isObject()) {
            const header = prototype_value.refHeader() orelse return null;
            return @fieldParentPtr("header", header);
        }
        var realm_source = new_target_object;
        while (true) {
            if (realm_source.class_id == core.class.ids.bound_function) {
                realm_source = boundFunctionTargetObject(realm_source) orelse break;
                continue;
            }
            if (realm_source.proxyTarget()) |target_value| {
                realm_source = thisObject(target_value) orelse break;
                continue;
            }
            break;
        }
        const realm_key = try realmPrototypeKey(rt, target_name);
        defer rt.memory.allocator.free(realm_key);
        const realm_proto_key = try rt.internAtom(realm_key);
        defer rt.atoms.free(realm_proto_key);
        const realm_proto_value = realm_source.getProperty(realm_proto_key);
        defer realm_proto_value.free(rt);
        if (realm_proto_value.isObject()) {
            const header = realm_proto_value.refHeader() orelse return null;
            return @fieldParentPtr("header", header);
        }
    }
    const target_object = expectCallableObject(target) orelse return null;
    return constructorPrototype(rt, target_object);
}

pub fn proxyRevocable(rt: *core.JSRuntime, global: ?*core.Object, args: []const core.JSValue) !core.JSValue {
    if (args.len < 2) return error.TypeError;
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

    _ = try expectObjectArg(rooted_args[0]);
    _ = try expectObjectArg(rooted_args[1]);

    const object = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &object.header);

    const proxy = try core.Object.create(rt, core.class.ids.object, null);
    var proxy_raw_owned = true;
    errdefer if (proxy_raw_owned) core.Object.destroyFromHeader(rt, &proxy.header);
    proxy.flags.is_proxy = true;
    try proxy.ensureProxyPayload(rt);
    try proxy.setOptionalValueSlot(rt, proxy.proxyTargetSlot(), rooted_args[0].dup());
    try proxy.setOptionalValueSlot(rt, proxy.proxyHandlerSlot(), rooted_args[1].dup());
    try defineObjectProperty(rt, object, "proxy", proxy.value());
    proxy_raw_owned = false;
    proxy.value().free(rt);
    const revoke = try core.function.nativeFunction(rt, "revoke", 0);
    defer revoke.free(rt);
    const revoke_object = thisObject(revoke) orelse return error.TypeError;
    revoke_object.nativeFunctionIdSlot().* = core.function.nativeBuiltinId(.reflect, @intFromEnum(StaticMethod.proxy_revoke));
    const empty_name = try core.string.String.createAscii(rt, "");
    const empty_name_value = empty_name.value();
    defer empty_name_value.free(rt);
    try revoke_object.defineOwnProperty(rt, core.atom.ids.name, core.Descriptor.data(empty_name_value, false, false, true));
    if (functionPrototypeFromGlobal(rt, global)) |function_proto| {
        try revoke_object.setPrototype(rt, function_proto);
    }
    try revoke_object.setOptionalValueSlot(rt, revoke_object.functionProxyRevokeTargetSlot(), proxy.value().dup());
    try defineObjectProperty(rt, object, "revoke", revoke);
    return object.value();
}

/// Revoke closure for `Proxy.revocable`: clears the captured proxy's handler
/// so subsequent trap lookups throw. Mirrors QuickJS `js_proxy_revoke`. Stays
/// in exec with the rest of the proxy core; the `.reflect` record handler in
/// builtins/reflect_proxy.zig forwards the `proxy_revoke` id here.
pub fn revokeProxy(rt: *core.JSRuntime, function_object: *core.Object) !core.JSValue {
    const proxy_slot = function_object.functionProxyRevokeTargetSlot();
    const proxy_value = function_object.takeOptionalValueSlot(proxy_slot) orelse return core.JSValue.undefinedValue();
    defer proxy_value.free(rt);
    const proxy = thisObject(proxy_value) orelse return core.JSValue.undefinedValue();
    proxy.clearOptionalValueSlot(rt, proxy.proxyHandlerSlot());
    return core.JSValue.undefinedValue();
}

pub fn reflectHas(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 2) return error.TypeError;
    const object = try expectObjectArg(args[0]);
    const key = try property_ops.propertyKeyAtom(ctx.runtime, args[1]);
    defer ctx.runtime.atoms.free(key);
    return core.JSValue.boolean(try reflectHasProperty(ctx, output, global, globals, object, key));
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
    const trap = try getValueProperty(ctx, output, global, globals, handler_value, has_atom);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) return reflectHasProperty(ctx, output, global, globals, target, atom_id);
    const key_value = try object_ops.proxyTrapKeyValue(ctx.runtime, atom_id);
    defer key_value.free(ctx.runtime);
    const result = try callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, handler_value, trap, &.{ target_value, key_value });
    defer result.free(ctx.runtime);
    return try object_ops.validateProxyHasResult(ctx.runtime, target, atom_id, value_ops.isTruthy(result));
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

pub fn reflectDefineProperty(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue {
    if (args.len < 3) return error.TypeError;
    const object = try expectObjectArg(args[0]);
    const key = try property_ops.propertyKeyAtom(rt, args[1]);
    defer rt.atoms.free(key);
    const desc_object = try expectObjectArg(args[2]);
    const desc = try descriptorFromObject(rt, desc_object);
    defer desc.destroy(rt);
    if (core.object.isTypedArrayObject(object)) {
        if (try typedArrayReflectDefineOwnProperty(rt, object, key, desc)) |ok| return core.JSValue.boolean(ok);
    }
    object.defineOwnProperty(rt, key, desc) catch |err| switch (err) {
        error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return core.JSValue.boolean(false),
        error.InvalidLength => return error.RangeError,
        else => return err,
    };
    return core.JSValue.boolean(true);
}

fn typedArrayReflectDefineOwnProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, desc: core.Descriptor) !?bool {
    return try core.typed_array.typedArrayDefineOwnProperty(rt, object, atom_id, desc);
}

pub fn reflectGet(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue {
    if (args.len < 2) return error.TypeError;
    const object = try expectObjectArg(args[0]);
    const key = try property_ops.propertyKeyAtom(rt, args[1]);
    defer rt.atoms.free(key);
    return object.getProperty(key);
}

pub fn reflectSet(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (global) |global_object| {
        if (try call_runtime.qjsReflectSetCall(ctx, output, global_object, args, null, null)) |value| {
            return value;
        }
    }
    if (args.len < 1) return error.TypeError;
    const set_value = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
    const object = try expectObjectArg(args[0]);
    const key_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const key = try property_ops.propertyKeyAtom(ctx.runtime, key_value);
    defer ctx.runtime.atoms.free(key);
    object.setProperty(ctx.runtime, key, set_value) catch |err| switch (err) {
        error.ReadOnly, error.AccessorWithoutSetter, error.NotExtensible, error.IncompatibleDescriptor => return core.JSValue.boolean(false),
        error.InvalidLength => return error.RangeError,
        else => return err,
    };
    return core.JSValue.boolean(true);
}

fn boundFunctionTargetObject(object: *core.Object) ?*core.Object {
    const target = object.boundTarget() orelse return null;
    return thisObject(target);
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
