const atom = @import("../core/atom.zig");

pub fn description(atoms: *atom.AtomTable, symbol: atom.Atom) ?[]const u8 {
    if (atoms.kind(symbol) != .symbol) return null;
    return atoms.name(symbol);
}
