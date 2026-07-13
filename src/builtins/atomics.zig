//! Transitional compatibility shim. Atomics metadata lives in
//! `exec/atomics_ops.zig`.

const atomics_ops = @import("../exec/atomics_ops.zig");

pub const StaticMethod = atomics_ops.StaticMethod;
pub const methodId = atomics_ops.methodId;
