const core = @import("../core/root.zig");
const builtins = @import("../builtins/root.zig");
const closure_mod = @import("closure.zig");
const construct_mod = @import("construct.zig");
const globals_mod = @import("globals.zig");
const value_ops = @import("value_ops.zig");
const std = @import("std");

pub fn returnThis(this_value: core.Value) core.Value {
    return this_value.dup();
}

/// QuickJS source map: JS_CallInternal() dispatches callable objects after the
/// VM has prepared callee/argument values. This Zig slice currently owns the
/// host callables installed for the CLI-visible global object.
pub fn installHostGlobals(rt: *core.Runtime, global: *core.Object) !void {
    try defineHostFunction(rt, global, "print", .output);
    try defineHostFunction(rt, global, "Test262Error", .test262_error);
    try defineHostFunction(rt, global, "verifyProperty", .test262_verify_property);
    try defineHostFunction(rt, global, "verifyCallableProperty", .test262_verify_callable_property);
    try defineHostFunction(rt, global, "verifyNotWritable", .test262_verify_not_writable);
    try defineHostFunction(rt, global, "verifyNotEnumerable", .test262_verify_not_enumerable);
    try defineHostFunction(rt, global, "verifyConfigurable", .test262_verify_configurable);
    try defineHostFunction(rt, global, "isConstructor", .test262_is_constructor);
    try installStandardGlobals(rt, global);
    try installTest262Namespace(rt, global);

    const console = try core.Object.create(rt, core.class.ids.object, null);
    errdefer console.value().free(rt);
    try defineHostFunction(rt, console, "log", .output);
    try defineObjectProperty(rt, global, "console", console.value());
    console.value().free(rt);

    const assert = try createHostFunction(rt, .test262_assert);
    errdefer assert.value().free(rt);
    try defineStringProperty(rt, assert, "name", "assert");
    try defineIntProperty(rt, assert, "length", 1);
    try defineHostFunction(rt, assert, "sameValue", .test262_same_value);
    try defineHostFunction(rt, assert, "notSameValue", .test262_not_same_value);
    try defineHostFunction(rt, assert, "compareArray", .test262_compare_array);
    try defineHostFunction(rt, assert, "throws", .test262_throws);
    try defineObjectProperty(rt, global, "assert", assert.value());
    assert.value().free(rt);
}

fn installStandardGlobals(rt: *core.Runtime, global: *core.Object) !void {
    try builtins.registry.installStandardGlobals(rt, global);
}

pub fn callValue(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    callee: core.Value,
    args: []const core.Value,
) !core.Value {
    return callValueWithThisAndGlobals(ctx, output, &.{}, core.Value.undefinedValue(), callee, args);
}

pub fn callValueWithGlobals(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    globals: []globals_mod.Slot,
    callee: core.Value,
    args: []const core.Value,
) !core.Value {
    return callValueWithThisAndGlobals(ctx, output, globals, core.Value.undefinedValue(), callee, args);
}

pub fn callValueWithThis(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    this_value: core.Value,
    callee: core.Value,
    args: []const core.Value,
) !core.Value {
    return callValueWithThisAndGlobals(ctx, output, &.{}, this_value, callee, args);
}

pub fn callValueWithThisAndGlobals(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    globals: []globals_mod.Slot,
    this_value: core.Value,
    callee: core.Value,
    args: []const core.Value,
) !core.Value {
    const object = expectCallableObject(callee) orelse return error.TypeError;
    if (try getOptionalIntProperty(ctx.runtime, object, host_function_key)) |kind_value| {
        const kind: HostFunction = switch (kind_value) {
            @intFromEnum(HostFunction.output) => .output,
            @intFromEnum(HostFunction.test262_assert) => .test262_assert,
            @intFromEnum(HostFunction.test262_same_value) => .test262_same_value,
            @intFromEnum(HostFunction.test262_not_same_value) => .test262_not_same_value,
            @intFromEnum(HostFunction.test262_throws) => .test262_throws,
            @intFromEnum(HostFunction.test262_error) => .test262_error,
            @intFromEnum(HostFunction.test262_verify_property) => .test262_verify_property,
            @intFromEnum(HostFunction.test262_verify_callable_property) => .test262_verify_callable_property,
            @intFromEnum(HostFunction.test262_is_constructor) => .test262_is_constructor,
            @intFromEnum(HostFunction.test262_verify_not_writable) => .test262_verify_not_writable,
            @intFromEnum(HostFunction.test262_verify_not_enumerable) => .test262_verify_not_enumerable,
            @intFromEnum(HostFunction.test262_verify_configurable) => .test262_verify_configurable,
            @intFromEnum(HostFunction.test262_compare_array) => .test262_compare_array,
            @intFromEnum(HostFunction.test262_create_realm) => .test262_create_realm,
            else => return error.TypeError,
        };
        return switch (kind) {
            .output => hostOutputValues(ctx.runtime, output, args),
            .test262_assert => hostAssertTrue(args),
            .test262_same_value => hostAssertSameValue(args),
            .test262_not_same_value => hostAssertNotSameValue(args),
            .test262_throws => hostAssertThrows(ctx, output, globals, args),
            .test262_error => error.Test262Error,
            .test262_verify_property => hostVerifyProperty(ctx.runtime, args, false),
            .test262_verify_callable_property => hostVerifyProperty(ctx.runtime, args, true),
            .test262_is_constructor => hostIsConstructor(ctx.runtime, args),
            .test262_verify_not_writable => hostVerifyPropertyFlag(ctx.runtime, args, .not_writable),
            .test262_verify_not_enumerable => hostVerifyPropertyFlag(ctx.runtime, args, .not_enumerable),
            .test262_verify_configurable => hostVerifyPropertyFlag(ctx.runtime, args, .configurable),
            .test262_compare_array => hostCompareArray(ctx.runtime, args),
            .test262_create_realm => hostCreateRealm(ctx.runtime),
        };
    }
    if (object.class_id == core.class.ids.c_closure) {
        const closure_kind = closure_mod.closureKind(ctx.runtime, callee) catch 0;
        if (closure_kind == 51) {
            const encoded = try closure_mod.closureValue(ctx.runtime, callee);
            return construct_mod.constructCollectionClosure(ctx.runtime, encoded, globals);
        }
        return closure_mod.callWithThis(ctx.runtime, callee, this_value, args, globals) catch |err| switch (err) {
            error.UnsupportedClosureCall => error.TypeError,
            else => err,
        };
    }
    return callNativeBuiltin(ctx, output, globals, this_value, object, args);
}

