const atom = @import("../core/atom.zig");
const core = @import("../core/root.zig");
const std = @import("std");
const boolean = @import("boolean.zig");

pub const registry_prefix = "Symbol.for:";
pub const undefined_description = "Symbol.undefined";

/// Symbol's slice of the `.primitive` native-builtin domain (class tag 4; see
/// the encoding note in boolean.zig). Methods: 1 toString, 2 valueOf, 3
/// `Symbol(...)` called as a function, 4 the `description` getter, 5
/// `[Symbol.toPrimitive]`. All share the delegating handler in boolean.zig,
/// which routes to the exec op `qjsPrimitivePrototypeMethod` (kept in exec for
/// the VM fast path). The `description` getter and `[Symbol.toPrimitive]` ids
/// must match the `primitive_symbol_*_id` constants the registry installs.
pub const symbol_entries = [_]core.host_function.InternalEntry{
    symbolEntry("toString", 0, 41),
    symbolEntry("valueOf", 0, 42),
    symbolEntry("Symbol", 0, 43),
    symbolEntry("get description", 0, 44),
    symbolEntry("[Symbol.toPrimitive]", 1, 45),
};

fn symbolEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{ .name = name, .length = length, .id = id, .magic = @intCast(id), .prepared_call_ok = false, .call = &boolean.primitiveCall };
}

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
