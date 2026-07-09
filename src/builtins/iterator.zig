//! Transitional compatibility shim. Iterator native records and JS-visible
//! method bodies live in `exec/iterator_builtin_ops.zig`.

const iterator_ops = @import("../exec/iterator_builtin_ops.zig");

pub const Result = iterator_ops.Result;
pub const AccessorMethod = iterator_ops.AccessorMethod;
pub const StaticMethod = iterator_ops.StaticMethod;
pub const PrototypeMethod = iterator_ops.PrototypeMethod;
pub const internal_entries = iterator_ops.internal_entries;

pub const staticMethodId = iterator_ops.staticMethodId;
pub const prototypeMethodId = iterator_ops.prototypeMethodId;
pub const next = iterator_ops.next;
