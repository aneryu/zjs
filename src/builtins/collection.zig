//! Transitional compatibility shim. Collection native records and JS-visible
//! method bodies live in `exec/collection_ops.zig`.

const collection_ops = @import("../exec/collection_ops.zig");

pub const CallbackError = collection_ops.CallbackError;
pub const CallbackCallFn = collection_ops.CallbackCallFn;
pub const CallbackKindFn = collection_ops.CallbackKindFn;
pub const CallbackHost = collection_ops.CallbackHost;
pub const StaticMethod = collection_ops.StaticMethod;
pub const ConstructorMethod = collection_ops.ConstructorMethod;
pub const ConstructorKind = collection_ops.ConstructorKind;
pub const constructorId = collection_ops.constructorId;
pub const constructIdForKind = collection_ops.constructIdForKind;
pub const PrototypeMethod = collection_ops.PrototypeMethod;
pub const prototypeMethodId = collection_ops.prototypeMethodId;
pub const legacyClosureMethodId = collection_ops.legacyClosureMethodId;
pub const fastPrototypeMethodIdForClass = collection_ops.fastPrototypeMethodIdForClass;
pub const internal_entries = collection_ops.internal_entries;
pub const Entry = collection_ops.Entry;
pub const setWeakMapEntry = collection_ops.setWeakMapEntry;
pub const setWeakMapEntryByIdentity = collection_ops.setWeakMapEntryByIdentity;
pub const mapGetLatin1PrefixIntValue = collection_ops.mapGetLatin1PrefixIntValue;
pub const mapSetLatin1PrefixInt32Range = collection_ops.mapSetLatin1PrefixInt32Range;
pub const sweepWeakEntries = collection_ops.sweepWeakEntries;

pub const staticMethodId = collection_ops.staticMethodId;
pub const legacyPrototypeMethodId = collection_ops.legacyPrototypeMethodId;
pub const sameValueZero = collection_ops.sameValueZero;
pub const construct = collection_ops.construct;
pub const constructWithPrototype = collection_ops.constructWithPrototype;
pub const methodCall = collection_ops.methodCall;
pub const methodCallWithGlobals = collection_ops.methodCallWithGlobals;
pub const methodCallWithCallbackHost = collection_ops.methodCallWithCallbackHost;
pub const methodCallWithContext = collection_ops.methodCallWithContext;
pub const methodCallWithContextAndHost = collection_ops.methodCallWithContextAndHost;
pub const methodCallWithGlobal = collection_ops.methodCallWithGlobal;
pub const methodCallWithGlobalAndHost = collection_ops.methodCallWithGlobalAndHost;
pub const methodCallObjectWithGlobal = collection_ops.methodCallObjectWithGlobal;
pub const methodCallObjectWithGlobalAndHost = collection_ops.methodCallObjectWithGlobalAndHost;
pub const readOnlyMethodCallObject = collection_ops.readOnlyMethodCallObject;
pub const methodCallDroppedResult = collection_ops.methodCallDroppedResult;
pub const groupBy = collection_ops.groupBy;
pub const groupByWithCallbackHost = collection_ops.groupByWithCallbackHost;
pub const qjsCollectionIteratorMethodCall = collection_ops.qjsCollectionIteratorMethodCall;
pub const qjsCollectionForEachCall = collection_ops.qjsCollectionForEachCall;
pub const qjsSetMethodCall = collection_ops.qjsSetMethodCall;
pub const qjsCollectionNativeRecord = collection_ops.qjsCollectionNativeRecord;
pub const qjsMapGroupByCall = collection_ops.qjsMapGroupByCall;
pub const qjsMapGroupByRecord = collection_ops.qjsMapGroupByRecord;
pub const qjsMapGetOrInsertComputed = collection_ops.qjsMapGetOrInsertComputed;
pub const collectionMethodOwnerClass = collection_ops.collectionMethodOwnerClass;
