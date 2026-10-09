//! Predefined atom ids, aliases, and the static spelling hash.
//!
//! Order is the engine contract. `atom.zig` re-exports the public names.

const std = @import("std");
const atom = @import("atom.zig");

const Atom = atom.Atom;
const AtomKind = atom.AtomKind;
const null_atom = atom.null_atom;
const tagged_int_bit = atom.tagged_int_bit;
const max_int_atom = atom.max_int_atom;
const parseArrayIndex = @import("atom_list.zig").parseArrayIndex;

pub const PredefinedAtom = struct {
    id: Atom,
    name: []const u8,
    kind: AtomKind = .string,
};

/// One row per predefined atom. Ids are 1-based indices into this table;
/// `ids` and `predefined_atoms` are both generated from it. Order is the
/// engine contract (keyword token arithmetic, well-known symbol ids, group
/// markers): append new entries at the end and do not reorder.
const PredefinedSpec = struct {
    name: []const u8,
    kind: AtomKind = .string,
};

const predefined_spec = [_]PredefinedSpec{
    // Keywords (1..46). Parser token atoms are `ids.null_ + (tok - TOK_NULL)`.
    .{ .name = "null" },
    .{ .name = "false" },
    .{ .name = "true" },
    .{ .name = "if" },
    .{ .name = "else" },
    .{ .name = "return" },
    .{ .name = "var" },
    .{ .name = "this" },
    .{ .name = "delete" },
    .{ .name = "void" },
    .{ .name = "typeof" },
    .{ .name = "new" },
    .{ .name = "in" },
    .{ .name = "instanceof" },
    .{ .name = "do" },
    .{ .name = "while" },
    .{ .name = "for" },
    .{ .name = "break" },
    .{ .name = "continue" },
    .{ .name = "switch" },
    .{ .name = "case" },
    .{ .name = "default" },
    .{ .name = "throw" },
    .{ .name = "try" },
    .{ .name = "catch" },
    .{ .name = "finally" },
    .{ .name = "function" },
    .{ .name = "debugger" },
    .{ .name = "with" },
    .{ .name = "class" },
    .{ .name = "const" },
    .{ .name = "enum" },
    .{ .name = "export" },
    .{ .name = "extends" },
    .{ .name = "import" },
    .{ .name = "super" },
    .{ .name = "implements" },
    .{ .name = "interface" },
    .{ .name = "let" },
    .{ .name = "package" },
    .{ .name = "private" },
    .{ .name = "protected" },
    .{ .name = "public" },
    .{ .name = "static" },
    .{ .name = "yield" },
    .{ .name = "await" },
    // Empty string and common property / typeof keys.
    .{ .name = "" },
    .{ .name = "keys" },
    .{ .name = "size" },
    .{ .name = "length" },
    .{ .name = "message" },
    .{ .name = "cause" },
    .{ .name = "errors" },
    .{ .name = "stack" },
    .{ .name = "name" },
    .{ .name = "toString" },
    .{ .name = "toLocaleString" },
    .{ .name = "valueOf" },
    .{ .name = "eval" },
    .{ .name = "prototype" },
    .{ .name = "constructor" },
    .{ .name = "configurable" },
    .{ .name = "writable" },
    .{ .name = "enumerable" },
    .{ .name = "value" },
    .{ .name = "get" },
    .{ .name = "set" },
    .{ .name = "of" },
    .{ .name = "__proto__" },
    .{ .name = "undefined" },
    .{ .name = "number" },
    .{ .name = "boolean" },
    .{ .name = "string" },
    .{ .name = "object" },
    .{ .name = "symbol" },
    .{ .name = "integer" },
    .{ .name = "unknown" },
    .{ .name = "arguments" },
    .{ .name = "callee" },
    .{ .name = "caller" },
    .{ .name = "<eval>" },
    .{ .name = "<ret>" },
    .{ .name = "<var>" },
    .{ .name = "<arg_var>" },
    .{ .name = "<with>" },
    .{ .name = "lastIndex" },
    .{ .name = "target" },
    .{ .name = "index" },
    .{ .name = "input" },
    .{ .name = "defineProperties" },
    .{ .name = "apply" },
    .{ .name = "join" },
    .{ .name = "concat" },
    .{ .name = "split" },
    .{ .name = "construct" },
    .{ .name = "getPrototypeOf" },
    .{ .name = "setPrototypeOf" },
    .{ .name = "isExtensible" },
    .{ .name = "preventExtensions" },
    .{ .name = "has" },
    .{ .name = "deleteProperty" },
    .{ .name = "defineProperty" },
    .{ .name = "getOwnPropertyDescriptor" },
    .{ .name = "ownKeys" },
    .{ .name = "add" },
    .{ .name = "done" },
    .{ .name = "next" },
    .{ .name = "values" },
    .{ .name = "source" },
    .{ .name = "flags" },
    .{ .name = "global" },
    .{ .name = "unicode" },
    .{ .name = "raw" },
    .{ .name = "rawJSON" },
    .{ .name = "new.target" },
    .{ .name = "this.active_func" },
    .{ .name = "<home_object>" },
    .{ .name = "<computed_field>" },
    .{ .name = "<static_computed_field>" },
    .{ .name = "<class_fields_init>" },
    .{ .name = "<brand>" },
    .{ .name = "#constructor" },
    .{ .name = "as" },
    .{ .name = "from" },
    .{ .name = "fromAsync" },
    .{ .name = "meta" },
    .{ .name = "*default*" },
    .{ .name = "*" },
    .{ .name = "Module" },
    .{ .name = "then" },
    .{ .name = "resolve" },
    .{ .name = "reject" },
    .{ .name = "promise" },
    .{ .name = "proxy" },
    .{ .name = "revoke" },
    .{ .name = "async" },
    .{ .name = "exec" },
    .{ .name = "groups" },
    .{ .name = "indices" },
    .{ .name = "status" },
    .{ .name = "reason" },
    .{ .name = "globalThis" },
    .{ .name = "bigint" },
    .{ .name = "not-equal" },
    .{ .name = "timed-out" },
    .{ .name = "ok" },
    .{ .name = "toJSON" },
    .{ .name = "maxByteLength" },
    .{ .name = "zip" },
    .{ .name = "zipKeyed" },
    .{ .name = "Object" },
    .{ .name = "Array" },
    .{ .name = "Error" },
    .{ .name = "Number" },
    .{ .name = "String" },
    .{ .name = "Boolean" },
    .{ .name = "Symbol" },
    .{ .name = "Arguments" },
    .{ .name = "Math" },
    .{ .name = "JSON" },
    .{ .name = "Date" },
    .{ .name = "Function" },
    .{ .name = "GeneratorFunction" },
    .{ .name = "ForInIterator" },
    .{ .name = "RegExp" },
    .{ .name = "ArrayBuffer" },
    .{ .name = "SharedArrayBuffer" },
    .{ .name = "Uint8ClampedArray" },
    .{ .name = "Int8Array" },
    .{ .name = "Uint8Array" },
    .{ .name = "Int16Array" },
    .{ .name = "Uint16Array" },
    .{ .name = "Int32Array" },
    .{ .name = "Uint32Array" },
    .{ .name = "BigInt64Array" },
    .{ .name = "BigUint64Array" },
    .{ .name = "Float16Array" },
    .{ .name = "Float32Array" },
    .{ .name = "Float64Array" },
    .{ .name = "DataView" },
    .{ .name = "BigInt" },
    .{ .name = "WeakRef" },
    .{ .name = "FinalizationRegistry" },
    .{ .name = "Map" },
    .{ .name = "Set" },
    .{ .name = "WeakMap" },
    .{ .name = "WeakSet" },
    .{ .name = "Iterator" },
    .{ .name = "Iterator Concat" },
    .{ .name = "Iterator Helper" },
    .{ .name = "Iterator Wrap" },
    .{ .name = "Map Iterator" },
    .{ .name = "Set Iterator" },
    .{ .name = "Array Iterator" },
    .{ .name = "String Iterator" },
    .{ .name = "RegExp String Iterator" },
    .{ .name = "Generator" },
    .{ .name = "Proxy" },
    .{ .name = "Promise" },
    .{ .name = "PromiseResolveFunction" },
    .{ .name = "PromiseRejectFunction" },
    .{ .name = "AsyncFunction" },
    .{ .name = "AsyncFunctionResolve" },
    .{ .name = "AsyncFunctionReject" },
    .{ .name = "AsyncGeneratorFunction" },
    .{ .name = "AsyncGenerator" },
    .{ .name = "EvalError" },
    .{ .name = "RangeError" },
    .{ .name = "ReferenceError" },
    .{ .name = "SyntaxError" },
    .{ .name = "TypeError" },
    .{ .name = "URIError" },
    .{ .name = "InternalError" },
    .{ .name = "DOMException" },
    .{ .name = "CallSite" },
    // Private brand and well-known symbols.
    .{ .name = "<brand>", .kind = .private },
    .{ .name = "Symbol.toPrimitive", .kind = .symbol },
    .{ .name = "Symbol.iterator", .kind = .symbol },
    .{ .name = "Symbol.match", .kind = .symbol },
    .{ .name = "Symbol.matchAll", .kind = .symbol },
    .{ .name = "Symbol.replace", .kind = .symbol },
    .{ .name = "Symbol.search", .kind = .symbol },
    .{ .name = "Symbol.split", .kind = .symbol },
    .{ .name = "Symbol.toStringTag", .kind = .symbol },
    .{ .name = "Symbol.isConcatSpreadable", .kind = .symbol },
    .{ .name = "Symbol.hasInstance", .kind = .symbol },
    .{ .name = "Symbol.species", .kind = .symbol },
    .{ .name = "Symbol.unscopables", .kind = .symbol },
    .{ .name = "Symbol.asyncIterator", .kind = .symbol },
    .{ .name = "Symbol.asyncDispose", .kind = .symbol },
    .{ .name = "Symbol.dispose", .kind = .symbol },
    // Host-internal markers.
    .{ .name = "__zjs_proto_keepalive" },
    .{ .name = "__zjs_BigInt_proto" },
    .{ .name = "__zjs_Boolean_proto" },
    .{ .name = "__zjs_Number_proto" },
    .{ .name = "__zjs_String_proto" },
    .{ .name = "__zjs_Symbol_proto" },
    .{ .name = "__zjs_array_concat" },
    .{ .name = "__zjs_array_constructor" },
    .{ .name = "__zjs_array_iterator_kind" },
    .{ .name = "__zjs_array_species_getter" },
    .{ .name = "__zjs_array_to_locale_string" },
    .{ .name = "__zjs_array_to_string" },
    .{ .name = "__zjs_arraybuffer_proto" },
    .{ .name = "__zjs_atomics_static" },
    .{ .name = "__zjs_buffer_method_kind" },
    .{ .name = "__zjs_define_property_kind" },
    .{ .name = "__zjs_error_to_string" },
    .{ .name = "__zjs_function_to_string" },
    .{ .name = "__zjs_immutable_prototype" },
    .{ .name = "__zjs_iterator_accessor" },
    .{ .name = "__zjs_iterator_method" },
    .{ .name = "__zjs_iterator_static" },
    .{ .name = "__zjs_json_static" },
    .{ .name = "__zjs_number_method" },
    .{ .name = "__zjs_object_method" },
    .{ .name = "__zjs_object_static" },
    .{ .name = "__zjs_primitive_method" },
    .{ .name = "__zjs_reflect_set_prototype_of" },
    .{ .name = "__zjs_reflect_static" },
    .{ .name = "__zjs_regexp_method" },
    .{ .name = "__zjs_string_method" },
    .{ .name = "__zjs_typedarray_method" },
    .{ .name = "__zjs_typedarray_static" },
    // Builtin and registry names.
    .{ .name = "assign" },
    .{ .name = "create" },
    .{ .name = "getOwnPropertyDescriptors" },
    .{ .name = "getOwnPropertyNames" },
    .{ .name = "getOwnPropertySymbols" },
    .{ .name = "hasOwn" },
    .{ .name = "seal" },
    .{ .name = "isSealed" },
    .{ .name = "isFrozen" },
    .{ .name = "freeze" },
    .{ .name = "fromEntries" },
    .{ .name = "groupBy" },
    .{ .name = "hasOwnProperty" },
    .{ .name = "isPrototypeOf" },
    .{ .name = "propertyIsEnumerable" },
    .{ .name = "__defineGetter__" },
    .{ .name = "__defineSetter__" },
    .{ .name = "__lookupGetter__" },
    .{ .name = "__lookupSetter__" },
    .{ .name = "bind" },
    .{ .name = "isArray" },
    .{ .name = "map" },
    .{ .name = "filter" },
    .{ .name = "reduce" },
    .{ .name = "reduceRight" },
    .{ .name = "forEach" },
    .{ .name = "push" },
    .{ .name = "pop" },
    .{ .name = "shift" },
    .{ .name = "unshift" },
    .{ .name = "some" },
    .{ .name = "every" },
    .{ .name = "find" },
    .{ .name = "findIndex" },
    .{ .name = "findLast" },
    .{ .name = "findLastIndex" },
    .{ .name = "includes" },
    .{ .name = "indexOf" },
    .{ .name = "lastIndexOf" },
    .{ .name = "at" },
    .{ .name = "copyWithin" },
    .{ .name = "fill" },
    .{ .name = "slice" },
    .{ .name = "splice" },
    .{ .name = "reverse" },
    .{ .name = "sort" },
    .{ .name = "flat" },
    .{ .name = "flatMap" },
    .{ .name = "toReversed" },
    .{ .name = "toSorted" },
    .{ .name = "toSpliced" },
    .{ .name = "fromCharCode" },
    .{ .name = "fromCodePoint" },
    .{ .name = "charAt" },
    .{ .name = "charCodeAt" },
    .{ .name = "codePointAt" },
    .{ .name = "substring" },
    .{ .name = "toUpperCase" },
    .{ .name = "toLowerCase" },
    .{ .name = "toLocaleUpperCase" },
    .{ .name = "toLocaleLowerCase" },
    .{ .name = "startsWith" },
    .{ .name = "endsWith" },
    .{ .name = "localeCompare" },
    .{ .name = "repeat" },
    .{ .name = "padStart" },
    .{ .name = "padEnd" },
    .{ .name = "normalize" },
    .{ .name = "isWellFormed" },
    .{ .name = "toWellFormed" },
    .{ .name = "trim" },
    .{ .name = "trimStart" },
    .{ .name = "trimEnd" },
    .{ .name = "anchor" },
    .{ .name = "big" },
    .{ .name = "blink" },
    .{ .name = "bold" },
    .{ .name = "fixed" },
    .{ .name = "fontcolor" },
    .{ .name = "fontsize" },
    .{ .name = "italics" },
    .{ .name = "link" },
    .{ .name = "small" },
    .{ .name = "strike" },
    .{ .name = "substr" },
    .{ .name = "replace" },
    .{ .name = "replaceAll" },
    .{ .name = "sup" },
    .{ .name = "isInteger" },
    .{ .name = "isSafeInteger" },
    .{ .name = "toFixed" },
    .{ .name = "toExponential" },
    .{ .name = "toPrecision" },
    .{ .name = "asIntN" },
    .{ .name = "asUintN" },
    .{ .name = "revocable" },
    .{ .name = "getTime" },
    .{ .name = "getTimezoneOffset" },
    .{ .name = "setTime" },
    .{ .name = "toISOString" },
    .{ .name = "Reflect" },
    .{ .name = "Atomics" },
    .{ .name = "performance" },
    .{ .name = "print" },
    .{ .name = "console" },
    .{ .name = "now" },
    .{ .name = "timeOrigin" },
    .{ .name = "decodeURI" },
    .{ .name = "decodeURIComponent" },
    .{ .name = "encodeURI" },
    .{ .name = "encodeURIComponent" },
    .{ .name = "escape" },
    .{ .name = "unescape" },
    .{ .name = "isNaN" },
    .{ .name = "isFinite" },
    .{ .name = "parseInt" },
    .{ .name = "parseFloat" },
    .{ .name = "btoa" },
    .{ .name = "atob" },
    .{ .name = "queueMicrotask" },
    .{ .name = "gc" },
    .{ .name = "navigator" },
    .{ .name = "NaN" },
    .{ .name = "POSITIVE_INFINITY" },
    .{ .name = "NEGATIVE_INFINITY" },
    .{ .name = "MAX_VALUE" },
    .{ .name = "MIN_VALUE" },
    .{ .name = "MAX_SAFE_INTEGER" },
    .{ .name = "MIN_SAFE_INTEGER" },
    .{ .name = "EPSILON" },
    .{ .name = "description" },
    .{ .name = "sub" },
    .{ .name = "match" },
    .{ .name = "matchAll" },
    .{ .name = "search" },
    .{ .name = "UTC" },
    .{ .name = "parse" },
    .{ .name = "getFullYear" },
    .{ .name = "getMonth" },
    .{ .name = "getDate" },
    .{ .name = "getDay" },
    .{ .name = "getHours" },
    .{ .name = "getMinutes" },
    .{ .name = "and" },
    .{ .name = "compareExchange" },
    .{ .name = "exchange" },
    .{ .name = "isLockFree" },
    .{ .name = "load" },
    .{ .name = "notify" },
    .{ .name = "or" },
    .{ .name = "pause" },
    .{ .name = "store" },
    .{ .name = "wait" },
    .{ .name = "waitAsync" },
    .{ .name = "xor" },
    .{ .name = "ABORT_ERR" },
    .{ .name = "AggregateError" },
    .{ .name = "DATA_CLONE_ERR" },
    .{ .name = "DOMSTRING_SIZE_ERR" },
    .{ .name = "HIERARCHY_REQUEST_ERR" },
    .{ .name = "INDEX_SIZE_ERR" },
    .{ .name = "INUSE_ATTRIBUTE_ERR" },
    .{ .name = "INVALID_ACCESS_ERR" },
    .{ .name = "INVALID_CHARACTER_ERR" },
    .{ .name = "INVALID_MODIFICATION_ERR" },
    .{ .name = "INVALID_NODE_TYPE_ERR" },
    .{ .name = "INVALID_STATE_ERR" },
    .{ .name = "NAMESPACE_ERR" },
    .{ .name = "NETWORK_ERR" },
    .{ .name = "NOT_FOUND_ERR" },
    .{ .name = "NOT_SUPPORTED_ERR" },
    .{ .name = "NO_DATA_ALLOWED_ERR" },
    .{ .name = "NO_MODIFICATION_ALLOWED_ERR" },
    .{ .name = "QUOTA_EXCEEDED_ERR" },
    .{ .name = "SECURITY_ERR" },
    .{ .name = "SYNTAX_ERR" },
    .{ .name = "TIMEOUT_ERR" },
    .{ .name = "TYPE_MISMATCH_ERR" },
    .{ .name = "TypedArray" },
    .{ .name = "URL_MISMATCH_ERR" },
    .{ .name = "VALIDATION_ERR" },
    .{ .name = "WRONG_DOCUMENT_ERR" },
    .{ .name = "[Symbol.matchAll]" },
    .{ .name = "[Symbol.match]" },
    .{ .name = "[Symbol.replace]" },
    .{ .name = "[Symbol.search]" },
    .{ .name = "[Symbol.split]" },
    .{ .name = "abs" },
    .{ .name = "acos" },
    .{ .name = "acosh" },
    .{ .name = "all" },
    .{ .name = "allSettled" },
    .{ .name = "any" },
    .{ .name = "asin" },
    .{ .name = "asinh" },
    .{ .name = "atan" },
    .{ .name = "atan2" },
    .{ .name = "atanh" },
    .{ .name = "call" },
    .{ .name = "captureStackTrace" },
    .{ .name = "cbrt" },
    .{ .name = "ceil" },
    .{ .name = "clear" },
    .{ .name = "clz32" },
    .{ .name = "compile" },
    .{ .name = "cos" },
    .{ .name = "cosh" },
    .{ .name = "deref" },
    .{ .name = "difference" },
    .{ .name = "drop" },
    .{ .name = "entries" },
    .{ .name = "exp" },
    .{ .name = "expm1" },
    .{ .name = "f16round" },
    .{ .name = "floor" },
    .{ .name = "fromBase64" },
    .{ .name = "fromHex" },
    .{ .name = "fround" },
    .{ .name = "getBigInt64" },
    .{ .name = "getBigUint64" },
    .{ .name = "getFloat16" },
    .{ .name = "getFloat32" },
    .{ .name = "getFloat64" },
    .{ .name = "getInt16" },
    .{ .name = "getInt32" },
    .{ .name = "getInt8" },
    .{ .name = "getMilliseconds" },
    .{ .name = "getOrInsert" },
    .{ .name = "getOrInsertComputed" },
    .{ .name = "getSeconds" },
    .{ .name = "getUTCDate" },
    .{ .name = "getUTCDay" },
    .{ .name = "getUTCFullYear" },
    .{ .name = "getUTCHours" },
    .{ .name = "getUTCMilliseconds" },
    .{ .name = "getUTCMinutes" },
    .{ .name = "getUTCMonth" },
    .{ .name = "getUTCSeconds" },
    .{ .name = "getUint16" },
    .{ .name = "getUint32" },
    .{ .name = "getUint8" },
    .{ .name = "getYear" },
    .{ .name = "grow" },
    .{ .name = "hypot" },
    .{ .name = "imul" },
    .{ .name = "intersection" },
    .{ .name = "is" },
    .{ .name = "isDisjointFrom" },
    .{ .name = "isError" },
    .{ .name = "isRawJSON" },
    .{ .name = "isSubsetOf" },
    .{ .name = "isSupersetOf" },
    .{ .name = "isView" },
    .{ .name = "keyFor" },
    .{ .name = "log" },
    .{ .name = "log10" },
    .{ .name = "log1p" },
    .{ .name = "log2" },
    .{ .name = "max" },
    .{ .name = "min" },
    .{ .name = "pow" },
    .{ .name = "race" },
    .{ .name = "random" },
    .{ .name = "register" },
    .{ .name = "resize" },
    .{ .name = "round" },
    .{ .name = "setBigInt64" },
    .{ .name = "setBigUint64" },
    .{ .name = "setDate" },
    .{ .name = "setFloat16" },
    .{ .name = "setFloat32" },
    .{ .name = "setFloat64" },
    .{ .name = "setFromBase64" },
    .{ .name = "setFromHex" },
    .{ .name = "setFullYear" },
    .{ .name = "setHours" },
    .{ .name = "setInt16" },
    .{ .name = "setInt32" },
    .{ .name = "setInt8" },
    .{ .name = "setMilliseconds" },
    .{ .name = "setMinutes" },
    .{ .name = "setMonth" },
    .{ .name = "setSeconds" },
    .{ .name = "setUTCDate" },
    .{ .name = "setUTCFullYear" },
    .{ .name = "setUTCHours" },
    .{ .name = "setUTCMilliseconds" },
    .{ .name = "setUTCMinutes" },
    .{ .name = "setUTCMonth" },
    .{ .name = "setUTCSeconds" },
    .{ .name = "setUint16" },
    .{ .name = "setUint32" },
    .{ .name = "setUint8" },
    .{ .name = "setYear" },
    .{ .name = "sign" },
    .{ .name = "sin" },
    .{ .name = "sinh" },
    .{ .name = "sliceToImmutable" },
    .{ .name = "sqrt" },
    .{ .name = "stringify" },
    .{ .name = "subarray" },
    .{ .name = "sumPrecise" },
    .{ .name = "symmetricDifference" },
    .{ .name = "take" },
    .{ .name = "tan" },
    .{ .name = "tanh" },
    .{ .name = "test" },
    .{ .name = "toArray" },
    .{ .name = "toBase64" },
    .{ .name = "toDateString" },
    .{ .name = "toHex" },
    .{ .name = "toLocaleDateString" },
    .{ .name = "toLocaleTimeString" },
    .{ .name = "toTimeString" },
    .{ .name = "toUTCString" },
    .{ .name = "transfer" },
    .{ .name = "transferToFixedLength" },
    .{ .name = "transferToImmutable" },
    .{ .name = "trunc" },
    .{ .name = "union" },
    .{ .name = "unregister" },
    .{ .name = "withResolvers" },
    .{ .name = "__zjs_native_name" },
    .{ .name = "__zjs_dstr_get" },
    .{ .name = "__zjs_dstr_elide" },
    .{ .name = "__zjs_dstr_rest" },
    .{ .name = "__zjs_dstr_obj_rest" },
    .{ .name = "__zjs_dstr_close" },
    .{ .name = "__zjs_dstr_require_iterator" },
    .{ .name = "trimLeft" },
    .{ .name = "trimRight" },
    .{ .name = "__primitive" },
    .{ .name = "toPrimitive" },
    .{ .name = "species" },
    .{ .name = "iterator" },
    .{ .name = "toStringTag" },
    .{ .name = "isConcatSpreadable" },
    .{ .name = "hasInstance" },
    .{ .name = "unscopables" },
    .{ .name = "asyncIterator" },
    .{ .name = "asyncDispose" },
    .{ .name = "dispose" },
    .{ .name = "toGMTString" },
    .{ .name = "ignoreCase" },
    .{ .name = "multiline" },
    .{ .name = "dotAll" },
    .{ .name = "sticky" },
    .{ .name = "hasIndices" },
    .{ .name = "unicodeSets" },
    .{ .name = "stackTraceLimit" },
    .{ .name = "__zjs_collection_method_owner" },
    .{ .name = "byteLength" },
    .{ .name = "detached" },
    .{ .name = "resizable" },
    .{ .name = "growable" },
    .{ .name = "BYTES_PER_ELEMENT" },
    .{ .name = "buffer" },
    .{ .name = "byteOffset" },
    .{ .name = "Infinity" },
    .{ .name = "__zjs_throw_type_error_function_proto" },
    .{ .name = "__zjs_throw_type_error_intrinsic" },
    .{ .name = "scriptArgs" },
    .{ .name = "$_" },
    .{ .name = "lastMatch" },
    .{ .name = "$&" },
    .{ .name = "lastParen" },
    .{ .name = "$+" },
    .{ .name = "leftContext" },
    .{ .name = "$`" },
    .{ .name = "rightContext" },
    .{ .name = "$'" },
    .{ .name = "$1" },
    .{ .name = "$2" },
    .{ .name = "$3" },
    .{ .name = "$4" },
    .{ .name = "$5" },
    .{ .name = "$6" },
    .{ .name = "$7" },
    .{ .name = "$8" },
    .{ .name = "$9" },
    .{ .name = "SuppressedError" },
    .{ .name = "DisposableStack" },
    .{ .name = "use" },
    .{ .name = "adopt" },
    .{ .name = "defer" },
    .{ .name = "move" },
    .{ .name = "disposed" },
    .{ .name = "AsyncDisposableStack" },
    .{ .name = "disposeAsync" },
    .{ .name = "allKeyed" },
    .{ .name = "allSettledKeyed" },
    .{ .name = "immutable" },
    // S3 predefined property keys (append-only).
    .{ .name = "alphabet" },
    .{ .name = "lastChunkHandling" },
    .{ .name = "omitPadding" },
    .{ .name = "padding" },
    .{ .name = "mode" },
    .{ .name = "prepareStackTrace" },
    .{ .name = "type" },
    .{ .name = "userAgent" },
    .{ .name = "E" },
    .{ .name = "LN10" },
    .{ .name = "LN2" },
    .{ .name = "LOG2E" },
    .{ .name = "LOG10E" },
    .{ .name = "PI" },
    .{ .name = "SQRT1_2" },
    .{ .name = "SQRT2" },
    .{ .name = "k" },
    .{ .name = "mapfn" },
    .{ .name = "this_arg" },
    .{ .name = "iter" },
    .{ .name = "items" },
    .{ .name = "len" },
    .{ .name = "phase" },
    .{ .name = "state" },
    .{ .name = "pending" },
    .{ .name = "rejected" },
    .{ .name = "fileName" },
    .{ .name = "lineNumber" },
    .{ .name = "columnNumber" },
    .{ .name = "code" },
    .{ .name = "error" },
    .{ .name = "suppressed" },
    .{ .name = "url" },
    .{ .name = "main" },
    .{ .name = "read" },
    .{ .name = "written" },
};

