const memory = @import("memory.zig");
const string = @import("string.zig");
const JSValue = @import("value.zig").JSValue;

pub const Atom = u32;

pub const null_atom: Atom = 0;
pub const tagged_int_bit: Atom = 1 << 31;
pub const max_int_atom: Atom = tagged_int_bit - 1;

pub const AtomKind = enum {
    string,
    symbol,
    private,
};

pub const PredefinedAtom = struct {
    id: Atom,
    name: []const u8,
    kind: AtomKind = .string,
};

pub const ids = struct {
    pub const null_: Atom = 1;
    pub const false_: Atom = 2;
    pub const true_: Atom = 3;
    pub const if_: Atom = 4;
    pub const super: Atom = 36;
    pub const yield: Atom = 45;
    pub const await: Atom = 46;
    pub const empty_string: Atom = 47;
    pub const length: Atom = 50;
    pub const name: Atom = 55;
    pub const prototype: Atom = 60;
    pub const constructor: Atom = 61;
    pub const undefined_: Atom = 70;
    pub const arguments: Atom = 78;
    pub const lastIndex: Atom = 86;
    pub const source: Atom = 109;
    pub const rawJSON: Atom = 114;
    pub const toJSON: Atom = 147;
    pub const Object: Atom = 151;
    pub const Array: Atom = 152;
    pub const Error: Atom = 153;
    pub const Function: Atom = 162;
    pub const Map: Atom = 184;
    pub const Set: Atom = 185;
    pub const WeakMap: Atom = 186;
    pub const WeakSet: Atom = 187;
    pub const Private_brand: Atom = 216;
    pub const Symbol_toPrimitive: Atom = 217;
    pub const Symbol_iterator: Atom = 218;
    pub const Symbol_asyncIterator: Atom = 229;
    pub const Symbol_asyncDispose: Atom = 230;
    pub const Symbol_dispose: Atom = 231;
    pub const zjs_proto_keepalive: Atom = 232;
    pub const zjs_last_internal_marker: Atom = 264;
    pub const zjs_last_registry_name: Atom = 364;
    pub const zjs_last_global_setup_name: Atom = 381;
    pub const zjs_last_global_extra_name: Atom = 419;
    pub const zjs_last_registry_extra_name: Atom = 586;
    pub const scriptArgs: Atom = 626;
    pub const zjs_last_startup_name: Atom = 656;
};

pub const last_keyword = ids.await;
pub const last_strict_keyword = ids.yield;
pub const predefined_count = predefined_atoms.len;
pub const first_dynamic_atom = predefined_count + 1;

