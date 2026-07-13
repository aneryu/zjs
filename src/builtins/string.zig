//! Transitional compatibility shim. String native records and JS-visible
//! method bodies live in `exec/string_builtin_ops.zig`.

const string_ops = @import("../exec/string_builtin_ops.zig");

pub const StaticMethod = string_ops.StaticMethod;
pub const ConstructorMethod = string_ops.ConstructorMethod;
pub const PrototypeMethod = string_ops.PrototypeMethod;
pub const legacy_split_method_id = string_ops.legacy_split_method_id;
pub const legacy_normalize_method_id = string_ops.legacy_normalize_method_id;
pub const legacy_search_method_id = string_ops.legacy_search_method_id;
pub const legacy_match_method_id = string_ops.legacy_match_method_id;
pub const legacy_replace_all_method_id = string_ops.legacy_replace_all_method_id;
pub const legacy_match_all_method_id = string_ops.legacy_match_all_method_id;
pub const staticMethodId = string_ops.staticMethodId;
pub const prototypeMethodId = string_ops.prototypeMethodId;
pub const decodePrototypeMethodId = string_ops.decodePrototypeMethodId;
pub const encodePrototypeMethodId = string_ops.encodePrototypeMethodId;
pub const internal_entries = string_ops.internal_entries;
pub const iterator = string_ops.iterator;

pub const charAt = string_ops.charAt;
pub const toUpperAscii = string_ops.toUpperAscii;
pub const construct = string_ops.construct;
pub const constructWithPrototype = string_ops.constructWithPrototype;
pub const iteratorNext = string_ops.iteratorNext;
pub const fromCharCode = string_ops.fromCharCode;
pub const fromCodePoint = string_ops.fromCodePoint;
pub const charAtValue = string_ops.charAtValue;
pub const methodCall = string_ops.methodCall;
pub const stringValueFromReceiver = string_ops.stringValueFromReceiver;
