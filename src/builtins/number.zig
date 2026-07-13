//! Transitional compatibility shim. Number global/static/prototype records and
//! method bodies live in `exec/number_ops.zig`, matching the QuickJS
//! engine-owned standard-global model.

const number_ops = @import("../exec/number_ops.zig");

pub const parseIntValue = number_ops.parseIntValue;
pub const parseFloatValue = number_ops.parseFloatValue;
pub const parseIntLatin1Bytes = number_ops.parseIntLatin1Bytes;
pub const parseFloatLatin1Bytes = number_ops.parseFloatLatin1Bytes;
pub const StaticMethod = number_ops.StaticMethod;
pub const PrototypeMethod = number_ops.PrototypeMethod;
pub const internal_entries = number_ops.internal_entries;

pub const staticMethodId = number_ops.staticMethodId;
pub const prototypeMethodId = number_ops.prototypeMethodId;
pub const parseFloat = number_ops.parseFloat;
pub const toString = number_ops.toString;
pub const toFixed = number_ops.toFixed;
pub const toExponential = number_ops.toExponential;
pub const toPrecision = number_ops.toPrecision;
pub const toStringMethod = number_ops.toStringMethod;
