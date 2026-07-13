//! Transitional compatibility shim. Object native records and JS-visible
//! method bodies live in `exec/object_builtin_ops.zig`.

const object_ops = @import("../exec/object_builtin_ops.zig");

pub const EntriesMode = object_ops.EntriesMode;
pub const StaticMethod = object_ops.StaticMethod;
pub const PrototypeMethod = object_ops.PrototypeMethod;
pub const internal_entries = object_ops.internal_entries;
pub const OwnPropertyKeyFilter = object_ops.OwnPropertyKeyFilter;

pub const staticMethodId = object_ops.staticMethodId;
pub const staticMethodName = object_ops.staticMethodName;
pub const prototypeMethodId = object_ops.prototypeMethodId;
pub const prototypeMethodOrdinal = object_ops.prototypeMethodOrdinal;
pub const create = object_ops.create;
pub const keys = object_ops.keys;
pub const literal = object_ops.literal;
pub const ownEntriesArray = object_ops.ownEntriesArray;
pub const qjsObjectIsPrototypeOf = object_ops.qjsObjectIsPrototypeOf;
pub const qjsObjectValueOfCall = object_ops.qjsObjectValueOfCall;
pub const qjsObjectCreateCall = object_ops.qjsObjectCreateCall;
pub const qjsObjectAssignCall = object_ops.qjsObjectAssignCall;
pub const qjsObjectAssignKeys = object_ops.qjsObjectAssignKeys;
pub const qjsObjectHasOwnCall = object_ops.qjsObjectHasOwnCall;
pub const qjsObjectPrototypeOwnPropertyCall = object_ops.qjsObjectPrototypeOwnPropertyCall;
pub const qjsObjectPrototypeDefineAccessorCall = object_ops.qjsObjectPrototypeDefineAccessorCall;
pub const qjsObjectPrototypeLookupAccessorCall = object_ops.qjsObjectPrototypeLookupAccessorCall;
pub const qjsObjectFromEntriesCall = object_ops.qjsObjectFromEntriesCall;
pub const qjsObjectGroupByCall = object_ops.qjsObjectGroupByCall;
pub const qjsObjectSetIntegrityCall = object_ops.qjsObjectSetIntegrityCall;
pub const qjsObjectTestIntegrityCall = object_ops.qjsObjectTestIntegrityCall;
pub const objectIsExtensibleForIntegrity = object_ops.objectIsExtensibleForIntegrity;
pub const appendObjectGroupByValue = object_ops.appendObjectGroupByValue;
pub const qjsObjectPreventExtensionsCall = object_ops.qjsObjectPreventExtensionsCall;
pub const qjsGetOwnPropertyDescriptorCall = object_ops.qjsGetOwnPropertyDescriptorCall;
pub const qjsObjectGetPrototypeOfCall = object_ops.qjsObjectGetPrototypeOfCall;
pub const qjsObjectPrototypeMethodFunctionPrototype = object_ops.qjsObjectPrototypeMethodFunctionPrototype;
pub const isObjectPrototypeNativeRecord = object_ops.isObjectPrototypeNativeRecord;
pub const qjsGetOwnPropertyDescriptorsCall = object_ops.qjsGetOwnPropertyDescriptorsCall;
pub const qjsObjectOwnPropertyKeysCall = object_ops.qjsObjectOwnPropertyKeysCall;
