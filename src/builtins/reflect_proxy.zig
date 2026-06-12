const core = @import("../core/root.zig");
const std = @import("std");

const builtins = @import("root.zig");
const array_ops = @import("../exec/array_ops.zig");
const call = @import("../exec/call.zig");
const call_runtime = @import("../exec/call_runtime.zig");
const construct_mod = @import("../exec/construct.zig");
const exceptions = @import("../exec/exceptions.zig");
const globals_mod = @import("../exec/globals.zig");
const object_ops = @import("../exec/object_ops.zig");
const property_ops = @import("../exec/property_ops.zig");
const value_ops = @import("../exec/value_ops.zig");

const HostError = exceptions.HostError;
const ValueSliceRoot = array_ops.ValueSliceRoot;

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

pub const StaticMethod = enum(u32) {
    define_property = 1,
    get_own_property_descriptor = 2,
    delete_property = 3,
    get = 4,
    get_prototype_of = 5,
    set = 6,
    set_prototype_of = 7,
    is_extensible = 8,
    prevent_extensions = 9,
    has = 10,
    own_keys = 11,
    construct = 12,
    apply = 13,
};

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

pub fn ownKeys(rt: *core.JSRuntime, object: *core.Object) ![]core.Atom {
    return object.ownKeys(rt);
}

pub const RevocableProxy = struct {
    revoked: bool = false,

    pub fn revoke(self: *RevocableProxy) void {
        self.revoked = true;
    }
};

pub fn reflectConstruct(rt: *core.JSRuntime, args: []const core.JSValue, globals: []globals_mod.Slot) !core.JSValue {
    if (args.len < 2) return error.TypeError;
    if (!isConstructorValue(rt, args[0])) return error.TypeError;
    const target = thisObject(args[0]) orelse return error.TypeError;
    const target_name = nativeFunctionName(rt, target) catch null;
    defer if (target_name) |name| rt.memory.allocator.free(name);
    const new_target = if (args.len >= 3) args[2] else args[0];
    if (!isConstructorValue(rt, new_target)) return error.TypeError;
    if (builtins.date.isConstructorRecord(target)) {
        var construct_args = ReflectConstructArguments{};
        try construct_args.init(rt, args[1]);
        defer construct_args.deinit();
        const prototype = try reflectConstructPrototype(rt, "Date", new_target, args[0]);
        return builtins.date.constructWithPrototype(rt, construct_args.values, prototype);
    }
    if (target_name) |name| {
        if (std.mem.eql(u8, name, "Array")) {
            if (args.len < 2) return error.TypeError;
            var construct_args = ReflectConstructArguments{};
            try construct_args.init(rt, args[1]);
            defer construct_args.deinit();
            const prototype = try reflectConstructPrototype(rt, name, new_target, args[0]);
            return builtins.array.constructConstructorWithPrototype(rt, construct_args.values, prototype);
        }
        if (std.mem.eql(u8, name, "Iterator")) {
            if (builtins.object.sameValue(new_target, args[0])) return error.TypeError;
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
            return primitiveWrapper(rt, core.class.ids.number, primitive, prototype);
        }
        if (std.mem.eql(u8, name, "Date")) {
            var construct_args = ReflectConstructArguments{};
            try construct_args.init(rt, args[1]);
            defer construct_args.deinit();
            const prototype = try reflectConstructPrototype(rt, name, new_target, args[0]);
            return builtins.date.constructWithPrototype(rt, construct_args.values, prototype);
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
            if (!builtins.symbol.canBeHeldWeakly(rt, target_value)) return error.TypeError;
            const prototype = try reflectConstructPrototype(rt, name, new_target, args[0]);
            return construct_mod.weakRefWithPrototype(rt, target_value, prototype);
        }
        if (builtins.collection.constructorId(name)) |kind| {
            const prototype = try reflectConstructPrototype(rt, name, new_target, args[0]);
            return builtins.collection.constructWithPrototype(rt, kind, prototype) catch |err| switch (err) {
                error.TypeError => error.TypeError,
                else => err,
            };
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
    if (builtins.date.isConstructorRecord(object)) return true;
    return switch (object.class_id) {
        core.class.ids.c_function => {
            if (object.hostFunctionKindSlot().* == core.host_function.ids.external_host) {
                return object.hasOwnProperty(core.atom.ids.prototype);
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
    const revoke = try builtins.function.nativeFunction(rt, "revoke", 0);
    defer revoke.free(rt);
    const revoke_object = thisObject(revoke) orelse return error.TypeError;
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
    switch (try builtins.buffer.typedArrayCanonicalNumericIndex(rt, atom_id)) {
        .none => return null,
        .invalid => return false,
        .index => |index| {
            const length = builtins.buffer.typedArrayLength(rt, object) catch return false;
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
    if (builtins.buffer.isTypedArrayObject(object)) {
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
    return try builtins.buffer.typedArrayDefineOwnProperty(rt, object, atom_id, desc);
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
        builtins.error_names.isErrorConstructorName(name) or
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
