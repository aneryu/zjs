//! Transitional compatibility shim. Array native records and JS-visible method
//! bodies live in `exec/array_builtin_ops.zig`.

const array_ops = @import("../exec/array_builtin_ops.zig");

pub const StaticMethod = array_ops.StaticMethod;
pub const PrototypeMethod = array_ops.PrototypeMethod;
pub const ConstructorMethod = array_ops.ConstructorMethod;
pub const decodePrototypeMethodId = array_ops.decodePrototypeMethodId;
pub const internal_entries = array_ops.internal_entries;
pub const isArrayValue = array_ops.isArrayValue;
pub const expectArray = array_ops.expectArray;

pub const staticMethodId = array_ops.staticMethodId;
pub const prototypeMethodId = array_ops.prototypeMethodId;
pub const legacyPrototypeMethodId = array_ops.legacyPrototypeMethodId;
pub const isArrayIndex = array_ops.isArrayIndex;
pub const lengthAfterSet = array_ops.lengthAfterSet;
pub const construct = array_ops.construct;
pub const constructConstructorWithPrototype = array_ops.constructConstructorWithPrototype;
pub const constructWithPrototype = array_ops.constructWithPrototype;
pub const join = array_ops.join;
pub const methodCall = array_ops.methodCall;
