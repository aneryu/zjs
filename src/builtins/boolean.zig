//! Transitional compatibility shim. Primitive wrapper records and method
//! dispatch live in `exec/primitive_ops.zig`, matching QuickJS's shared
//! primitive-wrapper native domain.

const primitive_ops = @import("../exec/primitive_ops.zig");

pub const boolean_entries = primitive_ops.boolean_entries;
pub const shared_entries = primitive_ops.shared_entries;

pub const primitiveCall = primitive_ops.primitiveCall;
pub const toString = primitive_ops.toString;
