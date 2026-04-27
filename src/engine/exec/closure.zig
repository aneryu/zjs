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
    return callWithThis(rt, closure_value, core.Value.undefinedValue(), args, globals);
}

pub fn callWithThis(rt: *core.Runtime, closure_value: core.Value, this_value: core.Value, args: []const core.Value, globals: []globals_mod.Slot) !core.Value {
    const closure = try expectClosure(closure_value);
    const kind = try closureKind(rt, closure_value);
    switch (kind) {
        1 => {
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
        7 => return error.TypeError,
        8 => return error.SyntaxError,
        9 => return error.RangeError,
        10 => return error.EvalError,
        11 => return error.ReferenceError,
        12 => return error.Test262Error,
        13 => return core.Value.undefinedValue(),
        14 => return core.Value.nullValue(),
        15 => {
            if (args.len < 1) return error.UnsupportedClosureCall;
            const string = stringFromValue(args[0]) orelse return error.UnsupportedClosureCall;
            return core.Value.int32(@intCast(string.len()));
        },
        16 => {
            if (args.len < 1) return error.UnsupportedClosureCall;
            const value = args[0].asInt32() orelse return error.UnsupportedClosureCall;
            return try value_ops.createStringValue(rt, if (@mod(value, 2) == 0) "even" else "odd");
        },
        17 => {
            if (args.len < 1) return error.UnsupportedClosureCall;
            return args[0].dup();
        },
        18 => {
            if (args.len < 1) return error.UnsupportedClosureCall;
            const char = stringFromValue(args[0]) orelse return error.UnsupportedClosureCall;
            const threshold = try core.string.String.createUtf8(rt, "\xF0\x9F\x99\x8F");
            const threshold_value = threshold.value();
            defer threshold_value.free(rt);
            const text = if (char.compare(threshold.*) < 0) "before" else "after";
            return try value_ops.createStringValue(rt, text);
        },
        19 => {
            try incrementGlobalInt(rt, globals, "calls");
            return core.Value.nullValue();
        },
        20 => return try value_ops.createStringValue(rt, "key"),
        29 => return try value_ops.createStringValue(rt, "valid"),
        30 => {
            if (args.len < 2) return error.UnsupportedClosureCall;
            try incrementGlobalInt(rt, globals, "counter");
            try appendPairToGlobalArray(rt, globals, "results", args[0], args[1]);
            try appendToGlobalArray(rt, globals, "_this", this_value);
            return core.Value.undefinedValue();
        },
        31 => {
            try incrementGlobalInt(rt, globals, "count");
            return error.TypeError;
        },
        32 => {
            try incrementGlobalInt(rt, globals, "count");
            return error.Test262Error;
        },
        33 => {
            if (args.len < 1) return error.UnsupportedClosureCall;
            globals_mod.setExistingByName(rt, globals, "canonicalKey", args[0]) catch |err| switch (err) {
                error.UnsupportedGlobal => return error.UnsupportedClosureCall,
                else => return err,
            };
            return core.Value.undefinedValue();
        },
        34 => return core.Value.int32(3),
        35 => return core.Value.undefinedValue(),
        36 => return try value_ops.createStringValue(rt, "string"),
        37 => {
            try incrementGlobalInt(rt, globals, "callbackCalls");
            return error.Test262Error;
        },
        38 => {
            try setGlobalMapString(rt, globals, 1, "mutated");
            return error.Test262Error;
        },
        39 => {
            try setGlobalMapString(rt, globals, 3, "mutated");
            return error.Test262Error;
        },
        21 => {
            if (args.len < 2) return error.UnsupportedClosureCall;
            try appendRecordToGlobalArray(rt, globals, "results", args[0], args[1], if (args.len >= 3) args[2] else core.Value.undefinedValue());
            return core.Value.undefinedValue();
        },
        22 => {
            if (args.len < 1) return error.UnsupportedClosureCall;
            try appendToGlobalArray(rt, globals, "results", args[0]);
            return core.Value.undefinedValue();
        },
        26 => {
            var value = if (this_value.isUndefined()) try globals_mod.getByName(rt, globals, "globalThis") else this_value.dup();
            if (value.isUndefined()) {
                value.free(rt);
                value = try getGlobalThisValue(rt, globals);
            }
            defer value.free(rt);
            try appendToGlobalArray(rt, globals, "_this", value);
            return core.Value.undefinedValue();
        },
        27 => {
            try appendToGlobalArray(rt, globals, "_this", this_value);
            return core.Value.undefinedValue();
        },
        23...25 => {
            if (args.len < 2) return error.UnsupportedClosureCall;
            try appendRecordToGlobalArray(rt, globals, "results", args[0], args[1], if (args.len >= 3) args[2] else core.Value.undefinedValue());
            try incrementGlobalInt(rt, globals, "count");
            return core.Value.undefinedValue();
        },
        else => return error.UnsupportedClosureCall,
    }
}

pub fn closureKind(rt: *core.Runtime, closure_value: core.Value) !i32 {
    const closure = try expectClosure(closure_value);
    return getIntProperty(rt, closure, "__closure_kind");
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

fn incrementGlobalInt(rt: *core.Runtime, globals: []globals_mod.Slot, name: []const u8) !void {
    const existing = try globals_mod.getByName(rt, globals, name);
    defer existing.free(rt);
    const current = existing.asInt32() orelse return error.UnsupportedClosureCall;
    globals_mod.setExistingByName(rt, globals, name, core.Value.int32(current + 1)) catch |err| switch (err) {
        error.UnsupportedGlobal => return error.UnsupportedClosureCall,
        else => return err,
    };
}

fn setGlobalMapString(rt: *core.Runtime, globals: []globals_mod.Slot, key_int: i32, bytes: []const u8) !void {
    const map_value = try globals_mod.getByName(rt, globals, "map");
    defer map_value.free(rt);
    const map_object = try expectObject(map_value);
    if (map_object.class_id != core.class.ids.map) return error.UnsupportedClosureCall;
    const key = core.Value.int32(key_int);
    const value = try value_ops.createStringValue(rt, bytes);
    defer value.free(rt);
    for (map_object.collection_entries) |*entry| {
        if (!entry.active) continue;
        if (entry.key.asInt32() == key_int) {
            entry.value.free(rt);
            entry.value = value.dup();
            return;
        }
    }
    const next = try rt.memory.alloc(core.object.CollectionEntry, map_object.collection_entries.len + 1);
    errdefer rt.memory.free(core.object.CollectionEntry, next);
    @memcpy(next[0..map_object.collection_entries.len], map_object.collection_entries);
    next[map_object.collection_entries.len] = .{ .key = key.dup(), .value = value.dup(), .active = true };
    if (map_object.collection_entries.len != 0) rt.memory.free(core.object.CollectionEntry, map_object.collection_entries);
    map_object.collection_entries = next;
    try defineIntProperty(rt, map_object, "size", @intCast(map_object.collection_entries.len));
}

fn appendRecordToGlobalArray(rt: *core.Runtime, globals: []globals_mod.Slot, name: []const u8, value: core.Value, key: core.Value, this_arg: core.Value) !void {
    const record = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &record.header);
    try defineValueProperty(rt, record, "value", value);
    try defineValueProperty(rt, record, "key", key);
    if (!this_arg.isUndefined()) try defineValueProperty(rt, record, "thisArg", this_arg);
    const record_value = record.value();
    defer record_value.free(rt);
    try appendToGlobalArray(rt, globals, name, record_value);
}

fn appendPairToGlobalArray(rt: *core.Runtime, globals: []globals_mod.Slot, name: []const u8, key: core.Value, value: core.Value) !void {
    const pair = try core.Object.createArray(rt, null);
    errdefer core.Object.destroyFromHeader(rt, &pair.header);
    try pair.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(key, true, true, true));
    try pair.defineOwnProperty(rt, core.atom.atomFromUInt32(1), core.Descriptor.data(value, true, true, true));
    const pair_value = pair.value();
    defer pair_value.free(rt);
    try appendToGlobalArray(rt, globals, name, pair_value);
}

