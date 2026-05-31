const core = @import("../core/root.zig");

pub const Slot = struct {
    name: core.Atom,
    value: core.Value,
};

pub fn getByName(rt: *core.Runtime, slots: []const Slot, name: []const u8) !core.Value {
    const atom_id = try rt.internAtom(name);
    defer rt.atoms.free(atom_id);
    for (slots) |slot| {
        if (slot.name == atom_id) return slot.value.dup();
    }
    return core.Value.undefinedValue();
}

pub fn setExistingByName(rt: *core.Runtime, slots: []Slot, name: []const u8, value: core.Value) !void {
    const atom_id = try rt.internAtom(name);
    defer rt.atoms.free(atom_id);
    for (slots) |*slot| {
        if (slot.name == atom_id) {
            const next_value = value.dup();
            const old_value = slot.value;
            slot.value = next_value;
            old_value.free(rt);
            return;
        }
    }
    return error.TypeError;
}
