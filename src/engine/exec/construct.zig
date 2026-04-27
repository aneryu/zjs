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
        if (collectionConstructorId(name)) |kind| return constructCollectionValue(rt, constructor, kind, prototype, args, globals);
        if (std.mem.eql(u8, name, "Function")) return constructFunctionValue(rt, constructor);
    }

    const instance = try core.Object.create(rt, core.class.ids.object, prototype);
    return instance.value();
}

fn constructFunctionValue(rt: *core.Runtime, constructor: *core.Object) !core.Value {
    const out = try closure_mod.create(rt, 13, 0, 0, 0);
    errdefer out.free(rt);
    const realm_proto_key = try rt.internAtom("__realm_map_proto");
    defer rt.atoms.free(realm_proto_key);
    const realm_proto_value = constructor.getProperty(realm_proto_key);
    defer realm_proto_value.free(rt);
    if (!realm_proto_value.isUndefined()) {
        const function_object = try expectObject(out);
        try function_object.defineOwnProperty(rt, realm_proto_key, core.Descriptor.data(realm_proto_value, true, false, true));
    }
    return out;
}

fn constructCollectionValue(
    rt: *core.Runtime,
    constructor: *core.Object,
    kind: u32,
    prototype: ?*core.Object,
    args: []const core.Value,
    globals: []globals_mod.Slot,
) !core.Value {
    _ = constructor;
    const collection_value = try builtins.collection.constructWithPrototype(rt, kind, prototype);
    errdefer collection_value.free(rt);
    if (args.len == 0 or args[0].isUndefined() or args[0].isNull()) return collection_value;

    const collection = try expectObject(collection_value);
    const adder_name: []const u8 = if (kind == 1 or kind == 3) "set" else "add";
    const adder = try getCollectionAdder(rt, collection, adder_name);
    defer adder.free(rt);
    if (!isCallableObject(adder)) return error.TypeError;

    const source = try expectObject(args[0]);
    if (!source.is_array) return error.TypeError;
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
