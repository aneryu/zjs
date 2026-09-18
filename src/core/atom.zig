//! Runtime-owned atom interning, predefined ids, and symbol identity.
//!
//! Atom ids are table handles: interning returns an owned reference unless an
//! API explicitly says borrowed, and every owned dynamic id must be released
//! through its originating Runtime's `AtomTable`. Value-symbol atoms also root
//! their refcounted name storage. Predefined ids are process-stable and need no
//! release. QuickJS source map: the shared JSString/JSAtom representation at
//! quickjs.c:583-599 and atom-table operations nearby. This core module may be
//! consumed by higher layers but never imports exec or binding.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const gc = @import("gc.zig");
const memory = @import("memory.zig");
const string = @import("string.zig");
const JSRuntime = @import("runtime.zig").JSRuntime;
const JSValue = @import("value.zig").JSValue;

/// `-Dzjs_ownership_audit`. Audit tier (ASAN / leak-checker class): CI,
/// fuzzing and regression builds only, never ReleaseFast or the production
/// path. See `AtomTable.OwnershipAuditState` for what it turns on.
pub const ownership_audit_enabled: bool = build_options.zjs_ownership_audit;

/// 4-byte table handle. Bytecode operands, shape keys, and host pins store
/// this tag; it is not a pointer. Non-exhaustive so dynamic ids and tagged
/// ints stay in the same word as predefined constants.
pub const Atom = enum(u32) {
    empty = 0,
    _,

    pub inline fn raw(self: Atom) u32 {
        return @intFromEnum(self);
    }

    pub inline fn fromRaw(n: u32) Atom {
        return @enumFromInt(n);
    }

    pub inline fn isEmpty(self: Atom) bool {
        return self == .empty;
    }

    pub inline fn isConst(self: Atom) bool {
        return self.raw() < first_dynamic_atom;
    }

    pub inline fn isTaggedInt(self: Atom) bool {
        return (self.raw() & tagged_int_bit) != 0;
    }

    pub fn taggedInt(n: u32) Atom {
        std.debug.assert(n <= max_int_atom);
        return fromRaw(n | tagged_int_bit);
    }

    pub fn toUInt32(self: Atom) u32 {
        std.debug.assert(self.isTaggedInt());
        return self.raw() & ~tagged_int_bit;
    }
};

pub const null_atom: Atom = .empty;
pub const tagged_int_bit: u32 = 1 << 31;
pub const max_int_atom: u32 = tagged_int_bit - 1;

pub const AtomKind = enum {
    string,
    symbol,
    global_symbol,
    private,
};

pub fn isPublicSymbolKind(kind: AtomKind) bool {
    return kind == .symbol or kind == .global_symbol;
}

pub fn isValueSymbolKind(kind: AtomKind) bool {
    return kind == .symbol or kind == .global_symbol or kind == .private;
}

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
    // Host-internal markers; `zjs_last_internal_marker` aliases the last one.
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
/// typeof-result aliases, pseudo-bindings, well-known symbols, and the
/// `zjs_last_*` group markers. `caller` / `arguments` keep their table
/// names; the comptime asserts below pin the spellings.
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
    .{ .field = "zjs_last_internal_marker", .name = "__zjs_typedarray_static" },
    .{ .field = "zjs_last_registry_name", .name = "toISOString" },
    .{ .field = "zjs_last_global_setup_name", .name = "parseFloat" },
    .{ .field = "zjs_last_global_extra_name", .name = "xor" },
    .{ .field = "zjs_last_registry_extra_name", .name = "withResolvers" },
    .{ .field = "zjs_last_startup_name", .name = "immutable" },
    .{ .field = "return_", .name = "return" },
    .{ .field = "type_", .name = "type" },
    .{ .field = "error_", .name = "error" },
    .{ .field = "zjs_last_predefined_key_name", .name = "written" },
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
/// Historical spellings (`if_`, `type_function`, `zjs_last_*`, …) are
/// aliases so existing call sites keep compiling.
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
    std.debug.assert(ids.zjs_last_startup_name.raw() == 656);
    std.debug.assert(ids.zjs_last_predefined_key_name.raw() == predefined_count);
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
// 676 string atoms in 2048 buckets leave the table at 33.0% load.
const predefined_string_hash_capacity = 2048;
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

pub const DynamicAtom = struct {
    id: Atom,
    bytes: []u8,
    /// Lazily materialized runtime string for this atom (string kind only).
    /// The table roots it (the tracer reaches it through this slot) and the
    /// string's `atom_id` is a weak back-pointer, so the cached string cannot
    /// die while it sits here; when `sweepDead` retires the entry it clears
    /// the back-pointer and drops this slot.
    str: ?*string.String = null,
    /// Link in the table's free-slot list, only meaningful while the entry
    /// is dead (`occupied == false`). `no_free_slot` terminates the list.
    next_free: EntryIndex = no_free_slot,
    /// qjs `JSString.hash` (set at quickjs.c:3314): the full spelling hash of
    /// this atom, stored so a chain walk rejects a non-match without reading
    /// the bytes and so the unlink never has to re-hash the spelling. Only
    /// meaningful for the chained kinds (`.string` / `.global_symbol`).
    hash: u32 = 0,
    /// qjs `JSString.hash_next` (spliced at quickjs.c:3318): next atom id in
    /// this atom's bucket, `null_atom` at the end of the chain.
    hash_next: Atom = null_atom,
    kind: AtomKind,
    /// TGC S3 §2.1. `ref_count` is gone: an entry is either IN USE (a spelling
    /// is bound to this id) or free-listed. Liveness is decided once per major
    /// by `sweepDead`, never by a store or a drop.
    occupied: bool,
    /// TGC S3 (`docs/tracing-gc-s3-spec.md` §2.1). Last major mark epoch that
    /// reached this entry through a `visitAtom` edge, a root, the insertion
    /// barrier or black allocation; `Heap.mark_epoch` is even and non-zero, so
    /// `0` reads as "never marked".
    mark_epoch: u64 = 0,
    /// Epoch this entry was interned in (`internDynamic`). An atom born inside
    /// an open marking window cannot have been reached by the trace that
    /// started before it existed, so it is live for that cycle by construction.
    born_epoch: u64 = 0,
    /// P-class explicit host pins (`pinForHost` / `unpinForHost`).
    /// The only remaining count in the table, and the only one an embedder can
    /// move (§2.5).
    host_pins: u32 = 0,
    registry_managed_symbol: bool = false,
    weakref_count: usize = 0,
    no_symbol_description: bool = false,

    // TGC S3 §2.1/§2.4. A VALUE SYMBOL's identity is its body: holders that
    // name it by id (shape keys, bytecode operands) report a `visitAtom` edge
    // that shades the body, holders that hold it as a JSValue mark the body
    // directly, and `sweepDead` retires the entry when neither happened. The
    // sweep leaves a weak shell (`occupied == false`, `str == null`,
    // `weakref_count != 0`) when a WeakRef still has to observe the death;
    // `onSymbolBodyDead` is the same verdict reached through the body's own
    // sweep, and `releaseSymbolWeakRef` retires the shell when the last
    // WeakRef goes.
    pub fn isLive(self: DynamicAtom) bool {
        return self.occupied;
    }

    pub fn slotOccupied(self: DynamicAtom) bool {
        return self.occupied or self.weakref_count != 0;
    }
};

const runtime_mod = @import("runtime.zig");

/// Index in `AtomTable.entries`, used as the secondary lookup key for the
/// hash maps below.
const EntryIndex = u32;

/// Sentinel terminating the free-slot list.
const no_free_slot: EntryIndex = std.math.maxInt(EntryIndex);

// ---------------------------------------------------------------------------
// Atom hash: QuickJS's chained table, mirrored.
//
// QuickJS keeps every interned atom in one chained hash. `rt->atom_hash` holds
// the bucket heads (atom indices), each atom stores the full spelling hash in
// `JSString.hash` and the next atom of its bucket in `JSString.hash_next`:
//
//   lookup  quickjs.c:3196-3212 (`__JS_NewAtom`) and 3348-3375 (`__JS_FindAtom`)
//   insert  quickjs.c:3317-3322 (splice at the bucket head, then resize check)
//   unlink  quickjs.c:3387-3409 (`JS_FreeAtomStruct`)
//   resize  quickjs.c:3055-3072 (`JS_ResizeAtomHash`)
//
// Two properties matter and are reproduced exactly:
//   * the *stored full hash* gates the byte comparison, so a chain step that is
//     not the answer never reads the spelling (quickjs.c:3363 `p->hash == h`);
//   * insert and unlink are O(1)/O(chain) pointer splices, never a probe to a
//     free slot, so intern/free churn cannot degrade the table.
//
// QuickJS's atom hash stores atom ids for both predefined and dynamic atoms.
// Use the same value here so the chain can hold predefined atoms and answer the
// steady-state lookup with one bucket load regardless of atom lifetime; the
// predefined half lives in comptime storage (`predefined_atoms`), so its
// mutable chain links live in `AtomTable.predefined_hash_next` instead of in an
// entry record.
// ---------------------------------------------------------------------------

/// qjs seeds the spelling hash with the atom type (quickjs.c:3200
/// `hash_string(str, atom_type)`), so one table can hold the same spelling
/// interned as a string and as a global symbol without them colliding, and the
/// kind check at quickjs.c:3364 stays a cheap confirmation rather than the
/// separator. Unique symbols and private names are never chained (qjs keeps
/// `JS_ATOM_TYPE_SYMBOL` out of `atom_hash`, quickjs.c:3316).
fn atomHashSeed(kind: AtomKind) u64 {
    return switch (kind) {
        .string => 0,
        .global_symbol => 1,
        .symbol, .private => 2,
    };
}

/// The spelling hash stored in the atom. qjs keeps 30 bits (`JS_ATOM_HASH_MASK`,
/// quickjs.c:580) because it packs `hash` into a bitfield next to `atom_type`;
/// zjs has a whole word, so it keeps all 32.
fn spellingHash(bytes: []const u8, kind: AtomKind) u32 {
    // qjs `hash_string8` (quickjs.c:2941): `h = h * 263 + c`, seeded with the
    // atom type and `static inline`, so the lookup never pays a call to hash
    // its own key.
    var h: u32 = @intCast(atomHashSeed(kind));
    for (bytes) |c| h = h *% 263 +% c;
    return h;
}