pub const predefined_atoms = [_]PredefinedAtom{
    .{ .id = 1, .name = "null" },
    .{ .id = 2, .name = "false" },
    .{ .id = 3, .name = "true" },
    .{ .id = 4, .name = "if" },
    .{ .id = 5, .name = "else" },
    .{ .id = 6, .name = "return" },
    .{ .id = 7, .name = "var" },
    .{ .id = 8, .name = "this" },
    .{ .id = 9, .name = "delete" },
    .{ .id = 10, .name = "void" },
    .{ .id = 11, .name = "typeof" },
    .{ .id = 12, .name = "new" },
    .{ .id = 13, .name = "in" },
    .{ .id = 14, .name = "instanceof" },
    .{ .id = 15, .name = "do" },
    .{ .id = 16, .name = "while" },
    .{ .id = 17, .name = "for" },
    .{ .id = 18, .name = "break" },
    .{ .id = 19, .name = "continue" },
    .{ .id = 20, .name = "switch" },
    .{ .id = 21, .name = "case" },
    .{ .id = 22, .name = "default" },
    .{ .id = 23, .name = "throw" },
    .{ .id = 24, .name = "try" },
    .{ .id = 25, .name = "catch" },
    .{ .id = 26, .name = "finally" },
    .{ .id = 27, .name = "function" },
    .{ .id = 28, .name = "debugger" },
    .{ .id = 29, .name = "with" },
    .{ .id = 30, .name = "class" },
    .{ .id = 31, .name = "const" },
    .{ .id = 32, .name = "enum" },
    .{ .id = 33, .name = "export" },
    .{ .id = 34, .name = "extends" },
    .{ .id = 35, .name = "import" },
    .{ .id = 36, .name = "super" },
    .{ .id = 37, .name = "implements" },
    .{ .id = 38, .name = "interface" },
    .{ .id = 39, .name = "let" },
    .{ .id = 40, .name = "package" },
    .{ .id = 41, .name = "private" },
    .{ .id = 42, .name = "protected" },
    .{ .id = 43, .name = "public" },
    .{ .id = 44, .name = "static" },
    .{ .id = 45, .name = "yield" },
    .{ .id = 46, .name = "await" },
    .{ .id = 47, .name = "" },
    .{ .id = 48, .name = "keys" },
    .{ .id = 49, .name = "size" },
    .{ .id = 50, .name = "length" },
    .{ .id = 51, .name = "message" },
    .{ .id = 52, .name = "cause" },
    .{ .id = 53, .name = "errors" },
    .{ .id = 54, .name = "stack" },
    .{ .id = 55, .name = "name" },
    .{ .id = 56, .name = "toString" },
    .{ .id = 57, .name = "toLocaleString" },
    .{ .id = 58, .name = "valueOf" },
    .{ .id = 59, .name = "eval" },
    .{ .id = 60, .name = "prototype" },
    .{ .id = 61, .name = "constructor" },
    .{ .id = 62, .name = "configurable" },
    .{ .id = 63, .name = "writable" },
    .{ .id = 64, .name = "enumerable" },
    .{ .id = 65, .name = "value" },
    .{ .id = 66, .name = "get" },
    .{ .id = 67, .name = "set" },
    .{ .id = 68, .name = "of" },
    .{ .id = 69, .name = "__proto__" },
    .{ .id = 70, .name = "undefined" },
    .{ .id = 71, .name = "number" },
    .{ .id = 72, .name = "boolean" },
    .{ .id = 73, .name = "string" },
    .{ .id = 74, .name = "object" },
    .{ .id = 75, .name = "symbol" },
    .{ .id = 76, .name = "integer" },
    .{ .id = 77, .name = "unknown" },
    .{ .id = 78, .name = "arguments" },
    .{ .id = 79, .name = "callee" },
    .{ .id = 80, .name = "caller" },
    .{ .id = 81, .name = "<eval>" },
    .{ .id = 82, .name = "<ret>" },
    .{ .id = 83, .name = "<var>" },
    .{ .id = 84, .name = "<arg_var>" },
    .{ .id = 85, .name = "<with>" },
    .{ .id = 86, .name = "lastIndex" },
    .{ .id = 87, .name = "target" },
    .{ .id = 88, .name = "index" },
    .{ .id = 89, .name = "input" },
    .{ .id = 90, .name = "defineProperties" },
    .{ .id = 91, .name = "apply" },
    .{ .id = 92, .name = "join" },
    .{ .id = 93, .name = "concat" },
    .{ .id = 94, .name = "split" },
    .{ .id = 95, .name = "construct" },
    .{ .id = 96, .name = "getPrototypeOf" },
    .{ .id = 97, .name = "setPrototypeOf" },
    .{ .id = 98, .name = "isExtensible" },
    .{ .id = 99, .name = "preventExtensions" },
    .{ .id = 100, .name = "has" },
    .{ .id = 101, .name = "deleteProperty" },
    .{ .id = 102, .name = "defineProperty" },
    .{ .id = 103, .name = "getOwnPropertyDescriptor" },
    .{ .id = 104, .name = "ownKeys" },
    .{ .id = 105, .name = "add" },
    .{ .id = 106, .name = "done" },
    .{ .id = 107, .name = "next" },
    .{ .id = 108, .name = "values" },
    .{ .id = 109, .name = "source" },
    .{ .id = 110, .name = "flags" },
    .{ .id = 111, .name = "global" },
    .{ .id = 112, .name = "unicode" },
    .{ .id = 113, .name = "raw" },
    .{ .id = 114, .name = "rawJSON" },
    .{ .id = 115, .name = "new.target" },
    .{ .id = 116, .name = "this.active_func" },
    .{ .id = 117, .name = "<home_object>" },
    .{ .id = 118, .name = "<computed_field>" },
    .{ .id = 119, .name = "<static_computed_field>" },
    .{ .id = 120, .name = "<class_fields_init>" },
    .{ .id = 121, .name = "<brand>" },
    .{ .id = 122, .name = "#constructor" },
    .{ .id = 123, .name = "as" },
    .{ .id = 124, .name = "from" },
    .{ .id = 125, .name = "fromAsync" },
    .{ .id = 126, .name = "meta" },
    .{ .id = 127, .name = "*default*" },
    .{ .id = 128, .name = "*" },
    .{ .id = 129, .name = "Module" },
    .{ .id = 130, .name = "then" },
    .{ .id = 131, .name = "resolve" },
    .{ .id = 132, .name = "reject" },
    .{ .id = 133, .name = "promise" },
    .{ .id = 134, .name = "proxy" },
    .{ .id = 135, .name = "revoke" },
    .{ .id = 136, .name = "async" },
    .{ .id = 137, .name = "exec" },
    .{ .id = 138, .name = "groups" },
    .{ .id = 139, .name = "indices" },
    .{ .id = 140, .name = "status" },
    .{ .id = 141, .name = "reason" },
    .{ .id = 142, .name = "globalThis" },
    .{ .id = 143, .name = "bigint" },
    .{ .id = 144, .name = "not-equal" },
    .{ .id = 145, .name = "timed-out" },
    .{ .id = 146, .name = "ok" },
    .{ .id = 147, .name = "toJSON" },
    .{ .id = 148, .name = "maxByteLength" },
    .{ .id = 149, .name = "zip" },
    .{ .id = 150, .name = "zipKeyed" },
    .{ .id = 151, .name = "Object" },
    .{ .id = 152, .name = "Array" },
    .{ .id = 153, .name = "Error" },
    .{ .id = 154, .name = "Number" },
    .{ .id = 155, .name = "String" },
    .{ .id = 156, .name = "Boolean" },
    .{ .id = 157, .name = "Symbol" },
    .{ .id = 158, .name = "Arguments" },
    .{ .id = 159, .name = "Math" },
    .{ .id = 160, .name = "JSON" },
    .{ .id = 161, .name = "Date" },
    .{ .id = 162, .name = "Function" },
    .{ .id = 163, .name = "GeneratorFunction" },
    .{ .id = 164, .name = "ForInIterator" },
    .{ .id = 165, .name = "RegExp" },
    .{ .id = 166, .name = "ArrayBuffer" },
    .{ .id = 167, .name = "SharedArrayBuffer" },
    .{ .id = 168, .name = "Uint8ClampedArray" },
    .{ .id = 169, .name = "Int8Array" },
    .{ .id = 170, .name = "Uint8Array" },
    .{ .id = 171, .name = "Int16Array" },
    .{ .id = 172, .name = "Uint16Array" },
    .{ .id = 173, .name = "Int32Array" },
    .{ .id = 174, .name = "Uint32Array" },
    .{ .id = 175, .name = "BigInt64Array" },
    .{ .id = 176, .name = "BigUint64Array" },
    .{ .id = 177, .name = "Float16Array" },
    .{ .id = 178, .name = "Float32Array" },
    .{ .id = 179, .name = "Float64Array" },
    .{ .id = 180, .name = "DataView" },
    .{ .id = 181, .name = "BigInt" },
    .{ .id = 182, .name = "WeakRef" },
    .{ .id = 183, .name = "FinalizationRegistry" },
    .{ .id = 184, .name = "Map" },
    .{ .id = 185, .name = "Set" },
    .{ .id = 186, .name = "WeakMap" },
    .{ .id = 187, .name = "WeakSet" },
    .{ .id = 188, .name = "Iterator" },
    .{ .id = 189, .name = "Iterator Concat" },
    .{ .id = 190, .name = "Iterator Helper" },
    .{ .id = 191, .name = "Iterator Wrap" },
    .{ .id = 192, .name = "Map Iterator" },
    .{ .id = 193, .name = "Set Iterator" },
    .{ .id = 194, .name = "Array Iterator" },
    .{ .id = 195, .name = "String Iterator" },
    .{ .id = 196, .name = "RegExp String Iterator" },
    .{ .id = 197, .name = "Generator" },
    .{ .id = 198, .name = "Proxy" },
    .{ .id = 199, .name = "Promise" },
    .{ .id = 200, .name = "PromiseResolveFunction" },
    .{ .id = 201, .name = "PromiseRejectFunction" },
    .{ .id = 202, .name = "AsyncFunction" },
    .{ .id = 203, .name = "AsyncFunctionResolve" },
    .{ .id = 204, .name = "AsyncFunctionReject" },
    .{ .id = 205, .name = "AsyncGeneratorFunction" },
    .{ .id = 206, .name = "AsyncGenerator" },
    .{ .id = 207, .name = "EvalError" },
    .{ .id = 208, .name = "RangeError" },
    .{ .id = 209, .name = "ReferenceError" },
    .{ .id = 210, .name = "SyntaxError" },
    .{ .id = 211, .name = "TypeError" },
    .{ .id = 212, .name = "URIError" },
    .{ .id = 213, .name = "InternalError" },
    .{ .id = 214, .name = "DOMException" },
    .{ .id = 215, .name = "CallSite" },
    .{ .id = 216, .name = "<brand>", .kind = .private },
    .{ .id = 217, .name = "Symbol.toPrimitive", .kind = .symbol },
    .{ .id = 218, .name = "Symbol.iterator", .kind = .symbol },
    .{ .id = 219, .name = "Symbol.match", .kind = .symbol },
    .{ .id = 220, .name = "Symbol.matchAll", .kind = .symbol },
    .{ .id = 221, .name = "Symbol.replace", .kind = .symbol },
    .{ .id = 222, .name = "Symbol.search", .kind = .symbol },
    .{ .id = 223, .name = "Symbol.split", .kind = .symbol },
    .{ .id = 224, .name = "Symbol.toStringTag", .kind = .symbol },
    .{ .id = 225, .name = "Symbol.isConcatSpreadable", .kind = .symbol },
    .{ .id = 226, .name = "Symbol.hasInstance", .kind = .symbol },
    .{ .id = 227, .name = "Symbol.species", .kind = .symbol },
    .{ .id = 228, .name = "Symbol.unscopables", .kind = .symbol },
    .{ .id = 229, .name = "Symbol.asyncIterator", .kind = .symbol },
    .{ .id = 230, .name = "Symbol.asyncDispose", .kind = .symbol },
    .{ .id = 231, .name = "Symbol.dispose", .kind = .symbol },
    .{ .id = 232, .name = "__zjs_proto_keepalive" },
    .{ .id = 233, .name = "__zjs_BigInt_proto" },
    .{ .id = 234, .name = "__zjs_Boolean_proto" },
    .{ .id = 235, .name = "__zjs_Number_proto" },
    .{ .id = 236, .name = "__zjs_String_proto" },
    .{ .id = 237, .name = "__zjs_Symbol_proto" },
    .{ .id = 238, .name = "__zjs_array_concat" },
    .{ .id = 239, .name = "__zjs_array_constructor" },
    .{ .id = 240, .name = "__zjs_array_iterator_kind" },
    .{ .id = 241, .name = "__zjs_array_species_getter" },
    .{ .id = 242, .name = "__zjs_array_to_locale_string" },
    .{ .id = 243, .name = "__zjs_array_to_string" },
    .{ .id = 244, .name = "__zjs_arraybuffer_proto" },
    .{ .id = 245, .name = "__zjs_atomics_static" },
    .{ .id = 246, .name = "__zjs_buffer_method_kind" },
    .{ .id = 247, .name = "__zjs_define_property_kind" },
    .{ .id = 248, .name = "__zjs_error_to_string" },
    .{ .id = 249, .name = "__zjs_function_to_string" },
    .{ .id = 250, .name = "__zjs_immutable_prototype" },
    .{ .id = 251, .name = "__zjs_iterator_accessor" },
    .{ .id = 252, .name = "__zjs_iterator_method" },
    .{ .id = 253, .name = "__zjs_iterator_static" },
    .{ .id = 254, .name = "__zjs_json_static" },
    .{ .id = 255, .name = "__zjs_number_method" },
    .{ .id = 256, .name = "__zjs_object_method" },
    .{ .id = 257, .name = "__zjs_object_static" },
    .{ .id = 258, .name = "__zjs_primitive_method" },
    .{ .id = 259, .name = "__zjs_reflect_set_prototype_of" },
    .{ .id = 260, .name = "__zjs_reflect_static" },
    .{ .id = 261, .name = "__zjs_regexp_method" },
    .{ .id = 262, .name = "__zjs_string_method" },
    .{ .id = 263, .name = "__zjs_typedarray_method" },
    .{ .id = 264, .name = "__zjs_typedarray_static" },
    .{ .id = 265, .name = "assign" },
    .{ .id = 266, .name = "create" },
    .{ .id = 267, .name = "getOwnPropertyDescriptors" },
    .{ .id = 268, .name = "getOwnPropertyNames" },
    .{ .id = 269, .name = "getOwnPropertySymbols" },
    .{ .id = 270, .name = "hasOwn" },
    .{ .id = 271, .name = "seal" },
    .{ .id = 272, .name = "isSealed" },
    .{ .id = 273, .name = "isFrozen" },
    .{ .id = 274, .name = "freeze" },
    .{ .id = 275, .name = "fromEntries" },
    .{ .id = 276, .name = "groupBy" },
    .{ .id = 277, .name = "hasOwnProperty" },
    .{ .id = 278, .name = "isPrototypeOf" },
    .{ .id = 279, .name = "propertyIsEnumerable" },
    .{ .id = 280, .name = "__defineGetter__" },
    .{ .id = 281, .name = "__defineSetter__" },
    .{ .id = 282, .name = "__lookupGetter__" },
    .{ .id = 283, .name = "__lookupSetter__" },
    .{ .id = 284, .name = "bind" },
    .{ .id = 285, .name = "isArray" },
    .{ .id = 286, .name = "map" },
    .{ .id = 287, .name = "filter" },
    .{ .id = 288, .name = "reduce" },
    .{ .id = 289, .name = "reduceRight" },
    .{ .id = 290, .name = "forEach" },
    .{ .id = 291, .name = "push" },
    .{ .id = 292, .name = "pop" },
    .{ .id = 293, .name = "shift" },
    .{ .id = 294, .name = "unshift" },
    .{ .id = 295, .name = "some" },
    .{ .id = 296, .name = "every" },
    .{ .id = 297, .name = "find" },
    .{ .id = 298, .name = "findIndex" },
    .{ .id = 299, .name = "findLast" },
    .{ .id = 300, .name = "findLastIndex" },
    .{ .id = 301, .name = "includes" },
    .{ .id = 302, .name = "indexOf" },
    .{ .id = 303, .name = "lastIndexOf" },
    .{ .id = 304, .name = "at" },
    .{ .id = 305, .name = "copyWithin" },
    .{ .id = 306, .name = "fill" },
    .{ .id = 307, .name = "slice" },
    .{ .id = 308, .name = "splice" },
    .{ .id = 309, .name = "reverse" },
    .{ .id = 310, .name = "sort" },
    .{ .id = 311, .name = "flat" },
    .{ .id = 312, .name = "flatMap" },
    .{ .id = 313, .name = "toReversed" },
    .{ .id = 314, .name = "toSorted" },
    .{ .id = 315, .name = "toSpliced" },
    .{ .id = 316, .name = "fromCharCode" },
    .{ .id = 317, .name = "fromCodePoint" },
    .{ .id = 318, .name = "charAt" },
    .{ .id = 319, .name = "charCodeAt" },
    .{ .id = 320, .name = "codePointAt" },
    .{ .id = 321, .name = "substring" },
    .{ .id = 322, .name = "toUpperCase" },
    .{ .id = 323, .name = "toLowerCase" },
    .{ .id = 324, .name = "toLocaleUpperCase" },
    .{ .id = 325, .name = "toLocaleLowerCase" },
    .{ .id = 326, .name = "startsWith" },
    .{ .id = 327, .name = "endsWith" },
    .{ .id = 328, .name = "localeCompare" },
    .{ .id = 329, .name = "repeat" },
    .{ .id = 330, .name = "padStart" },
    .{ .id = 331, .name = "padEnd" },
    .{ .id = 332, .name = "normalize" },
    .{ .id = 333, .name = "isWellFormed" },
    .{ .id = 334, .name = "toWellFormed" },
    .{ .id = 335, .name = "trim" },
    .{ .id = 336, .name = "trimStart" },
    .{ .id = 337, .name = "trimEnd" },
    .{ .id = 338, .name = "anchor" },
    .{ .id = 339, .name = "big" },
    .{ .id = 340, .name = "blink" },
    .{ .id = 341, .name = "bold" },
    .{ .id = 342, .name = "fixed" },
    .{ .id = 343, .name = "fontcolor" },
    .{ .id = 344, .name = "fontsize" },
    .{ .id = 345, .name = "italics" },
    .{ .id = 346, .name = "link" },
    .{ .id = 347, .name = "small" },
    .{ .id = 348, .name = "strike" },
    .{ .id = 349, .name = "substr" },
    .{ .id = 350, .name = "replace" },
    .{ .id = 351, .name = "replaceAll" },
    .{ .id = 352, .name = "sup" },
    .{ .id = 353, .name = "isInteger" },
    .{ .id = 354, .name = "isSafeInteger" },
    .{ .id = 355, .name = "toFixed" },
    .{ .id = 356, .name = "toExponential" },
    .{ .id = 357, .name = "toPrecision" },
    .{ .id = 358, .name = "asIntN" },
    .{ .id = 359, .name = "asUintN" },
    .{ .id = 360, .name = "revocable" },
    .{ .id = 361, .name = "getTime" },
    .{ .id = 362, .name = "getTimezoneOffset" },
    .{ .id = 363, .name = "setTime" },
    .{ .id = 364, .name = "toISOString" },
    .{ .id = 365, .name = "Reflect" },
    .{ .id = 366, .name = "Atomics" },
    .{ .id = 367, .name = "performance" },
    .{ .id = 368, .name = "print" },
    .{ .id = 369, .name = "console" },
    .{ .id = 370, .name = "now" },
    .{ .id = 371, .name = "timeOrigin" },
    .{ .id = 372, .name = "decodeURI" },
    .{ .id = 373, .name = "decodeURIComponent" },
    .{ .id = 374, .name = "encodeURI" },
    .{ .id = 375, .name = "encodeURIComponent" },
    .{ .id = 376, .name = "escape" },
    .{ .id = 377, .name = "unescape" },
    .{ .id = 378, .name = "isNaN" },
    .{ .id = 379, .name = "isFinite" },
    .{ .id = 380, .name = "parseInt" },
    .{ .id = 381, .name = "parseFloat" },
    .{ .id = 382, .name = "btoa" },
    .{ .id = 383, .name = "atob" },
    .{ .id = 384, .name = "queueMicrotask" },
    .{ .id = 385, .name = "gc" },
    .{ .id = 386, .name = "navigator" },
    .{ .id = 387, .name = "NaN" },
    .{ .id = 388, .name = "POSITIVE_INFINITY" },
    .{ .id = 389, .name = "NEGATIVE_INFINITY" },
    .{ .id = 390, .name = "MAX_VALUE" },
    .{ .id = 391, .name = "MIN_VALUE" },
    .{ .id = 392, .name = "MAX_SAFE_INTEGER" },
    .{ .id = 393, .name = "MIN_SAFE_INTEGER" },
    .{ .id = 394, .name = "EPSILON" },
    .{ .id = 395, .name = "description" },
    .{ .id = 396, .name = "sub" },
    .{ .id = 397, .name = "match" },
    .{ .id = 398, .name = "matchAll" },
    .{ .id = 399, .name = "search" },
    .{ .id = 400, .name = "UTC" },
    .{ .id = 401, .name = "parse" },
    .{ .id = 402, .name = "getFullYear" },
    .{ .id = 403, .name = "getMonth" },
    .{ .id = 404, .name = "getDate" },
    .{ .id = 405, .name = "getDay" },
    .{ .id = 406, .name = "getHours" },
    .{ .id = 407, .name = "getMinutes" },
    .{ .id = 408, .name = "and" },
    .{ .id = 409, .name = "compareExchange" },
    .{ .id = 410, .name = "exchange" },
    .{ .id = 411, .name = "isLockFree" },
    .{ .id = 412, .name = "load" },
    .{ .id = 413, .name = "notify" },
    .{ .id = 414, .name = "or" },
    .{ .id = 415, .name = "pause" },
    .{ .id = 416, .name = "store" },
    .{ .id = 417, .name = "wait" },
    .{ .id = 418, .name = "waitAsync" },
    .{ .id = 419, .name = "xor" },
    .{ .id = 420, .name = "ABORT_ERR" },
    .{ .id = 421, .name = "AggregateError" },
    .{ .id = 422, .name = "DATA_CLONE_ERR" },
    .{ .id = 423, .name = "DOMSTRING_SIZE_ERR" },
    .{ .id = 424, .name = "HIERARCHY_REQUEST_ERR" },
    .{ .id = 425, .name = "INDEX_SIZE_ERR" },
    .{ .id = 426, .name = "INUSE_ATTRIBUTE_ERR" },
    .{ .id = 427, .name = "INVALID_ACCESS_ERR" },
    .{ .id = 428, .name = "INVALID_CHARACTER_ERR" },
    .{ .id = 429, .name = "INVALID_MODIFICATION_ERR" },
    .{ .id = 430, .name = "INVALID_NODE_TYPE_ERR" },
    .{ .id = 431, .name = "INVALID_STATE_ERR" },
    .{ .id = 432, .name = "NAMESPACE_ERR" },
    .{ .id = 433, .name = "NETWORK_ERR" },
    .{ .id = 434, .name = "NOT_FOUND_ERR" },
    .{ .id = 435, .name = "NOT_SUPPORTED_ERR" },
    .{ .id = 436, .name = "NO_DATA_ALLOWED_ERR" },
    .{ .id = 437, .name = "NO_MODIFICATION_ALLOWED_ERR" },
    .{ .id = 438, .name = "QUOTA_EXCEEDED_ERR" },
    .{ .id = 439, .name = "SECURITY_ERR" },
    .{ .id = 440, .name = "SYNTAX_ERR" },
    .{ .id = 441, .name = "TIMEOUT_ERR" },
    .{ .id = 442, .name = "TYPE_MISMATCH_ERR" },
    .{ .id = 443, .name = "TypedArray" },
    .{ .id = 444, .name = "URL_MISMATCH_ERR" },
    .{ .id = 445, .name = "VALIDATION_ERR" },
    .{ .id = 446, .name = "WRONG_DOCUMENT_ERR" },
    .{ .id = 447, .name = "[Symbol.matchAll]" },
    .{ .id = 448, .name = "[Symbol.match]" },
    .{ .id = 449, .name = "[Symbol.replace]" },
    .{ .id = 450, .name = "[Symbol.search]" },
    .{ .id = 451, .name = "[Symbol.split]" },
    .{ .id = 452, .name = "abs" },
    .{ .id = 453, .name = "acos" },
    .{ .id = 454, .name = "acosh" },
    .{ .id = 455, .name = "all" },
    .{ .id = 456, .name = "allSettled" },
    .{ .id = 457, .name = "any" },
    .{ .id = 458, .name = "asin" },
    .{ .id = 459, .name = "asinh" },
    .{ .id = 460, .name = "atan" },
    .{ .id = 461, .name = "atan2" },
    .{ .id = 462, .name = "atanh" },
    .{ .id = 463, .name = "call" },
    .{ .id = 464, .name = "captureStackTrace" },
    .{ .id = 465, .name = "cbrt" },
    .{ .id = 466, .name = "ceil" },
    .{ .id = 467, .name = "clear" },
    .{ .id = 468, .name = "clz32" },
    .{ .id = 469, .name = "compile" },
    .{ .id = 470, .name = "cos" },
    .{ .id = 471, .name = "cosh" },
    .{ .id = 472, .name = "deref" },
    .{ .id = 473, .name = "difference" },
    .{ .id = 474, .name = "drop" },
    .{ .id = 475, .name = "entries" },
    .{ .id = 476, .name = "exp" },
    .{ .id = 477, .name = "expm1" },
    .{ .id = 478, .name = "f16round" },
    .{ .id = 479, .name = "floor" },
    .{ .id = 480, .name = "fromBase64" },
    .{ .id = 481, .name = "fromHex" },
    .{ .id = 482, .name = "fround" },
    .{ .id = 483, .name = "getBigInt64" },
    .{ .id = 484, .name = "getBigUint64" },
    .{ .id = 485, .name = "getFloat16" },
    .{ .id = 486, .name = "getFloat32" },
    .{ .id = 487, .name = "getFloat64" },
    .{ .id = 488, .name = "getInt16" },
    .{ .id = 489, .name = "getInt32" },
    .{ .id = 490, .name = "getInt8" },
    .{ .id = 491, .name = "getMilliseconds" },
    .{ .id = 492, .name = "getOrInsert" },
    .{ .id = 493, .name = "getOrInsertComputed" },
    .{ .id = 494, .name = "getSeconds" },
    .{ .id = 495, .name = "getUTCDate" },
    .{ .id = 496, .name = "getUTCDay" },
    .{ .id = 497, .name = "getUTCFullYear" },
    .{ .id = 498, .name = "getUTCHours" },
    .{ .id = 499, .name = "getUTCMilliseconds" },
    .{ .id = 500, .name = "getUTCMinutes" },
    .{ .id = 501, .name = "getUTCMonth" },
    .{ .id = 502, .name = "getUTCSeconds" },
    .{ .id = 503, .name = "getUint16" },
    .{ .id = 504, .name = "getUint32" },
    .{ .id = 505, .name = "getUint8" },
    .{ .id = 506, .name = "getYear" },
    .{ .id = 507, .name = "grow" },
    .{ .id = 508, .name = "hypot" },
    .{ .id = 509, .name = "imul" },
    .{ .id = 510, .name = "intersection" },
    .{ .id = 511, .name = "is" },
    .{ .id = 512, .name = "isDisjointFrom" },
    .{ .id = 513, .name = "isError" },
    .{ .id = 514, .name = "isRawJSON" },
    .{ .id = 515, .name = "isSubsetOf" },
    .{ .id = 516, .name = "isSupersetOf" },
    .{ .id = 517, .name = "isView" },
    .{ .id = 518, .name = "keyFor" },
    .{ .id = 519, .name = "log" },
    .{ .id = 520, .name = "log10" },
    .{ .id = 521, .name = "log1p" },
    .{ .id = 522, .name = "log2" },
    .{ .id = 523, .name = "max" },
    .{ .id = 524, .name = "min" },
    .{ .id = 525, .name = "pow" },
    .{ .id = 526, .name = "race" },
    .{ .id = 527, .name = "random" },
    .{ .id = 528, .name = "register" },
    .{ .id = 529, .name = "resize" },
    .{ .id = 530, .name = "round" },
    .{ .id = 531, .name = "setBigInt64" },
    .{ .id = 532, .name = "setBigUint64" },
    .{ .id = 533, .name = "setDate" },
    .{ .id = 534, .name = "setFloat16" },
    .{ .id = 535, .name = "setFloat32" },
    .{ .id = 536, .name = "setFloat64" },
    .{ .id = 537, .name = "setFromBase64" },
    .{ .id = 538, .name = "setFromHex" },
    .{ .id = 539, .name = "setFullYear" },
    .{ .id = 540, .name = "setHours" },
    .{ .id = 541, .name = "setInt16" },
    .{ .id = 542, .name = "setInt32" },
    .{ .id = 543, .name = "setInt8" },
    .{ .id = 544, .name = "setMilliseconds" },
    .{ .id = 545, .name = "setMinutes" },
    .{ .id = 546, .name = "setMonth" },
    .{ .id = 547, .name = "setSeconds" },
    .{ .id = 548, .name = "setUTCDate" },
    .{ .id = 549, .name = "setUTCFullYear" },
    .{ .id = 550, .name = "setUTCHours" },
    .{ .id = 551, .name = "setUTCMilliseconds" },
    .{ .id = 552, .name = "setUTCMinutes" },
    .{ .id = 553, .name = "setUTCMonth" },
    .{ .id = 554, .name = "setUTCSeconds" },
    .{ .id = 555, .name = "setUint16" },
    .{ .id = 556, .name = "setUint32" },
    .{ .id = 557, .name = "setUint8" },
    .{ .id = 558, .name = "setYear" },
    .{ .id = 559, .name = "sign" },
    .{ .id = 560, .name = "sin" },
    .{ .id = 561, .name = "sinh" },
    .{ .id = 562, .name = "sliceToImmutable" },
    .{ .id = 563, .name = "sqrt" },
    .{ .id = 564, .name = "stringify" },
    .{ .id = 565, .name = "subarray" },
    .{ .id = 566, .name = "sumPrecise" },
    .{ .id = 567, .name = "symmetricDifference" },
    .{ .id = 568, .name = "take" },
    .{ .id = 569, .name = "tan" },
    .{ .id = 570, .name = "tanh" },
    .{ .id = 571, .name = "test" },
    .{ .id = 572, .name = "toArray" },
    .{ .id = 573, .name = "toBase64" },
    .{ .id = 574, .name = "toDateString" },
    .{ .id = 575, .name = "toHex" },
    .{ .id = 576, .name = "toLocaleDateString" },
    .{ .id = 577, .name = "toLocaleTimeString" },
    .{ .id = 578, .name = "toTimeString" },
    .{ .id = 579, .name = "toUTCString" },
    .{ .id = 580, .name = "transfer" },
    .{ .id = 581, .name = "transferToFixedLength" },
    .{ .id = 582, .name = "transferToImmutable" },
    .{ .id = 583, .name = "trunc" },
    .{ .id = 584, .name = "union" },
    .{ .id = 585, .name = "unregister" },
    .{ .id = 586, .name = "withResolvers" },
    .{ .id = 587, .name = "__zjs_native_name" },
    .{ .id = 588, .name = "__zjs_dstr_get" },
    .{ .id = 589, .name = "__zjs_dstr_elide" },
    .{ .id = 590, .name = "__zjs_dstr_rest" },
    .{ .id = 591, .name = "__zjs_dstr_obj_rest" },
    .{ .id = 592, .name = "__zjs_dstr_close" },
    .{ .id = 593, .name = "__zjs_dstr_require_iterator" },
    .{ .id = 594, .name = "trimLeft" },
    .{ .id = 595, .name = "trimRight" },
    .{ .id = 596, .name = "__primitive" },
    .{ .id = 597, .name = "toPrimitive" },
    .{ .id = 598, .name = "species" },
    .{ .id = 599, .name = "iterator" },
    .{ .id = 600, .name = "toStringTag" },
    .{ .id = 601, .name = "isConcatSpreadable" },
    .{ .id = 602, .name = "hasInstance" },
    .{ .id = 603, .name = "unscopables" },
    .{ .id = 604, .name = "asyncIterator" },
    .{ .id = 605, .name = "asyncDispose" },
    .{ .id = 606, .name = "dispose" },
    .{ .id = 607, .name = "toGMTString" },
    .{ .id = 608, .name = "ignoreCase" },
    .{ .id = 609, .name = "multiline" },
    .{ .id = 610, .name = "dotAll" },
    .{ .id = 611, .name = "sticky" },
    .{ .id = 612, .name = "hasIndices" },
    .{ .id = 613, .name = "unicodeSets" },
    .{ .id = 614, .name = "stackTraceLimit" },
    .{ .id = 615, .name = "__zjs_collection_method_owner" },
    .{ .id = 616, .name = "byteLength" },
    .{ .id = 617, .name = "detached" },
    .{ .id = 618, .name = "resizable" },
    .{ .id = 619, .name = "growable" },
    .{ .id = 620, .name = "BYTES_PER_ELEMENT" },
    .{ .id = 621, .name = "buffer" },
    .{ .id = 622, .name = "byteOffset" },
    .{ .id = 623, .name = "Infinity" },
    .{ .id = 624, .name = "__zjs_throw_type_error_function_proto" },
    .{ .id = 625, .name = "__zjs_throw_type_error_intrinsic" },
    .{ .id = 626, .name = "scriptArgs" },
    .{ .id = 627, .name = "$_" },
    .{ .id = 628, .name = "lastMatch" },
    .{ .id = 629, .name = "$&" },
    .{ .id = 630, .name = "lastParen" },
    .{ .id = 631, .name = "$+" },
    .{ .id = 632, .name = "leftContext" },
    .{ .id = 633, .name = "$`" },
    .{ .id = 634, .name = "rightContext" },
    .{ .id = 635, .name = "$'" },
    .{ .id = 636, .name = "$1" },
    .{ .id = 637, .name = "$2" },
    .{ .id = 638, .name = "$3" },
    .{ .id = 639, .name = "$4" },
    .{ .id = 640, .name = "$5" },
    .{ .id = 641, .name = "$6" },
    .{ .id = 642, .name = "$7" },
    .{ .id = 643, .name = "$8" },
    .{ .id = 644, .name = "$9" },
    .{ .id = 645, .name = "SuppressedError" },
    .{ .id = 646, .name = "DisposableStack" },
    .{ .id = 647, .name = "use" },
    .{ .id = 648, .name = "adopt" },
    .{ .id = 649, .name = "defer" },
    .{ .id = 650, .name = "move" },
    .{ .id = 651, .name = "disposed" },
    .{ .id = 652, .name = "AsyncDisposableStack" },
    .{ .id = 653, .name = "disposeAsync" },
    .{ .id = 654, .name = "allKeyed" },
    .{ .id = 655, .name = "allSettledKeyed" },
    .{ .id = 656, .name = "immutable" },
};

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

