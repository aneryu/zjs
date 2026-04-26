const core = @import("../core/root.zig");
const Value = @import("../core/value.zig").Value;

pub const BuiltinFunction = struct {
    name: []const u8,
    length: u16,
};

pub fn applyReturnThis(this_value: Value) Value {
    return this_value.dup();
}

pub fn nativeFunction(rt: *core.Runtime, name: []const u8, length: i32) !core.Value {
    const function_object = try core.Object.create(rt, core.class.ids.c_function, null);
    errdefer function_object.value().free(rt);

    try defineFunctionName(rt, function_object, name);
    try defineData(rt, function_object, "length", core.Value.int32(length), false, false, true);

    return function_object.value();
}

pub fn sourceFunction(rt: *core.Runtime, name: []const u8, source: []const u8) !core.Value {
    const function_object = try core.Object.create(rt, core.class.ids.c_function, null);
    errdefer function_object.value().free(rt);

    try defineFunctionName(rt, function_object, name);
    const source_string = try core.string.String.createUtf8(rt, source);
    const source_value = source_string.value();
    function_object.function_source = source_value.dup();
    source_value.free(rt);

    return function_object.value();
}

pub fn defineNativeMethod(rt: *core.Runtime, target: *core.Object, name: []const u8, length: i32) !void {
    const method = try nativeFunction(rt, name, length);
    defer method.free(rt);
    try defineData(rt, target, name, method, true, false, true);
}

fn defineData(
    rt: *core.Runtime,
    target: *core.Object,
    name: []const u8,
    value: core.Value,
    writable: bool,
    enumerable: bool,
    configurable: bool,
) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try target.defineOwnProperty(rt, key, core.Descriptor.data(value, writable, enumerable, configurable));
}

fn defineFunctionName(rt: *core.Runtime, function_object: *core.Object, name: []const u8) !void {
    const name_string = try core.string.String.createUtf8(rt, name);
    const name_value = name_string.value();
    defer name_value.free(rt);
    try defineData(rt, function_object, "name", name_value, false, false, true);
}