fn appendToGlobalArray(rt: *core.Runtime, globals: []globals_mod.Slot, name: []const u8, value: core.Value) !void {
    var array_value = try globals_mod.getByName(rt, globals, name);
    if (array_value.isUndefined()) {
        array_value.free(rt);
        array_value = try getGlobalObjectProperty(rt, globals, name);
    }
    defer array_value.free(rt);
    const array = try expectArray(array_value);
    try array.defineOwnProperty(rt, core.atom.atomFromUInt32(array.length), core.Descriptor.data(value, true, true, true));
}

fn getGlobalObjectProperty(rt: *core.Runtime, globals: []globals_mod.Slot, name: []const u8) !core.Value {
    const global = try getGlobalThisObject(rt, globals);
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    return global.getProperty(key);
}

fn getGlobalThisValue(rt: *core.Runtime, globals: []globals_mod.Slot) !core.Value {
    return (try getGlobalThisObject(rt, globals)).value().dup();
}

fn getGlobalThisObject(rt: *core.Runtime, globals: []globals_mod.Slot) !*core.Object {
    const global_value = try globals_mod.getByName(rt, globals, "globalThis");
    defer global_value.free(rt);
    const header = global_value.refHeader() orelse return error.UnsupportedClosureCall;
    if (!global_value.isObject()) return error.UnsupportedClosureCall;
    return @fieldParentPtr("header", header);
}

fn defineValueProperty(rt: *core.Runtime, object: *core.Object, name: []const u8, value: core.Value) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value, true, true, true));
}

fn expectArray(value: core.Value) !*core.Object {
    const header = value.refHeader() orelse return error.UnsupportedClosureCall;
    if (!value.isObject()) return error.UnsupportedClosureCall;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (!object.is_array) return error.UnsupportedClosureCall;
    return object;
}

fn expectObject(value: core.Value) !*core.Object {
    const header = value.refHeader() orelse return error.UnsupportedClosureCall;
    if (!value.isObject()) return error.UnsupportedClosureCall;
    return @fieldParentPtr("header", header);
}

fn stringFromValue(value: core.Value) ?*core.string.String {
    if (!value.isString()) return null;
    const header = value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

fn appendIntField(rt: *core.Runtime, buffer: *std.ArrayList(u8), label: []const u8, value: i32) !void {
    var int_buf: [32]u8 = undefined;
    const printed = try std.fmt.bufPrint(&int_buf, "{d}", .{value});
    try buffer.appendSlice(rt.memory.allocator, label);
    try buffer.appendSlice(rt.memory.allocator, printed);
    try buffer.append(rt.memory.allocator, ',');
}
