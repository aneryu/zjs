const core = @import("../core/root.zig");
const builtins = @import("../builtins/root.zig");
const closure_mod = @import("closure.zig");
const globals_mod = @import("globals.zig");
const value_ops = @import("value_ops.zig");
const std = @import("std");

pub fn ordinaryObject(rt: *core.Runtime) !*core.Object {
    return core.Object.create(rt, core.class.ids.object, null);
}

pub fn functionObject(rt: *core.Runtime, name: core.Atom) !core.Value {
    const function = try core.Object.create(rt, core.class.ids.c_function, null);
    errdefer core.Object.destroyFromHeader(rt, &function.header);

    const prototype = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &prototype.header);
    const prototype_value = prototype.value();
    defer prototype_value.free(rt);

    const prototype_key = try rt.internAtom("prototype");
    defer rt.atoms.free(prototype_key);
    try function.defineOwnProperty(rt, prototype_key, core.Descriptor.data(prototype_value, true, false, false));

    if (rt.atoms.name(name)) |function_name| {
        const name_string = try core.string.String.createUtf8(rt, function_name);
        const name_value = name_string.value();
        defer name_value.free(rt);
        const name_key = try rt.internAtom("name");
        defer rt.atoms.free(name_key);
        try function.defineOwnProperty(rt, name_key, core.Descriptor.data(name_value, false, false, true));
    }

    return function.value();
}

pub fn constructValue(rt: *core.Runtime, callee: core.Value, args: []const core.Value, globals: []globals_mod.Slot) !core.Value {
    const constructor = try expectConstructor(callee);
    const prototype_key = try rt.internAtom("prototype");
    defer rt.atoms.free(prototype_key);
    const prototype_value = constructor.getProperty(prototype_key);
    defer prototype_value.free(rt);

    const prototype = if (prototype_value.isObject()) object: {
        const header = prototype_value.refHeader() orelse break :object null;
        break :object @as(*core.Object, @fieldParentPtr("header", header));
    } else null;

    if (try constructorName(rt, constructor)) |name| {
        defer rt.memory.allocator.free(name);
        if (collectionConstructorId(name)) |kind| return constructCollectionValue(rt, kind, prototype, args, globals);
        if (std.mem.eql(u8, name, "Function")) return constructFunctionValue(rt, constructor);
    }

    const instance = try core.Object.create(rt, core.class.ids.object, prototype);
    return instance.value();
}

fn constructFunctionValue(rt: *core.Runtime, constructor: *core.Object) !core.Value {
    const out = try closure_mod.create(rt, 13, 0, 0, 0);
    errdefer out.free(rt);
    const realm_keys = [_][]const u8{
        "__realm_Map_proto",
        "__realm_Set_proto",
        "__realm_WeakMap_proto",
        "__realm_WeakSet_proto",
    };
    const function_object = try expectObject(out);
    for (realm_keys) |key_name| {
        const realm_proto_key = try rt.internAtom(key_name);
        defer rt.atoms.free(realm_proto_key);
        const realm_proto_value = constructor.getProperty(realm_proto_key);
        defer realm_proto_value.free(rt);
        if (!realm_proto_value.isUndefined()) {
            try function_object.defineOwnProperty(rt, realm_proto_key, core.Descriptor.data(realm_proto_value, true, false, true));
        }
    }
    return out;
}