const predefined_string_map = blk: {
    @setEvalBranchQuota(10000);
    break :blk std.StaticStringMap(Atom).initComptime(makePredefinedMapEntries(.string));
};
const predefined_symbol_map = blk: {
    @setEvalBranchQuota(10000);
    break :blk std.StaticStringMap(Atom).initComptime(makePredefinedMapEntries(.symbol));
};
const predefined_private_map = blk: {
    @setEvalBranchQuota(10000);
    break :blk std.StaticStringMap(Atom).initComptime(makePredefinedMapEntries(.private));
};

pub const DynamicAtom = struct {
    id: Atom,
    bytes: []u8,
    hash: u32,
    kind: AtomKind,
    ref_count: usize,
    gc_managed_symbol: bool = false,
    registry_managed_symbol: bool = false,

    pub fn isLive(self: DynamicAtom) bool {
        return self.ref_count != 0;
    }
};

/// Index in `AtomTable.entries`, used as the secondary lookup key for the
/// hash maps below.
const EntryIndex = u32;

/// Hash-map context for live string-kind entries. The key is the bytes
/// slice; the value is an entry index. Equality dereferences into
/// `entries` to compare bytes — this is safe because we update the map
/// whenever the entry's bytes / kind / liveness change.
const InternKey = struct {
    bytes: []const u8,
};

