const core = @import("../core/root.zig");

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
