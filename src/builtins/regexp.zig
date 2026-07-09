//! Transitional compatibility shim. RegExp native records and JS-visible
//! method bodies live in `exec/regexp_ops.zig`.

const regexp_ops = @import("../exec/regexp_ops.zig");

pub const StaticMethod = regexp_ops.StaticMethod;
pub const ConstructorMethod = regexp_ops.ConstructorMethod;
pub const PrototypeMethod = regexp_ops.PrototypeMethod;
pub const AccessorMethod = regexp_ops.AccessorMethod;
pub const LegacyAccessorMethod = regexp_ops.LegacyAccessorMethod;
pub const accessorMethodId = regexp_ops.accessorMethodId;
pub const accessorNameFromId = regexp_ops.accessorNameFromId;
pub const accessorNameFromGetterName = regexp_ops.accessorNameFromGetterName;
pub const legacyAccessorMethodFromId = regexp_ops.legacyAccessorMethodFromId;
pub const legacyCaptureIndex = regexp_ops.legacyCaptureIndex;
pub const internal_entries = regexp_ops.internal_entries;
pub const compilePatternAndFlags = regexp_ops.compilePatternAndFlags;
pub const classMatchesUtf16Unit = regexp_ops.classMatchesUtf16Unit;

pub const staticMethodId = regexp_ops.staticMethodId;
pub const prototypeMethodId = regexp_ops.prototypeMethodId;
pub const legacyPrototypeMethodId = regexp_ops.legacyPrototypeMethodId;
pub const decodePrototypeMethodId = regexp_ops.decodePrototypeMethodId;
pub const construct = regexp_ops.construct;
pub const constructLiteral = regexp_ops.constructLiteral;
pub const constructLiteralWithValues = regexp_ops.constructLiteralWithValues;
pub const constructWithPrototype = regexp_ops.constructWithPrototype;
pub const methodCall = regexp_ops.methodCall;
pub const accessor = regexp_ops.accessor;
pub const escape = regexp_ops.escape;
