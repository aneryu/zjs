const core = @import("../core/root.zig");
const function_builtin = @import("function.zig");
const std = @import("std");

pub const Flags = struct {
    writable: bool,
    enumerable: bool,
    configurable: bool,
};

pub const Method = struct {
    name: []const u8,
    length: i32,
};

const ConstructorSpec = struct {
    name: []const u8,
    length: i32,
    static_methods: []const Method = &.{},
    prototype_methods: []const Method = &.{},
};

pub const global_flags = Flags{ .writable = true, .enumerable = false, .configurable = true };
pub const method_flags = Flags{ .writable = true, .enumerable = false, .configurable = true };
pub const prototype_flags = Flags{ .writable = false, .enumerable = false, .configurable = false };

pub fn defineData(
    rt: *core.Runtime,
    target: *core.Object,
    name: []const u8,
    value: core.Value,
    flags: Flags,
) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try target.defineOwnProperty(rt, key, core.Descriptor.data(value, flags.writable, flags.enumerable, flags.configurable));
}

pub fn defineDataAtom(
    rt: *core.Runtime,
    target: *core.Object,
    atom_id: core.Atom,
    value: core.Value,
    flags: Flags,
) !void {
    try target.defineOwnProperty(rt, atom_id, core.Descriptor.data(value, flags.writable, flags.enumerable, flags.configurable));
}

pub fn defineAccessorAtom(
    rt: *core.Runtime,
    target: *core.Object,
    atom_id: core.Atom,
    getter: core.Value,
    setter: core.Value,
    flags: Flags,
) !void {
    _ = flags.writable;
    try target.defineOwnProperty(rt, atom_id, core.Descriptor.accessor(getter, setter, flags.enumerable, flags.configurable));
}

pub fn defineNativeMethod(rt: *core.Runtime, target: *core.Object, method: Method) !void {
    const value = try function_builtin.nativeFunction(rt, method.name, method.length);
    defer value.free(rt);
    try defineData(rt, target, method.name, value, method_flags);
}

pub fn defineNativeMethods(rt: *core.Runtime, target: *core.Object, methods: []const Method) !void {
    for (methods) |method| try defineNativeMethod(rt, target, method);
}

pub fn defineGlobalFunction(rt: *core.Runtime, global: *core.Object, name: []const u8, length: i32) !void {
    const value = try function_builtin.nativeFunction(rt, name, length);
    defer value.free(rt);
    try defineData(rt, global, name, value, global_flags);
}

pub fn defineNamespace(rt: *core.Runtime, global: *core.Object, name: []const u8, methods: []const Method) !void {
    const namespace = try core.Object.create(rt, core.class.ids.object, null);
    errdefer namespace.value().free(rt);
    try defineNativeMethods(rt, namespace, methods);
    try defineData(rt, global, name, namespace.value(), global_flags);
    namespace.value().free(rt);
}

pub fn defineConstructor(
    rt: *core.Runtime,
    global: *core.Object,
    name: []const u8,
    length: i32,
    prototype_methods: []const Method,
) !core.Value {
    const constructor_value = try function_builtin.nativeFunction(rt, name, length);
    errdefer constructor_value.free(rt);
    const constructor = expectObject(constructor_value);

    const prototype = try core.Object.create(rt, core.class.ids.object, null);
    errdefer prototype.value().free(rt);
    try defineNativeMethods(rt, prototype, prototype_methods);
    try defineData(rt, constructor, "prototype", prototype.value(), prototype_flags);
    prototype.value().free(rt);

    try defineData(rt, global, name, constructor_value, global_flags);
    return constructor_value;
}

fn expectObject(value: core.Value) *core.Object {
    const header = value.refHeader().?;
    return @fieldParentPtr("header", header);
}