/// Stored hash of every predefined atom, indexed by `id - 1`. This is the
/// comptime half of `JSString.hash`.
const predefined_hash = blk: {
    @setEvalBranchQuota(200000);
    var out: [predefined_count]u32 = undefined;
    for (predefined_atoms, 0..) |entry, i| out[i] = spellingHash(entry.name, entry.kind);
    break :blk out;
};

/// qjs sizes the bucket array once for the predefined set — `JS_ResizeAtomHash(rt, 512)`
/// with the comment "there are at least 504 predefined atoms" (quickjs.c:3089) —
/// and doubles it whenever the atom count reaches `JS_ATOM_COUNT_RESIZE`
/// (quickjs.c:2875, `2 * size`). zjs has 640 predefined string atoms, so the
/// same rule ("next power of two that holds the predefined set") gives 1024.
const atom_hash_initial_size: u32 = 1024;

pub const AtomTable = struct {
    /// Extra table state carried only by `-Dzjs_ownership_audit` builds.
    ///
    /// The audit's one and only job is to break the *slot-reuse coincidence*
    /// that masks borrowed-atom use-after-free. `finalizeDeadEntry` pushes a
    /// dead slot on a LIFO free list keeping its id, and `internDynamic` pops
    /// that head first, so "free an atom, immediately re-intern the identical
    /// string" hands the same id straight back and a stale borrow looks alive.
    /// Quarantining every slot retired since the previous release point means
    /// no intern can reclaim a slot that died in the current round: a stale id
    /// then names either an empty slot (`name` reports it dead) or, a round
    /// later, a different string (the wrong-value outcome, which the caller's
    /// own checks surface).
    ///
    /// **The round is a sweep, not a single death** (TGC S3). Before the
    /// tracer owned atom liveness, entries died one at a time under
    /// `AtomTable.free`, and holding back exactly one slot was enough: the
    /// slot that just died was by definition the whole of the last round.
    /// `sweepDead` now retires a whole batch inside one pause, so a one-slot
    /// quarantine would hand back every slot of that batch but the last to the
    /// very next intern -- the audit would keep reporting green while masking
    /// n-1 of every n stale borrows. The quarantine is therefore a second free
    /// list, threaded through the same `next_free` link, that `sweepDead`
    /// splices onto the real free list on its way in.
    ///
    /// Delaying reuse by one round rather than "stop recycling entirely" is
    /// deliberate. Recycling still happens, so the table's steady-state size
    /// grows by at most one round's worth of dead slots instead of growing
    /// monotonically with intern/free churn; `next_id` growth and the `deinit`
    /// teardown invariants stay the ones the default build has, and the audit
    /// cannot itself turn a churn-heavy test into an out-of-memory or a
    /// different-table-geometry failure.
    ///
    /// When the option is off this is an empty struct: the field, the
    /// quarantine code and even the names are absent from the binary.
    pub const OwnershipAuditState = if (ownership_audit_enabled) struct {
        /// LIFO head of the slots retired since the last
        /// `releaseQuarantinedSlots`, held back from the free list. Linked
        /// through `DynamicAtom.next_free`; `no_free_slot` when empty.
        quarantined_head: EntryIndex = no_free_slot,
    } else struct {};

    memory: *memory.MemoryAccount,
    /// Owning runtime, set right after init. Needed to release cached
    /// strings (`DynamicAtom.str`) when an atom dies. Tables created
    /// without a runtime (parser-only tests) never cache strings.
    runtime: ?*JSRuntime = null,
    entries: []DynamicAtom = &.{},
    /// Geometric-growth capacity for `entries`. The visible slice length
    /// is the live count; the backing buffer extends to `entries_capacity`.
    entries_capacity: usize = 0,
    next_id: Atom = Atom.fromRaw(first_dynamic_atom),
    /// qjs `JSRuntime.atom_hash` (quickjs.c:3067): bucket heads of the chained
    /// atom hash, a power-of-two array shared by string and global-symbol
    /// atoms. `null_atom` terminates a bucket. Empty until the first intern;
    /// `AtomTable.init` stays infallible for the allocation-free callers.
    atom_hash: []Atom = &.{},
    /// qjs `JSRuntime.atom_count` (quickjs.c:3322), restricted to the atoms
    /// that are actually chained — qjs also counts its unchained unique
    /// symbols, but only the chained population drives the resize rule.
    atom_hash_count: u32 = 0,
    /// qjs `JSRuntime.atom_count_resize` (quickjs.c:3073) = 2 * bucket count.
    atom_count_resize: u32 = 0,
    /// Chain links for the predefined atoms. QuickJS keeps predefined atoms in
    /// `atom_array` next to the dynamic ones and threads them through the same
    /// `hash_next` field; zjs holds the predefined half in comptime storage, so
    /// only their mutable link lives here. Indexed by `id - 1`.
    predefined_hash_next: [predefined_count]Atom = @splat(null_atom),
    /// Head of the dead-slot free list threaded through
    /// `DynamicAtom.next_free`. Slots (and therefore ids) are recycled
    /// only after their ref count reached zero, so no live holder can be
    /// retargeted. Predefined atom ids live below `first_dynamic_atom`
    /// and never enter `entries`, so they are never recycled.
    free_slot_head: EntryIndex = no_free_slot,
    /// Zero-sized in default builds; see `OwnershipAuditState`.
    ownership_audit: OwnershipAuditState = .{},
    /// Conservative lower bound for dynamic private atoms. Dynamic slots are
    /// recycled across atom kinds, so this is intentionally a "might be
    /// private" range for hot-path rejection, not an exact kind predicate.
    first_private_dynamic_atom: Atom = Atom.fromRaw(std.math.maxInt(u32)),
    /// Lazily materialized strings for predefined string-kind atoms and
    /// predefined symbol bodies, indexed by `id - 1`. Predefined ids are never
    /// recycled, so entries here are released only by `releaseCachedStrings`.
    predefined_str: [predefined_count]?*string.String = @splat(null),
    /// TGC S3: back-pointer to the owning runtime, installed by `JSRuntime`
    /// after its address is stable. Null for the standalone tables the
    /// compiler/parser fixtures build, which have no collector at all; every
    /// S3 seam degrades to a no-op in that case.
    owner_runtime: ?*runtime_mod.JSRuntime = null,
    /// TGC S3 §2.2: innermost active `CompileAtomScope`. Non-null only while a
    /// compile is in flight; every intern/dup entry point notes into it so the
    /// front end's plain-`u32` atom fields have an interval root.
    compile_scope: ?*CompileAtomScope = null,
    /// Audit readings (`--gc-stats`, `docs/tracing-gc-s3-spec.md` §2.6). With
    /// the tracer owning liveness the question the audit asks is the inverse
    /// of the pre-flip one: no holder edge may still name an entry the sweep
    /// already retired.
    ///
    /// `stale_edge` is that reading and must be 0 -- a non-zero one is a
    /// holder that survived the collection naming a recycled slot, which is
    /// the borrowed-atom failure mode of `docs/borrowed_atom_audit.md` §1.1.
    /// `shell_edge` is the informational mirror: an edge reaching a weak
    /// shell, which is legal (the shell exists precisely so a WeakRef can
    /// observe the death) but should be rare.
    atom_audit_stale_edge: usize = 0,
    atom_audit_shell_edge: usize = 0,
    /// TGC S3-c x S2-g: value-symbol atoms whose body was minted since the
    /// last generational promotion point. A MINOR-ONLY root set.
    ///
    /// §2.2 makes a symbol atom's body live through its HOLDERS' `visitAtom`
    /// edges, and that rule is complete for a MAJOR only. A minor walks the
    /// roots plus the remembered set, so an OLD shape's property keys are
    /// never visited; and even when the holder IS traced, `markAtomAtEpoch`
    /// short-circuits on `entry.mark_epoch == epoch` -- the epoch only moves
    /// at `beginMajor`, so the second and later minors of a major epoch (and
    /// every minor before the first major, where both sides read 0) reach the
    /// entry and shade nothing. No barrier covers the gap either: the
    /// generational barrier prices JSValue stores, and a shape's property key
    /// is a plain `u32`. The minor then sweeps the young body, the destroy
    /// handshake runs `onSymbolBodyDead`, and the entry is retired (or
    /// degraded to a weak shell) while a live holder still names it --
    /// `Object.getOwnPropertySymbols` comes back short.
    ///
    /// The rule that closes it is the one the young string extents already
    /// use: a young body is an unconditional root for the MINOR until it is
    /// promoted. `collectMinor` seeds this list; the minor's promotion block
    /// (and `clearYoungState` on the major path) empties it, after which the
    /// body is old, no minor can reach it, and §2.2's edge rules alone decide
    /// its fate. Deliberately NOT a major root: a major must still be able to
    /// retire a symbol whose last holder died in the same cycle that created
    /// it. Predefined bodies never enter -- `predefined_str` already roots
    /// them unconditionally.
    ///
    /// ATOM IDS, not `*String`: a major can legally kill a listed body (it is
    /// not a major root), and the id keeps the list from ever holding a
    /// dangling pointer -- a retired or unbound entry simply reports nothing.
    young_symbol_atoms: std.ArrayListUnmanaged(Atom) = .empty,

    /// Only the PREDEFINED bodies are table roots. A dynamic entry's cached
    /// `str` is not: §2.2's holder edges shade a value symbol's body through
    /// the id, a string atom's cache is droppable, and §2.4's sweep is what
    /// decides the entry itself.
    pub fn traceRoots(self: *AtomTable, visitor: *runtime_mod.RootVisitor) runtime_mod.RootTraceError!void {
        for (self.predefined_str) |cached| {
            if (cached) |body| try visitor.constValue(JSValue.string(body.header()));
        }
    }

    /// The minor's extra root set (see `young_symbol_atoms`). Entries that
    /// died, lost their body or had their slot recycled report nothing; a
    /// recycled slot can at worst over-retain one body for one collection.
    pub fn traceYoungSymbolBodies(self: *AtomTable, visitor: *runtime_mod.RootVisitor) runtime_mod.RootTraceError!void {
        for (self.young_symbol_atoms.items) |id| {
            const entry = self.findDynamic(id) orelse continue;
            if (!entry.occupied or !isValueSymbolKind(entry.kind)) continue;
            const body = entry.str orelse continue;
            try visitor.constValue(JSValue.string(body.header()));
        }
    }

    /// Allocator for `young_symbol_atoms`; mirrors `CompileAtomScope.init`.
    inline fn youngListAllocator(self: *AtomTable) std.mem.Allocator {
        if (self.owner_runtime) |rt| return rt.memory.persistent_allocator;
        return self.memory.persistent_allocator;
    }

    /// TGC S3-c: called from the generational promotion points (the minor's
    /// promotion block and `clearYoungState`). Everything still alive there is
    /// old now, so the interval root ends and §2.2's edges take over.
    pub fn retireYoungSymbolBodies(self: *AtomTable) void {
        self.young_symbol_atoms.clearRetainingCapacity();
    }

    pub fn init(account: *memory.MemoryAccount) AtomTable {
        return .{ .memory = account };
    }

    pub fn deinit(self: *AtomTable) void {
        const account = self.memory;
        self.young_symbol_atoms.deinit(self.youngListAllocator());
        const entries = self.entries;
        const backing: []DynamicAtom = if (self.entries_capacity != 0) self.entries.ptr[0..self.entries_capacity] else self.entries[0..0];
        self.entries = &.{};
        self.entries_capacity = 0;
        const buckets = self.atom_hash;
        self.atom_hash = &.{};
        if (buckets.len != 0) account.free(Atom, buckets);
        for (&self.predefined_str) |slot| std.debug.assert(slot == null);
        for (entries) |*entry| {
            // Cached strings/symbol bodies must have been released through `free` or
            // `releaseCachedStrings` while the runtime was still usable.
            std.debug.assert(entry.str == null);
            const bytes = entry.bytes;
            entry.bytes = &.{};
            if (bytes.len != 0) account.free(u8, bytes);
        }
        self.* = .{ .memory = account };
        if (backing.len != 0) account.free(DynamicAtom, backing);
    }

    /// Drop cached atom strings and predefined symbol bodies before GC
    /// registry teardown. This clears the table's trace roots. Every body is
    /// unbound here while its memory is still valid, so the back-pointer can
    /// be cleared and no teardown handshake will find a dynamic atom id on a
    /// cell; `gc.deinit` reclaims the memory wholesale.
    pub fn releaseCachedStrings(self: *AtomTable) void {
        // The interval root ends with the last usable trace; the bodies
        // themselves are reclaimed wholesale by `gc.deinit`.
        self.young_symbol_atoms.clearRetainingCapacity();
        for (&self.predefined_str) |*slot| {
            if (slot.* != null) {
                slot.* = null;
                // Predefined ids are never recycled, so the weak
                // back-pointer can stay valid on the string.
            }
        }
        for (self.entries) |*entry| {
            if (entry.str) |cached| {
                entry.str = null;
                cached.atom_id = string.String.no_atom_id;
            }
        }
    }

    /// Drop any dynamic value-symbol bodies that remain after the GC registry
    /// has destroyed objects, bytecode, VarRefs, and (last) shapes. At this
    /// point no GC-managed owner can still free a property-key atom, so forcing
    /// the residual registry/manual references to zero cannot invalidate a
    /// later shape teardown.
    ///
    /// TGC S2 (tracer-owned strings): `gc.deinit` has already freed every
    /// string cell, so the slot is nulled without dereferencing the body
    /// (`releaseCachedStrings` normally leaves nothing here).
    pub fn releaseValueSymbolBodiesAfterGc(self: *AtomTable) void {
        for (self.entries) |*entry| {
            if (!isValueSymbolKind(entry.kind)) continue;
            if (entry.str == null) continue;
            entry.str = null;
        }
    }

    /// Mutable chain link of any atom id, the `p->hash_next` of quickjs.c:3318.
    /// Predefined ids read from the table-owned side array, dynamic ids from
    /// their entry; both are plain `Atom` slots, so this is an address select.
    inline fn hashNextPtr(self: *AtomTable, id: Atom) *Atom {
        return if (id.raw() < first_dynamic_atom)
            &self.predefined_hash_next[id.raw() - 1]
        else
            &self.entries[id.raw() - first_dynamic_atom].hash_next;
    }

    /// Stored spelling hash of any atom id, the `p->hash` of quickjs.c:3363.
    inline fn storedHash(self: *const AtomTable, id: Atom) u32 {
        return if (id.raw() < first_dynamic_atom)
            predefined_hash[id.raw() - 1]
        else
            self.entries[id.raw() - first_dynamic_atom].hash;
    }

    /// qjs `JS_InitAtoms` (quickjs.c:3078-3089): size the bucket array once and
    /// enter every predefined *string* atom into the chain the dynamic atoms
    /// share. Predefined unique symbols and private names stay out, exactly as
    /// qjs keeps `JS_ATOM_TYPE_SYMBOL` out of `atom_hash` (quickjs.c:3316).
    fn initAtomHash(self: *AtomTable) !void {
        std.debug.assert(self.atom_hash.len == 0);
        const buckets = try self.memory.alloc(Atom, atom_hash_initial_size);
        @memset(buckets, null_atom);
        self.atom_hash = buckets;
        self.atom_count_resize = atom_hash_initial_size * 2;
        self.atom_hash_count = 0;
        const mask = atom_hash_initial_size - 1;
        for (predefined_atoms, 0..) |entry, i| {
            if (entry.kind != .string) continue;
            const id: Atom = Atom.fromRaw(@intCast(i + 1));
            const bucket = &buckets[predefined_hash[i] & mask];
            self.predefined_hash_next[i] = bucket.*;
            bucket.* = id;
            self.atom_hash_count += 1;
        }
    }

    inline fn ensureAtomHash(self: *AtomTable) !void {
        if (self.atom_hash.len == 0) try self.initAtomHash();
    }

    /// qjs `JS_ResizeAtomHash` (quickjs.c:3055-3072): allocate the new bucket
    /// array and re-splice every chain into it using the stored hashes — no
    /// spelling is re-hashed and no atom moves.
    fn resizeAtomHash(self: *AtomTable, new_size: u32) !void {
        std.debug.assert(std.math.isPowerOfTwo(new_size));
        const new_hash = try self.memory.alloc(Atom, new_size);
        @memset(new_hash, null_atom);
        const new_mask = new_size - 1;
        for (self.atom_hash) |head| {
            var i = head;
            while (i != null_atom) {
                const next_ptr = self.hashNextPtr(i);
                const following = next_ptr.*;
                const j = self.storedHash(i) & new_mask;
                next_ptr.* = new_hash[j];
                new_hash[j] = i;
                i = following;
            }
        }
        const old = self.atom_hash;
        self.atom_hash = new_hash;
        self.memory.free(Atom, old);
        self.atom_count_resize = new_size *| 2;
    }

    /// qjs `__JS_FindAtom` (quickjs.c:3348-3375) and the lookup arm of
    /// `__JS_NewAtom` (quickjs.c:3196-3212). The stored hash, the atom kind and
    /// the length gate the byte comparison, so a chain step that is not the
    /// answer never touches the spelling.
    inline fn findAtom(self: *const AtomTable, bytes: []const u8, atom_kind: AtomKind, h: u32) Atom {
        if (self.atom_hash.len == 0) return null_atom;
        var i = self.atom_hash[h & (self.atom_hash.len - 1)];
        while (i != null_atom) {
            if (i.raw() < first_dynamic_atom) {
                const p = &predefined_atoms[i.raw() - 1];
                if (predefined_hash[i.raw() - 1] == h and p.kind == atom_kind and
                    p.name.len == bytes.len and std.mem.eql(u8, p.name, bytes))
                {
                    return i;
                }
                i = self.predefined_hash_next[i.raw() - 1];
            } else {
                const entry = &self.entries[i.raw() - first_dynamic_atom];
                if (entry.hash == h and entry.kind == atom_kind and
                    entry.bytes.len == bytes.len and std.mem.eql(u8, entry.bytes, bytes))
                {
                    return i;
                }
                i = entry.hash_next;
            }
        }
        return null_atom;
    }

    /// qjs `__JS_NewAtom` insert (quickjs.c:3317-3322): splice the atom at the
    /// head of its bucket, then double the table once the chained population
    /// reaches `atom_count_resize`. A failed resize is ignored exactly as qjs
    /// ignores `JS_ResizeAtomHash`'s return value — the table stays correct,
    /// only its chains get longer.
    fn chainInsert(self: *AtomTable, id: Atom, h: u32) void {
        const bucket = &self.atom_hash[h & (self.atom_hash.len - 1)];
        self.hashNextPtr(id).* = bucket.*;
        bucket.* = id;
        self.atom_hash_count += 1;
        if (self.atom_hash_count >= self.atom_count_resize) {
            const next_size = self.atom_hash.len * 2;
            if (next_size <= std.math.maxInt(u32)) {
                self.resizeAtomHash(@intCast(next_size)) catch {};
            }
        }
    }

    /// qjs `JS_FreeAtomStruct`'s unlink (quickjs.c:3387-3409): walk the bucket
    /// from its head and splice the atom out. The stored hash means the dying
    /// atom's spelling is never re-hashed and never compared.
    fn chainUnlink(self: *AtomTable, id: Atom, h: u32) void {
        std.debug.assert(self.atom_hash.len != 0);
        const bucket = &self.atom_hash[h & (self.atom_hash.len - 1)];
        var i = bucket.*;
        std.debug.assert(i != null_atom);
        if (i == id) {
            bucket.* = self.hashNextPtr(id).*;
        } else {
            while (true) {
                const link = self.hashNextPtr(i);
                const following = link.*;
                std.debug.assert(following != null_atom);
                if (following == id) {
                    link.* = self.hashNextPtr(id).*;
                    break;
                }
                i = following;
            }
        }
        self.hashNextPtr(id).* = null_atom;
        self.atom_hash_count -= 1;
    }

    pub fn internString(self: *AtomTable, bytes: []const u8) !Atom {
        const id = try self.internStringInner(bytes);
        self.noteCompileScope(id);
        return id;
    }

    fn internStringInner(self: *AtomTable, bytes: []const u8) !Atom {
        // Match JS_NewAtomLen's digit gate: integer atoms do not need a
        // string hash at all (quickjs.c:3465 `is_digit(*str)`).
        if (parseArrayIndex(bytes)) |n| return Atom.taggedInt(n);
        try self.ensureAtomHash();
        const hash = spellingHash(bytes, .string);
        const found = self.findAtom(bytes, .string, hash);
        if (found != null_atom) {
            // qjs:3207 / 3370: `__JS_AtomIsConst` atoms carry no ref count.
            if (found.isConst()) return found;
            const entry = &self.entries[found.raw() - first_dynamic_atom];
            std.debug.assert(entry.occupied and entry.kind == .string);
            return found;
        }
        return self.internDynamic(bytes, .string, true, false, hash);
    }

    pub fn newSymbol(self: *AtomTable, description: []const u8, atom_kind: AtomKind) !Atom {
        std.debug.assert(atom_kind == .symbol or atom_kind == .private);
        return self.internDynamic(description, atom_kind, false, false, 0);
    }

    pub fn newValueSymbol(self: *AtomTable, description: []const u8) !Atom {
        return self.internDynamic(description, .symbol, false, false, 0);
    }

    pub fn newValueSymbolNoDescription(self: *AtomTable) !Atom {
        return self.internDynamic("", .symbol, false, true, 0);
    }

    pub fn internSymbol(self: *AtomTable, description: []const u8) !Atom {
        return self.internGlobalSymbol(description);
    }

    pub fn internGlobalSymbol(self: *AtomTable, description: []const u8) !Atom {
        const id = try self.internGlobalSymbolInner(description);
        self.noteCompileScope(id);
        return id;
    }

    fn internGlobalSymbolInner(self: *AtomTable, description: []const u8) !Atom {
        try self.ensureAtomHash();
        const hash = spellingHash(description, .global_symbol);
        const found = self.findAtom(description, .global_symbol, hash);
        if (found != null_atom) {
            const entry = self.findDynamic(found).?;
            std.debug.assert(entry.occupied and entry.kind == .global_symbol);
            return found;
        }
        return self.internDynamic(description, .global_symbol, true, false, hash);
    }

    pub fn internRegisteredValueSymbol(self: *AtomTable, description: []const u8) !Atom {
        const id = try self.internRegisteredValueSymbolInner(description);
        self.noteCompileScope(id);
        return id;
    }

    fn internRegisteredValueSymbolInner(self: *AtomTable, description: []const u8) !Atom {
        try self.ensureAtomHash();
        const hash = spellingHash(description, .global_symbol);
        const found = self.findAtom(description, .global_symbol, hash);
        if (found != null_atom) {
            const entry = self.findDynamic(found).?;
            std.debug.assert(entry.occupied and entry.kind == .global_symbol);
            entry.registry_managed_symbol = true;
            return found;
        }
        const id = try self.internDynamic(description, .global_symbol, true, false, hash);
        const entry = self.findDynamic(id).?;
        entry.registry_managed_symbol = true;
        return id;
    }

    pub fn isRegisteredSymbol(self: *const AtomTable, atom_id: Atom) bool {
        const idx = dynamicEntryIndex(atom_id) orelse return false;
        if (idx >= self.entries.len) return false;
        const entry = self.entries[idx];
        if (!entry.occupied or entry.kind != .global_symbol) return false;
        return self.findAtom(entry.bytes, .global_symbol, entry.hash) == atom_id;
    }

    // ---- TGC S3: tracing-owned atom liveness (docs/tracing-gc-s3-spec.md) ----
    //
    // Live == reached this major by a `visitAtom` edge, a declared root, the
    // insertion barrier or black allocation; or its string body was marked; or
    // an embedder pinned it. `sweepDead` is the only killer.

    /// This runtime's current major mark epoch. `Heap.mark_epoch` is even and
    /// becomes non-zero at the first major, so the `0` a table without a
    /// runtime (compiler/parser fixtures) reports can never match a stamp.
    inline fn traceEpoch(self: *const AtomTable) u64 {
        const rt = self.owner_runtime orelse return 0;
        return rt.gc.block_heap.mark_epoch;
    }

    /// §2.2, the table half of `Collector.visitAtom`: stamp `id` with this
    /// major's epoch and hand back the symbol body the caller must shade.
    /// Predefined and tagged-int atoms are not entries and never die, so they
    /// short-circuit.
    ///
    /// A holder naming a VALUE SYMBOL by id must be able to re-materialize the
    /// body (`getOwnPropertySymbols` hands out the JSValue), so the id edge
    /// keeps the body alive. A string atom's `str` is a droppable cache and is
    /// deliberately not shaded.
    pub fn markAtomAtEpoch(self: *AtomTable, id: Atom, epoch: u64) ?*string.String {
        return self.atomEdge(id, epoch, .stamp);
    }

    /// The same edge WITHOUT the entry write, for `computeFullReachable`.
    ///
    /// The verifier's probe re-walks every edge the cycle just walked. It has
    /// to shade what an id edge keeps alive -- a value symbol's body is its
    /// identity, and a probe that skipped it would report the body as garbage
    /// the cycle wrongly kept -- but it must not touch the entry, for the same
    /// reason it does not run `processWeak`: the stamp it would write is its
    /// OWN epoch, which overwrites the cycle's stamp beyond recovery and makes
    /// the probe's roots, not the cycle's, decide which atoms survive. The
    /// audit counters are writes too, and the real walk already made them.
    pub fn atomEdgeBodyWithoutStamp(self: *AtomTable, id: Atom) ?*string.String {
        return self.atomEdge(id, 0, .observe);
    }

    const EdgeMode = enum { stamp, observe };

    fn atomEdge(self: *AtomTable, id: Atom, epoch: u64, mode: EdgeMode) ?*string.String {
        if (id == null_atom or id.isConst() or id.isTaggedInt()) return null;
        const entry = self.findDynamic(id) orelse return null;
        if (!entry.occupied) {
            if (mode == .observe) return null;
            // §2.6, post-flip form. Reaching a retired slot through a holder
            // edge means the holder outlived the entry it names -- the exact
            // stale-id shape `check_borrowed_atoms.js` and the
            // `-Dzjs_ownership_audit` quarantine exist to catch.
            if (entry.weakref_count != 0) {
                self.atom_audit_shell_edge += 1;
            } else {
                self.atom_audit_stale_edge += 1;
                if (comptime builtin.mode == .Debug) {
                    std.debug.print(
                        "gc: ATOM AUDIT stale edge id={d} kind={s}\n",
                        .{ entry.id, @tagName(entry.kind) },
                    );
                    if (gc.atom_audit_fatal) @panic("ATOM AUDIT: a holder edge names a retired atom entry");
                }
            }
            return null;
        }
        if (mode == .stamp and entry.mark_epoch != epoch) entry.mark_epoch = epoch;
        // The BODY is offered on every edge, stamped or not. Gating it on the
        // stamp lost bodies two ways: `stampBirthEpoch` (§2.3 black
        // allocation) stamps an entry interned inside the marking window
        // without shading anything, so the holder edge that follows would find
        // the stamp already set and hand back nothing; and the epoch only
        // moves at `beginMajor`, so every minor after the first of an epoch
        // (and every minor before the first major, where both sides read 0)
        // did the same. `shadeExact` already short-circuits a marked cell, and
        // a string atom's droppable cache is still never shaded, so the
        // ordinary shape-key walk leaves on the kind test as before.
        if (!isValueSymbolKind(entry.kind)) return null;
        return entry.str;
    }

    /// §2.3 Dijkstra insertion barrier. Storing an atom id into an already
    /// published holder during an open marking window can hide it from the
    /// trace (white holder -> black holder id migration), so the store shades
    /// it. Outside a marking window this is one relaxed byte load.
    pub inline fn shadeAtomIfMarking(self: *AtomTable, id: Atom) void {
        const rt = self.owner_runtime orelse return;
        if (rt.gc.incremental.markingActive()) {
            @branchHint(.unlikely);
            self.shadeAtomBarrierSlow(rt, id);
        }
    }

    noinline fn shadeAtomBarrierSlow(self: *AtomTable, rt: *runtime_mod.JSRuntime, id: Atom) void {
        const epoch = rt.gc.block_heap.mark_epoch;
        if (self.markAtomAtEpoch(id, epoch)) |body| rt.gc.shadeCellForAtomBarrier(body.header());
    }

    /// §2.4 companion for `gc_trace_stw.computeFullReachable`.
    ///
    /// Atom liveness is a stamp compared against `Heap.mark_epoch`, and the
    /// verifier's probe advances that epoch to get a mark space of its own.
    /// Every stamp the real cycle laid down therefore reads stale by the time
    /// `sweepAtomTable` runs, and the sweep retires the whole live table --
    /// with `ZJS_GC_VERIFY_MAJOR_ALL=1` pdfjs loses shape keys mid-lookup and
    /// dies in `getLineNumber`. The header half of the probe is undone by
    /// re-marking the saved set; this is the table half, and it makes the same
    /// promise: leave the epoch-keyed liveness exactly as it was found.
    ///
    /// This is a pure translation of the epoch, not a re-decision: `from`
    /// stamps become `to` stamps and nothing else moves. It is exact because
    /// the probe walks its edges through `atomEdgeBodyWithoutStamp` and the
    /// insertion barrier is disarmed for its duration, so no entry can carry a
    /// stamp the probe wrote -- there is nothing to tell apart afterwards.
    pub fn restampTraceEpoch(self: *AtomTable, from: u64, to: u64) void {
        if (from == to) return;
        var idx: EntryIndex = 0;
        while (idx < self.entries.len) : (idx += 1) {
            const entry = &self.entries[idx];
            if (!entry.slotOccupied()) continue;
            if (entry.mark_epoch == from) entry.mark_epoch = to;
            if (entry.born_epoch == from) entry.born_epoch = to;
        }
    }

    /// §2.3 black allocation: an atom interned inside an open marking window
    /// cannot have been reachable from the roots that window snapshotted, so
    /// it is live for this cycle by construction.
    fn stampBirthEpoch(self: *AtomTable, entry: *DynamicAtom) void {
        const epoch = self.traceEpoch();
        entry.born_epoch = epoch;
        entry.host_pins = 0;
        entry.mark_epoch = 0;
        const rt = self.owner_runtime orelse return;
        if (rt.gc.incremental.markingActive()) entry.mark_epoch = epoch;
    }

    /// §2.2 compile scope: record `id` in the innermost active
    /// `CompileAtomScope`. One nullable load outside a compile.
    pub inline fn noteCompileScope(self: *AtomTable, id: Atom) void {
        if (self.compile_scope) |scope| {
            @branchHint(.unlikely);
            scope.note(id);
        }
    }

    /// §2.5 host pin (`pinForHost` / `unpinForHost`): the only count
    /// left in the table, and the only liveness an embedder can assert.
    pub fn pinForHost(self: *AtomTable, id: Atom) void {
        if (id.isConst() or id.isTaggedInt()) return;
        const entry = self.findDynamic(id) orelse return;
        entry.host_pins +|= 1;
    }

    pub fn unpinForHost(self: *AtomTable, id: Atom) void {
        if (id.isConst() or id.isTaggedInt()) return;
        const entry = self.findDynamic(id) orelse return;
        entry.host_pins -|= 1;
    }

    /// §2.4. Called from both major paths INSIDE the pause that finished the
    /// mark, right after condemnation (`gc_trace_stw.sweepAtomTable` states the
    /// why). This is the only place a dynamic atom entry dies.
    ///
    /// On the STW path every doomed cell is already destroyed and the
    /// `onSymbolBodyDead` handshake has already nulled its `entry.str`. On the
    /// INCREMENTAL path destruction is sliced across later polls, so a doomed
    /// string body is still addressable here -- which is why the sweep must
    /// also unbind the caches whose body did not survive the mark. Leaving them
    /// bound would let `cachedString`/`createAtomBacked` hand a condemned cell
    /// back to the mutator during the destruction run.
    pub fn sweepDead(self: *AtomTable, rt: *runtime_mod.JSRuntime, epoch: u64) void {
        // A sweep is the audit's quarantine round (see `OwnershipAuditState`):
        // the batch retired by the PREVIOUS sweep becomes recyclable here, and
        // everything this sweep retires goes into the now-empty quarantine.
        // Comptime-off, so the default build enters the loop as before.
        if (comptime ownership_audit_enabled) self.releaseQuarantinedSlots();
        var idx: EntryIndex = 0;
        while (idx < self.entries.len) : (idx += 1) {
            const entry = &self.entries[idx];
            if (!entry.slotOccupied()) continue;
            // §2.4 only judges OCCUPIED, NON-SHELL entries. A weak shell
            // (kept alive only by `weakref_count`) is already unindexed and
            // already reported dead by `symbolValueIfLive`; re-running the
            // verdict on it would unlink it from a hash chain it left long ago.
            if (!entry.occupied) continue;
            const body_marked = if (entry.str) |body| rt.gc.headerMarked(body.header()) else false;
            const live = entry.mark_epoch == epoch or
                entry.born_epoch == epoch or
                entry.host_pins != 0 or
                body_marked;
            if (live) {
                // Doomed cache on a surviving entry. Marking is over and
                // condemnation has run, so an unmarked cell here is condemned
                // by definition; a string atom's `str` is a droppable cache, so
                // dropping it now is the same event the destroy handshake would
                // report later -- only early enough that the mutator can never
                // observe the corpse. A value symbol's body IS its identity and
                // every id edge shades it, so it is left to the handshake.
                if (!body_marked and entry.kind == .string) {
                    if (entry.str) |cached| {
                        entry.str = null;
                        cached.atom_id = string.String.no_atom_id;
                    }
                }
                continue;
            }
            if (entry.weakref_count != 0) {
                // WeakRef'd symbol: keep the shell so `symbolValueIfLive`
                // can report the death, exactly as `onSymbolBodyDead` does.
                self.unindexEntry(idx);
                if (entry.str) |cached| {
                    entry.str = null;
                    cached.atom_id = string.String.no_atom_id;
                }
                entry.occupied = false;
                continue;
            }
            self.finalizeDeadEntry(idx);
        }
    }

    /// TGC S3 §2.3: a store of `atom` into a GC-VISIBLE HOLDER (a shape's
    /// property key, a module's metadata, a FunctionBytecode's names, a
    /// backtrace frame, the class table). All that is left of the old
    /// `dupForHolder` is the Dijkstra insertion barrier, which is what keeps
    /// an id migrating between holders from hiding behind an already-black
    /// one. The id is handed back so a holder field can be initialized in
    /// place: `.field = atoms.noteHolderStore(id)`.
    pub fn noteHolderStore(self: *AtomTable, atom: Atom) Atom {
        self.noteCompileScope(atom);
        self.shadeAtomIfMarking(atom);
        return atom;
    }

    pub fn name(self: *const AtomTable, atom: Atom) ?[]const u8 {
        if (atom == null_atom) return null;
        if (atom.isTaggedInt()) return null;
        if (predefinedById(atom)) |entry| return entry.name;
        if (self.findDynamicConst(atom)) |entry| {
            if (entry.occupied) return entry.bytes;
        }
        return null;
    }

    /// Fast "is this atom an array index?" predicate for the property-define hot
    /// path, where only the boolean is needed (the caller never uses the index
    /// value). Mirrors qjs `add_property` (quickjs.c:9184), which pays only
    /// `__JS_AtomIsTaggedInt` for a named key and treats the string-atom index
    /// range through the ordinary shape add. zjs `internString` already tags every
    /// numeric-form string in `[0, max_int_atom]` as an integer atom, so the only
    /// NON-tagged atom that can still be an array index is a *dynamic string* atom
    /// whose decimal name lands in `(max_int_atom, max_array_index]` — necessarily
    /// >= 10 digits. Reject predefined atoms (never numeric) and short names
    /// without touching `name()`'s null/tagged/live-value resolution chain; only a
    /// >= 10-char dynamic string entry pays the full parse.
    ///
    /// Semantics are identical to `array.arrayIndexFromAtom(...) != null`: the
    /// full decimal range is `[0, max_array_index]` (2^32-2), so the string leg
    /// uses `parseHighArrayIndex` (bounded by `max_array_index`) — NOT
    /// `parseArrayIndex` (bounded by the tighter `max_int_atom`).
    pub fn atomIsArrayIndex(self: *const AtomTable, atom: Atom) bool {
        if (atom.isTaggedInt()) return atom.toUInt32() <= max_array_index;
        // Predefined atoms (id.raw() < first_dynamic_atom) are fixed identifiers/symbols;
        // none has an all-numeric name, so none is an array index.
        const idx = dynamicEntryIndex(atom) orelse return false;
        if (idx >= self.entries.len) return false;
        const entry = &self.entries[idx];
        // Length probe FIRST: a canonical array index that interns as a
        // DYNAMIC string atom is always >= 10 digits ("2147483648" ..
        // "4294967294" — everything smaller became a tagged-int atom), so
        // this single in-struct field read rejects every ordinary identifier
        // key without touching the liveness/kind fields (two dependent loads
        // through the lazily-cached string body). Pure conjunct reorder: the
        // len field lives in the entry struct itself (always readable), and
        // the live/kind gates still precede the parse that dereferences
        // `bytes.ptr`.
        if (entry.bytes.len < 10) return false;
        if (!entry.occupied or entry.kind != .string) return false;
        return parseHighArrayIndex(entry.bytes) != null;
    }

    pub fn kind(self: *const AtomTable, atom: Atom) ?AtomKind {
        if (atom == null_atom) return null;
        if (atom.isTaggedInt()) return .string;
        if (predefinedById(atom)) |entry| return entry.kind;
        if (self.findDynamicConst(atom)) |entry| {
            if (entry.occupied) return entry.kind;
        }
        return null;
    }

    pub fn isPublicSymbol(self: *const AtomTable, atom_id: Atom) bool {
        const atom_kind = self.kind(atom_id) orelse return false;
        return isPublicSymbolKind(atom_kind);
    }

    /// QJS `OP_push_atom_value` indexes `atom_array[atom]` and duplicates the
    /// already-materialized JSString directly. zjs keeps atoms and strings in
    /// separate structures, but after the first conversion the predefined or
    /// dynamic entry has the same direct pointer. Inline that steady-state
    /// lookup so hot atom-to-string users do not repeat tagged/const/name/
    /// liveness/cache dispatch. The slow path preserves tagged-int, symbol-
    /// description and first-materialization behavior.
    ///
    /// The allocation-free half of `toStringValueForPush`: a materialized body
    /// already in the table, handed back with no chance of a collection.
    ///
    /// It is split out because `OP_push_atom_value`'s register-resident handler
    /// runs with an UNPUBLISHED operand stack -- `Stack.liveValues` stops at
    /// `top_ptr`, so everything pushed since the last publish is invisible to
    /// the tracer. That is sound only while the handler cannot collect, which
    /// is exactly this arm; the miss arm allocates (`String.createUtf8`) and
    /// must publish first. Before TGC S3-c the miss arm's victims were saved by
    /// accident: `AtomTable.traceRoots` reported every `entries[].str` as a
    /// strong root, so the array-literal elements already pushed above
    /// `top_ptr` were kept alive by the atom table rather than by the stack.
    pub inline fn cachedPushValue(self: *AtomTable, atom_id: Atom) ?JSValue {
        if (atom_id != null_atom and atom_id.raw() < first_dynamic_atom) {
            if (self.predefined_str[atom_id.raw() - 1]) |cached| return cached.value();
            return null;
        }
        if (atom_id.raw() >= first_dynamic_atom and atom_id.raw() < tagged_int_bit) {
            const idx: usize = @intCast(atom_id.raw() - first_dynamic_atom);
            if (idx < self.entries.len) {
                const entry = &self.entries[idx];
                if (entry.kind == .string) {
                    if (entry.str) |cached| return cached.value();
                }
            }
        }
        return null;
    }

    pub inline fn toStringValueForPush(self: *AtomTable, rt: anytype, atom_id: Atom) !JSValue {
        if (self.cachedPushValue(atom_id)) |cached| return cached;
        return self.toStringValue(rt, atom_id);
    }

    pub fn toStringValue(self: *AtomTable, rt: anytype, atom_id: Atom) !JSValue {
        if (atom_id.isTaggedInt()) {
            var buf: [10]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d}", .{atom_id.toUInt32()}) catch unreachable;
            if (text.len == 1 and text[0] <= 0x7f) {
                const cached = try rt.singleByteString(text[0]);
                return cached.value();
            }
            const cached = try rt.recentAtomString(atom_id, text);
            return cached.value();
        }
        if (atom_id == null_atom) return JSValue.undefinedValue();

        // QJS atom ids index an array whose entry is itself the string body.
        // Keep zjs's split Atom/String storage, but resolve the entry only once
        // on this hot OP_push_atom_value path instead of repeating name(),
        // kind(), cachedString(), and cacheString() table lookups.
        if (atom_id.isConst()) {
            const predefined = predefinedById(atom_id) orelse return JSValue.undefinedValue();
            const text = predefined.name;
            if (text.len == 1 and text[0] <= 0x7f) {
                const cached = try rt.singleByteString(text[0]);
                return cached.value();
            }
            if (predefined.kind != .string) {
                const created = try string.String.createUtf8(rt, text);
                return created.value();
            }
            const slot = &self.predefined_str[atom_id.raw() - 1];
            if (slot.*) |cached| return cached.value();
            const created = try string.String.createUtf8(rt, text);
            created.atom_id = atom_id;
            slot.* = created;
            return created.value();
        }

        const entry = self.findDynamic(atom_id) orelse return JSValue.undefinedValue();
        if (!entry.isLive()) return JSValue.undefinedValue();
        const text = entry.bytes;
        if (text.len == 1 and text[0] <= 0x7f) {
            const cached = try rt.singleByteString(text[0]);
            // QJS `__JS_AtomToValue` (quickjs.c:3595) is a single
            // `atom_array[atom]` load + refcount bump because the atom entry
            // IS the string. Bind the shared single-byte body into the
            // entry's materialized-string slot so `toStringValueForPush`'s
            // inline cached arm hits on every later push instead of
            // repeating this findDynamic hash walk per OP_push_atom_value.
            if (entry.kind == .string and entry.str == null) {
                entry.str = cached;
                if (cached.atom_id == string.String.no_atom_id) cached.bindAtomId(rt, atom_id);
            }
            return cached.value();
        }
        if (entry.kind != .string) {
            const created = try string.String.createUtf8(rt, text);
            return created.value();
        }
        if (entry.str) |cached| return cached.value();
        const created = try string.String.createUtf8(rt, text);
        entry.str = created;
        created.bindAtomId(rt, atom_id);
        return created.value();
    }

    /// Borrowed lookup of the lazily materialized string for a string-kind
    /// atom. Returns null for tagged ints, dead atoms, and atoms that were
    /// never converted.
    pub fn cachedString(self: *const AtomTable, atom_id: Atom) ?*string.String {
        if (atom_id == null_atom or atom_id.isTaggedInt()) return null;
        if (atom_id.isConst()) return self.predefined_str[atom_id.raw() - 1];
        const entry = self.findDynamicConst(atom_id) orelse return null;
        if (!entry.isLive()) return null;
        return entry.str;
    }

    /// Bind `s` as the materialized string for `atom_id`, if the slot is
    /// free and `s` is not already bound elsewhere. The table takes one
    /// string reference; `s.atom_id` becomes a weak back-pointer (no atom
    /// reference) cleared when the atom dies. First binding wins; a
    /// content-equal string interned later simply stays unbound. No-op for
    /// non-string atoms, so a symbol's description never converts back
    /// into the symbol atom.
    pub fn cacheString(self: *AtomTable, rt: *JSRuntime, atom_id: Atom, s: *string.String) void {
        if (s.atom_id != string.String.no_atom_id) return;
        if (atom_id.isTaggedInt()) {
            // Tagged ints have no table entry, but the id encodes the
            // value itself and is never recycled: a bare back-pointer is
            // always safe and makes future internAtom calls free.
            s.atom_id = atom_id;
            return;
        }
        if (atom_id == null_atom) return;
        if (atom_id.isConst()) {
            const pre = predefined_atoms[atom_id.raw() - 1];
            if (pre.kind != .string) return;
            // Predefined ids are never recycled either, so the weak
            // back-pointer is safe even when the cache slot is taken.
            s.atom_id = atom_id;
            const slot = &self.predefined_str[atom_id.raw() - 1];
            if (slot.* == null) {
                slot.* = s;
            }
            return;
        }
        const entry = self.findDynamic(atom_id) orelse return;
        if (!entry.isLive() or entry.kind != .string or entry.str != null) return;
        entry.str = s;
        s.bindAtomId(rt, atom_id);
    }

    /// JSValue for an atom the caller keeps holding BY ID. The value is an
    /// uncounted mark-tracked reference; the caller's ID count is untouched.
    pub fn symbolValue(self: *AtomTable, rt: *JSRuntime, atom_id: Atom) !JSValue {
        const body = try self.ensureSymbolBody(rt, atom_id);
        const hdr = body.header();
        return JSValue.symbol(hdr);
    }

    /// JSValue for a symbol the caller is handing over to its JS holders (the
    /// creation path: `newSymbolValue`, private names). TGC S3-c: identical to
    /// `symbolValue` now that there is no ID count to give back; both names
    /// survive because the call sites read differently.
    pub fn takeSymbolValue(self: *AtomTable, rt: *JSRuntime, atom_id: Atom) !JSValue {
        const body = try self.ensureSymbolBody(rt, atom_id);
        return JSValue.symbol(body.header());
    }

    /// Retire a symbol interned in this call that never became a JSValue.
    /// No-op if the entry was already swept, has a body, or still has pins.
    pub fn abandonUnpublishedSymbol(self: *AtomTable, atom_id: Atom) void {
        if (atom_id.isConst() or atom_id.isTaggedInt()) return;
        const idx = dynamicEntryIndex(atom_id) orelse return;
        if (idx >= self.entries.len) return;
        const entry = &self.entries[idx];
        if (!entry.occupied or !isValueSymbolKind(entry.kind)) return;
        if (entry.str != null) return;
        if (entry.host_pins != 0 or entry.weakref_count != 0) return;
        self.finalizeDeadEntry(@intCast(idx));
    }

    pub fn symbolValueIfLive(self: *const AtomTable, rt: *const JSRuntime, atom_id: Atom) JSValue {
        const body = self.symbolBodyIfLive(rt, atom_id) orelse return JSValue.undefinedValue();
        return JSValue.symbol(body.header());
    }

    pub fn retainSymbolWeakRef(self: *AtomTable, atom_id: Atom) void {
        if (atom_id.isConst() or atom_id.isTaggedInt()) return;
        const entry = self.findDynamic(atom_id) orelse return;
        if (!isValueSymbolKind(entry.kind)) return;
        std.debug.assert(entry.occupied);
        entry.weakref_count += 1;
    }

    pub fn releaseSymbolWeakRef(self: *AtomTable, _: *JSRuntime, atom_id: Atom) void {
        if (atom_id.isConst() or atom_id.isTaggedInt()) return;
        const idx = dynamicEntryIndex(atom_id) orelse return;
        if (idx >= self.entries.len) return;
        const entry = &self.entries[idx];
        if (!isValueSymbolKind(entry.kind)) return;
        std.debug.assert(entry.weakref_count > 0);
        entry.weakref_count -= 1;
        // Only a weak shell (body already swept, no ID holder) is finalized
        // here; a live body is the sweep's business.
        if (entry.weakref_count == 0 and entry.str == null and !entry.occupied) {
            self.finalizeDeadEntry(@intCast(idx));
        }
    }

    pub fn symbolDescription(self: *const AtomTable, rt: *const JSRuntime, symbol: Atom) ?[]const u8 {
        const body = self.symbolBodyIfLive(rt, symbol) orelse return null;
        if (body.isSymbolNoDescription()) return null;
        return self.name(symbol);
    }

    /// GC weak-key liveness query. The atom id is only an identity; under
    /// tracing the symbol body's mark, not table membership, decides whether
    /// a WeakRef/WeakMap key survived the current trace.
    pub fn symbolBodyHeaderIfLive(self: *const AtomTable, rt: *const JSRuntime, atom_id: Atom) ?*gc.Header {
        const body = self.symbolBodyIfLive(rt, atom_id) orelse return null;
        return @ptrCast(@alignCast(body));
    }

    /// TGC S2 §6 lane A: `entry.str` is the mutator's liveness authority, but
    /// only outside the sweep. Once the collector has entered
    /// `.tracer_destroy` the trace has already decided who lives, and the
    /// unbinding handshake (`onSymbolBodyDead`) has not necessarily reached
    /// this entry yet -- so a body that is condemned but not yet destroyed is
    /// still bound. Reporting it as live there hands a doomed symbol back to a
    /// destructor-time observer (WeakRef deref / weak-persistent get /
    /// description), which either resurrects it or reads a recycled cell one
    /// step later. The mark is the only authority that is correct in both
    /// windows, so consult it exactly in the window where the binding is not.
    ///
    /// This mirrors what the object side does with `headerIsHusk` in
    /// `liveObjectFromWeakIdentity`, one step earlier: the husk bit only
    /// appears once teardown has actually stripped the object, whereas the
    /// mark is already false for the whole condemned set.
    fn bodyLiveForCurrentPhase(rt: *const JSRuntime, body: *string.String) bool {
        if (rt.gc.hot.phase != .tracer_destroy) return true;
        return rt.gc.headerMarked(body.header());
    }

    fn symbolBodyIfLive(self: *const AtomTable, rt: *const JSRuntime, atom_id: Atom) ?*string.String {
        if (atom_id == null_atom or atom_id.isTaggedInt()) return null;
        if (atom_id.isConst()) {
            const pre = predefined_atoms[atom_id.raw() - 1];
            if (!isValueSymbolKind(pre.kind)) return null;
            // Predefined bodies are unconditional trace roots (`traceRoots`),
            // so they are marked whenever a sweep is running; the phase test
            // rides along rather than special-casing them.
            const body = self.predefined_str[atom_id.raw() - 1] orelse return null;
            if (!bodyLiveForCurrentPhase(rt, body)) return null;
            return body;
        }
        const entry = self.findDynamicConst(atom_id) orelse return null;
        if (!isValueSymbolKind(entry.kind)) return null;
        const body = entry.str orelse return null;
        // A body that is still bound is live until the sweep
        // handshake unbinds it (weak shell) or retires the entry --
        // except inside the sweep itself, where the mark decides.
        if (!bodyLiveForCurrentPhase(rt, body)) return null;
        return body;
    }

    fn ensureSymbolBody(self: *AtomTable, rt: *JSRuntime, atom_id: Atom) !*string.String {
        if (atom_id == null_atom or atom_id.isTaggedInt()) return error.InvalidAtom;
        if (atom_id.isConst()) {
            const pre = predefined_atoms[atom_id.raw() - 1];
            if (!isValueSymbolKind(pre.kind)) return error.InvalidAtom;
            const slot = &self.predefined_str[atom_id.raw() - 1];
            if (slot.*) |cached| return cached;
            const body = try string.String.createUtf8(rt, pre.name);
            body.atom_id = atom_id;
            slot.* = body;
            return body;
        }
        const entry = self.findDynamic(atom_id) orelse return error.InvalidAtom;
        if (!entry.occupied or !isValueSymbolKind(entry.kind)) return error.InvalidAtom;
        if (entry.str) |cached| return cached;
        // The fresh body is YOUNG and its only holder may be an old object's
        // shape, which reaches it over an atom id no minor traces. Reserve the
        // interval-root slot BEFORE the body exists, so the publish and the
        // rooting cannot be separated by an allocation failure.
        try self.young_symbol_atoms.ensureUnusedCapacity(self.youngListAllocator(), 1);
        const body = if (entry.no_symbol_description)
            try string.String.createSymbolNoDescription(rt)
        else
            try string.String.createUtf8(rt, entry.bytes);
        body.bindAtomId(rt, atom_id);
        entry.str = body;
        self.young_symbol_atoms.appendAssumeCapacity(atom_id);
        return body;
    }

    /// `lookup_hash` is the spelling hash the caller already computed while
    /// missing in the chain; it is only read for the chained kinds. Every
    /// `index_entry` caller has just proved the atom is absent, mirroring
    /// `__JS_NewAtom`, where the create path is the fall-through of the same
    /// function that did the chain walk (quickjs.c:3196-3320).
    fn internDynamic(self: *AtomTable, bytes: []const u8, atom_kind: AtomKind, index_entry: bool, no_symbol_description: bool, lookup_hash: u32) !Atom {
        const id = try self.internDynamicInner(bytes, atom_kind, index_entry, no_symbol_description, lookup_hash);
        self.noteCompileScope(id);
        return id;
    }

    fn internDynamicInner(self: *AtomTable, bytes: []const u8, atom_kind: AtomKind, index_entry: bool, no_symbol_description: bool, lookup_hash: u32) !Atom {
        std.debug.assert(!index_entry or atom_kind == .string or atom_kind == .global_symbol);
        std.debug.assert(!index_entry or self.atom_hash.len != 0);

        const owned: []u8 = if (bytes.len == 0) &.{} else try self.memory.alloc(u8, bytes.len);
        errdefer if (owned.len != 0) self.memory.free(u8, owned);
        if (bytes.len != 0) @memcpy(owned, bytes);

        // Reuse a dead slot when one is available. A slot only enters the
        // free list once a major proved the entry unreachable (`sweepDead`),
        // so rebinding its id cannot retarget a live holder; the recycled id
        // behaves exactly like a fresh one. Without recycling the table (and
        // the id space) grows monotonically under intern churn.
        if (self.free_slot_head != no_free_slot) {
            const idx = self.free_slot_head;
            const entry = &self.entries[idx];
            std.debug.assert(!entry.slotOccupied());
            std.debug.assert(entry.id.raw() == idx + first_dynamic_atom);
            std.debug.assert(entry.str == null);
            self.free_slot_head = entry.next_free;
            entry.bytes = owned;
            entry.kind = atom_kind;
            entry.occupied = true;
            entry.registry_managed_symbol = false;
            entry.weakref_count = 0;
            entry.no_symbol_description = no_symbol_description;
            self.stampBirthEpoch(entry);
            errdefer {
                // Exact inverse of the pop above: the slot goes back on the
                // free-list head it came from. It deliberately does not enter
                // the ownership-audit quarantine — this slot already served
                // its quarantine round before it was popped, and a failed
                // intern must leave the free list exactly as it found it.
                entry.bytes = &.{};
                entry.occupied = false;
                entry.weakref_count = 0;
                entry.next_free = self.free_slot_head;
                self.free_slot_head = idx;
            }
            if (index_entry) self.indexEntry(idx, lookup_hash);
            if (atom_kind == .private and entry.id.raw() < self.first_private_dynamic_atom.raw()) {
                self.first_private_dynamic_atom = entry.id;
            }
            return entry.id;
        }

        const id = self.next_id;
        self.next_id = Atom.fromRaw(self.next_id.raw() + 1);
        errdefer self.next_id = id;
        const idx = try self.appendEntry(.{
            .id = id,
            .bytes = owned,
            .kind = atom_kind,
            .occupied = true,
            .no_symbol_description = no_symbol_description,
        });
        errdefer self.entries = self.entries[0..idx];
        self.stampBirthEpoch(&self.entries[idx]);
        if (index_entry) self.indexEntry(idx, lookup_hash);
        if (atom_kind == .private and id.raw() < self.first_private_dynamic_atom.raw()) {
            self.first_private_dynamic_atom = id;
        }
        return id;
    }

    pub inline fn mightBePrivate(self: *const AtomTable, atom_id: Atom) bool {
        if (atom_id == ids.Private_brand) return true;
        return !atom_id.isTaggedInt() and atom_id.raw() >= self.first_private_dynamic_atom.raw();
    }

    fn appendEntry(self: *AtomTable, entry: DynamicAtom) !EntryIndex {
        const new_used = self.entries.len + 1;
        if (new_used > self.entries_capacity) {
            var new_cap: usize = if (self.entries_capacity == 0) 8 else self.entries_capacity * 2;
            if (new_cap < new_used) new_cap = new_used;
            const new_buf = try self.memory.alloc(DynamicAtom, new_cap);
            const old_entries = self.entries;
            const old_capacity = self.entries_capacity;
            @memcpy(new_buf[0..old_entries.len], old_entries);
            self.entries = new_buf[0..old_entries.len];
            self.entries_capacity = new_cap;
            if (old_capacity != 0) {
                self.memory.free(DynamicAtom, old_entries.ptr[0..old_capacity]);
            }
        }
        const idx: EntryIndex = @intCast(self.entries.len);
        self.entries = self.entries.ptr[0..new_used];
        self.entries[idx] = entry;
        return idx;
    }

    /// Store the spelling hash in the new atom and splice it into its bucket —
    /// the `p->hash = h; p->hash_next = atom_hash[h1]; atom_hash[h1] = i;` of
    /// quickjs.c:3314-3319. Unlike the open-addressed table it replaces this
    /// cannot fail and cannot probe: a create is one head splice.
    fn indexEntry(self: *AtomTable, idx: EntryIndex, hash: u32) void {
        const entry = &self.entries[idx];
        std.debug.assert(entry.kind == .string or entry.kind == .global_symbol);
        entry.hash = hash;
        self.chainInsert(entry.id, hash);
    }

    /// qjs `JS_FreeAtomStruct` (quickjs.c:3387-3409). Symbols and private names
    /// were never chained, so they have nothing to unlink (quickjs.c:3385).
    fn unindexEntry(self: *AtomTable, idx: EntryIndex) void {
        const entry = &self.entries[idx];
        switch (entry.kind) {
            .string, .global_symbol => self.chainUnlink(entry.id, entry.hash),
            .symbol, .private => {},
        }
    }

    fn finalizeDeadEntry(self: *AtomTable, idx: EntryIndex) void {
        const entry = &self.entries[idx];
        self.unindexEntry(idx);
        if (entry.str) |cached| {
            entry.str = null;
            std.debug.assert(cached.atom_id == entry.id);
            cached.atom_id = string.String.no_atom_id;
        }
        const bytes = entry.bytes;
        entry.bytes = &.{};
        if (bytes.len != 0) self.memory.free(u8, bytes);
        entry.occupied = false;
        entry.weakref_count = 0;
        entry.no_symbol_description = false;
        entry.registry_managed_symbol = false;
        // A recycled slot must not inherit the previous tenant's TGC S3
        // stamps; `internDynamic` re-stamps on the way out, this closes the
        // window where a dead slot still reads "marked this epoch".
        entry.mark_epoch = 0;
        entry.born_epoch = 0;
        entry.host_pins = 0;
        // Recycle the slot: nobody holds the id anymore, so the next
        // intern may rebind it. See `internDynamic` for the pop side.
        //
        // Audit builds hold this slot back one round (see
        // `OwnershipAuditState`) so no intern of this round can hand its id
        // straight back and mask a borrowed-atom use-after-free. The branch
        // is written inline, and the default arm below is left exactly as it
        // was, so the default build's codegen is untouched: a `self`+`idx`
        // helper made LLVM reload `self.entries.ptr` here and cost +0.03%
        // instructions on the code-load compile micro.
        if (comptime ownership_audit_enabled) {
            entry.next_free = self.ownership_audit.quarantined_head;
            self.ownership_audit.quarantined_head = idx;
            return;
        }
        entry.next_free = self.free_slot_head;
        self.free_slot_head = idx;
    }

    /// End the current audit quarantine round: every slot retired since the
    /// last call joins the real free list, and the quarantine restarts empty.
    /// Only reachable from audit builds (`sweepDead`); the default build never
    /// references it, so it is never even analyzed.
    fn releaseQuarantinedSlots(self: *AtomTable) void {
        comptime std.debug.assert(ownership_audit_enabled);
        var idx = self.ownership_audit.quarantined_head;
        self.ownership_audit.quarantined_head = no_free_slot;
        while (idx != no_free_slot) {
            const entry = &self.entries[idx];
            std.debug.assert(!entry.slotOccupied());
            const next = entry.next_free;
            entry.next_free = self.free_slot_head;
            self.free_slot_head = idx;
            idx = next;
        }
    }

    fn findDynamic(self: *AtomTable, atom: Atom) ?*DynamicAtom {
        const idx = dynamicEntryIndex(atom) orelse return null;
        if (idx >= self.entries.len) return null;
        return &self.entries[idx];
    }

    fn findDynamicConst(self: *const AtomTable, atom: Atom) ?*const DynamicAtom {
        const idx = dynamicEntryIndex(atom) orelse return null;
        if (idx >= self.entries.len) return null;
        return &self.entries[idx];
    }

    /// TGC S2 §5.7 atom handshake: the tracer found symbol body `body` unmarked and
    /// `String.destroyCellFromHeader` is about to recycle its cell, so the
    /// entry must stop naming it. Same outcome as the rc-zero path -- a
    /// WeakRef'd entry stays as a weak shell (unindexed, `str = null`, so
    /// `symbolValueIfLive` reports it dead), anything else is finalized --
    /// with no retain/release transition.
    pub fn onSymbolBodyDead(self: *AtomTable, atom_id: Atom, body: *string.String) void {
        std.debug.assert(!atom_id.isConst() and !atom_id.isTaggedInt());
        const idx = dynamicEntryIndex(atom_id) orelse return;
        if (idx >= self.entries.len) return;
        const entry = &self.entries[idx];
        if (!isValueSymbolKind(entry.kind)) {
            // TGC S3 §2.4: the entry does not root its cached body, so losing
            // that cache is a legal event -- drop the binding.
            if (entry.str == body) entry.str = null;
            return;
        }
        if (entry.str != body) return;
        if (entry.weakref_count != 0) {
            self.unindexEntry(@intCast(idx));
            entry.str = null;
            entry.occupied = false;
            return;
        }
        self.finalizeDeadEntry(@intCast(idx));
    }
};

