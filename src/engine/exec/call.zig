const core = @import("../core/root.zig");
const function_builtin = @import("../builtins/function.zig");
const value_ops = @import("value_ops.zig");
const std = @import("std");

pub fn returnThis(this_value: core.Value) core.Value {
    return this_value.dup();
}

/// QuickJS source map: JS_CallInternal() dispatches callable objects after the
/// VM has prepared callee/argument values. This Zig slice currently owns the
/// host callables installed for the CLI-visible global object.
pub fn installHostGlobals(rt: *core.Runtime, global: *core.Object) !void {
    try defineHostFunction(rt, global, "print", .output);
    try defineHostFunction(rt, global, "Test262Error", .test262_error);
    try installStandardGlobals(rt, global);

    const console = try core.Object.create(rt, core.class.ids.object, null);
    errdefer console.value().free(rt);
    try defineHostFunction(rt, console, "log", .output);
    try defineObjectProperty(rt, global, "console", console.value());
    console.value().free(rt);

    const assert = try core.Object.create(rt, core.class.ids.object, null);
    errdefer assert.value().free(rt);
    try defineHostFunction(rt, assert, "sameValue", .test262_same_value);
    try defineObjectProperty(rt, global, "assert", assert.value());
    assert.value().free(rt);
}

fn installStandardGlobals(rt: *core.Runtime, global: *core.Object) !void {
    const math = try core.Object.create(rt, core.class.ids.object, null);
    errdefer math.value().free(rt);
    try defineObjectProperty(rt, global, "Math", math.value());
    math.value().free(rt);

    const json = try core.Object.create(rt, core.class.ids.object, null);
    errdefer json.value().free(rt);
    try defineObjectProperty(rt, global, "JSON", json.value());
    json.value().free(rt);

    try defineNativeGlobal(rt, global, "Promise");
    try defineNativeGlobal(rt, global, "Map");
    try defineNativeGlobal(rt, global, "Set");
    try defineNativeGlobal(rt, global, "WeakMap");
    try defineNativeGlobal(rt, global, "WeakSet");
    try defineNativeGlobal(rt, global, "ArrayBuffer");
    try defineNativeGlobal(rt, global, "DataView");
    try defineNativeGlobal(rt, global, "Symbol");
}

fn defineNativeGlobal(rt: *core.Runtime, global: *core.Object, name: []const u8) !void {
    const function_value = try function_builtin.nativeFunction(rt, name, 1);
    defer function_value.free(rt);
    try defineObjectProperty(rt, global, name, function_value);
}

pub fn callValue(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    callee: core.Value,
    args: []const core.Value,
) !core.Value {
    const object = expectCallableHostObject(callee) orelse return error.TypeError;
    const kind_value = try getIntProperty(ctx.runtime, object, host_function_key);
    const kind: HostFunction = switch (kind_value) {
        @intFromEnum(HostFunction.output) => .output,
        @intFromEnum(HostFunction.test262_same_value) => .test262_same_value,
        @intFromEnum(HostFunction.test262_error) => .test262_error,
        else => return error.TypeError,
    };
    return switch (kind) {
        .output => hostOutputValues(ctx.runtime, output, args),
        .test262_same_value => hostAssertSameValue(args),
        .test262_error => error.Test262Error,
    };
}

pub fn printValue(rt: *core.Runtime, writer: *std.Io.Writer, value: core.Value) anyerror!void {
    if (value.asInt32()) |int_value| {
        try writer.print("{d}", .{int_value});
    } else if (value_ops.numberValue(value)) |float_value| {
        if (std.math.isNan(float_value)) {
            try writer.print("NaN", .{});
        } else if (std.math.isPositiveInf(float_value)) {
            try writer.print("Infinity", .{});
        } else if (std.math.isNegativeInf(float_value)) {
            try writer.print("-Infinity", .{});
        } else {
            try writer.print("{d}", .{float_value});
        }
    } else if (value.isBigInt()) {
        var big = try value_ops.cloneBigIntValue(rt, value);
        defer big.deinit();
        const text = try big.formatBase10Alloc(rt.memory.allocator);
        defer rt.memory.allocator.free(text);
        try writer.print("{s}", .{text});
    } else if (value.asBool()) |bool_value| {
        try writer.print("{s}", .{if (bool_value) "true" else "false"});
    } else if (value.isUndefined()) {
        try writer.print("undefined", .{});
    } else if (value.isNull()) {
        try writer.print("null", .{});
    } else if (value.isString()) {
        try printString(writer, value);
    } else if (value.isObject()) {
        const header = value.refHeader() orelse return writer.print("[object Object]", .{});
        const object_value: *core.Object = @fieldParentPtr("header", header);
        if (isFunctionClass(object_value.class_id)) {
            try printNativeFunction(rt, writer, object_value);
        } else if (object_value.class_id == core.class.ids.array_buffer) {
            try writer.print("[object ArrayBuffer]", .{});
        } else if (object_value.class_id == core.class.ids.promise) {
            try writer.print("[object Promise]", .{});
        } else if (object_value.is_array) {
            try printArray(rt, writer, object_value);
        } else {
            try writer.print("[object Object]", .{});
        }
    } else {
        try writer.print("[object Object]", .{});
    }
}