pub const predefined_atoms = blk: {
    @setEvalBranchQuota(100000);
    var out: [predefined_spec.len]PredefinedAtom = undefined;
    for (predefined_spec, 0..) |item, i| {
        out[i] = .{
            .id = Atom.fromRaw(@intCast(i + 1)),
            .name = item.name,
            .kind = item.kind,
        };
    }
    break :blk out;
};

/// Call-site spellings that differ from the spec name: Zig keywords,
/// typeof-result aliases, pseudo-bindings, and well-known symbols.
/// `caller` / `arguments` keep their table names; the comptime asserts
/// below pin the spellings.
const PredefinedIdAlias = struct {
    field: []const u8,
    name: []const u8,
    kind: AtomKind = .string,
};

const predefined_id_aliases = [_]PredefinedIdAlias{
    .{ .field = "null_", .name = "null" },
    .{ .field = "false_", .name = "false" },
    .{ .field = "true_", .name = "true" },
    .{ .field = "if_", .name = "if" },
    .{ .field = "this_", .name = "this" },
    .{ .field = "eval_", .name = "eval" },
    .{ .field = "undefined_", .name = "undefined" },
    // typeof result strings: interned atoms, not a fresh alloc per `OP_typeof`.
    .{ .field = "type_function", .name = "function" },
    .{ .field = "type_number", .name = "number" },
    .{ .field = "type_boolean", .name = "boolean" },
    .{ .field = "type_string", .name = "string" },
    .{ .field = "type_object", .name = "object" },
    .{ .field = "type_symbol", .name = "symbol" },
    .{ .field = "type_bigint", .name = "bigint" },
    .{ .field = "ret", .name = "<ret>" },
    .{ .field = "var_object", .name = "<var>" },
    .{ .field = "arg_var_object", .name = "<arg_var>" },
    .{ .field = "with_object", .name = "<with>" },
    .{ .field = "new_target", .name = "new.target" },
    .{ .field = "this_active_func", .name = "this.active_func" },
    .{ .field = "home_object", .name = "<home_object>" },
    .{ .field = "class_fields_init", .name = "<class_fields_init>" },
    .{ .field = "async_", .name = "async" },
    .{ .field = "Private_brand", .name = "<brand>", .kind = .private },
    .{ .field = "Symbol_iterator", .name = "Symbol.iterator", .kind = .symbol },
    .{ .field = "Symbol_asyncIterator", .name = "Symbol.asyncIterator", .kind = .symbol },
    .{ .field = "Symbol_asyncDispose", .name = "Symbol.asyncDispose", .kind = .symbol },
    .{ .field = "Symbol_dispose", .name = "Symbol.dispose", .kind = .symbol },
    .{ .field = "zjs_proto_keepalive", .name = "__zjs_proto_keepalive" },
    .{ .field = "return_", .name = "return" },
    .{ .field = "type_", .name = "type" },
    .{ .field = "error_", .name = "error" },
};

