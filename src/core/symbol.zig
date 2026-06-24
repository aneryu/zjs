//! Symbol description / registry primitives.
//!
//! These are the pure atom-table helpers behind the Symbol description getter,
//! the global symbol registry (`Symbol.for` / `Symbol.keyFor`), and the
//! `canBeHeldWeakly` predicate used by `WeakRef` / `WeakMap` / `WeakSet` /
//! `FinalizationRegistry`. They depend only on `core.atom` (atom kind / name /
//! registered-symbol lookup) and the `core` value/runtime types, carrying zero
//! exec/builtins/opcode dependency. They live in core and are consumed directly
//! by the VM (exec value/object/construct/reflect ops and builtin glue) as well
//! as by the builtins Symbol install path (builtins/symbol.zig re-exports them).

const core = @import("root.zig");
const atom = @import("atom.zig");

/// Returns the description string of `symbol`, or null when the symbol has no
/// description.
pub fn description(atoms: *atom.AtomTable, symbol: atom.Atom) ?[]const u8 {
    const kind = atoms.kind(symbol) orelse return null;
    if (!atom.isPublicSymbolKind(kind) and kind != .private) return null;
    return atoms.symbolDescription(symbol);
}

/// Returns the global-registry key of `symbol` (the string passed to
/// `Symbol.for`), or null when `symbol` is not a registered symbol.
pub fn registryKey(atoms: *atom.AtomTable, symbol: atom.Atom) ?[]const u8 {
    if (atoms.kind(symbol) != .global_symbol) return null;
    return atoms.name(symbol);
}

/// CanBeHeldWeakly predicate: objects and non-registered (unique) symbols may be
/// held weakly; registered (`Symbol.for`) symbols and primitives may not.
pub fn canBeHeldWeakly(rt: *core.JSRuntime, value: core.JSValue) bool {
    if (value.isObject()) return true;
    if (value.asSymbolAtom()) |atom_id| {
        return rt.atoms.kind(atom_id) == .symbol;
    }
    return false;
}