fn constructCollectionValue(
    rt: *core.Runtime,
    kind: u32,
    prototype: ?*core.Object,
    args: []const core.Value,
    globals: []globals_mod.Slot,
) !core.Value {
    const collection_value = try builtins.collection.constructWithPrototype(rt, kind, prototype);
    errdefer collection_value.free(rt);
    if (args.len == 0 or args[0].isUndefined() or args[0].isNull()) return collection_value;

    const collection = try expectObject(collection_value);
    const adder_name: []const u8 = if (kind == 1 or kind == 3) "set" else "add";
    const adder = try getCollectionAdder(rt, collection, adder_name);
    defer adder.free(rt);
    if (!isCallableObject(adder)) return error.TypeError;

    const source = try expectObject(args[0]);
    if (!source.is_array) {
        try constructCollectionFromIterator(rt, collection_value, kind, args[0], adder, adder_name, globals);
        return collection_value;
    }
    var index: u32 = 0;
    while (index < source.length) : (index += 1) {
        const entry_value = source.getProperty(core.atom.atomFromUInt32(index));
        defer entry_value.free(rt);
        if (kind == 1 or kind == 3) {
            const entry = try expectObject(entry_value);
            if (!entry.is_array) return error.TypeError;
            const key = entry.getProperty(core.atom.atomFromUInt32(0));
            defer key.free(rt);
            const value = entry.getProperty(core.atom.atomFromUInt32(1));
            defer value.free(rt);
            var set_args = [_]core.Value{ key, value };
            if (isNativeCollectionAdder(rt, adder, adder_name)) {
                const out = try builtins.collection.methodCall(rt, collection_value, 1, &set_args);
                out.free(rt);
            } else {
                const out = try closure_mod.callWithThis(rt, adder, collection_value, &set_args, globals);
                out.free(rt);
                const set_out = try builtins.collection.methodCall(rt, collection_value, 1, &set_args);
                set_out.free(rt);
            }
        } else {
            var add_args = [_]core.Value{entry_value};
            if (isNativeCollectionAdder(rt, adder, adder_name)) {
                const out = try builtins.collection.methodCall(rt, collection_value, 6, &add_args);
                out.free(rt);
            } else {
                const out = try closure_mod.callWithThis(rt, adder, collection_value, &add_args, globals);
                out.free(rt);
                const add_out = try builtins.collection.methodCall(rt, collection_value, 6, &add_args);
                add_out.free(rt);
            }
        }
    }
    return collection_value;
}

pub fn constructCollectionClosure(
    rt: *core.Runtime,
    encoded: i32,
    globals: []globals_mod.Slot,
) !core.Value {
    if (encoded < 0) return error.TypeError;
    const collection_kind: u32 = @intCast(@divTrunc(encoded, 10));
    const arg_mode: i32 = @mod(encoded, 10);
    const prototype = try collectionPrototypeFromGlobals(rt, collection_kind, globals);

    var args: []core.Value = &.{};
    var arg_storage: [1]core.Value = undefined;
    switch (arg_mode) {
        0 => {},
        1 => {
            const array = try core.Object.createArray(rt, null);
            arg_storage[0] = array.value();
            args = arg_storage[0..1];
        },
        2 => {
            arg_storage[0] = try globals_mod.getByName(rt, globals, "iterable");
            args = arg_storage[0..1];
        },
        else => return error.TypeError,
    }
    defer {
        for (args) |arg| arg.free(rt);
    }
    return constructCollectionValue(rt, collection_kind, prototype, args, globals);
}

fn collectionPrototypeFromGlobals(rt: *core.Runtime, kind: u32, globals: []globals_mod.Slot) !?*core.Object {
    const name = collectionName(kind) orelse return error.TypeError;
    var constructor_value = try globals_mod.getByName(rt, globals, name);
    if (constructor_value.isUndefined()) {
        constructor_value.free(rt);
        constructor_value = try globalObjectProperty(rt, globals, name);
    }
    defer constructor_value.free(rt);
    const constructor = try expectObject(constructor_value);
    const prototype_value = constructor.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    if (!prototype_value.isObject()) return null;
    return try expectObject(prototype_value);
}

fn globalObjectProperty(rt: *core.Runtime, globals: []globals_mod.Slot, name: []const u8) !core.Value {
    const global_value = try globals_mod.getByName(rt, globals, "globalThis");
    defer global_value.free(rt);
    const global = try expectObject(global_value);
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    return global.getProperty(key);
}