fn predefinedSpecId(comptime name: []const u8, comptime kind: AtomKind) Atom {
    @setEvalBranchQuota(10000);
    for (predefined_spec, 0..) |item, i| {
        if (item.kind == kind and std.mem.eql(u8, item.name, name)) {
            return Atom.fromRaw(@intCast(i + 1));
        }
    }
    @compileError("predefined atom not in spec: " ++ name);
}

fn predefinedFieldName(comptime index: usize) []const u8 {
    const item = predefined_spec[index];
    if (item.name.len == 0) return "empty_string";
    // The only duplicate spelling: string `<brand>` (computed field) vs private.
    if (std.mem.eql(u8, item.name, "<brand>")) {
        return "<brand>__" ++ @tagName(item.kind);
    }
    return item.name;
}

const PredefinedIds = blk: {
    @setEvalBranchQuota(200000);
    const n = predefined_spec.len + predefined_id_aliases.len;
    var field_names: [n][]const u8 = undefined;
    var field_types: [n]type = @splat(Atom);
    var field_attrs: [n]std.builtin.Type.StructField.Attributes = undefined;
    for (predefined_spec, 0..) |_, i| {
        field_names[i] = predefinedFieldName(i);
        field_attrs[i] = .{
            .@"comptime" = true,
            .default_value_ptr = &predefined_atoms[i].id,
        };
    }
    for (predefined_id_aliases, 0..) |alias, j| {
        const i = predefined_spec.len + j;
        field_names[i] = alias.field;
        const id = predefinedSpecId(alias.name, alias.kind);
        field_attrs[i] = .{
            .@"comptime" = true,
            .default_value_ptr = &predefined_atoms[id.raw() - 1].id,
        };
    }
    break :blk @Struct(.auto, null, &field_names, &field_types, &field_attrs);
};

