//! Name-based access to caller-owned arrays of global-style atom/value slots.
//!
//! The containing realm/runtime structure owns slot-name atoms and stored
//! JSValues, and the tracer keeps them alive: reads hand back a borrowed value
//! and replacement is a plain bit copy over the old one, with no ownership
//! taken of the lookup name.
//! This mirrors QuickJS global variable cells (`JSVarRef`/global var table)
//! without owning the table itself. Higher layers may use this core helper;
//! it imports core only and never parser/exec/runtime/binding.

const atom = @import("atom.zig");
const value = @import("value.zig");

pub const Slot = struct {
    name: atom.Atom,
    value: value.JSValue,
};

/// Atom-keyed form. Engine callers look up spellings that are predefined
/// (`globalThis`), so they hold an `atom.ids.*` constant and never intern.
pub fn getByAtom(slots: []const Slot, atom_id: atom.Atom) value.JSValue {
    for (slots) |slot| {
        if (slot.name == atom_id) return slot.value;
    }
    return value.JSValue.undefinedValue();
}