const InternContext = struct {
    pub fn hash(_: InternContext, key: InternKey) u64 {
        return std.hash.Wyhash.hash(0, key.bytes);
    }
    pub fn eql(_: InternContext, a: InternKey, b: InternKey) bool {
        return std.mem.eql(u8, a.bytes, b.bytes);
    }
};

const InternMap = std.HashMapUnmanaged(InternKey, EntryIndex, InternContext, std.hash_map.default_max_load_percentage);

pub const AtomTable = struct {
    memory: *memory.MemoryAccount,
    entries: []DynamicAtom = &.{},
    /// Geometric-growth capacity for `entries`. The visible slice length
    /// is the live count; the backing buffer extends to `entries_capacity`.
    entries_capacity: usize = 0,
    next_id: Atom = first_dynamic_atom,
    /// Live string interns indexed by bytes. Lookup is O(1) average.
    string_index: InternMap = .{},
    /// Registered symbols indexed by bytes. Ordinary unique symbols and
    /// private names intentionally do not enter this map.
    symbol_index: InternMap = .{},
    pub fn init(account: *memory.MemoryAccount) AtomTable {
        return .{ .memory = account };
    }

    pub fn deinit(self: *AtomTable) void {
        const account = self.memory;
        const entries = self.entries;
        const backing: []DynamicAtom = if (self.entries_capacity != 0) self.entries.ptr[0..self.entries_capacity] else self.entries[0..0];
        self.entries = &.{};
        self.entries_capacity = 0;
        self.string_index.deinit(account.persistent_allocator);
        self.symbol_index.deinit(account.persistent_allocator);
        for (entries) |*entry| {
            const bytes = entry.bytes;
            entry.bytes = &.{};
            if (bytes.len != 0) account.free(u8, bytes);
        }
        self.* = .{ .memory = account };
        if (backing.len != 0) account.free(DynamicAtom, backing);
    }

    pub fn internString(self: *AtomTable, bytes: []const u8) !Atom {
        if (predefinedId(bytes, .string)) |id| return id;
        if (parseArrayIndex(bytes)) |n| return atomFromUInt32(n);
        return self.internDynamic(bytes, .string, true, false);
    }

    pub fn newSymbol(self: *AtomTable, description: []const u8, atom_kind: AtomKind) !Atom {
        std.debug.assert(atom_kind == .symbol or atom_kind == .private);
        return self.internDynamic(description, atom_kind, false, false);
    }

    pub fn newValueSymbol(self: *AtomTable, description: []const u8) !Atom {
        return self.internDynamic(description, .symbol, false, true);
    }

    pub fn internSymbol(self: *AtomTable, description: []const u8) !Atom {
        if (self.symbol_index.get(.{ .bytes = description })) |idx| {
            const entry = &self.entries[idx];
            std.debug.assert(entry.isLive() and entry.kind == .symbol);
            entry.ref_count += 1;
            return entry.id;
        }
        return self.internDynamic(description, .symbol, true, false);
    }

    pub fn internRegisteredValueSymbol(self: *AtomTable, description: []const u8) !Atom {
        if (self.symbol_index.get(.{ .bytes = description })) |idx| {
            const entry = &self.entries[idx];
            std.debug.assert(entry.isLive() and entry.kind == .symbol);
            if (!entry.registry_managed_symbol) {
                entry.ref_count += 1;
                entry.registry_managed_symbol = true;
            }
            return entry.id;
        }
        const id = try self.internDynamic(description, .symbol, true, false);
        const entry = self.findDynamic(id).?;
        entry.registry_managed_symbol = true;
        return id;
    }

    pub fn isRegisteredSymbol(self: *const AtomTable, atom_id: Atom) bool {
        const idx = dynamicEntryIndex(atom_id) orelse return false;
        if (idx >= self.entries.len) return false;
        const entry = self.entries[idx];
        if (!entry.isLive() or entry.kind != .symbol) return false;
        const indexed = self.symbol_index.get(.{ .bytes = entry.bytes }) orelse return false;
        return indexed == idx;
    }

    pub fn sweepUnrootedUniqueSymbols(self: *AtomTable, roots: anytype) usize {
        var freed: usize = 0;
        for (self.entries) |*entry| {
            if (!entry.isLive() or entry.kind != .symbol) continue;
            if (!entry.gc_managed_symbol) continue;
            if (self.isRegisteredSymbol(entry.id)) continue;
            if (entry.ref_count > 1) continue;
            if (roots.contains(entry.id)) continue;
            self.free(entry.id);
            freed += 1;
        }
        return freed;
    }

    pub fn dup(self: *AtomTable, atom: Atom) Atom {
        if (isConst(atom) or isTaggedInt(atom)) return atom;
        if (self.findDynamic(atom)) |entry| {
            std.debug.assert(entry.isLive());
            entry.ref_count += 1;
        }
        return atom;
    }

    pub fn free(self: *AtomTable, atom: Atom) void {
        if (isConst(atom) or isTaggedInt(atom)) return;
        const entry = self.findDynamic(atom) orelse return;
        std.debug.assert(entry.ref_count > 0);
        entry.ref_count -= 1;
        if (entry.ref_count == 0) {
            // Remove from interning map(s) before clearing bytes so the
            // hash-map key (which slices into entry.bytes) is valid.
            switch (entry.kind) {
                .string => _ = self.string_index.remove(.{ .bytes = entry.bytes }),
                .symbol => {
                    if (self.isRegisteredSymbol(atom)) _ = self.symbol_index.remove(.{ .bytes = entry.bytes });
                },
                .private => {},
            }
            const bytes = entry.bytes;
            entry.bytes = &.{};
            if (bytes.len != 0) self.memory.free(u8, bytes);
            // Slot stays in `entries`. The id is gone for good (no recycle):
            // see `internDynamic` for the rationale.
        }
    }

    pub fn refCount(self: *const AtomTable, atom_id: Atom) ?usize {
        if (isConst(atom_id) or isTaggedInt(atom_id)) return null;
        const entry = self.findDynamicConst(atom_id) orelse return null;
        if (!entry.isLive()) return null;
        return entry.ref_count;
    }

    pub fn replace(self: *AtomTable, slot: *Atom, next: Atom) void {
        const retained = self.dup(next);
        const old = slot.*;
        slot.* = retained;
        self.free(old);
    }

    pub fn name(self: *const AtomTable, atom: Atom) ?[]const u8 {
        if (atom == null_atom) return null;
        if (isTaggedInt(atom)) return null;
        if (predefinedById(atom)) |entry| return entry.name;
        if (self.findDynamicConst(atom)) |entry| {
            if (entry.isLive()) return entry.bytes;
        }
        return null;
    }

    pub fn kind(self: *const AtomTable, atom: Atom) ?AtomKind {
        if (atom == null_atom) return null;
        if (isTaggedInt(atom)) return .string;
        if (predefinedById(atom)) |entry| return entry.kind;
        if (self.findDynamicConst(atom)) |entry| {
            if (entry.isLive()) return entry.kind;
        }
        return null;
    }

    pub fn toStringValue(self: *const AtomTable, rt: anytype, atom_id: Atom) !JSValue {
        if (isTaggedInt(atom_id)) {
            var buf: [10]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "{d}", .{atomToUInt32(atom_id)});
            if (text.len == 1 and text[0] <= 0x7f) {
                const cached = (try rt.singleByteString(text[0])).?;
                return cached.value().dup();
            }
            const cached = try rt.recentAtomString(atom_id, text);
            return cached.value().dup();
        }
        const text = self.name(atom_id) orelse return JSValue.undefinedValue();
        if (text.len == 1 and text[0] <= 0x7f) {
            const cached = (try rt.singleByteString(text[0])).?;
            return cached.value().dup();
        }
        if (self.kind(atom_id) != .string) {
            const created = try string.String.createUtf8(rt, text);
            return created.value();
        }
        const cached = try rt.recentAtomString(atom_id, text);
        return cached.value().dup();
    }

    fn internDynamic(self: *AtomTable, bytes: []const u8, atom_kind: AtomKind, index_entry: bool, gc_managed_symbol: bool) !Atom {
        // Fast path: interning lookup via hash map. The map is keyed by
        // bytes, indexed per-kind (string vs symbol/private) so a string
        // `"foo"` and a symbol description `"foo"` map to distinct atoms.
        if (atom_kind == .string) {
            if (self.string_index.get(.{ .bytes = bytes })) |idx| {
                const entry = &self.entries[idx];
                std.debug.assert(entry.isLive() and entry.kind == .string);
                entry.ref_count += 1;
                return entry.id;
            }
        }

        const owned: []u8 = if (bytes.len == 0) &.{} else try self.memory.alloc(u8, bytes.len);
        errdefer if (owned.len != 0) self.memory.free(u8, owned);
        if (bytes.len != 0) @memcpy(owned, bytes);

        // Always assign a fresh id; never recycle a dead slot. Reusing a
        // dead slot would keep its old `Atom` id but rebind it to new
        // bytes/kind, silently retargeting any callers that still hold the
        // id. The original linear-scan AtomTable did recycle dead slots,
        // but the rest of the engine assumes ids are stable across the
        // table's lifetime, so we keep the simpler "monotonic id" scheme.
        const id = self.next_id;
        self.next_id += 1;
        errdefer self.next_id = id;
        const idx = try self.appendEntry(.{
            .id = id,
            .bytes = owned,
            .hash = string.hashBytes(bytes),
            .kind = atom_kind,
            .ref_count = 1,
            .gc_managed_symbol = atom_kind == .symbol and gc_managed_symbol,
        });
        errdefer self.entries = self.entries[0..idx];
        if (index_entry) try self.indexEntry(idx);
        return id;
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

    fn indexEntry(self: *AtomTable, idx: EntryIndex) !void {
        const entry = &self.entries[idx];
        switch (entry.kind) {
            .string => try self.string_index.put(self.memory.persistent_allocator, .{ .bytes = entry.bytes }, idx),
            .symbol => try self.symbol_index.put(self.memory.persistent_allocator, .{ .bytes = entry.bytes }, idx),
            .private => {},
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
};

fn dynamicEntryIndex(atom: Atom) ?usize {
    if (atom < first_dynamic_atom or isTaggedInt(atom)) return null;
    return @intCast(atom - first_dynamic_atom);
}

pub fn isConst(atom: Atom) bool {
    return atom < first_dynamic_atom;
}

pub fn isTaggedInt(atom: Atom) bool {
    return (atom & tagged_int_bit) != 0;
}

pub fn atomFromUInt32(n: u32) Atom {
    std.debug.assert(n <= max_int_atom);
    return n | tagged_int_bit;
}

pub fn atomToUInt32(atom: Atom) u32 {
    std.debug.assert(isTaggedInt(atom));
    return atom & ~tagged_int_bit;
}

pub fn predefinedById(id: Atom) ?PredefinedAtom {
    if (id == null_atom or id >= first_dynamic_atom) return null;
    return predefined_atoms[id - 1];
}

pub fn predefinedId(bytes: []const u8, kind: AtomKind) ?Atom {
    @setEvalBranchQuota(10000);
    return switch (kind) {
        .string => predefined_string_map.get(bytes),
        .symbol => predefined_symbol_map.get(bytes),
        .private => predefined_private_map.get(bytes),
    };
}

fn parseArrayIndex(bytes: []const u8) ?u32 {
    if (bytes.len == 0) return null;
    if (bytes.len > 1 and bytes[0] == '0') return null;
    var n: u64 = 0;
    for (bytes) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
        if (n > max_int_atom) return null;
    }
    return @intCast(n);
}

const std = @import("std");