pub fn forEachArrayPrint(rt: *core.Runtime, output: ?*std.Io.Writer, array_value: core.Value) !core.Value {
    const array = try expectArray(array_value);
    if (output) |writer| {
        var index: u32 = 0;
        while (index < array.length) : (index += 1) {
            const item = array.getProperty(core.atom.atomFromUInt32(index));
            defer item.free(rt);
            try printValue(rt, writer, item);
            try writer.print("\n", .{});
        }
    }
    return core.Value.undefinedValue();
}

const host_function_key = "__host_function";

const HostFunction = enum(i32) {
    output = 1,
    test262_same_value = 2,
    test262_error = 3,
};

fn defineHostFunction(rt: *core.Runtime, target: *core.Object, name: []const u8, kind: HostFunction) !void {
    const function_object = try core.Object.create(rt, core.class.ids.c_function, null);
    errdefer function_object.value().free(rt);
    try defineIntProperty(rt, function_object, host_function_key, @intFromEnum(kind));
    try defineObjectProperty(rt, target, name, function_object.value());
    function_object.value().free(rt);
}

fn defineObjectProperty(rt: *core.Runtime, object: *core.Object, name: []const u8, value: core.Value) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value, true, true, true));
}

fn defineIntProperty(rt: *core.Runtime, object: *core.Object, name: []const u8, value: i32) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(core.Value.int32(value), true, true, true));
}

fn getIntProperty(rt: *core.Runtime, object: *core.Object, name: []const u8) !i32 {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    const value = object.getProperty(key);
    defer value.free(rt);
    return value.asInt32() orelse error.TypeError;
}

fn expectCallableHostObject(value: core.Value) ?*core.Object {
    const header = value.refHeader() orelse return null;
    if (!value.isObject()) return null;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_id != core.class.ids.c_function) return null;
    return object;
}

fn expectArray(value: core.Value) !*core.Object {
    const header = value.refHeader() orelse return error.UnsupportedOutputCall;
    if (!value.isObject()) return error.UnsupportedOutputCall;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (!object.is_array) return error.UnsupportedOutputCall;
    return object;
}

fn hostOutputValues(rt: *core.Runtime, output: ?*std.Io.Writer, values: []const core.Value) !core.Value {
    if (output) |writer| {
        var i: usize = 0;
        while (i < values.len) : (i += 1) {
            if (i != 0) try writer.print(" ", .{});
            try printValue(rt, writer, values[i]);
        }
        try writer.print("\n", .{});
    }
    return core.Value.undefinedValue();
}

fn hostAssertSameValue(values: []const core.Value) !core.Value {
    if (values.len < 2) return error.TypeError;
    if (!@import("../builtins/root.zig").object.sameValue(values[0], values[1])) return error.Test262Error;
    return core.Value.undefinedValue();
}

fn printArray(rt: *core.Runtime, writer: *std.Io.Writer, object: *core.Object) anyerror!void {
    var index: u32 = 0;
    while (index < object.length) : (index += 1) {
        if (index != 0) try writer.print(",", .{});
        const value = object.getProperty(core.atom.atomFromUInt32(index));
        defer value.free(rt);
        try printValue(rt, writer, value);
    }
}

fn printString(writer: *std.Io.Writer, value: core.Value) !void {
    const header = value.refHeader() orelse return writer.print("[string]", .{});
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    switch (string_value.data) {
        .latin1 => |bytes| try writer.print("{s}", .{bytes}),
        .utf16 => |units| {
            for (units) |unit| {
                if (unit <= 0x7f) {
                    try writer.writeByte(@intCast(unit));
                } else {
                    try writer.print("\\u{x}", .{unit});
                }
            }
        },
    }
}

fn isFunctionClass(class_id: core.ClassId) bool {
    return class_id == core.class.ids.c_function or
        class_id == core.class.ids.bytecode_function or
        class_id == core.class.ids.bound_function or
        class_id == core.class.ids.c_function_data or
        class_id == core.class.ids.c_closure;
}

fn printNativeFunction(rt: *core.Runtime, writer: *std.Io.Writer, object: *core.Object) !void {
    if (object.function_source) |source| {
        try printString(writer, source);
        return;
    }

    const name_key = try rt.internAtom("name");
    defer rt.atoms.free(name_key);
    const name_value = object.getProperty(name_key);
    defer name_value.free(rt);

    try writer.print("function ", .{});
    if (name_value.isString()) try printString(writer, name_value);
    try writer.print("() {{\n    [native code]\n}}", .{});
}