/// TGC S3 §2.2 "编译作用域 provider" (K/L/M): a precise root for every atom id
/// the compile front end is holding in plain `u32` fields.
///
/// The parser/lexer/compiler chain (lexer token -> `FunctionDef` -> builder ->
/// `resolve_variables`/`resolve_labels` -> published `FunctionBytecode`) parks
/// atom ids in Zig-heap structs that the conservative stack scan cannot read
/// as roots and that carry no tracer edge until the `FunctionBytecode` is
/// published, so a major inside a compile would retire them mid-flight. This scope is the interval root: every id the
/// compile OBTAINS is recorded (including ids that already existed -- an atom
/// whose only other holder dies during the compile must not be swept), and the
/// registered provider reports the whole list on every trace.
///
/// Recording is ambient: `AtomTable.compile_scope` points at the innermost
/// active scope and every intern/dup entry point notes into it, so the ~267
/// compile-side call sites need no signature change and none can be missed.
/// Scopes nest (direct eval, sub-parse); each one registers its own provider,
/// so an inner scope's death cannot orphan an outer scope's ids.
///
/// `rt == null` (the standalone `AtomTable` the parser/compiler fixtures build,
/// which has no collector at all) degrades to record-only: no registration, no
/// provider, and the list is still kept so the type behaves identically.
pub const CompileAtomScope = struct {
    /// Power of two; `note` masks with `recent_slots - 1`.
    const recent_slots: u32 = 64;

    rt: ?*runtime_mod.JSRuntime,
    table: *AtomTable,
    allocator: std.mem.Allocator,
    ids: std.ArrayListUnmanaged(Atom) = .empty,
    /// Ambient chain: the scope that was installed on the table when this one
    /// activated. Restored on `deinit`.
    prev: ?*CompileAtomScope = null,
    active: bool = false,
    registered: bool = false,
    /// Direct-mapped "already in `ids`" filter. A compile re-obtains the same
    /// identifier constantly (every `get_field`, every scope-var resolution),
    /// so without a filter a large file appends millions of entries. A hit is
    /// exact -- the slot only ever holds an id this scope really appended --
    /// so a miss costs a duplicate list entry, never a missing root.
    /// Measured: the 1.2 MB `typescript-compiler.js` records 27,875 ids
    /// (~112 KB) for one compile, roughly 2x its distinct-identifier count.
    recent: [recent_slots]Atom = @splat(null_atom),

    /// Build a detached scope. `activate` must run once the scope sits at its
    /// final address -- the provider stores `&self`, so a scope that is still
    /// going to be moved (e.g. a `State` returned by value) must not register
    /// yet. Mirrors `ReplaceMatchRoots.activate` in exec/string_ops.zig.
    pub fn init(table: *AtomTable) CompileAtomScope {
        const rt = table.owner_runtime;
        return .{
            .rt = rt,
            .table = table,
            .allocator = if (rt) |r| r.memory.persistent_allocator else table.memory.persistent_allocator,
        };
    }

    fn traceRootsThunk(context: *anyopaque, visitor: *runtime_mod.RootVisitor) runtime_mod.RootTraceError!void {
        const self: *CompileAtomScope = @ptrCast(@alignCast(context));
        for (self.ids.items) |id| try visitor.atomRoot(id);
    }

    fn provider(self: *CompileAtomScope) runtime_mod.RootProvider {
        return .{ .context = @ptrCast(self), .trace = traceRootsThunk };
    }

    /// Install as the innermost ambient scope and (when there is a runtime)
    /// register the root provider.
    pub fn activate(self: *CompileAtomScope) !void {
        std.debug.assert(!self.active);
        if (self.rt) |rt| {
            if (comptime runtime_mod.value_root_frames_enabled) {
                try rt.registerRootProvider(self.provider());
                self.registered = true;
            }
        }
        self.prev = self.table.compile_scope;
        self.table.compile_scope = self;
        self.active = true;
    }

    pub fn deinit(self: *CompileAtomScope) void {
        if (self.active) {
            // Scopes are strictly stack-disciplined; anything else means a
            // caller leaked one.
            std.debug.assert(self.table.compile_scope == self);
            self.table.compile_scope = self.prev;
            self.prev = null;
            self.active = false;
        }
        if (self.registered) {
            self.rt.?.unregisterRootProvider(self.provider());
            self.registered = false;
        }
        self.ids.deinit(self.allocator);
        self.ids = .empty;
        self.recent = @splat(null_atom);
    }

    /// Record an id the compile obtained. Predefined and tagged-int ids are
    /// not table entries and can never be retired, so they are dropped here
    /// rather than growing the list.
    pub fn note(self: *CompileAtomScope, id: Atom) void {
        if (id == null_atom or id.isConst() or id.isTaggedInt()) return;
        const slot = id.raw() & (recent_slots - 1);
        if (self.recent[slot] == id) return;
        self.ids.append(self.allocator, id) catch {
            // A root list that cannot grow must not silently drop a root.
            // Pin the id for the rest of the runtime instead: over-retention
            // is the only safe direction, and this is an OOM-only path.
            self.table.pinForHost(id);
            return;
        };
        self.recent[slot] = id;
    }

    /// Explicit form of the ambient recording, for a call site that wants the
    /// scope spelled out. The symbol family (`newSymbol`/`internSymbol`, the
    /// parser's private names) needs no wrapper: those entry points note into
    /// the ambient scope like every other one.
    pub fn intern(self: *CompileAtomScope, bytes: []const u8) !Atom {
        const id = try self.table.internString(bytes);
        self.note(id);
        return id;
    }

    /// Explicit form for an id the scope did not intern itself (the caller
    /// obtained it before the scope opened).
    pub fn noteExisting(self: *CompileAtomScope, id: Atom) Atom {
        self.note(id);
        return id;
    }
};

