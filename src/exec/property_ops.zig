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

pub fn setProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, value: core.JSValue) !void {
    try object.setProperty(rt, atom_id, value);
}

pub fn defineDataProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, value: core.JSValue) !void {
    try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(value, true, true, true));
}

pub fn getPropertyValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) !core.JSValue {
    const object_value = try expectObject(value);
    if (object_value.isGlobal() and value_ops.atomNameEql(rt, atom_id, "globalThis")) return object_value.value();
    return try object_value.getProperty(atom_id);
}

/// Allocation-free prefix of `propertyKeyAtom`: the atom when `value` is
/// already a property key that needs no interning work (a symbol, a string
/// whose atom is bound, or a non-negative int32 index); null otherwise so the
/// caller takes `propertyKeyAtom`. Keep the arms in lockstep with it.
pub fn propertyKeyAtomIfReady(value: core.JSValue) ?core.Atom {
    if (value.asSymbolAtom()) |atom_id| return atom_id;
    if (value.asStringBody()) |string_value| {
        if (string_value.atom_id != core.string.String.no_atom_id) return string_value.atom_id;
        return null;
    }
    if (value.asInt32()) |index| {
        if (index >= 0) return core.atom.atomFromUInt32(@intCast(index));
    }
    return null;
}

pub fn propertyKeyAtom(rt: *core.JSRuntime, value: core.JSValue) !core.Atom {
    if (value.asSymbolAtom()) |atom_id| return atom_id;
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
