const atom = @import("../core/atom.zig");
const core = @import("../core/root.zig");
const std = @import("std");

pub const registry_prefix = "Symbol.for:";
pub const undefined_description = "Symbol.undefined";

pub fn description(atoms: *atom.AtomTable, symbol: atom.Atom) ?[]const u8 {
    if (atoms.kind(symbol) != .symbol) return null;
    const name = atoms.name(symbol) orelse return null;
    if (std.mem.startsWith(u8, name, registry_prefix)) return name[registry_prefix.len..];
    if (std.mem.eql(u8, name, undefined_description)) return null;
    return name;
}

pub fn registryKey(atoms: *atom.AtomTable, symbol: atom.Atom) ?[]const u8 {
    if (atoms.kind(symbol) != .symbol) return null;
    if (!atoms.isRegisteredSymbol(symbol)) return null;
    const name = atoms.name(symbol) orelse return null;
    if (!std.mem.startsWith(u8, name, registry_prefix)) return null;
    return name[registry_prefix.len..];
}

pub fn canBeHeldWeakly(rt: *core.JSRuntime, value: core.JSValue) bool {
    if (value.isObject()) return true;
    if (value.asSymbolAtom()) |atom_id| {
        return rt.atoms.kind(atom_id) == .symbol and registryKey(&rt.atoms, atom_id) == null;
    }
    return false;
}
