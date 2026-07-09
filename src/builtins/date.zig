//! Transitional compatibility shim. Date native records and JS-visible method
//! bodies live in `exec/date_ops.zig`.

const date_ops = @import("../exec/date_ops.zig");

pub const ms_per_day = date_ops.ms_per_day;

pub const StaticMethod = date_ops.StaticMethod;
pub const ConstructorMethod = date_ops.ConstructorMethod;
pub const PrototypeMethod = date_ops.PrototypeMethod;
pub const ExtendedPrototypeMethod = date_ops.ExtendedPrototypeMethod;
pub const internal_entries = date_ops.internal_entries;

pub const staticMethodId = date_ops.staticMethodId;
pub const decodePrototypeMethodId = date_ops.decodePrototypeMethodId;
pub const encodePrototypeMethodId = date_ops.encodePrototypeMethodId;

pub const prototypeMethodId = date_ops.prototypeMethodId;
pub const call = date_ops.call;
pub const construct = date_ops.construct;
pub const constructWithPrototype = date_ops.constructWithPrototype;
pub const staticCall = date_ops.staticCall;
pub const methodCall = date_ops.methodCall;
pub const methodCallArgs = date_ops.methodCallArgs;
pub const methodCallArgsWithCapturedMs = date_ops.methodCallArgsWithCapturedMs;
pub const setYearNumber = date_ops.setYearNumber;