/// TGC S3 §2.2: the comptime shell every `traceChildEdges` uses to report an
/// atom edge. A visitor without a `visitAtom` decl (the cycle-collector mark
/// visitor, the census walkers, the minor audit) skips silently, exactly like
/// `callVisitShape` does.
pub inline fn callVisitAtom(vis: anytype, id: Atom) !void {
    const VisType = @TypeOf(vis);
    const CleanType = comptime if (@typeInfo(VisType) == .pointer) @typeInfo(VisType).pointer.child else VisType;
    if (comptime @hasDecl(CleanType, "visitAtom")) {
        const ReturnType = @typeInfo(@TypeOf(CleanType.visitAtom)).@"fn".return_type.?;
        if (comptime @typeInfo(ReturnType) == .error_union) {
            try vis.visitAtom(id);
        } else {
            vis.visitAtom(id);
        }
    }
}

fn dynamicEntryIndex(atom_id: Atom) ?usize {
    if (atom_id.isConst() or atom_id.isTaggedInt()) return null;
    return atom_id.raw() - first_dynamic_atom;
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

fn parseArrayIndex(bytes: []const u8) ?u32 {
    // Leading-digit gate before any scan work, mirroring qjs JS_NewAtomLen
    // (quickjs.c:3465 `is_digit(*str)`): identifier spellings bail here.
    if (bytes.len == 0 or bytes[0] < '0' or bytes[0] > '9') return null;
    if (bytes.len > 1 and bytes[0] == '0') return null;
    var n: u64 = 0;
    for (bytes) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
        if (n > max_int_atom) return null;
    }
    return @intCast(n);
}

