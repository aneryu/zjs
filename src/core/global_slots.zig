//! Name-based access to caller-owned arrays of global-style atom/value slots.
//!
//! The containing realm/runtime structure owns slot-name atoms and stored
//! JSValues. Reads return a retained value; replacement retains the new value
//! before releasing the old one and never takes ownership of the lookup name.
//! This mirrors QuickJS global variable cells (`JSVarRef`/global var table)
//! without owning the table itself. Higher layers may use this core helper;
//! it imports core only and never parser/exec/runtime/binding.

const atom = @import("atom.zig");
const runtime = @import("runtime.zig");
const value = @import("value.zig");

pub const Slot = struct {
    name: atom.Atom,
    value: value.JSValue,
};

pub fn getByName(rt: *runtime.JSRuntime, slots: []const Slot, name: []const u8) !value.JSValue {
    const atom_id = try rt.internAtom(name);
    defer rt.atoms.free(atom_id);
    for (slots) |slot| {
        if (slot.name == atom_id) return slot.value.dup();
    }
    return value.JSValue.undefinedValue();
}

pub fn setExistingByName(rt: *runtime.JSRuntime, slots: []Slot, name: []const u8, next_value: value.JSValue) !void {
    const atom_id = try rt.internAtom(name);
    defer rt.atoms.free(atom_id);
    for (slots) |*slot| {
        if (slot.name == atom_id) {
            const duplicated = next_value.dup();
            const old_value = slot.value;
            slot.value = duplicated;
            old_value.free(rt);
            return;
        }
    }
    return error.TypeError;
}