pub fn printValue(rt: *core.Runtime, writer: *std.Io.Writer, value: core.Value) anyerror!void {
    if (value.asInt32()) |int_value| {
        try writer.print("{d}", .{int_value});
    } else if (value_ops.numberValue(value)) |float_value| {
        if (std.math.isNan(float_value)) {
            try writer.print("NaN", .{});
        } else if (std.math.isPositiveInf(float_value)) {
            try writer.print("Infinity", .{});
        } else if (std.math.isNegativeInf(float_value)) {
            try writer.print("-Infinity", .{});
        } else {
            try writer.print("{d}", .{float_value});
        }
    } else if (value.isBigInt()) {
        var big = try value_ops.cloneBigIntValue(rt, value);
        defer big.deinit();
        const text = try big.formatBase10Alloc(rt.memory.allocator);
        defer rt.memory.allocator.free(text);
        try writer.print("{s}", .{text});
    } else if (value.asBool()) |bool_value| {
        try writer.print("{s}", .{if (bool_value) "true" else "false"});
    } else if (value.isUndefined()) {
        try writer.print("undefined", .{});
    } else if (value.isNull()) {
        try writer.print("null", .{});
    } else if (value.isString()) {
        try printString(writer, value);
    } else if (value.isObject()) {
        const header = value.refHeader() orelse return writer.print("[object Object]", .{});
        const object_value: *core.Object = @fieldParentPtr("header", header);
        if (isFunctionClass(object_value.class_id)) {
            try printNativeFunction(rt, writer, object_value);
        } else if (object_value.class_id == core.class.ids.array_buffer) {
            try writer.print("[object ArrayBuffer]", .{});
        } else if (object_value.class_id == core.class.ids.promise) {
            try writer.print("[object Promise]", .{});
        } else if (object_value.is_array) {
            try printArray(rt, writer, object_value);
        } else {
            try writer.print("[object Object]", .{});
        }
    } else {
        try writer.print("[object Object]", .{});
    }
}

pub fn forEachArrayPrint(rt: *core.Runtime, output: ?*std.Io.Writer, array_value: core.Value) !core.Value {
    const array = try expectArray(array_value);
    if (output) |writer| {
        var index: u32 = 0;
        while (index < array.length) : (index += 1) {
            const item = array.getProperty(core.atom.atomFromUInt32(index));
            defer item.free(rt);
            try printValue(rt, writer, item);
            try writer.print("\n", .{});
        }
    }
    return core.Value.undefinedValue();
}

const host_function_key = "__host_function";

const HostFunction = enum(i32) {
    output = 1,
    test262_same_value = 2,
    test262_error = 3,
    test262_assert = 4,
    test262_not_same_value = 5,
    test262_throws = 6,
    test262_verify_property = 7,
    test262_verify_callable_property = 8,
    test262_is_constructor = 9,
    test262_verify_not_writable = 10,
    test262_verify_not_enumerable = 11,
    test262_verify_configurable = 12,
    test262_compare_array = 13,
    test262_create_realm = 14,
};

fn installTest262Namespace(rt: *core.Runtime, global: *core.Object) !void {
    const namespace = try core.Object.create(rt, core.class.ids.object, null);
    errdefer namespace.value().free(rt);
    try defineHostFunction(rt, namespace, "createRealm", .test262_create_realm);
    try defineObjectProperty(rt, global, "$262", namespace.value());
    namespace.value().free(rt);
}

fn defineHostFunction(rt: *core.Runtime, target: *core.Object, name: []const u8, kind: HostFunction) !void {
    const function_object = try createHostFunction(rt, kind);
    errdefer function_object.value().free(rt);
    try defineStringProperty(rt, function_object, "name", name);
    try defineIntProperty(rt, function_object, "length", hostFunctionLength(kind));
    try defineObjectProperty(rt, target, name, function_object.value());
    function_object.value().free(rt);
}

fn createHostFunction(rt: *core.Runtime, kind: HostFunction) !*core.Object {
    const function_object = try core.Object.create(rt, core.class.ids.c_function, null);
    errdefer function_object.value().free(rt);
    try defineIntProperty(rt, function_object, host_function_key, @intFromEnum(kind));
    return function_object;
}

fn defineObjectProperty(rt: *core.Runtime, object: *core.Object, name: []const u8, value: core.Value) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value, true, true, true));
}

fn defineIntProperty(rt: *core.Runtime, object: *core.Object, name: []const u8, value: i32) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(core.Value.int32(value), true, true, true));
}

fn defineStringProperty(rt: *core.Runtime, object: *core.Object, name: []const u8, value: []const u8) !void {
    const string_value = try value_ops.createStringValue(rt, value);
    defer string_value.free(rt);
    try defineObjectProperty(rt, object, name, string_value);
}

fn hostFunctionLength(kind: HostFunction) i32 {
    return switch (kind) {
        .output => 1,
        .test262_assert => 1,
        .test262_same_value => 2,
        .test262_not_same_value => 2,
        .test262_throws => 2,
        .test262_error => 1,
        .test262_verify_property => 3,
        .test262_verify_callable_property => 4,
        .test262_is_constructor => 1,
        .test262_verify_not_writable => 2,
        .test262_verify_not_enumerable => 2,
        .test262_verify_configurable => 2,
        .test262_compare_array => 2,
        .test262_create_realm => 0,
    };
}

fn getIntProperty(rt: *core.Runtime, object: *core.Object, name: []const u8) !i32 {
    return (try getOptionalIntProperty(rt, object, name)) orelse error.TypeError;
}

fn getOptionalIntProperty(rt: *core.Runtime, object: *core.Object, name: []const u8) !?i32 {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    const value = object.getProperty(key);
    defer value.free(rt);
    if (value.isUndefined()) return null;
    return value.asInt32() orelse error.TypeError;
}

fn expectCallableObject(value: core.Value) ?*core.Object {
    const header = value.refHeader() orelse return null;
    if (!value.isObject()) return null;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_id != core.class.ids.c_function and object.class_id != core.class.ids.c_closure) return null;
    return object;
}

