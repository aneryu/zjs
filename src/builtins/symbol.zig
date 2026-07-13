//! Transitional compatibility shim. Symbol primitive-wrapper records live in
//! `exec/primitive_ops.zig`; pure symbol helpers live in `core/symbol.zig`.

const core = @import("../core/root.zig");
const primitive_ops = @import("../exec/primitive_ops.zig");

pub const description = core.symbol.description;
pub const registryKey = core.symbol.registryKey;
pub const canBeHeldWeakly = core.symbol.canBeHeldWeakly;

pub const symbol_entries = primitive_ops.symbol_entries;
