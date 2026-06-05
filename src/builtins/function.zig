const core = @import("../core/root.zig");
const JSValue = @import("../core/value.zig").JSValue;
const std = @import("std");

pub const BuiltinFunction = struct {
    name: []const u8,
    length: u16,
};

pub const PrototypeMethod = enum(u32) {
    to_string = 1,
};

pub fn applyReturnThis(this_value: JSValue) JSValue {
    return this_value.dup();
}

/// Returns true when `bytes` is plain ASCII (every code unit < 0x80).
/// Used by `nativeFunction` to take a memcpy-only string path for
/// builtin / host-helper names without paying the two-pass UTF-8
/// scan that `createUtf8` performs. Hot during builtins install but
/// also cheap for arbitrary inputs (single linear pass, vectorisable).
fn isAsciiBuiltinName(bytes: []const u8) bool {
    for (bytes) |b| {
        if (b >= 0x80) return false;
    }
    return true;
}

pub fn nativeFunction(rt: *core.JSRuntime, name: []const u8, length: i32) !core.JSValue {
    const function_object = try core.Object.create(rt, core.class.ids.c_function, null);
    errdefer function_object.value().free(rt);

    // Hot path during `installStandardGlobals`: this runs ~700 times
    // per fresh global. Three optimizations vs the general
    // `defineOwnProperty` path:
    //
    // 1. Resolve visible-property atoms via the predefined fast path
    //    (`length`, `name`) instead of paying `internAtom`'s predefined-
    //    name scan plus dynamic-table lookup on every call.
    // 2. Materialize the visible name string once. The dispatch identity
    //    lives in the function payload so user code cannot observe or
    //    mutate it through ordinary property operations.
    // 3. Use `defineOwnPropertyAssumingNew` to skip the duplicate-
    //    property scan (the function object is fresh and the two
    //    visible keys are mutually distinct).
    const length_key = core.atom.predefinedId("length", .string).?;
    try function_object.defineOwnPropertyAssumingNew(rt, length_key, core.Descriptor.data(core.JSValue.int32(length), false, false, true));

    // ASCII fast path: every standard-globals / host-helpers entry
    // passes plain ASCII (`hasOwnProperty`, `toLocaleString`, ...).
    // `createUtf8` would scan the bytes twice
    // (once to plan width, once to decode); ASCII names skip both
    // scans and just memcpy + hash. Falls back to `createUtf8` for
    // names that contain a non-ASCII byte so any callers passing
    // arbitrary user-provided text remain correct.
    const name_string = if (name.len == 0)
        try rt.emptyString()
    else if (isAsciiBuiltinName(name))
        try core.string.String.createAscii(rt, name)
    else
        try core.string.String.createUtf8(rt, name);
    const name_value = if (name.len == 0) name_string.value().dup() else name_string.value();
    defer name_value.free(rt);

    const name_key = core.atom.predefinedId("name", .string).?;
    try function_object.defineOwnPropertyAssumingNew(rt, name_key, core.Descriptor.data(name_value, false, false, true));

    function_object.nativeDispatchNameSlot().* = try rt.internAtom(name);

    return function_object.value();
}

pub fn sourceFunction(rt: *core.JSRuntime, name: []const u8, source: []const u8) !core.JSValue {
    const function_object = try core.Object.create(rt, core.class.ids.c_function, null);
    var function_value = function_object.value();
    var source_value = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &function_value },
        .{ .value = &source_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    errdefer {
        const failed_function = function_value;
        function_value = core.JSValue.undefinedValue();
        failed_function.free(rt);
    }

    try defineFunctionName(rt, function_object, name);
    const source_string = try core.string.String.createUtf8(rt, source);
    source_value = source_string.value();
    try function_object.setOptionalValueSlot(rt, function_object.functionSourceSlot(), source_value.dup());
    source_value.free(rt);
    source_value = core.JSValue.undefinedValue();

    return function_value;
}

pub fn defineNativeMethod(rt: *core.JSRuntime, target: *core.Object, name: []const u8, length: i32) !void {
    const method = try nativeFunction(rt, name, length);
    defer method.free(rt);
    try defineData(rt, target, name, method, true, false, true);
}

fn defineData(
    rt: *core.JSRuntime,
    target: *core.Object,
    name: []const u8,
    value: core.JSValue,
    writable: bool,
    enumerable: bool,
    configurable: bool,
) !void {
    var target_value = target.value();
    var rooted_value = value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &target_value },
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try target.defineOwnProperty(rt, key, core.Descriptor.data(rooted_value, writable, enumerable, configurable));
}

fn defineFunctionName(rt: *core.JSRuntime, function_object: *core.Object, name: []const u8) !void {
    const name_string = try core.string.String.createUtf8(rt, name);
    const name_value = name_string.value();
    defer name_value.free(rt);
    try defineData(rt, function_object, "name", name_value, false, false, true);
}

test "sourceFunction roots function and source while attaching source text" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const function_value = try sourceFunction(rt, "namedSource", "function namedSource() { return 1; }");
    defer function_value.free(rt);
    const function_object = try expectObject(function_value);
    const source_value = function_object.functionSource() orelse return error.TypeError;
    const source_string = try expectString(source_value);
    try std.testing.expect(source_string.eqlBytes("function namedSource() { return 1; }"));
}

fn expectObject(value: core.JSValue) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    return @fieldParentPtr("header", header);
}

fn expectString(value: core.JSValue) !*core.string.String {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isString()) return error.TypeError;
    return @fieldParentPtr("header", header);
}