fn callNativeBuiltin(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    globals: []globals_mod.Slot,
    this_value: core.Value,
    function_object: *core.Object,
    args: []const core.Value,
) !core.Value {
    const name = try nativeFunctionName(ctx.runtime, function_object);
    defer ctx.runtime.memory.allocator.free(name);

    if (std.mem.eql(u8, name, "get [Symbol.species]")) return this_value.dup();
    if (std.mem.eql(u8, name, "construct")) return reflectConstruct(ctx.runtime, args, globals);
    if (std.mem.eql(u8, name, "get size")) {
        return builtins.collection.methodCall(ctx.runtime, this_value, 14, &.{}) catch |err| switch (err) {
            error.TypeError, error.UnsupportedCollectionCall => error.TypeError,
            else => err,
        };
    }

    if (try constructorNameEql(ctx.runtime, function_object, "Object")) {
        const object = try core.Object.create(ctx.runtime, core.class.ids.object, null);
        return object.value();
    }
    if (try constructorNameEql(ctx.runtime, function_object, "Array")) {
        return builtins.array.constructWithPrototype(ctx.runtime, args, null);
    }
    if (try constructorNameEql(ctx.runtime, function_object, "Symbol")) {
        const description = if (args.len >= 1 and args[0].isString()) try stringBytes(ctx.runtime, args[0]) else try ctx.runtime.memory.allocator.dupe(u8, "");
        defer ctx.runtime.memory.allocator.free(description);
        const symbol_atom = try ctx.runtime.atoms.newSymbol(description, .symbol);
        return core.Value.symbol(symbol_atom);
    }
    if (std.mem.eql(u8, name, "from")) return arrayFrom(ctx.runtime, args);

    if (thisObject(this_value)) |receiver| {
        if (receiver.class_id == core.class.ids.c_function or receiver.class_id == core.class.ids.c_closure) {
            if (std.mem.eql(u8, name, "call")) {
                if (args.len < 1) return error.TypeError;
                return callValueWithThisAndGlobals(ctx, output, globals, args[0], this_value, args[1..]);
            }
            if (std.mem.eql(u8, name, "bind")) return this_value.dup();
            if (std.mem.eql(u8, name, "toString")) return objectToString(ctx.runtime, this_value);
            if (receiver.class_id == core.class.ids.c_closure) return error.TypeError;
            if (try constructorNameEql(ctx.runtime, receiver, "Symbol")) {
                if (std.mem.eql(u8, name, "for")) return symbolFor(ctx.runtime, args);
            }
            if (try constructorNameEql(ctx.runtime, receiver, "Promise")) {
                if (promiseStaticId(name)) |mode| {
                    const reason: ?core.Value = if (mode == 4 and args.len >= 1) args[0] else null;
                    return builtins.promise.staticCallWithPrototype(ctx, mode, reason, constructorPrototype(ctx.runtime, receiver)) catch |err| switch (err) {
                        error.UnsupportedPromiseCall => error.TypeError,
                        else => err,
                    };
                }
            }
            if (try constructorNameEql(ctx.runtime, receiver, "Date")) {
                if (dateStaticId(name)) |method| {
                    return builtins.date.staticCall(ctx.runtime, method, args) catch |err| switch (err) {
                        error.UnsupportedDateCall => error.TypeError,
                        else => err,
                    };
                }
            }
            if (try constructorNameEql(ctx.runtime, receiver, "String")) {
                if (std.mem.eql(u8, name, "fromCharCode")) {
                    return builtins.string.fromCharCode(ctx.runtime, args) catch |err| switch (err) {
                        error.UnsupportedStringCall => error.TypeError,
                        else => err,
                    };
                }
            }
            if (try constructorNameEql(ctx.runtime, receiver, "Array")) {
                if (std.mem.eql(u8, name, "isArray")) return core.Value.boolean(args.len >= 1 and isArrayValue(args[0]));
                if (std.mem.eql(u8, name, "from")) return arrayFrom(ctx.runtime, args);
            }
            if (try constructorNameEql(ctx.runtime, receiver, "Object")) {
                return callObjectStatic(ctx.runtime, name, args) catch |err| switch (err) {
                    error.TypeError, error.UnsupportedObjectCall => error.TypeError,
                    else => err,
                };
            }
            if (try constructorNameEql(ctx.runtime, receiver, "Map")) {
                if (std.mem.eql(u8, name, "groupBy")) return builtins.collection.groupBy(ctx.runtime, args, globals, constructorPrototype(ctx.runtime, receiver)) catch |err| switch (err) {
                    error.TypeError, error.UnsupportedCollectionCall, error.UnsupportedClosureCall => error.TypeError,
                    else => err,
                };
            }
            return error.TypeError;
        }

        if (receiver.is_array) {
            return callArrayMethod(ctx.runtime, output, globals, this_value, name, args);
        }
        if (receiver.class_id == core.class.ids.map or receiver.class_id == core.class.ids.set or
            receiver.class_id == core.class.ids.weakmap or receiver.class_id == core.class.ids.weakset)
        {
            if (collectionMethodId(name)) |method| {
                return builtins.collection.methodCallWithGlobals(ctx.runtime, this_value, method, args, globals) catch |err| switch (err) {
                    error.TypeError, error.UnsupportedCollectionCall => error.TypeError,
                    else => err,
                };
            }
        }
        if ((receiver.class_id == core.class.ids.map_iterator or receiver.class_id == core.class.ids.set_iterator) and std.mem.eql(u8, name, "next")) {
            return builtins.collection.methodCall(ctx.runtime, this_value, 13, args) catch |err| switch (err) {
                error.TypeError, error.UnsupportedCollectionCall => error.TypeError,
                else => err,
            };
        }
        if (receiver.class_id == core.class.ids.string) {
            return callStringMethod(ctx.runtime, this_value, name, args);
        }
        if (receiver.class_id == core.class.ids.date) {
            if (dateMethodId(name)) |method| {
                return builtins.date.methodCall(ctx.runtime, this_value, method) catch |err| switch (err) {
                    error.TypeError, error.UnsupportedDateCall => error.TypeError,
                    else => err,
                };
            }
        }
        if (receiver.class_id == core.class.ids.regexp) {
            if (regexpMethodId(name)) |method| {
                const arg: ?core.Value = if (method == 1 or args.len == 0) null else args[0];
                return builtins.regexp.methodCall(ctx.runtime, this_value, method, arg) catch |err| switch (err) {
                    error.TypeError, error.UnsupportedRegExpCall => error.TypeError,
                    else => err,
                };
            }
        }
        if (receiver.class_id == core.class.ids.promise and (std.mem.eql(u8, name, "then") or std.mem.eql(u8, name, "catch"))) {
            return core.Value.undefinedValue();
        }
        if (std.mem.eql(u8, name, "toString")) return objectToString(ctx.runtime, this_value);
    } else if (this_value.isNumber() or this_value.isBool()) {
        return callPrimitiveMethod(ctx.runtime, this_value, name, args);
    } else if (this_value.isString()) {
        return callStringMethod(ctx.runtime, this_value, name, args);
    }

    return error.TypeError;
}

fn hostCreateRealm(rt: *core.Runtime) !core.Value {
    const realm = try core.Object.create(rt, core.class.ids.object, null);
    errdefer realm.value().free(rt);
    const realm_global = try core.Object.create(rt, core.class.ids.object, null);
    errdefer realm_global.value().free(rt);
    try builtins.registry.installStandardGlobals(rt, realm_global);
    try tagRealmFunctionConstructor(rt, realm_global);
    try defineObjectProperty(rt, realm, "global", realm_global.value());
    realm_global.value().free(rt);
    return realm.value();
}