/// Predefined atom ids generated from `predefined_spec` (1-based index).
/// Historical spellings (`if_`, `type_function`, …) are aliases so
/// existing call sites keep compiling.
pub const ids: PredefinedIds = .{};

pub const last_keyword = ids.await;
pub const last_strict_keyword = ids.yield;
pub const predefined_count = predefined_atoms.len;
pub const first_dynamic_atom = predefined_count + 1;

comptime {
    std.debug.assert(@sizeOf(Atom) == 4);
    std.debug.assert(@bitSizeOf(Atom) == 32);
    std.debug.assert(@sizeOf(PredefinedIds) == 0);
    std.debug.assert(null_atom == .empty);
    std.debug.assert(null_atom.raw() == 0);
    std.debug.assert(tagged_int_bit == @as(u32, 1) << 31);
    std.debug.assert(max_int_atom == tagged_int_bit - 1);
    std.debug.assert(predefined_count == 692);
    std.debug.assert(ids.null_.raw() == 1);
    std.debug.assert(ids.await.raw() == 46);
    std.debug.assert(ids.yield.raw() == 45);
    // Legacy-function gates compare `caller`/`arguments` by id, the way qjs
    // compares against JS_ATOM_caller. Pin both to the table so a renumbering
    // fails the build instead of silently turning those gates into no-ops.
    std.debug.assert(std.mem.eql(u8, predefined_atoms[ids.caller.raw() - 1].name, "caller"));
    std.debug.assert(std.mem.eql(u8, predefined_atoms[ids.arguments.raw() - 1].name, "arguments"));
    std.debug.assert(first_dynamic_atom == predefined_count + 1);
}

