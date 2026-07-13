//! Transitional compatibility shim. URI global function records and method
//! bodies live in `exec/uri_ops.zig`, matching the QuickJS engine-owned
//! standard-global model.

const uri_ops = @import("../exec/uri_ops.zig");

pub const internal_entries = uri_ops.internal_entries;
pub const FourByteEscapeUnits = uri_ops.FourByteEscapeUnits;
pub const decodeSingleFourByteEscapeUnits = uri_ops.decodeSingleFourByteEscapeUnits;
pub const methodId = uri_ops.methodId;

pub const call = uri_ops.call;
pub const escape = uri_ops.escape;
pub const unescape = uri_ops.unescape;