fn tagRealmFunctionConstructor(rt: *core.Runtime, realm_global: *core.Object) !void {
    const function_key = try rt.internAtom("Function");
    defer rt.atoms.free(function_key);
    const function_value = realm_global.getProperty(function_key);
    defer function_value.free(rt);
    const function_object = expectObjectArg(function_value) catch return;
    const collection_names = [_][]const u8{ "Map", "Set", "WeakMap", "WeakSet" };
    for (collection_names) |name| {
        const key = try rt.internAtom(name);
        defer rt.atoms.free(key);
        const value = realm_global.getProperty(key);
        defer value.free(rt);
        const object = try expectObjectArg(value);
        if (constructorPrototype(rt, object)) |proto| {
            const realm_key = try realmPrototypeKey(rt, name);
            defer rt.memory.allocator.free(realm_key);
            try defineObjectProperty(rt, function_object, realm_key, proto.value());
        }
    }
}

fn reflectConstruct(rt: *core.Runtime, args: []const core.Value, globals: []globals_mod.Slot) !core.Value {
    _ = globals;
    if (args.len < 1) return error.TypeError;
    const target = expectCallableObject(args[0]) orelse return error.TypeError;
    const target_name = try nativeFunctionName(rt, target);
    defer rt.memory.allocator.free(target_name);
    const kind = collectionConstructorId(target_name) orelse return error.TypeError;
    const new_target = if (args.len >= 3) args[2] else args[0];
    const prototype = try reflectConstructPrototype(rt, target_name, new_target, args[0]);
    return builtins.collection.constructWithPrototype(rt, kind, prototype) catch |err| switch (err) {
        error.UnsupportedCollectionCall => error.TypeError,
        else => err,
    };
}

fn reflectConstructPrototype(rt: *core.Runtime, target_name: []const u8, new_target: core.Value, target: core.Value) !?*core.Object {
    if (thisObject(new_target)) |new_target_object| {
        const prototype_value = new_target_object.getProperty(core.atom.ids.prototype);
        defer prototype_value.free(rt);
        if (prototype_value.isObject()) {
            const header = prototype_value.refHeader() orelse return null;
            return @fieldParentPtr("header", header);
        }
        const realm_key = try realmPrototypeKey(rt, target_name);
        defer rt.memory.allocator.free(realm_key);
        const realm_proto_key = try rt.internAtom(realm_key);
        defer rt.atoms.free(realm_proto_key);
        const realm_proto_value = new_target_object.getProperty(realm_proto_key);
        defer realm_proto_value.free(rt);
        if (realm_proto_value.isObject()) {
            const header = realm_proto_value.refHeader() orelse return null;
            return @fieldParentPtr("header", header);
        }
    }
    const target_object = expectCallableObject(target) orelse return null;
    return constructorPrototype(rt, target_object);
}

fn realmPrototypeKey(rt: *core.Runtime, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(rt.memory.allocator, "__realm_{s}_proto", .{name});
}

fn callArrayMethod(
    rt: *core.Runtime,
    output: ?*std.Io.Writer,
    globals: []globals_mod.Slot,
    receiver: core.Value,
    name: []const u8,
    args: []const core.Value,
) !core.Value {
    if (std.mem.eql(u8, name, "forEach")) return forEachArrayPrint(rt, output, receiver);
    if (std.mem.eql(u8, name, "map")) return arrayMapCallback(rt, receiver, args, globals);
    if (std.mem.eql(u8, name, "join")) return arrayJoinCall(rt, receiver, args);
    if (arrayMethodId(name)) |method| {
        return switch (method) {
            1, 2, 4, 5 => builtins.array.methodCall(rt, receiver, method, &.{}),
            else => builtins.array.methodCall(rt, receiver, method, args),
        } catch |err| switch (err) {
            error.UnsupportedArrayCall => error.TypeError,
            else => err,
        };
    }
    return error.TypeError;
}

fn callObjectStatic(rt: *core.Runtime, name: []const u8, args: []const core.Value) !core.Value {
    if (std.mem.eql(u8, name, "is")) {
        const lhs = if (args.len >= 1) args[0] else core.Value.undefinedValue();
        const rhs = if (args.len >= 2) args[1] else core.Value.undefinedValue();
        return core.Value.boolean(builtins.object.sameValue(lhs, rhs));
    }
    if (std.mem.eql(u8, name, "keys")) {
        if (args.len < 1) return error.TypeError;
        const object = try expectObjectArg(args[0]);
        return builtins.object.ownEntriesArray(rt, object.value(), .keys);
    }
    if (std.mem.eql(u8, name, "values")) {
        if (args.len < 1) return error.TypeError;
        const object = try expectObjectArg(args[0]);
        return builtins.object.ownEntriesArray(rt, object.value(), .values);
    }
    if (std.mem.eql(u8, name, "entries")) {
        if (args.len < 1) return error.TypeError;
        const object = try expectObjectArg(args[0]);
        return builtins.object.ownEntriesArray(rt, object.value(), .entries);
    }
    if (std.mem.eql(u8, name, "getOwnPropertyDescriptor")) {
        if (args.len < 2) return error.TypeError;
        const object = try expectObjectArg(args[0]);
        const key = try atomFromPropertyKey(rt, args[1]);
        defer rt.atoms.free(key);
        const desc = object.getOwnProperty(key) orelse return core.Value.undefinedValue();
        defer desc.destroy(rt);
        return descriptorObject(rt, desc);
    }
    if (std.mem.eql(u8, name, "getOwnPropertyNames")) {
        if (args.len < 1) return error.TypeError;
        const object = try expectObjectArg(args[0]);
        const keys = try object.ownKeys(rt);
        defer core.Object.freeKeys(rt, keys);
        const out = try core.Object.createArray(rt, null);
        errdefer core.Object.destroyFromHeader(rt, &out.header);
        for (keys, 0..) |key, index| {
            const name_value = try atomToStringValue(rt, key);
            defer name_value.free(rt);
            try out.defineOwnProperty(rt, core.atom.atomFromUInt32(@intCast(index)), core.Descriptor.data(name_value, true, true, true));
        }
        return out.value();
    }
    if (std.mem.eql(u8, name, "getPrototypeOf")) {
        if (args.len < 1) return error.TypeError;
        const object = try expectObjectArg(args[0]);
        if (object.getPrototype()) |prototype| return prototype.value().dup();
        return core.Value.nullValue();
    }
    if (std.mem.eql(u8, name, "isExtensible")) {
        if (args.len < 1) return error.TypeError;
        const object = try expectObjectArg(args[0]);
        return core.Value.boolean(object.isExtensible());
    }
    if (std.mem.eql(u8, name, "defineProperty")) {
        if (args.len < 3) return error.TypeError;
        const object = try expectObjectArg(args[0]);
        const key = try atomFromPropertyKey(rt, args[1]);
        defer rt.atoms.free(key);
        const desc_object = try expectObjectArg(args[2]);
        const desc = try descriptorFromObject(rt, desc_object);
        defer desc.destroy(rt);
        try object.defineOwnProperty(rt, key, desc);
        return object.value().dup();
    }
    return error.TypeError;
}