pub fn installStandardGlobals(rt: *core.Runtime, global: *core.Object) !void {
    for (constructor_specs) |spec| {
        {
            const constructor_value = try defineConstructor(rt, global, spec.name, spec.length, spec.prototype_methods);
            defer constructor_value.free(rt);
            try defineNativeMethods(rt, expectObject(constructor_value), spec.static_methods);
            if (std.mem.eql(u8, spec.name, "Symbol")) try installWellKnownSymbolProperties(rt, expectObject(constructor_value));
            if (std.mem.eql(u8, spec.name, "Map")) try installMapSpecies(rt, expectObject(constructor_value));
        }
    }

    try defineNamespace(rt, global, "Math", &math_methods);
    try defineNamespace(rt, global, "JSON", &json_methods);
    try defineNamespace(rt, global, "Reflect", &reflect_methods);
    try defineNamespace(rt, global, "Atomics", &atomics_methods);

    try defineGlobalFunction(rt, global, "parseInt", 2);
    try defineGlobalFunction(rt, global, "parseFloat", 1);
    try defineGlobalFunction(rt, global, "encodeURI", 1);
    try defineGlobalFunction(rt, global, "decodeURI", 1);
    try defineGlobalFunction(rt, global, "encodeURIComponent", 1);
    try defineGlobalFunction(rt, global, "decodeURIComponent", 1);
}

const object_static = [_]Method{
    .{ .name = "defineProperty", .length = 3 },
    .{ .name = "getOwnPropertyDescriptor", .length = 2 },
    .{ .name = "getOwnPropertyNames", .length = 1 },
    .{ .name = "keys", .length = 1 },
    .{ .name = "values", .length = 1 },
    .{ .name = "entries", .length = 1 },
    .{ .name = "is", .length = 2 },
};

const object_prototype = [_]Method{
    .{ .name = "toString", .length = 0 },
    .{ .name = "hasOwnProperty", .length = 1 },
};

const function_prototype = [_]Method{
    .{ .name = "call", .length = 1 },
    .{ .name = "apply", .length = 2 },
    .{ .name = "bind", .length = 1 },
    .{ .name = "toString", .length = 0 },
};

const array_static = [_]Method{
    .{ .name = "from", .length = 1 },
    .{ .name = "isArray", .length = 1 },
};

const array_prototype = [_]Method{
    .{ .name = "map", .length = 1 },
    .{ .name = "filter", .length = 1 },
    .{ .name = "reduce", .length = 1 },
    .{ .name = "forEach", .length = 1 },
    .{ .name = "some", .length = 1 },
    .{ .name = "every", .length = 1 },
    .{ .name = "findIndex", .length = 1 },
    .{ .name = "includes", .length = 1 },
    .{ .name = "indexOf", .length = 1 },
    .{ .name = "lastIndexOf", .length = 1 },
    .{ .name = "at", .length = 1 },
    .{ .name = "slice", .length = 2 },
    .{ .name = "splice", .length = 2 },
    .{ .name = "join", .length = 1 },
};

const string_static = [_]Method{
    .{ .name = "fromCharCode", .length = 1 },
};

const string_prototype = [_]Method{
    .{ .name = "charAt", .length = 1 },
    .{ .name = "substring", .length = 2 },
    .{ .name = "toUpperCase", .length = 0 },
    .{ .name = "toLowerCase", .length = 0 },
    .{ .name = "indexOf", .length = 1 },
    .{ .name = "includes", .length = 1 },
    .{ .name = "startsWith", .length = 1 },
    .{ .name = "endsWith", .length = 1 },
    .{ .name = "trim", .length = 0 },
    .{ .name = "toString", .length = 0 },
};

const number_static = [_]Method{
    .{ .name = "parseInt", .length = 2 },
    .{ .name = "parseFloat", .length = 1 },
};

const number_prototype = [_]Method{
    .{ .name = "toString", .length = 1 },
    .{ .name = "valueOf", .length = 0 },
};

const primitive_prototype = [_]Method{
    .{ .name = "toString", .length = 0 },
    .{ .name = "valueOf", .length = 0 },
};

const date_static = [_]Method{
    .{ .name = "UTC", .length = 7 },
    .{ .name = "parse", .length = 1 },
    .{ .name = "now", .length = 0 },
};