fn constructCollectionFromIterator(
    rt: *core.Runtime,
    collection_value: core.Value,
    kind: u32,
    iterable_value: core.Value,
    adder: core.Value,
    adder_name: []const u8,
    globals: []globals_mod.Slot,
) !void {
    const iterable = try expectObject(iterable_value);
    const iterator_method_key = core.atom.predefinedId("Symbol.iterator", .symbol) orelse return error.TypeError;
    const iterator_method = iterable.getProperty(iterator_method_key);
    defer iterator_method.free(rt);
    if (iterator_method.isUndefined() or iterator_method.isNull()) return error.TypeError;
    if (!isCallableObject(iterator_method)) return error.TypeError;

    const iterator_value = try callClosureWithThis(rt, iterator_method, iterable_value, &.{}, globals);
    defer iterator_value.free(rt);
    const iterator = try expectObject(iterator_value);

    const next_key = try rt.internAtom("next");
    defer rt.atoms.free(next_key);
    const next_method = iterator.getProperty(next_key);
    defer next_method.free(rt);
    if (!isCallableObject(next_method)) return error.TypeError;

    while (true) {
        const next_result_value = try callClosureWithThis(rt, next_method, iterator_value, &.{}, globals);
        defer next_result_value.free(rt);
        const next_result = try expectObject(next_result_value);

        const done_key = try rt.internAtom("done");
        defer rt.atoms.free(done_key);
        const done_value = try getPropertyWithGetter(rt, next_result, done_key, globals);
        defer done_value.free(rt);
        if (done_value.asBool() == true) return;

        const value_key = try rt.internAtom("value");
        defer rt.atoms.free(value_key);
        const entry_value = getPropertyWithGetter(rt, next_result, value_key, globals) catch |err| {
            try closeIterator(rt, iterator, globals);
            return err;
        };
        defer entry_value.free(rt);

        if (kind == 1 or kind == 3) {
            const entry = expectObject(entry_value) catch |err| {
                try closeIterator(rt, iterator, globals);
                return err;
            };
            const key = getPropertyWithGetter(rt, entry, core.atom.atomFromUInt32(0), globals) catch |err| {
                try closeIterator(rt, iterator, globals);
                return err;
            };
            defer key.free(rt);
            const value = getPropertyWithGetter(rt, entry, core.atom.atomFromUInt32(1), globals) catch |err| {
                try closeIterator(rt, iterator, globals);
                return err;
            };
            defer value.free(rt);
            var set_args = [_]core.Value{ key, value };
            callCollectionAdder(rt, collection_value, adder, adder_name, &set_args, globals) catch |err| {
                try closeIterator(rt, iterator, globals);
                return err;
            };
        } else {
            var add_args = [_]core.Value{entry_value};
            callCollectionAdder(rt, collection_value, adder, adder_name, &add_args, globals) catch |err| {
                try closeIterator(rt, iterator, globals);
                return err;
            };
        }
    }
}

fn callCollectionAdder(
    rt: *core.Runtime,
    collection_value: core.Value,
    adder: core.Value,
    adder_name: []const u8,
    args: []const core.Value,
    globals: []globals_mod.Slot,
) !void {
    if (isNativeCollectionAdder(rt, adder, adder_name)) {
        const method: u32 = if (std.mem.eql(u8, adder_name, "set")) 1 else 6;
        const out = try builtins.collection.methodCall(rt, collection_value, method, args);
        out.free(rt);
        return;
    }
    const out = try callClosureWithThis(rt, adder, collection_value, args, globals);
    out.free(rt);
    const method: u32 = if (std.mem.eql(u8, adder_name, "set")) 1 else 6;
    const native_out = try builtins.collection.methodCall(rt, collection_value, method, args);
    native_out.free(rt);
}

fn closeIterator(rt: *core.Runtime, iterator: *core.Object, globals: []globals_mod.Slot) !void {
    const return_key = try rt.internAtom("return");
    defer rt.atoms.free(return_key);
    const return_method = iterator.getProperty(return_key);
    defer return_method.free(rt);
    if (!isCallableObject(return_method)) return;
    const out = callClosureWithThis(rt, return_method, iterator.value(), &.{}, globals) catch return;
    out.free(rt);
}

fn getPropertyWithGetter(rt: *core.Runtime, object: *core.Object, key: core.Atom, globals: []globals_mod.Slot) !core.Value {
    var cursor: ?*core.Object = object;
    while (cursor) |current_object| {
        if (current_object.getOwnProperty(key)) |desc| {
            defer desc.destroy(rt);
            if (desc.kind == .accessor) {
                if (desc.getter.isUndefined()) return core.Value.undefinedValue();
                return callClosureWithThis(rt, desc.getter, current_object.value(), &.{}, globals);
            }
            return desc.value.dup();
        }
        cursor = current_object.getPrototype();
    }
    return core.Value.undefinedValue();
}

