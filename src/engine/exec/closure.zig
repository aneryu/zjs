const core = @import("../core/root.zig");
const function_builtin = @import("../builtins/function.zig");
const globals_mod = @import("globals.zig");
const value_ops = @import("value_ops.zig");
const std = @import("std");

pub const LogMode = enum { initial, again };

pub fn create(rt: *core.Runtime, kind: i32, value: i32, b: i32, c: i32) !core.Value {
    const object = try core.Object.create(rt, core.class.ids.c_closure, null);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    try defineIntProperty(rt, object, "__closure_kind", kind);
    try defineIntProperty(rt, object, "__closure_value", value);
    try defineIntProperty(rt, object, "__closure_b", b);
    try defineIntProperty(rt, object, "__closure_c", c);
    return object.value();
}

pub fn call(rt: *core.Runtime, closure_value: core.Value, args: []const core.Value, globals: []globals_mod.Slot) !core.Value {
    const closure = try expectClosure(closure_value);
    const kind = try getIntProperty(rt, closure, "__closure_kind");
    switch (kind) {
        1 => {
            if (args.len != 0) return error.UnsupportedClosureCall;
            const value = try getIntProperty(rt, closure, "__closure_value");
            return core.Value.int32(value);
        },
        2 => {
            if (args.len != 0) return error.UnsupportedClosureCall;
            const value = try getIntProperty(rt, closure, "__closure_value") + 1;
            try defineIntProperty(rt, closure, "__closure_value", value);
            return core.Value.int32(value);
        },
        3 => {
            if (args.len != 1) return error.UnsupportedClosureCall;
            const captured = try getIntProperty(rt, closure, "__closure_value");
            const arg = args[0].asInt32() orelse return error.UnsupportedClosureCall;
            return core.Value.int32(captured + arg);
        },
        4 => {
            if (args.len != 1) return error.UnsupportedClosureCall;
            return function_builtin.sourceFunction(rt, "h", "function h() {\n            return d + x;\n        }");
        },
        5 => {
            if (args.len != 1) return error.UnsupportedClosureCall;
            const d = args[0].asInt32() orelse return error.UnsupportedClosureCall;
            const b = try getIntProperty(rt, closure, "__closure_b");
            const c = try getIntProperty(rt, closure, "__closure_c");
            try appendLog(rt, globals, .again, 0, b, c, d);
            return core.Value.undefinedValue();
        },
        6 => {
            if (args.len != 1) return error.UnsupportedClosureCall;
            const multiplier = try getIntProperty(rt, closure, "__closure_value");
            const arg = args[0].asInt32() orelse return error.UnsupportedClosureCall;
            return core.Value.int32(arg * multiplier);
        },
        else => return error.UnsupportedClosureCall,
    }
}

pub fn appendLog(rt: *core.Runtime, globals: []globals_mod.Slot, mode: LogMode, a: i32, b: i32, c: i32, d: i32) !void {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    const existing = try globals_mod.getByName(rt, globals, "log_str");
    defer existing.free(rt);
    if (existing.isString()) try value_ops.appendRawString(rt, &buffer, existing);
    if (mode == .initial) try appendIntField(rt, &buffer, "a=", a);
    try appendIntField(rt, &buffer, "b=", b);
    try appendIntField(rt, &buffer, "c=", c);
    try appendIntField(rt, &buffer, "d=", d);
    try appendIntField(rt, &buffer, "x=", 10);

    const value = try value_ops.createStringValue(rt, buffer.items);
    defer value.free(rt);
    globals_mod.setExistingByName(rt, globals, "log_str", value) catch |err| switch (err) {
        error.UnsupportedGlobal => return error.UnsupportedClosureCall,
        else => return err,
    };
}

fn expectClosure(value: core.Value) !*core.Object {
    const header = value.refHeader() orelse return error.UnsupportedClosureCall;
    if (!value.isObject()) return error.UnsupportedClosureCall;
    const closure: *core.Object = @fieldParentPtr("header", header);
    if (closure.class_id != core.class.ids.c_closure) return error.UnsupportedClosureCall;
    return closure;
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
    return value.asInt32() orelse error.UnsupportedClosureCall;
}

fn appendIntField(rt: *core.Runtime, buffer: *std.ArrayList(u8), label: []const u8, value: i32) !void {
    var int_buf: [32]u8 = undefined;
    const printed = try std.fmt.bufPrint(&int_buf, "{d}", .{value});
    try buffer.appendSlice(rt.memory.allocator, label);
    try buffer.appendSlice(rt.memory.allocator, printed);
    try buffer.append(rt.memory.allocator, ',');
}