const date_prototype = [_]Method{
    .{ .name = "getTime", .length = 0 },
    .{ .name = "valueOf", .length = 0 },
    .{ .name = "getFullYear", .length = 0 },
    .{ .name = "getMonth", .length = 0 },
    .{ .name = "getDate", .length = 0 },
    .{ .name = "getHours", .length = 0 },
    .{ .name = "getMinutes", .length = 0 },
    .{ .name = "getSeconds", .length = 0 },
    .{ .name = "getMilliseconds", .length = 0 },
    .{ .name = "toISOString", .length = 0 },
    .{ .name = "toJSON", .length = 1 },
    .{ .name = "getUTCFullYear", .length = 0 },
    .{ .name = "getUTCMonth", .length = 0 },
    .{ .name = "getUTCDate", .length = 0 },
    .{ .name = "getUTCHours", .length = 0 },
    .{ .name = "getUTCMinutes", .length = 0 },
    .{ .name = "getUTCSeconds", .length = 0 },
    .{ .name = "getUTCMilliseconds", .length = 0 },
    .{ .name = "getUTCDay", .length = 0 },
};

const regexp_prototype = [_]Method{
    .{ .name = "exec", .length = 1 },
    .{ .name = "test", .length = 1 },
    .{ .name = "toString", .length = 0 },
};

const promise_static = [_]Method{
    .{ .name = "resolve", .length = 1 },
    .{ .name = "all", .length = 1 },
    .{ .name = "race", .length = 1 },
    .{ .name = "reject", .length = 1 },
};

const promise_prototype = [_]Method{
    .{ .name = "then", .length = 2 },
    .{ .name = "catch", .length = 1 },
};

const map_static = [_]Method{
    .{ .name = "groupBy", .length = 2 },
};

const map_prototype = [_]Method{
    .{ .name = "set", .length = 2 },
    .{ .name = "get", .length = 1 },
    .{ .name = "has", .length = 1 },
    .{ .name = "delete", .length = 1 },
    .{ .name = "clear", .length = 0 },
    .{ .name = "keys", .length = 0 },
};

const weak_map_prototype = [_]Method{
    .{ .name = "set", .length = 2 },
    .{ .name = "get", .length = 1 },
    .{ .name = "has", .length = 1 },
    .{ .name = "delete", .length = 1 },
};

const set_prototype = [_]Method{
    .{ .name = "add", .length = 1 },
    .{ .name = "has", .length = 1 },
    .{ .name = "delete", .length = 1 },
    .{ .name = "clear", .length = 0 },
};

const weak_set_prototype = [_]Method{
    .{ .name = "add", .length = 1 },
    .{ .name = "has", .length = 1 },
    .{ .name = "delete", .length = 1 },
};

const buffer_prototype = [_]Method{
    .{ .name = "slice", .length = 2 },
};

const data_view_prototype = [_]Method{
    .{ .name = "getInt8", .length = 1 },
    .{ .name = "getUint8", .length = 1 },
    .{ .name = "getInt16", .length = 1 },
    .{ .name = "getUint16", .length = 1 },
    .{ .name = "getInt32", .length = 1 },
    .{ .name = "getUint32", .length = 1 },
    .{ .name = "setInt8", .length = 2 },
    .{ .name = "setUint8", .length = 2 },
};