/// Upper bound of a JS array index (2^32-2). Mirrors `array.max_array_index`;
/// duplicated here to keep the atom layer free of an `array.zig` import cycle.
pub const max_array_index: u32 = 0xffff_fffe;

/// Like `parseArrayIndex` but bounded by the full array-index range
/// (`max_array_index`) instead of the tighter tagged-int range (`max_int_atom`).
/// Matches `array.arrayIndexFromName`, used by `atomIsArrayIndex` for the high
/// string-atom index window `(max_int_atom, max_array_index]` that stays a
/// dynamic string atom (never tagged at intern time).
fn parseHighArrayIndex(bytes: []const u8) ?u32 {
    if (bytes.len == 0) return null;
    if (bytes.len > 1 and bytes[0] == '0') return null;
    var n: u64 = 0;
    for (bytes) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
        if (n > max_array_index) return null;
    }
    return @intCast(n);
}

// Atom-list helpers shared by the VM operation clusters (moved from the
// dissolved exec/vm_utils.zig).

pub fn atomListContains(list: []const Atom, needle: Atom) bool {
    for (list) |atom_id| {
        if (atom_id == needle) return true;
    }
    return false;
}

pub fn appendAtom(rt: *JSRuntime, list: *[]Atom, atom_id: Atom) !void {
    const next = try rt.memory.alloc(Atom, list.len + 1);
    errdefer rt.memory.free(Atom, next);
    @memcpy(next[0..list.len], list.*);
    next[list.len] = atom_id;
    const old = list.*;
    list.* = next;
    if (old.len != 0) rt.memory.free(Atom, old);
}

pub fn freeAtomList(rt: *JSRuntime, list: []Atom) void {
    if (list.len != 0) rt.memory.free(Atom, list);
}

/// Alias for the call sites that still name the "owned" form. Atoms carry no
/// per-reference count under the tracing collector, so appending an owned atom
/// and appending a borrowed one were already the same byte-for-byte routine.
pub const appendOwnedAtom = appendAtom;