fn arrayMapCallback(rt: *core.Runtime, receiver: core.Value, args: []const core.Value, globals: []globals_mod.Slot) !core.Value {
    if (args.len != 1) return error.TypeError;
    const array = builtins.array.expectArray(receiver) catch return error.TypeError;
    const mapped = try core.Object.createArray(rt, null);
    errdefer core.Object.destroyFromHeader(rt, &mapped.header);
    var index: u32 = 0;
    while (index < array.length) : (index += 1) {
        const item = array.getProperty(core.atom.atomFromUInt32(index));
        defer item.free(rt);
        const mapped_value = closure_mod.call(rt, args[0], &.{item}, globals) catch return error.TypeError;
        defer mapped_value.free(rt);
        try mapped.defineOwnProperty(rt, core.atom.atomFromUInt32(index), core.Descriptor.data(mapped_value, true, true, true));
    }
    return mapped.value();
}

fn arrayJoinCall(rt: *core.Runtime, receiver: core.Value, args: []const core.Value) !core.Value {
    if (args.len > 1) return error.TypeError;
    if (args.len == 1) return builtins.array.join(rt, receiver, args[0]) catch return error.TypeError;
    const comma = try core.string.String.createUtf8(rt, ",");
    const comma_value = comma.value();
    defer comma_value.free(rt);
    return builtins.array.join(rt, receiver, comma_value) catch return error.TypeError;
}

fn arrayFrom(rt: *core.Runtime, args: []const core.Value) !core.Value {
    if (args.len < 1) return error.TypeError;
    const source = try expectObjectArg(args[0]);
    if (source.class_id == core.class.ids.set or source.class_id == core.class.ids.map) {
        const iterator = try builtins.collection.methodCall(rt, source.value(), if (source.class_id == core.class.ids.set) 8 else 9, &.{});
        defer iterator.free(rt);
        return arrayFrom(rt, &.{iterator});
    }
    if (source.class_id == core.class.ids.map_iterator or source.class_id == core.class.ids.set_iterator) {
        const out = try core.Object.createArray(rt, null);
        errdefer core.Object.destroyFromHeader(rt, &out.header);
        while (true) {
            const next = try builtins.collection.methodCall(rt, source.value(), 13, &.{});
            defer next.free(rt);
            const next_object = try expectObjectArg(next);
            const done = next_object.getProperty(core.atom.predefinedId("done", .string).?);
            defer done.free(rt);
            if (done.asBool() == true) break;
            const value = next_object.getProperty(core.atom.predefinedId("value", .string).?);
            defer value.free(rt);
            try out.defineOwnProperty(rt, core.atom.atomFromUInt32(out.length), core.Descriptor.data(value, true, true, true));
        }
        return out.value();
    }
    if (!source.is_array) return error.TypeError;
    return source.value().dup();
}

fn callStringMethod(rt: *core.Runtime, receiver: core.Value, name: []const u8, args: []const core.Value) !core.Value {
    if (std.mem.eql(u8, name, "charAt")) {
        if (args.len != 1) return error.TypeError;
        return builtins.string.charAtValue(rt, receiver, args[0]) catch |err| switch (err) {
            error.TypeError, error.UnsupportedStringCall => error.TypeError,
            else => err,
        };
    }
    if (stringMethodId(name)) |method| {
        return builtins.string.methodCall(rt, receiver, method, args) catch |err| switch (err) {
            error.TypeError, error.UnsupportedStringCall => error.TypeError,
            else => err,
        };
    }
    return error.TypeError;
}

fn callPrimitiveMethod(rt: *core.Runtime, receiver: core.Value, name: []const u8, args: []const core.Value) !core.Value {
    if (args.len != 0) return error.TypeError;
    if (std.mem.eql(u8, name, "valueOf")) return receiver.dup();
    if (std.mem.eql(u8, name, "toString")) return value_ops.toStringValue(rt, receiver);
    return error.TypeError;
}

fn objectToString(rt: *core.Runtime, receiver: core.Value) !core.Value {
    const object = try expectObjectArg(receiver);
    const tag_atom = core.atom.predefinedId("Symbol.toStringTag", .symbol) orelse return value_ops.createStringValue(rt, "[object Object]");
    const tag_value = object.getProperty(tag_atom);
    defer tag_value.free(rt);
    if (tag_value.isString()) {
        var tag = std.ArrayList(u8).empty;
        defer tag.deinit(rt.memory.allocator);
        try value_ops.appendRawString(rt, &tag, tag_value);
        var out = std.ArrayList(u8).empty;
        defer out.deinit(rt.memory.allocator);
        try out.appendSlice(rt.memory.allocator, "[object ");
        try out.appendSlice(rt.memory.allocator, tag.items);
        try out.appendSlice(rt.memory.allocator, "]");
        return value_ops.createStringValue(rt, out.items);
    }
    return value_ops.createStringValue(rt, defaultObjectTag(object));
}

fn symbolFor(rt: *core.Runtime, args: []const core.Value) !core.Value {
    const key = if (args.len >= 1) try stringBytes(rt, args[0]) else try rt.memory.allocator.dupe(u8, "undefined");
    defer rt.memory.allocator.free(key);
    const registered = try std.fmt.allocPrint(rt.memory.allocator, "Symbol.for:{s}", .{key});
    defer rt.memory.allocator.free(registered);
    const atom_id = try rt.atoms.internString(registered);
    return core.Value.symbol(atom_id);
}

fn defaultObjectTag(object: *core.Object) []const u8 {
    if (object.is_array) return "[object Array]";
    return switch (object.class_id) {
        core.class.ids.c_function,
        core.class.ids.bytecode_function,
        core.class.ids.bound_function,
        core.class.ids.c_function_data,
        core.class.ids.c_closure,
        => "[object Function]",
        core.class.ids.map => "[object Map]",
        core.class.ids.set => "[object Set]",
        core.class.ids.weakmap => "[object WeakMap]",
        core.class.ids.weakset => "[object WeakSet]",
        core.class.ids.promise => "[object Promise]",
        core.class.ids.array_buffer => "[object ArrayBuffer]",
        core.class.ids.date => "[object Date]",
        core.class.ids.regexp => "[object RegExp]",
        else => "[object Object]",
    };
}

fn nativeFunctionName(rt: *core.Runtime, function_object: *core.Object) ![]u8 {
    const name_value = function_object.getProperty(core.atom.ids.name);
    defer name_value.free(rt);
    if (!name_value.isString()) return error.TypeError;
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(rt.memory.allocator);
    try value_ops.appendRawString(rt, &buffer, name_value);
    return buffer.toOwnedSlice(rt.memory.allocator);
}