const constructor_specs = [_]ConstructorSpec{
    .{ .name = "Object", .length = 1, .static_methods = &object_static, .prototype_methods = &object_prototype },
    .{ .name = "Function", .length = 1, .prototype_methods = &function_prototype },
    .{ .name = "Array", .length = 1, .static_methods = &array_static, .prototype_methods = &array_prototype },
    .{ .name = "String", .length = 1, .static_methods = &string_static, .prototype_methods = &string_prototype },
    .{ .name = "Number", .length = 1, .static_methods = &number_static, .prototype_methods = &number_prototype },
    .{ .name = "Boolean", .length = 1, .prototype_methods = &primitive_prototype },
    .{ .name = "Symbol", .length = 0, .prototype_methods = &primitive_prototype },
    .{ .name = "BigInt", .length = 1, .prototype_methods = &primitive_prototype },
    .{ .name = "Date", .length = 7, .static_methods = &date_static, .prototype_methods = &date_prototype },
    .{ .name = "RegExp", .length = 2, .prototype_methods = &regexp_prototype },
    .{ .name = "Error", .length = 1, .prototype_methods = &primitive_prototype },
    .{ .name = "EvalError", .length = 1, .prototype_methods = &primitive_prototype },
    .{ .name = "RangeError", .length = 1, .prototype_methods = &primitive_prototype },
    .{ .name = "ReferenceError", .length = 1, .prototype_methods = &primitive_prototype },
    .{ .name = "SyntaxError", .length = 1, .prototype_methods = &primitive_prototype },
    .{ .name = "TypeError", .length = 1, .prototype_methods = &primitive_prototype },
    .{ .name = "Promise", .length = 1, .static_methods = &promise_static, .prototype_methods = &promise_prototype },
    .{ .name = "Map", .length = 0, .static_methods = &map_static, .prototype_methods = &map_prototype },
    .{ .name = "Set", .length = 0, .prototype_methods = &set_prototype },
    .{ .name = "WeakMap", .length = 0, .prototype_methods = &weak_map_prototype },
    .{ .name = "WeakSet", .length = 0, .prototype_methods = &weak_set_prototype },
    .{ .name = "ArrayBuffer", .length = 1, .prototype_methods = &buffer_prototype },
    .{ .name = "TypedArray", .length = 1, .prototype_methods = &array_prototype },
    .{ .name = "DataView", .length = 1, .prototype_methods = &data_view_prototype },
    .{ .name = "Proxy", .length = 2 },
    .{ .name = "Iterator", .length = 0 },
};

const math_methods = [_]Method{
    .{ .name = "abs", .length = 1 },
    .{ .name = "floor", .length = 1 },
    .{ .name = "ceil", .length = 1 },
    .{ .name = "round", .length = 1 },
    .{ .name = "sqrt", .length = 1 },
    .{ .name = "pow", .length = 2 },
    .{ .name = "min", .length = 2 },
    .{ .name = "max", .length = 2 },
    .{ .name = "random", .length = 0 },
    .{ .name = "sin", .length = 1 },
    .{ .name = "cos", .length = 1 },
    .{ .name = "tan", .length = 1 },
    .{ .name = "acosh", .length = 1 },
    .{ .name = "asinh", .length = 1 },
    .{ .name = "atanh", .length = 1 },
    .{ .name = "log", .length = 1 },
};

const json_methods = [_]Method{
    .{ .name = "parse", .length = 2 },
    .{ .name = "stringify", .length = 3 },
};

const reflect_methods = [_]Method{
    .{ .name = "get", .length = 2 },
    .{ .name = "set", .length = 3 },
    .{ .name = "ownKeys", .length = 1 },
    .{ .name = "construct", .length = 2 },
    .{ .name = "apply", .length = 3 },
};

const atomics_methods = [_]Method{
    .{ .name = "load", .length = 2 },
    .{ .name = "store", .length = 3 },
    .{ .name = "add", .length = 3 },
    .{ .name = "sub", .length = 3 },
};

fn installWellKnownSymbolProperties(rt: *core.Runtime, symbol_ctor: *core.Object) !void {
    try defineWellKnownSymbol(rt, symbol_ctor, "species", "Symbol.species");
    try defineWellKnownSymbol(rt, symbol_ctor, "iterator", "Symbol.iterator");
}

fn defineWellKnownSymbol(rt: *core.Runtime, symbol_ctor: *core.Object, name: []const u8, symbol_name: []const u8) !void {
    const symbol_atom = core.atom.predefinedId(symbol_name, .symbol) orelse return error.UnsupportedBuiltinRegistry;
    try defineData(rt, symbol_ctor, name, core.Value.symbol(symbol_atom), Flags{ .writable = false, .enumerable = false, .configurable = false });
}

fn installMapSpecies(rt: *core.Runtime, map_ctor: *core.Object) !void {
    const species_atom = core.atom.predefinedId("Symbol.species", .symbol) orelse return error.UnsupportedBuiltinRegistry;
    const getter = try function_builtin.nativeFunction(rt, "get [Symbol.species]", 0);
    defer getter.free(rt);
    const getter_object = expectObject(getter);
    try function_builtin.defineNativeMethod(rt, getter_object, "call", 1);
    try defineAccessorAtom(rt, map_ctor, species_atom, getter, core.Value.undefinedValue(), Flags{ .writable = false, .enumerable = false, .configurable = true });
}
