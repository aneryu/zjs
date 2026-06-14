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

const std = @import("std");

const core = @import("root.zig");
const atom = @import("atom.zig");

/// Atom-name prefix marking a value symbol interned through the global registry
/// (`Symbol.for("key")`). The stored name is `"Symbol.for:" ++ key`.
pub const registry_prefix = "Symbol.for:";

/// Atom name used for the description-less symbol created by `Symbol()` with no
/// argument; `description` reports it as no description (null).
pub const undefined_description = "Symbol.undefined";

/// Returns the description string of `symbol`, or null when the symbol has no
/// description. Strips the registry prefix for registered symbols and maps the
/// sentinel `undefined_description` name back to null.
pub fn description(atoms: *atom.AtomTable, symbol: atom.Atom) ?[]const u8 {
    if (atoms.kind(symbol) != .symbol) return null;
    const name = atoms.name(symbol) orelse return null;
    if (std.mem.startsWith(u8, name, registry_prefix)) return name[registry_prefix.len..];
    if (std.mem.eql(u8, name, undefined_description)) return null;
    return name;
}

/// Returns the global-registry key of `symbol` (the string passed to
/// `Symbol.for`), or null when `symbol` is not a registered symbol.
pub fn registryKey(atoms: *atom.AtomTable, symbol: atom.Atom) ?[]const u8 {
    if (atoms.kind(symbol) != .symbol) return null;
    if (!atoms.isRegisteredSymbol(symbol)) return null;
    const name = atoms.name(symbol) orelse return null;
    if (!std.mem.startsWith(u8, name, registry_prefix)) return null;
    return name[registry_prefix.len..];
}

/// CanBeHeldWeakly predicate: objects and non-registered (unique) symbols may be
/// held weakly; registered (`Symbol.for`) symbols and primitives may not.
pub fn canBeHeldWeakly(rt: *core.JSRuntime, value: core.JSValue) bool {
    if (value.isObject()) return true;
    if (value.asSymbolAtom()) |atom_id| {
        return rt.atoms.kind(atom_id) == .symbol and registryKey(&rt.atoms, atom_id) == null;
    }
    return false;
}