const PredefinedMapEntry = struct { []const u8, Atom };

fn predefinedKindCount(comptime kind: AtomKind) comptime_int {
    var count: comptime_int = 0;
    for (predefined_atoms) |entry| {
        if (entry.kind == kind) count += 1;
    }
    return count;
}

fn makePredefinedMapEntries(comptime kind: AtomKind) [predefinedKindCount(kind)]PredefinedMapEntry {
    var entries: [predefinedKindCount(kind)]PredefinedMapEntry = undefined;
    var index: usize = 0;
    for (predefined_atoms) |entry| {
        if (entry.kind == kind) {
            entries[index] = .{ entry.name, entry.id };
            index += 1;
        }
    }
    return entries;
}

const predefined_symbol_map = blk: {
    @setEvalBranchQuota(10000);
    break :blk std.StaticStringMap(Atom).initComptime(makePredefinedMapEntries(.symbol));
};
const predefined_private_map = blk: {
    @setEvalBranchQuota(10000);
    break :blk std.StaticStringMap(Atom).initComptime(makePredefinedMapEntries(.private));
};

// QuickJS puts its predefined and dynamically-created atoms behind the same
// hash lookup. Keep the immutable predefined half in static storage, but use
// the same hash as `string_index`: a miss must not linearly compare every
// predefined spelling of the same length before probing the dynamic table.
const predefined_string_hash_capacity = 2048;
comptime {
    std.debug.assert(predefinedKindCount(.string) * 2 <= predefined_string_hash_capacity);
}
const predefined_string_hash_mask = predefined_string_hash_capacity - 1;
const predefined_string_hash_table = blk: {
    @setEvalBranchQuota(100000);
    var slots = [_]Atom{null_atom} ** predefined_string_hash_capacity;
    for (predefined_atoms) |entry| {
        if (entry.kind != .string) continue;
        std.debug.assert(parseArrayIndex(entry.name) == null);
        const hash = std.hash.Wyhash.hash(0, entry.name);
        var index: usize = @intCast(hash & predefined_string_hash_mask);
        while (slots[index] != null_atom) {
            index = (index + 1) & predefined_string_hash_mask;
        }
        slots[index] = entry.id;
    }
    break :blk slots;
};