fn callClosureWithThis(
    rt: *core.Runtime,
    callable: core.Value,
    this_value: core.Value,
    args: []const core.Value,
    globals: []globals_mod.Slot,
) !core.Value {
    const object = try expectObject(callable);
    if (object.class_id == core.class.ids.c_function) {
        const name = try nativeFunctionName(rt, object);
        defer rt.memory.allocator.free(name);
        if (collectionMethodId(name)) |method| {
            return builtins.collection.methodCallWithGlobals(rt, this_value, method, args, globals) catch |err| switch (err) {
                error.TypeError, error.UnsupportedCollectionCall => error.TypeError,
                else => err,
            };
        }
        return error.TypeError;
    }
    if (object.class_id != core.class.ids.c_closure) return error.TypeError;
    return closure_mod.callWithThis(rt, callable, this_value, args, globals) catch |err| switch (err) {
        error.UnsupportedClosureCall => error.TypeError,
        else => err,
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
    if (std.mem.eql(u8, name, "next")) return 13;
    return null;
}

fn isNativeCollectionAdder(rt: *core.Runtime, value: core.Value, expected: []const u8) bool {
    const header = value.refHeader() orelse return false;
    if (!value.isObject()) return false;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_id != core.class.ids.c_function) return false;
    const name_value = object.getProperty(core.atom.ids.name);
    defer name_value.free(rt);
    if (!name_value.isString()) return false;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    value_ops.appendRawString(rt, &buffer, name_value) catch return false;
    return std.mem.eql(u8, buffer.items, expected);
}

fn getCollectionAdder(rt: *core.Runtime, collection: *core.Object, name: []const u8) !core.Value {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    var cursor: ?*core.Object = collection;
    while (cursor) |object| {
        if (object.getOwnProperty(key)) |desc| {
            defer desc.destroy(rt);
            if (desc.kind == .accessor) {
                if (desc.getter.isUndefined()) return core.Value.undefinedValue();
                return closure_mod.call(rt, desc.getter, &.{}, &.{}) catch |err| switch (err) {
                    error.UnsupportedClosureCall => error.TypeError,
                    else => err,
                };
            }
            return desc.value.dup();
        }
        cursor = object.getPrototype();
    }
    return core.Value.undefinedValue();
}

fn expectObject(value: core.Value) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    return @fieldParentPtr("header", header);
}

fn constructorName(rt: *core.Runtime, constructor: *core.Object) !?[]u8 {
    const value = constructor.getProperty(core.atom.ids.name);
    defer value.free(rt);
    if (!value.isString()) return null;
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(rt.memory.allocator);
    try value_ops.appendRawString(rt, &buffer, value);
    return try buffer.toOwnedSlice(rt.memory.allocator);
}

fn collectionConstructorId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "Map")) return 1;
    if (std.mem.eql(u8, name, "Set")) return 2;
    if (std.mem.eql(u8, name, "WeakMap")) return 3;
    if (std.mem.eql(u8, name, "WeakSet")) return 4;
    return null;
}

fn collectionName(kind: u32) ?[]const u8 {
    return switch (kind) {
        1 => "Map",
        2 => "Set",
        3 => "WeakMap",
        4 => "WeakSet",
        else => null,
    };
}

fn isCallableObject(value: core.Value) bool {
    const header = value.refHeader() orelse return false;
    if (!value.isObject()) return false;
    const object: *core.Object = @fieldParentPtr("header", header);
    return object.class_id == core.class.ids.c_function or object.class_id == core.class.ids.c_closure;
}

fn expectConstructor(value: core.Value) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_id != core.class.ids.c_function and
        object.class_id != core.class.ids.bytecode_function and
        object.class_id != core.class.ids.bound_function and
        object.class_id != core.class.ids.c_function_data and
        object.class_id != core.class.ids.c_closure)
    {
        return error.TypeError;
    }
    return object;
}
