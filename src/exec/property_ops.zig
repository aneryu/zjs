//! Shared object-property wrappers, property-key conversion, and object checks.
//!
//! Object/value inputs are borrowed; getters and value-based reads return one
//! owned JSValue, while successful definitions duplicate or transfer only as
//! the core Object contract states. Property-key conversion owns its temporary
//! atom and byte buffer locally. Observable VM/proxy dispatch remains in the
//! higher property modules; these helpers map to QuickJS's generic property
//! operations around quickjs.c:8210-9172 and 9663 onward.

const std = @import("std");
const core = @import("../core/root.zig");
const value_ops = @import("value_ops.zig");

pub fn getProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) !core.JSValue {
    _ = rt;
    return try object.getProperty(atom_id);
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
    if (object_value.isGlobal() and value_ops.atomNameEql(rt, atom_id, "globalThis")) return object_value.value().dup();
    return try object_value.getProperty(atom_id);
}

pub fn optionalGetPropertyValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) !core.JSValue {
    _ = rt;
    if (value.isNull() or value.isUndefined()) return core.JSValue.undefinedValue();
    const object_value = try expectObject(value);
    return try object_value.getProperty(atom_id);
}

pub fn propertyIn(rt: *core.JSRuntime, object_value: core.JSValue, key_value: core.JSValue) !core.JSValue {
    const object = try expectObject(object_value);
    const key = try propertyKeyAtom(rt, key_value);
    defer rt.atoms.free(key);
    var found = object.hasProperty(key);
    if (!found and value_ops.atomNameEql(rt, key, "toString")) found = true;
    return core.JSValue.boolean(found);
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

pub const expectObject = core.value_semantics.expectObject;