fn collectionMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "set")) return 1;
    if (std.mem.eql(u8, name, "get")) return 2;
    if (std.mem.eql(u8, name, "has")) return 3;
    if (std.mem.eql(u8, name, "delete")) return 4;
    if (std.mem.eql(u8, name, "clear")) return 5;
    if (std.mem.eql(u8, name, "add")) return 6;
    if (std.mem.eql(u8, name, "keys")) return 7;
    if (std.mem.eql(u8, name, "values")) return 8;
    if (std.mem.eql(u8, name, "entries")) return 9;
    if (std.mem.eql(u8, name, "forEach")) return 10;
    if (std.mem.eql(u8, name, "getOrInsert")) return 11;
    if (std.mem.eql(u8, name, "getOrInsertComputed")) return 12;
    if (std.mem.eql(u8, name, "difference")) return 15;
    if (std.mem.eql(u8, name, "intersection")) return 16;
    if (std.mem.eql(u8, name, "isDisjointFrom")) return 17;
    if (std.mem.eql(u8, name, "isSubsetOf")) return 18;
    if (std.mem.eql(u8, name, "isSupersetOf")) return 19;
    if (std.mem.eql(u8, name, "symmetricDifference")) return 20;
    if (std.mem.eql(u8, name, "union")) return 21;
    return null;
}

fn arrayMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "filter")) return 1;
    if (std.mem.eql(u8, name, "reduce")) return 2;
    if (std.mem.eql(u8, name, "some")) return 4;
    if (std.mem.eql(u8, name, "every")) return 5;
    if (std.mem.eql(u8, name, "indexOf")) return 6;
    if (std.mem.eql(u8, name, "includes")) return 7;
    if (std.mem.eql(u8, name, "lastIndexOf")) return 8;
    if (std.mem.eql(u8, name, "at")) return 9;
    if (std.mem.eql(u8, name, "slice")) return 10;
    if (std.mem.eql(u8, name, "splice")) return 11;
    if (std.mem.eql(u8, name, "push")) return 13;
    if (std.mem.eql(u8, name, "pop")) return 14;
    return null;
}

fn stringMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "substring")) return 1;
    if (std.mem.eql(u8, name, "toUpperCase")) return 2;
    if (std.mem.eql(u8, name, "toLowerCase")) return 3;
    if (std.mem.eql(u8, name, "indexOf")) return 4;
    if (std.mem.eql(u8, name, "includes")) return 5;
    if (std.mem.eql(u8, name, "startsWith")) return 6;
    if (std.mem.eql(u8, name, "endsWith")) return 7;
    if (std.mem.eql(u8, name, "trim")) return 8;
    if (std.mem.eql(u8, name, "toString")) return 9;
    return null;
}

fn dateMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "getTime")) return 1;
    if (std.mem.eql(u8, name, "valueOf")) return 2;
    if (std.mem.eql(u8, name, "getFullYear")) return 3;
    if (std.mem.eql(u8, name, "getMonth")) return 4;
    if (std.mem.eql(u8, name, "getDate")) return 5;
    if (std.mem.eql(u8, name, "getHours")) return 6;
    if (std.mem.eql(u8, name, "getMinutes")) return 7;
    if (std.mem.eql(u8, name, "getSeconds")) return 8;
    if (std.mem.eql(u8, name, "getMilliseconds")) return 9;
    if (std.mem.eql(u8, name, "toISOString")) return 10;
    if (std.mem.eql(u8, name, "toJSON")) return 11;
    if (std.mem.eql(u8, name, "getUTCFullYear")) return 12;
    if (std.mem.eql(u8, name, "getUTCMonth")) return 13;
    if (std.mem.eql(u8, name, "getUTCDate")) return 14;
    if (std.mem.eql(u8, name, "getUTCHours")) return 15;
    if (std.mem.eql(u8, name, "getUTCMinutes")) return 16;
    if (std.mem.eql(u8, name, "getUTCSeconds")) return 17;
    if (std.mem.eql(u8, name, "getUTCMilliseconds")) return 18;
    if (std.mem.eql(u8, name, "getUTCDay")) return 19;
    return null;
}

fn dateStaticId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "UTC")) return 1;
    if (std.mem.eql(u8, name, "parse")) return 2;
    if (std.mem.eql(u8, name, "now")) return 3;
    return null;
}

fn regexpMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "toString")) return 1;
    if (std.mem.eql(u8, name, "test")) return 2;
    if (std.mem.eql(u8, name, "exec")) return 3;
    return null;
}

fn promiseStaticId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "resolve")) return 1;
    if (std.mem.eql(u8, name, "all")) return 2;
    if (std.mem.eql(u8, name, "race")) return 3;
    if (std.mem.eql(u8, name, "reject")) return 4;
    return null;
}

fn collectionConstructorId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "Map")) return 1;
    if (std.mem.eql(u8, name, "Set")) return 2;
    if (std.mem.eql(u8, name, "WeakMap")) return 3;
    if (std.mem.eql(u8, name, "WeakSet")) return 4;
    return null;
}

fn thisObject(value: core.Value) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

fn constructorNameEql(rt: *core.Runtime, object: *core.Object, expected: []const u8) !bool {
    const name_value = object.getProperty(core.atom.ids.name);
    defer name_value.free(rt);
    if (!name_value.isString()) return false;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try value_ops.appendRawString(rt, &buffer, name_value);
    return std.mem.eql(u8, buffer.items, expected);
}

