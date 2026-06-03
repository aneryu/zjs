const core = @import("../core/root.zig");

pub const Slot = struct {
    name: core.Atom,
    value: core.JSValue,
};

pub fn getByName(rt: *core.JSRuntime, slots: []const Slot, name: []const u8) !core.JSValue {
    const atom_id = try rt.internAtom(name);
    defer rt.atoms.free(atom_id);
    for (slots) |slot| {
        if (slot.name == atom_id) return slot.value.dup();
    }
    return core.JSValue.undefinedValue();
}

pub fn setExistingByName(rt: *core.JSRuntime, slots: []Slot, name: []const u8, value: core.JSValue) !void {
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
