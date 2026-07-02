const std = @import("std");
const core = @import("../core/root.zig");
const value_ops = @import("value_ops.zig");

pub fn getProperty(object: *core.Object, atom_id: core.Atom) core.JSValue {
    return object.getProperty(atom_id);
}

pub fn setProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, value: core.JSValue) !void {
    try object.setProperty(rt, atom_id, value);
}

pub fn defineDataProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, value: core.JSValue) !void {
    try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(value, true, true, true));
}

pub fn deleteProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) bool {
    return object.deleteProperty(rt, atom_id);
}

pub fn getPropertyValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) !core.JSValue {
    const object_value = try expectObject(value);
    if (object_value.flags.is_global and value_ops.atomNameEql(rt, atom_id, "globalThis")) return object_value.value().dup();
    return object_value.getProperty(atom_id);
}

pub fn setPropertyValue(rt: *core.JSRuntime, object_value: core.JSValue, atom_id: core.Atom, value: core.JSValue) !core.JSValue {
    const object = try expectObject(object_value);
    try object.setProperty(rt, atom_id, value);
    return core.JSValue.undefinedValue();
}

pub fn optionalGetPropertyValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) !core.JSValue {
    _ = rt;
    if (value.isNull() or value.isUndefined()) return core.JSValue.undefinedValue();
    const object_value = try expectObject(value);
    return object_value.getProperty(atom_id);
}

pub fn getIndexValue(value: core.JSValue, index: u32) !core.JSValue {
    const object_value = try expectObject(value);
    return object_value.getProperty(core.atom.atomFromUInt32(index));
}

pub fn propertyIn(rt: *core.JSRuntime, object_value: core.JSValue, key_value: core.JSValue) !core.JSValue {
    const object = try expectObject(object_value);
    const key = try propertyKeyAtom(rt, key_value);
    defer rt.atoms.free(key);
    var found = object.hasProperty(key);
    if (!found and value_ops.atomNameEql(rt, key, "toString")) found = true;
    return core.JSValue.boolean(found);
}

pub fn instanceOfObject(value: core.JSValue) core.JSValue {
    return core.JSValue.boolean(objectHeader(value) != null);
}

pub fn instanceOfArray(value: core.JSValue) core.JSValue {
    const header = objectHeader(value) orelse return core.JSValue.boolean(false);
    const object: *core.Object = @fieldParentPtr("header", header);
    return core.JSValue.boolean(object.flags.is_array);
}

pub fn instanceOf(rt: *core.JSRuntime, value: core.JSValue, constructor_value: core.JSValue) !core.JSValue {
    const header = objectHeader(value) orelse return core.JSValue.boolean(false);
    const object: *core.Object = @fieldParentPtr("header", header);

    const constructor_header = objectHeader(constructor_value) orelse return error.TypeError;
    const constructor: *core.Object = @fieldParentPtr("header", constructor_header);
    const prototype_key = try rt.internAtom("prototype");
    defer rt.atoms.free(prototype_key);
    const prototype_value = constructor.getProperty(prototype_key);
    defer prototype_value.free(rt);
    const prototype_header = objectHeader(prototype_value) orelse return error.TypeError;
    const prototype: *core.Object = @fieldParentPtr("header", prototype_header);

    var cursor = object.getPrototype();
    while (cursor) |candidate| {
        if (candidate == prototype) return core.JSValue.boolean(true);
        cursor = candidate.getPrototype();
    }
    return core.JSValue.boolean(false);
}

pub fn propertyKeyAtom(rt: *core.JSRuntime, value: core.JSValue) !core.Atom {
    if (value.asSymbolAtom()) |atom_id| return rt.atoms.dup(atom_id);
    if (value.isString()) {
        const string_value = value.asStringBody().?;
        return string_value.internAtom(rt);
    }
    if (value.asInt32()) |index| {
        if (index >= 0) return core.atom.atomFromUInt32(@intCast(index));
    }
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try value_ops.appendValueString(rt, &bytes, value);
    return rt.internAtom(bytes.items);
}

pub fn expectObject(value: core.JSValue) !*core.Object {
    const header = objectHeader(value) orelse return error.TypeError;
    return @fieldParentPtr("header", header);
}

fn objectHeader(value: core.JSValue) ?*core.gc.Header {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    if (header.meta().kind != .object) return null;
    return header;
}
