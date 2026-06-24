const core = @import("../core/root.zig");
const boolean = @import("boolean.zig");

/// Pure Symbol description / registry primitives now live in core/symbol.zig.
/// Re-exported here so the registry/install path and other builtins keep their
/// existing `builtins.symbol.*` spellings (builtins -> core is permitted).
pub const description = core.symbol.description;
pub const registryKey = core.symbol.registryKey;
pub const canBeHeldWeakly = core.symbol.canBeHeldWeakly;

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