inline fn predefinedStringIdHashed(bytes: []const u8, hash: u64) ?Atom {
    var index: usize = @intCast(hash & predefined_string_hash_mask);
    var remaining: usize = predefined_string_hash_capacity;
    while (remaining != 0) : (remaining -= 1) {
        const id = predefined_string_hash_table[index];
        if (id == null_atom) return null;
        if (std.mem.eql(u8, predefined_atoms[id.raw() - 1].name, bytes)) return id;
        index = (index + 1) & predefined_string_hash_mask;
    }
    unreachable;
}

/// Spelling of a predefined atom. The bytes live in comptime storage, so the
/// slice needs no allocation, outlives every runtime, and cannot be invalidated
/// by a collection -- the property of `ids.*` constants that lets a helper take
/// the atom and still recover the name qjs would have passed around as a
/// `const char *`.
pub fn predefinedName(id: Atom) []const u8 {
    std.debug.assert(id != null_atom and id.isConst());
    return predefined_atoms[id.raw() - 1].name;
}

pub fn predefinedById(id: Atom) ?PredefinedAtom {
    if (id == null_atom or !id.isConst()) return null;
    return predefined_atoms[id.raw() - 1];
}

pub fn predefinedId(bytes: []const u8, kind: AtomKind) ?Atom {
    @setEvalBranchQuota(100000);
    return switch (kind) {
        .string => predefinedStringIdHashed(bytes, std.hash.Wyhash.hash(0, bytes)),
        .symbol => predefined_symbol_map.get(bytes),
        .global_symbol => null,
        .private => predefined_private_map.get(bytes),
    };
}
