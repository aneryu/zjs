const core = @import("../core/root.zig");
const value_ops = @import("value_ops.zig");
const std = @import("std");

pub fn getProperty(object: *core.Object, atom_id: core.Atom) core.Value {
    return object.getProperty(atom_id);
}

pub fn setProperty(rt: *core.Runtime, object: *core.Object, atom_id: core.Atom, value: core.Value) !void {
    try object.setProperty(rt, atom_id, value);
}

pub fn defineDataProperty(rt: *core.Runtime, object: *core.Object, atom_id: core.Atom, value: core.Value) !void {
    try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(value, true, true, true));
}

pub fn deleteProperty(rt: *core.Runtime, object: *core.Object, atom_id: core.Atom) bool {
    return object.deleteProperty(rt, atom_id);
}

pub fn getPropertyValue(rt: *core.Runtime, value: core.Value, atom_id: core.Atom) !core.Value {
    const object_value = try expectObject(value);
    if (object_value.is_global and value_ops.atomNameEql(rt, atom_id, "globalThis")) return object_value.value().dup();
    return object_value.getProperty(atom_id);
}

pub fn setPropertyValue(rt: *core.Runtime, object_value: core.Value, atom_id: core.Atom, value: core.Value) !core.Value {
    const object = try expectObject(object_value);
    try object.setProperty(rt, atom_id, value);
    return core.Value.undefinedValue();
}

pub fn optionalGetPropertyValue(rt: *core.Runtime, value: core.Value, atom_id: core.Atom) !core.Value {
    _ = rt;
    if (value.isNull() or value.isUndefined()) return core.Value.undefinedValue();
    const object_value = try expectObject(value);
    return object_value.getProperty(atom_id);
}

pub fn getIndexValue(value: core.Value, index: u32) !core.Value {
    const object_value = try expectObject(value);
    return object_value.getProperty(core.atom.atomFromUInt32(index));
}

pub fn propertyIn(rt: *core.Runtime, object_value: core.Value, key_value: core.Value) !core.Value {
    const object = try expectObject(object_value);
    const key = try propertyKeyAtom(rt, key_value);
    defer rt.atoms.free(key);
    var found = object.hasProperty(key);
    if (!found and value_ops.atomNameEql(rt, key, "toString")) found = true;
    return core.Value.boolean(found);
}

pub fn instanceOfObject(value: core.Value) core.Value {
    return core.Value.boolean(value.isObject());
}

pub fn instanceOfArray(value: core.Value) core.Value {
    const header = value.refHeader() orelse return core.Value.boolean(false);
    if (!value.isObject()) return core.Value.boolean(false);
    const object: *core.Object = @fieldParentPtr("header", header);
    return core.Value.boolean(object.is_array);
}

pub fn instanceOf(rt: *core.Runtime, value: core.Value, constructor_value: core.Value) !core.Value {
    const header = value.refHeader() orelse return core.Value.boolean(false);
    if (!value.isObject()) return core.Value.boolean(false);
    const object: *core.Object = @fieldParentPtr("header", header);

    const constructor_header = constructor_value.refHeader() orelse return error.TypeError;
    if (!constructor_value.isObject()) return error.TypeError;
    const constructor: *core.Object = @fieldParentPtr("header", constructor_header);
    const prototype_key = try rt.internAtom("prototype");
    defer rt.atoms.free(prototype_key);
    const prototype_value = constructor.getProperty(prototype_key);
    defer prototype_value.free(rt);
    const prototype_header = prototype_value.refHeader() orelse return error.TypeError;
    if (!prototype_value.isObject()) return error.TypeError;
    const prototype: *core.Object = @fieldParentPtr("header", prototype_header);

    var cursor = object.getPrototype();
    while (cursor) |candidate| {
        if (candidate == prototype) return core.Value.boolean(true);
        cursor = candidate.getPrototype();
    }
    return core.Value.boolean(false);
}

pub fn propertyKeyAtom(rt: *core.Runtime, value: core.Value) !core.Atom {
    if (value.asSymbolAtom()) |atom_id| return rt.atoms.dup(atom_id);
    if (value.isString()) {
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(rt.memory.allocator);
        try value_ops.appendRawString(rt, &bytes, value);
        return rt.internAtom(bytes.items);
    }
    if (value.asInt32()) |index| {
        if (index >= 0) return core.atom.atomFromUInt32(@intCast(index));
    }
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try value_ops.appendValueString(rt, &bytes, value);
    return rt.internAtom(bytes.items);
}

pub fn expectObject(value: core.Value) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    return @fieldParentPtr("header", header);
}
