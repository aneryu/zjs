//! Transitional compatibility shim. JSON's function-list table and method
//! bodies live in `exec/json_ops.zig`, matching the QuickJS engine-owned
//! standard-global model.

const json_ops = @import("../exec/json_ops.zig");

pub const StaticMethod = json_ops.StaticMethod;
pub const internal_entries = json_ops.internal_entries;
pub const JsonParseWithRecord = json_ops.JsonParseWithRecord;
pub const createJsonStringValue = json_ops.createJsonStringValue;
pub const appendJsonStringValue = json_ops.appendJsonStringValue;
pub const appendJsonAtomName = json_ops.appendJsonAtomName;
pub const appendEscapedJsonString = json_ops.appendEscapedJsonString;

pub const stringify = json_ops.stringify;
pub const parse = json_ops.parse;
pub const parseWithRecord = json_ops.parseWithRecord;
pub const rawJSON = json_ops.rawJSON;
pub const isRawJSON = json_ops.isRawJSON;
pub const stringifyInt = json_ops.stringifyInt;
pub const parseInt = json_ops.parseInt;
pub const qjsJsonParseCall = json_ops.qjsJsonParseCall;
pub const qjsJsonInternalizeProperty = json_ops.qjsJsonInternalizeProperty;
pub const qjsJsonInternalizeChild = json_ops.qjsJsonInternalizeChild;
pub const qjsJsonCreateDataProperty = json_ops.qjsJsonCreateDataProperty;
pub const qjsJsonStringifyCall = json_ops.qjsJsonStringifyCall;
pub const qjsJsonStringifyPropertyList = json_ops.qjsJsonStringifyPropertyList;
pub const qjsJsonStringifyGap = json_ops.qjsJsonStringifyGap;
pub const qjsJsonSerializeProperty = json_ops.qjsJsonSerializeProperty;
pub const qjsJsonAppendValue = json_ops.qjsJsonAppendValue;
pub const qjsJsonAppendArray = json_ops.qjsJsonAppendArray;
pub const qjsJsonAppendObject = json_ops.qjsJsonAppendObject;
pub const qjsJsonPrimitiveWrapperValue = json_ops.qjsJsonPrimitiveWrapperValue;
pub const qjsJsonObjectInStack = json_ops.qjsJsonObjectInStack;
pub const qjsJsonAppendIndent = json_ops.qjsJsonAppendIndent;