fn constructorPrototype(rt: *core.Runtime, object: *core.Object) ?*core.Object {
    const prototype_value = object.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    if (!prototype_value.isObject()) return null;
    const header = prototype_value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

fn isArrayValue(value: core.Value) bool {
    const object = thisObject(value) orelse return false;
    return object.is_array;
}

fn expectArray(value: core.Value) !*core.Object {
    const header = value.refHeader() orelse return error.UnsupportedOutputCall;
    if (!value.isObject()) return error.UnsupportedOutputCall;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (!object.is_array) return error.UnsupportedOutputCall;
    return object;
}

fn hostOutputValues(rt: *core.Runtime, output: ?*std.Io.Writer, values: []const core.Value) !core.Value {
    if (output) |writer| {
        var i: usize = 0;
        while (i < values.len) : (i += 1) {
            if (i != 0) try writer.print(" ", .{});
            try printValue(rt, writer, values[i]);
        }
        try writer.print("\n", .{});
    }
    return core.Value.undefinedValue();
}

fn hostAssertSameValue(values: []const core.Value) !core.Value {
    if (values.len < 2) return error.TypeError;
    if (!@import("../builtins/root.zig").object.sameValue(values[0], values[1])) return error.Test262Error;
    return core.Value.undefinedValue();
}

fn hostAssertTrue(values: []const core.Value) !core.Value {
    if (values.len < 1 or values[0].asBool() != true) return error.Test262Error;
    return core.Value.undefinedValue();
}

fn hostAssertNotSameValue(values: []const core.Value) !core.Value {
    if (values.len < 2) return error.TypeError;
    if (@import("../builtins/root.zig").object.sameValue(values[0], values[1])) return error.Test262Error;
    return core.Value.undefinedValue();
}

fn hostAssertThrows(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    globals: []globals_mod.Slot,
    values: []const core.Value,
) !core.Value {
    if (values.len < 2) return error.TypeError;
    const expected = thisObject(values[0]) orelse return error.Test262Error;
    const expected_name = try nativeFunctionName(ctx.runtime, expected);
    defer ctx.runtime.memory.allocator.free(expected_name);
    const result = callValueWithThisAndGlobals(ctx, output, globals, core.Value.undefinedValue(), values[1], &.{}) catch |err| {
        if (errorNameMatchesConstructor(err, expected_name)) return core.Value.undefinedValue();
        return error.Test262Error;
    };
    defer result.free(ctx.runtime);
    return error.Test262Error;
}

fn hostVerifyProperty(rt: *core.Runtime, values: []const core.Value, callable: bool) !core.Value {
    const desc_index: usize = if (callable) 4 else 2;
    if ((!callable and values.len <= desc_index) or (callable and values.len < 4)) return error.TypeError;
    const object = try expectObjectArg(values[0]);
    const key = try atomFromPropertyKey(rt, values[1]);
    defer rt.atoms.free(key);

    const original = object.getOwnProperty(key) orelse if (object.is_global and value_ops.atomNameEql(rt, key, "globalThis")) core.Descriptor.data(object.value().dup(), true, false, true) else {
        if (values[desc_index].isUndefined()) return core.Value.boolean(true);
        return error.Test262Error;
    };
    defer original.destroy(rt);

    if (callable) {
        const actual = object.getProperty(key);
        defer actual.free(rt);
        if (!value_ops.isFunctionObject(actual)) return error.Test262Error;
        const expected_name = try stringBytes(rt, values[2]);
        defer rt.memory.allocator.free(expected_name);
        const function_object = thisObject(actual) orelse return error.Test262Error;
        const actual_name = try nativeFunctionName(rt, function_object);
        defer rt.memory.allocator.free(actual_name);
        if (!std.mem.eql(u8, expected_name, actual_name)) return error.Test262Error;
        const expected_length = values[3].asInt32() orelse return error.Test262Error;
        const length_value = function_object.getProperty(core.atom.ids.length);
        defer length_value.free(rt);
        if (length_value.asInt32() != expected_length) return error.Test262Error;
        if (values.len <= desc_index or values[desc_index].isUndefined()) return core.Value.boolean(true);
    }

    const expected_object = try expectObjectArg(values[desc_index]);
    try verifyDescriptorObject(rt, original, expected_object);
    return core.Value.boolean(true);
}

fn hostIsConstructor(rt: *core.Runtime, values: []const core.Value) !core.Value {
    if (values.len < 1) return error.TypeError;
    const object = thisObject(values[0]) orelse return core.Value.boolean(false);
    if (!value_ops.isFunctionObject(values[0])) return core.Value.boolean(false);
    const name = nativeFunctionName(rt, object) catch return core.Value.boolean(false);
    defer rt.memory.allocator.free(name);
    return core.Value.boolean(isBuiltinConstructorName(name));
}

const VerifyFlag = enum {
    not_writable,
    not_enumerable,
    configurable,
};

fn hostVerifyPropertyFlag(rt: *core.Runtime, values: []const core.Value, flag: VerifyFlag) !core.Value {
    if (values.len < 2) return error.TypeError;
    const object = try expectObjectArg(values[0]);
    const key = try atomFromPropertyKey(rt, values[1]);
    defer rt.atoms.free(key);
    const desc = object.getOwnProperty(key) orelse return error.Test262Error;
    defer desc.destroy(rt);
    switch (flag) {
        .not_writable => if (desc.kind == .data and (desc.writable orelse false)) return error.Test262Error,
        .not_enumerable => if (desc.enumerable orelse false) return error.Test262Error,
        .configurable => if (!(desc.configurable orelse false)) return error.Test262Error,
    }
    return core.Value.undefinedValue();
}

fn hostCompareArray(rt: *core.Runtime, values: []const core.Value) !core.Value {
    if (values.len < 2) return error.TypeError;
    const actual = try expectObjectArg(values[0]);
    const expected = try expectObjectArg(values[1]);
    if (!actual.is_array or !expected.is_array) return error.Test262Error;
    if (actual.length != expected.length) return error.Test262Error;
    var index: u32 = 0;
    while (index < actual.length) : (index += 1) {
        const key = core.atom.atomFromUInt32(index);
        const lhs = actual.getProperty(key);
        defer lhs.free(rt);
        const rhs = expected.getProperty(key);
        defer rhs.free(rt);
        if (!builtins.object.sameValue(lhs, rhs)) return error.Test262Error;
    }
    return core.Value.undefinedValue();
}

fn verifyDescriptorObject(rt: *core.Runtime, actual: core.Descriptor, expected: *core.Object) !void {
    if (try expectedHas(rt, expected, "value")) {
        const expected_value = try expectedValue(rt, expected, "value");
        defer expected_value.free(rt);
        if (!builtins.object.sameValue(actual.value, expected_value)) return error.Test262Error;
    }
    if (try expectedHas(rt, expected, "writable")) {
        const writable_value = try expectedValue(rt, expected, "writable");
        defer writable_value.free(rt);
        const expected_writable = writable_value.asBool() orelse return error.Test262Error;
        if (actual.writable != expected_writable) return error.Test262Error;
    }
    if (try expectedHas(rt, expected, "enumerable")) {
        const enumerable_value = try expectedValue(rt, expected, "enumerable");
        defer enumerable_value.free(rt);
        const expected_enumerable = enumerable_value.asBool() orelse return error.Test262Error;
        if (actual.enumerable != expected_enumerable) return error.Test262Error;
    }
    if (try expectedHas(rt, expected, "configurable")) {
        const configurable_value = try expectedValue(rt, expected, "configurable");
        defer configurable_value.free(rt);
        const expected_configurable = configurable_value.asBool() orelse return error.Test262Error;
        if (actual.configurable != expected_configurable) return error.Test262Error;
    }
    if (try expectedHas(rt, expected, "get")) {
        const expected_getter = try expectedValue(rt, expected, "get");
        defer expected_getter.free(rt);
        if (!builtins.object.sameValue(actual.getter, expected_getter)) return error.Test262Error;
    }
    if (try expectedHas(rt, expected, "set")) {
        const expected_setter = try expectedValue(rt, expected, "set");
        defer expected_setter.free(rt);
        if (!builtins.object.sameValue(actual.setter, expected_setter)) return error.Test262Error;
    }
}

fn descriptorFromObject(rt: *core.Runtime, object: *core.Object) !core.Descriptor {
    const has_get = try expectedHas(rt, object, "get");
    const has_set = try expectedHas(rt, object, "set");
    if (has_get or has_set) {
        const getter = if (has_get) try expectedValue(rt, object, "get") else core.Value.undefinedValue();
        errdefer getter.free(rt);
        const setter = if (has_set) try expectedValue(rt, object, "set") else core.Value.undefinedValue();
        errdefer setter.free(rt);
        const enumerable = try optionalBoolProperty(rt, object, "enumerable", false);
        const configurable = try optionalBoolProperty(rt, object, "configurable", false);
        return core.Descriptor.accessor(getter, setter, enumerable, configurable);
    }
    const value = try expectedValue(rt, object, "value");
    errdefer value.free(rt);
    const writable = try optionalBoolProperty(rt, object, "writable", false);
    const enumerable = try optionalBoolProperty(rt, object, "enumerable", false);
    const configurable = try optionalBoolProperty(rt, object, "configurable", false);
    return core.Descriptor.data(value, writable, enumerable, configurable);
}

fn descriptorObject(rt: *core.Runtime, desc: core.Descriptor) !core.Value {
    const object = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    if (desc.kind == .data) try defineObjectProperty(rt, object, "value", desc.value);
    if (desc.kind == .accessor) {
        try defineObjectProperty(rt, object, "get", desc.getter);
        try defineObjectProperty(rt, object, "set", desc.setter);
    }
    if (desc.writable) |flag| try defineBoolProperty(rt, object, "writable", flag);
    if (desc.enumerable) |flag| try defineBoolProperty(rt, object, "enumerable", flag);
    if (desc.configurable) |flag| try defineBoolProperty(rt, object, "configurable", flag);
    return object.value();
}

fn expectedHas(rt: *core.Runtime, object: *core.Object, name: []const u8) !bool {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    return object.hasProperty(key);
}

fn expectedValue(rt: *core.Runtime, object: *core.Object, name: []const u8) !core.Value {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    return object.getProperty(key);
}

fn optionalBoolProperty(rt: *core.Runtime, object: *core.Object, name: []const u8, default: bool) !bool {
    if (!try expectedHas(rt, object, name)) return default;
    const value = try expectedValue(rt, object, name);
    defer value.free(rt);
    return value.asBool() orelse default;
}

fn atomFromPropertyKey(rt: *core.Runtime, value: core.Value) !core.Atom {
    if (value.isSymbol()) return rt.atoms.dup(@intCast(value.asInt32() orelse return error.TypeError));
    if (value.asInt32()) |index| {
        if (index >= 0) return core.atom.atomFromUInt32(@intCast(index));
    }
    const bytes = try stringBytes(rt, value);
    defer rt.memory.allocator.free(bytes);
    return rt.internAtom(bytes);
}

fn atomToStringValue(rt: *core.Runtime, atom_id: core.Atom) !core.Value {
    const name = rt.atoms.name(atom_id) orelse "";
    return value_ops.createStringValue(rt, name);
}

fn stringBytes(rt: *core.Runtime, value: core.Value) ![]u8 {
    if (!value.isString()) return error.TypeError;
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(rt.memory.allocator);
    try value_ops.appendRawString(rt, &buffer, value);
    return buffer.toOwnedSlice(rt.memory.allocator);
}

fn defineBoolProperty(rt: *core.Runtime, object: *core.Object, name: []const u8, value: bool) !void {
    try defineObjectProperty(rt, object, name, core.Value.boolean(value));
}

fn expectObjectArg(value: core.Value) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    return @fieldParentPtr("header", header);
}

fn errorNameMatchesConstructor(err: anyerror, constructor_name: []const u8) bool {
    return (err == error.TypeError and std.mem.eql(u8, constructor_name, "TypeError")) or
        (err == error.Test262Error and std.mem.eql(u8, constructor_name, "Error")) or
        (err == error.SyntaxError and std.mem.eql(u8, constructor_name, "SyntaxError")) or
        (err == error.RangeError and std.mem.eql(u8, constructor_name, "RangeError")) or
        (err == error.EvalError and std.mem.eql(u8, constructor_name, "EvalError")) or
        (err == error.ReferenceError and std.mem.eql(u8, constructor_name, "ReferenceError")) or
        (err == error.Test262Error and std.mem.eql(u8, constructor_name, "Test262Error")) or
        (err == error.Test262Error and !isBuiltinConstructorName(constructor_name));
}

fn isBuiltinConstructorName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Object") or
        std.mem.eql(u8, name, "Function") or
        std.mem.eql(u8, name, "Array") or
        std.mem.eql(u8, name, "String") or
        std.mem.eql(u8, name, "Number") or
        std.mem.eql(u8, name, "Boolean") or
        std.mem.eql(u8, name, "Symbol") or
        std.mem.eql(u8, name, "BigInt") or
        std.mem.eql(u8, name, "Date") or
        std.mem.eql(u8, name, "RegExp") or
        std.mem.eql(u8, name, "Error") or
        std.mem.eql(u8, name, "EvalError") or
        std.mem.eql(u8, name, "RangeError") or
        std.mem.eql(u8, name, "ReferenceError") or
        std.mem.eql(u8, name, "SyntaxError") or
        std.mem.eql(u8, name, "TypeError") or
        std.mem.eql(u8, name, "Promise") or
        std.mem.eql(u8, name, "Map") or
        std.mem.eql(u8, name, "Set") or
        std.mem.eql(u8, name, "WeakMap") or
        std.mem.eql(u8, name, "WeakSet") or
        std.mem.eql(u8, name, "ArrayBuffer") or
        std.mem.eql(u8, name, "DataView");
}

fn printArray(rt: *core.Runtime, writer: *std.Io.Writer, object: *core.Object) anyerror!void {
    var index: u32 = 0;
    while (index < object.length) : (index += 1) {
        if (index != 0) try writer.print(",", .{});
        const value = object.getProperty(core.atom.atomFromUInt32(index));
        defer value.free(rt);
        try printValue(rt, writer, value);
    }
}

fn printString(writer: *std.Io.Writer, value: core.Value) !void {
    const header = value.refHeader() orelse return writer.print("[string]", .{});
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    switch (string_value.data) {
        .latin1 => |bytes| try writer.print("{s}", .{bytes}),
        .utf16 => |units| {
            for (units) |unit| {
                if (unit <= 0x7f) {
                    try writer.writeByte(@intCast(unit));
                } else {
                    try writer.print("\\u{x}", .{unit});
                }
            }
        },
    }
}

fn isFunctionClass(class_id: core.ClassId) bool {
    return class_id == core.class.ids.c_function or
        class_id == core.class.ids.bytecode_function or
        class_id == core.class.ids.bound_function or
        class_id == core.class.ids.c_function_data or
        class_id == core.class.ids.c_closure;
}

fn printNativeFunction(rt: *core.Runtime, writer: *std.Io.Writer, object: *core.Object) !void {
    if (object.function_source) |source| {
        try printString(writer, source);
        return;
    }

    const name_key = try rt.internAtom("name");
    defer rt.atoms.free(name_key);
    const name_value = object.getProperty(name_key);
    defer name_value.free(rt);

    try writer.print("function ", .{});
    if (name_value.isString()) try printString(writer, name_value);
    try writer.print("() {{\n    [native code]\n}}", .{});
}
