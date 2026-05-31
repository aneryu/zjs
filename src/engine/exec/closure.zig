const core = @import("../core/root.zig");
const bytecode = @import("../bytecode/root.zig");
const collection_builtin = @import("../builtins/collection.zig");
const object_builtin = @import("../builtins/object.zig");
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
            if (args.len != 0) return error.TypeError;
            const value = try getIntProperty(rt, closure, "__closure_value") + 1;
            try defineIntProperty(rt, closure, "__closure_value", value);
            return core.Value.int32(value);
        },
        3 => {
            if (args.len != 1) return error.TypeError;
            const captured = try getIntProperty(rt, closure, "__closure_value");
            const arg = args[0].asInt32() orelse return error.TypeError;
            return core.Value.int32(captured + arg);
        },
        5 => {
            if (args.len != 1) return error.TypeError;
            const d = args[0].asInt32() orelse return error.TypeError;
            const b = try getIntProperty(rt, closure, "__closure_b");
            const c = try getIntProperty(rt, closure, "__closure_c");
            try appendLog(rt, globals, .again, 0, b, c, d);
            return core.Value.undefinedValue();
        },
        6 => {
            if (args.len != 1) return error.TypeError;
            const multiplier = try getIntProperty(rt, closure, "__closure_value");
            const arg = args[0].asInt32() orelse return error.TypeError;
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
            if (args.len < 1) return error.TypeError;
            const string = stringFromValue(args[0]) orelse return error.TypeError;
            return core.Value.int32(@intCast(string.len()));
        },
        16 => {
            if (args.len < 1) return error.TypeError;
            const value = args[0].asInt32() orelse return error.TypeError;
            return try value_ops.createStringValue(rt, if (@mod(value, 2) == 0) "even" else "odd");
        },
        17 => {
            if (args.len < 1) return error.TypeError;
            return args[0].dup();
        },
        18 => {
            if (args.len < 1) return error.TypeError;
            const char = stringFromValue(args[0]) orelse return error.TypeError;
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
            if (args.len < 2) return error.TypeError;
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
            if (args.len < 1) return error.TypeError;
            try globals_mod.setExistingByName(rt, globals, "canonicalKey", args[0]);
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
        40 => {
            try incrementGlobalInt(rt, globals, "count");
            return core.Value.undefinedValue();
        },
        41 => return error.Test262Error,
        42 => return iteratorNextValueGetterThrows(rt, closure),
        43 => return iteratorNextGlobalValue(rt, closure, globals, "nextItem"),
        44 => return iteratorNextGlobalValue(rt, closure, globals, "item"),
        45 => return iteratorNextEmptyArray(rt, closure),
        52 => return iteratorNextNull(rt, closure),
        53 => {
            const shape = try getIntProperty(rt, closure, "__closure_value");
            return arrayFromShape(rt, shape);
        },
        54 => {
            if (args.len < 1) return error.TypeError;
            const value = args[0].asInt32() orelse return error.Test262Error;
            if (value == 1) return core.Value.boolean(false);
            if (value == 2) return core.Value.boolean(true);
            return error.Test262Error;
        },
        55 => {
            try incrementGlobalInt(rt, globals, "coercionCalls");
            return error.TypeError;
        },
        46 => {
            const shape = try getIntProperty(rt, closure, "__closure_value");
            return iteratorFactory(rt, shape);
        },
        47 => {
            if (args.len < 2) return error.TypeError;
            try appendWeakMapAdderRecord(rt, globals, args[0], args[1], this_value);
            return core.Value.undefinedValue();
        },
        48 => {
            if (args.len < 1) return error.TypeError;
            try appendToGlobalArray(rt, globals, "added", args[0]);
            return core.Value.undefinedValue();
        },
        49 => {
            if (args.len < 1) return error.TypeError;
            try assertAndShiftExpected(rt, globals, args[0]);
            return core.Value.undefinedValue();
        },
        56 => return setForEachMutation(rt, globals, args, .add_after_begin),
        57 => return setForEachMutation(rt, globals, args, .delete_then_readd),
        58 => return setForEachMutation(rt, globals, args, .revisit_after_readd),
        50 => {
            try incrementGlobalInt(rt, globals, "counter");
            return core.Value.undefinedValue();
        },
        61 => {
            try incrementGlobalInt(rt, globals, "counter");
            return error.Test262Error;
        },
        62 => {
            if (args.len < 1) return error.TypeError;
            const value = args[0].asInt32() orelse return error.Test262Error;
            if (value == 1 or value == 2) return core.Value.boolean(true);
            return error.Test262Error;
        },
        63 => {
            if (args.len < 1) return error.TypeError;
            const value = args[0].asInt32() orelse return error.Test262Error;
            if (value == 1 or value == 2) return core.Value.boolean(false);
            return error.Test262Error;
        },
        64 => {
            if (args.len < 1) return error.TypeError;
            if (args[0].asInt32()) |value| return core.Value.boolean(value == 4 or value == 5 or value == 6);
            const string = stringFromValue(args[0]) orelse return core.Value.boolean(false);
            return core.Value.boolean(string.eqlBytes("a") or string.eqlBytes("b") or string.eqlBytes("c") or string.eqlBytes("x"));
        },
        21 => {
            if (args.len < 2) return error.TypeError;
            try appendRecordToGlobalArray(rt, globals, "results", args[0], args[1], if (args.len >= 3) args[2] else core.Value.undefinedValue());
            return core.Value.undefinedValue();
        },
        22 => {
            if (args.len < 1) return error.TypeError;
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
            if (args.len < 2) return error.TypeError;
            try appendRecordToGlobalArray(rt, globals, "results", args[0], args[1], if (args.len >= 3) args[2] else core.Value.undefinedValue());
            try incrementGlobalInt(rt, globals, "count");
            return core.Value.undefinedValue();
        },
        else => return error.TypeError,
    }
}

pub fn closureKind(rt: *core.Runtime, closure_value: core.Value) !i32 {
    const closure = try expectClosure(closure_value);
    return getIntProperty(rt, closure, "__closure_kind");
}

pub fn closureValue(rt: *core.Runtime, closure_value: core.Value) !i32 {
    const closure = try expectClosure(closure_value);
    return getIntProperty(rt, closure, "__closure_value");
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
    try globals_mod.setExistingByName(rt, globals, "log_str", value);
}

fn expectClosure(value: core.Value) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    const closure: *core.Object = @fieldParentPtr("header", header);
    if (closure.class_id != core.class.ids.c_closure) return error.TypeError;
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
    return value.asInt32() orelse error.TypeError;
}

fn incrementGlobalInt(rt: *core.Runtime, globals: []globals_mod.Slot, name: []const u8) !void {
    const existing = try globals_mod.getByName(rt, globals, name);
    defer existing.free(rt);
    const current = existing.asInt32() orelse return error.TypeError;
    try globals_mod.setExistingByName(rt, globals, name, core.Value.int32(current + 1));
}

fn iteratorFactory(rt: *core.Runtime, shape: i32) !core.Value {
    const iterator = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &iterator.header);

    const next_kind: i32 = switch (shape) {
        1 => 41,
        2 => 42,
        3 => 43,
        4 => 44,
        5, 6 => 45,
        8 => 52,
        else => return error.TypeError,
    };
    const next = try create(rt, next_kind, 0, 0, 0);
    defer next.free(rt);
    try defineValueProperty(rt, iterator, "next", next);

    const return_kind: ?i32 = switch (shape) {
        3, 4, 5, 8 => 40,
        6 => 7,
        else => null,
    };
    if (return_kind) |kind| {
        const return_fn = try create(rt, kind, 0, 0, 0);
        defer return_fn.free(rt);
        try defineValueProperty(rt, iterator, "return", return_fn);
    }

    return iterator.value();
}

fn iteratorNextGlobalValue(rt: *core.Runtime, closure: *core.Object, globals: []globals_mod.Slot, name: []const u8) !core.Value {
    if (try iteratorNextDoneIfConsumed(rt, closure)) |done| return done;
    const value = try globals_mod.getByName(rt, globals, name);
    defer value.free(rt);
    return iteratorResult(rt, value, false);
}

fn iteratorNextEmptyArray(rt: *core.Runtime, closure: *core.Object) !core.Value {
    if (try iteratorNextDoneIfConsumed(rt, closure)) |done| return done;
    const value = try core.Object.createArray(rt, null);
    defer value.value().free(rt);
    return iteratorResult(rt, value.value(), false);
}

fn iteratorNextNull(rt: *core.Runtime, closure: *core.Object) !core.Value {
    if (try iteratorNextDoneIfConsumed(rt, closure)) |done| return done;
    return iteratorResult(rt, core.Value.nullValue(), false);
}

fn iteratorNextValueGetterThrows(rt: *core.Runtime, closure: *core.Object) !core.Value {
    if (try iteratorNextDoneIfConsumed(rt, closure)) |done| return done;
    const result = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &result.header);
    const getter = try create(rt, 12, 0, 0, 0);
    defer getter.free(rt);
    const value_key = try rt.internAtom("value");
    defer rt.atoms.free(value_key);
    try result.defineOwnProperty(rt, value_key, core.Descriptor.accessor(getter, core.Value.undefinedValue(), true, true));
    try defineValueProperty(rt, result, "done", core.Value.boolean(false));
    return result.value();
}

fn iteratorNextDoneIfConsumed(rt: *core.Runtime, closure: *core.Object) !?core.Value {
    const consumed = try getIntProperty(rt, closure, "__closure_value");
    if (consumed != 0) return try iteratorResult(rt, core.Value.undefinedValue(), true);
    try defineIntProperty(rt, closure, "__closure_value", 1);
    return null;
}

fn iteratorResult(rt: *core.Runtime, value: core.Value, done: bool) !core.Value {
    var rooted_value = value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const result = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &result.header);
    try defineValueProperty(rt, result, "value", rooted_value);
    try defineValueProperty(rt, result, "done", core.Value.boolean(done));
    return result.value();
}

test "closure iteratorResult roots direct function bytecode value while creating result" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-closure-iterator-result-bytecode-symbol");
    fb.cpool = try rt.memory.alloc(core.Value, 1);
    fb.cpool[0] = core.Value.symbol(symbol_atom);
    fb.cpool_count = 1;

    var result_value = core.Value.functionBytecode(&fb.header);
    var result_alive = true;
    defer if (result_alive) result_value.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const iterator_result_value = try iteratorResult(rt, result_value, false);
    var iterator_result_alive = true;
    defer if (iterator_result_alive) iterator_result_value.free(rt);
    const iterator_result = try expectObject(iterator_result_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const value_atom = try rt.internAtom("value");
    defer rt.atoms.free(value_atom);
    const stored = iterator_result.getProperty(value_atom);
    defer stored.free(rt);
    try std.testing.expect(stored.same(result_value));

    iterator_result_value.free(rt);
    iterator_result_alive = false;
    result_value.free(rt);
    result_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

const TestFunctionBytecodeValue = struct {
    value: core.Value,
    symbol_atom: core.Atom,
};

fn createTestFunctionBytecodeValue(rt: *core.Runtime, symbol_name: []const u8) !TestFunctionBytecodeValue {
    const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);

    const symbol_atom = try rt.atoms.newValueSymbol(symbol_name);
    fb.cpool = try rt.memory.alloc(core.Value, 1);
    fb.cpool[0] = core.Value.symbol(symbol_atom);
    fb.cpool_count = 1;

    return .{
        .value = core.Value.functionBytecode(&fb.header),
        .symbol_atom = symbol_atom,
    };
}

fn expectObjectPropertySame(rt: *core.Runtime, object: *core.Object, name: []const u8, expected: core.Value) !void {
    const atom_id = try rt.internAtom(name);
    defer rt.atoms.free(atom_id);
    const stored = object.getProperty(atom_id);
    defer stored.free(rt);
    try std.testing.expect(stored.same(expected));
}

fn expectArrayIndexSame(rt: *core.Runtime, array: *core.Object, index: u32, expected: core.Value) !void {
    const stored = array.getProperty(core.atom.atomFromUInt32(index));
    defer stored.free(rt);
    try std.testing.expect(stored.same(expected));
}

test "appendRecordToGlobalArray roots direct function bytecode fields while creating record" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const results_name = try rt.internAtom("results");
    defer rt.atoms.free(results_name);
    const results = try core.Object.createArray(rt, null);
    var globals = [_]globals_mod.Slot{
        .{ .name = results_name, .value = results.value() },
    };
    var results_alive = true;
    defer if (results_alive) globals[0].value.free(rt);

    const record_value = try createTestFunctionBytecodeValue(rt, "gc-closure-record-value-bytecode-symbol");
    var record_value_alive = true;
    defer if (record_value_alive) record_value.value.free(rt);
    const record_key = try createTestFunctionBytecodeValue(rt, "gc-closure-record-key-bytecode-symbol");
    var record_key_alive = true;
    defer if (record_key_alive) record_key.value.free(rt);
    const record_this = try createTestFunctionBytecodeValue(rt, "gc-closure-record-this-bytecode-symbol");
    var record_this_alive = true;
    defer if (record_this_alive) record_this.value.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    try appendRecordToGlobalArray(rt, &globals, "results", record_value.value, record_key.value, record_this.value);

    try std.testing.expect(rt.atoms.name(record_value.symbol_atom) != null);
    try std.testing.expect(rt.atoms.name(record_key.symbol_atom) != null);
    try std.testing.expect(rt.atoms.name(record_this.symbol_atom) != null);

    {
        const stored_record_value = results.getProperty(core.atom.atomFromUInt32(0));
        defer stored_record_value.free(rt);
        const stored_record = try expectObject(stored_record_value);
        try expectObjectPropertySame(rt, stored_record, "value", record_value.value);
        try expectObjectPropertySame(rt, stored_record, "key", record_key.value);
        try expectObjectPropertySame(rt, stored_record, "thisArg", record_this.value);
    }

    record_value.value.free(rt);
    record_value_alive = false;
    record_key.value.free(rt);
    record_key_alive = false;
    record_this.value.free(rt);
    record_this_alive = false;
    globals[0].value.free(rt);
    results_alive = false;

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(record_value.symbol_atom) == null);
    try std.testing.expect(rt.atoms.name(record_key.symbol_atom) == null);
    try std.testing.expect(rt.atoms.name(record_this.symbol_atom) == null);
}

test "appendWeakMapAdderRecord roots direct function bytecode fields while creating record" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const results_name = try rt.internAtom("results");
    defer rt.atoms.free(results_name);
    const results = try core.Object.createArray(rt, null);
    var globals = [_]globals_mod.Slot{
        .{ .name = results_name, .value = results.value() },
    };
    var results_alive = true;
    defer if (results_alive) globals[0].value.free(rt);

    const record_key = try createTestFunctionBytecodeValue(rt, "gc-closure-weakmap-record-key-bytecode-symbol");
    var record_key_alive = true;
    defer if (record_key_alive) record_key.value.free(rt);
    const record_value = try createTestFunctionBytecodeValue(rt, "gc-closure-weakmap-record-value-bytecode-symbol");
    var record_value_alive = true;
    defer if (record_value_alive) record_value.value.free(rt);
    const record_this = try createTestFunctionBytecodeValue(rt, "gc-closure-weakmap-record-this-bytecode-symbol");
    var record_this_alive = true;
    defer if (record_this_alive) record_this.value.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    try appendWeakMapAdderRecord(rt, &globals, record_key.value, record_value.value, record_this.value);

    try std.testing.expect(rt.atoms.name(record_key.symbol_atom) != null);
    try std.testing.expect(rt.atoms.name(record_value.symbol_atom) != null);
    try std.testing.expect(rt.atoms.name(record_this.symbol_atom) != null);

    {
        const stored_record_value = results.getProperty(core.atom.atomFromUInt32(0));
        defer stored_record_value.free(rt);
        const stored_record = try expectObject(stored_record_value);
        try expectObjectPropertySame(rt, stored_record, "_this", record_this.value);
        try expectObjectPropertySame(rt, stored_record, "key", record_key.value);
        try expectObjectPropertySame(rt, stored_record, "value", record_value.value);
    }

    record_key.value.free(rt);
    record_key_alive = false;
    record_value.value.free(rt);
    record_value_alive = false;
    record_this.value.free(rt);
    record_this_alive = false;
    globals[0].value.free(rt);
    results_alive = false;

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(record_key.symbol_atom) == null);
    try std.testing.expect(rt.atoms.name(record_value.symbol_atom) == null);
    try std.testing.expect(rt.atoms.name(record_this.symbol_atom) == null);
}

test "appendPairToGlobalArray roots direct function bytecode entries while creating pair" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const results_name = try rt.internAtom("results");
    defer rt.atoms.free(results_name);
    const results = try core.Object.createArray(rt, null);
    var globals = [_]globals_mod.Slot{
        .{ .name = results_name, .value = results.value() },
    };
    var results_alive = true;
    defer if (results_alive) globals[0].value.free(rt);

    const pair_key = try createTestFunctionBytecodeValue(rt, "gc-closure-pair-key-bytecode-symbol");
    var pair_key_alive = true;
    defer if (pair_key_alive) pair_key.value.free(rt);
    const pair_value = try createTestFunctionBytecodeValue(rt, "gc-closure-pair-value-bytecode-symbol");
    var pair_value_alive = true;
    defer if (pair_value_alive) pair_value.value.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    try appendPairToGlobalArray(rt, &globals, "results", pair_key.value, pair_value.value);

    try std.testing.expect(rt.atoms.name(pair_key.symbol_atom) != null);
    try std.testing.expect(rt.atoms.name(pair_value.symbol_atom) != null);

    {
        const stored_pair_value = results.getProperty(core.atom.atomFromUInt32(0));
        defer stored_pair_value.free(rt);
        const stored_pair = try expectArray(stored_pair_value);
        try expectArrayIndexSame(rt, stored_pair, 0, pair_key.value);
        try expectArrayIndexSame(rt, stored_pair, 1, pair_value.value);
    }

    pair_key.value.free(rt);
    pair_key_alive = false;
    pair_value.value.free(rt);
    pair_value_alive = false;
    globals[0].value.free(rt);
    results_alive = false;

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(pair_key.symbol_atom) == null);
    try std.testing.expect(rt.atoms.name(pair_value.symbol_atom) == null);
}

test "appendToGlobalArray roots direct function bytecode value while appending" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const results_name = try rt.internAtom("results");
    defer rt.atoms.free(results_name);
    const results = try core.Object.createArray(rt, null);
    var globals = [_]globals_mod.Slot{
        .{ .name = results_name, .value = results.value() },
    };
    var results_alive = true;
    defer if (results_alive) globals[0].value.free(rt);

    const item = try createTestFunctionBytecodeValue(rt, "gc-closure-global-array-value-bytecode-symbol");
    var item_alive = true;
    defer if (item_alive) item.value.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    try appendToGlobalArray(rt, &globals, "results", item.value);

    try std.testing.expect(rt.atoms.name(item.symbol_atom) != null);
    try expectArrayIndexSame(rt, results, 0, item.value);

    item.value.free(rt);
    item_alive = false;
    globals[0].value.free(rt);
    results_alive = false;

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(item.symbol_atom) == null);
}

test "appendArrayValue roots direct function bytecode value while appending" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const array = try core.Object.createArray(rt, null);
    const array_value = array.value();
    var array_alive = true;
    defer if (array_alive) array_value.free(rt);

    const item = try createTestFunctionBytecodeValue(rt, "gc-closure-array-value-bytecode-symbol");
    var item_alive = true;
    defer if (item_alive) item.value.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    try appendArrayValue(rt, array, item.value);

    try std.testing.expect(rt.atoms.name(item.symbol_atom) != null);
    try expectArrayIndexSame(rt, array, 0, item.value);

    item.value.free(rt);
    item_alive = false;
    array_value.free(rt);
    array_alive = false;

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(item.symbol_atom) == null);
}

fn arrayFromShape(rt: *core.Runtime, shape: i32) !core.Value {
    const array = try core.Object.createArray(rt, null);
    errdefer core.Object.destroyFromHeader(rt, &array.header);
    switch (shape) {
        0 => {},
        1 => try appendArrayValue(rt, array, core.Value.int32(1)),
        23 => {
            try appendArrayValue(rt, array, core.Value.int32(2));
            try appendArrayValue(rt, array, core.Value.int32(3));
        },
        234 => {
            try appendArrayValue(rt, array, core.Value.int32(2));
            try appendArrayValue(rt, array, core.Value.int32(3));
            try appendArrayValue(rt, array, core.Value.int32(4));
        },
        100 => try appendArrayValue(rt, array, core.Value.int32(0)),
        101 => {
            const a_value = try value_ops.createStringValue(rt, "a");
            defer a_value.free(rt);
            const b_value = try value_ops.createStringValue(rt, "b");
            defer b_value.free(rt);
            try appendArrayValue(rt, array, a_value);
            try appendArrayValue(rt, array, b_value);
        },
        102 => {
            const a_value = try value_ops.createStringValue(rt, "a");
            defer a_value.free(rt);
            const b_value = try value_ops.createStringValue(rt, "b");
            defer b_value.free(rt);
            const c_value = try value_ops.createStringValue(rt, "c");
            defer c_value.free(rt);
            try appendArrayValue(rt, array, a_value);
            try appendArrayValue(rt, array, b_value);
            try appendArrayValue(rt, array, c_value);
        },
        103 => {
            const x_value = try value_ops.createStringValue(rt, "x");
            defer x_value.free(rt);
            const b_value = try value_ops.createStringValue(rt, "b");
            defer b_value.free(rt);
            try appendArrayValue(rt, array, x_value);
            try appendArrayValue(rt, array, b_value);
            try appendArrayValue(rt, array, b_value);
        },
        104 => {
            const x_value = try value_ops.createStringValue(rt, "x");
            defer x_value.free(rt);
            const b_value = try value_ops.createStringValue(rt, "b");
            defer b_value.free(rt);
            const c_value = try value_ops.createStringValue(rt, "c");
            defer c_value.free(rt);
            try appendArrayValue(rt, array, x_value);
            try appendArrayValue(rt, array, b_value);
            try appendArrayValue(rt, array, c_value);
            try appendArrayValue(rt, array, c_value);
        },
        else => return error.TypeError,
    }
    return array.value();
}

fn appendArrayValue(rt: *core.Runtime, array: *core.Object, value: core.Value) !void {
    var rooted_value = value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    if (!array.is_array) return error.TypeError;
    try array.defineOwnProperty(rt, core.atom.atomFromUInt32(array.length), core.Descriptor.data(rooted_value, true, true, true));
}

fn setGlobalMapString(rt: *core.Runtime, globals: []globals_mod.Slot, key_int: i32, bytes: []const u8) !void {
    const map_value = try globals_mod.getByName(rt, globals, "map");
    defer map_value.free(rt);
    const map_object = try expectObject(map_value);
    if (map_object.class_id == core.class.ids.weakmap) return setGlobalWeakMapString(rt, globals, map_object, key_int, bytes);
    if (map_object.class_id != core.class.ids.map) return error.TypeError;
    const key = core.Value.int32(key_int);
    const value = try value_ops.createStringValue(rt, bytes);
    defer value.free(rt);
    for (map_object.collectionEntriesSlot().*) |*entry| {
        if (!entry.active) continue;
        if (entry.key.asInt32() == key_int) {
            const next_value = value.dup();
            const old_value = entry.value;
            entry.value = next_value;
            old_value.free(rt);
            return;
        }
    }
    try appendUnindexedCollectionEntryAndDefineSize(rt, map_object, .{ .key = key.dup(), .value = value.dup(), .active = true });
}

fn setGlobalWeakMapString(rt: *core.Runtime, globals: []globals_mod.Slot, map_object: *core.Object, key_int: i32, bytes: []const u8) !void {
    var key_name_buf: [32]u8 = undefined;
    const key_name = try std.fmt.bufPrint(&key_name_buf, "obj{d}", .{key_int});
    var key_value = try globals_mod.getByName(rt, globals, key_name);
    if (key_value.isUndefined()) {
        key_value.free(rt);
        key_value = try getGlobalObjectProperty(rt, globals, key_name);
    }
    defer key_value.free(rt);
    const value = try value_ops.createStringValue(rt, bytes);
    defer value.free(rt);
    try collection_builtin.setWeakMapEntry(rt, map_object, key_value, value);
}

fn appendRecordToGlobalArray(rt: *core.Runtime, globals: []globals_mod.Slot, name: []const u8, value: core.Value, key: core.Value, this_arg: core.Value) !void {
    var rooted_value = value;
    var rooted_key = key;
    var rooted_this_arg = this_arg;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
        .{ .value = &rooted_key },
        .{ .value = &rooted_this_arg },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const record = try core.Object.create(rt, core.class.ids.object, null);
    const record_value = record.value();
    defer record_value.free(rt);
    try defineValueProperty(rt, record, "value", rooted_value);
    try defineValueProperty(rt, record, "key", rooted_key);
    if (!rooted_this_arg.isUndefined()) try defineValueProperty(rt, record, "thisArg", rooted_this_arg);
    try appendToGlobalArray(rt, globals, name, record_value);
}

fn appendWeakMapAdderRecord(rt: *core.Runtime, globals: []globals_mod.Slot, key: core.Value, value: core.Value, this_arg: core.Value) !void {
    var rooted_key = key;
    var rooted_value = value;
    var rooted_this_arg = this_arg;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_key },
        .{ .value = &rooted_value },
        .{ .value = &rooted_this_arg },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const record = try core.Object.create(rt, core.class.ids.object, null);
    const record_value = record.value();
    defer record_value.free(rt);
    try defineValueProperty(rt, record, "_this", rooted_this_arg);
    try defineValueProperty(rt, record, "key", rooted_key);
    try defineValueProperty(rt, record, "value", rooted_value);
    try appendToGlobalArray(rt, globals, "results", record_value);
}

fn assertAndShiftExpected(rt: *core.Runtime, globals: []globals_mod.Slot, actual: core.Value) !void {
    const expects_value = try globals_mod.getByName(rt, globals, "expects");
    defer expects_value.free(rt);
    const expects = try expectArray(expects_value);
    if (expects.length == 0) return error.Test262Error;
    const expected = expects.getProperty(core.atom.atomFromUInt32(0));
    defer expected.free(rt);
    if (!object_builtin.sameValue(actual, expected)) return error.Test262Error;
    var index: u32 = 1;
    while (index < expects.length) : (index += 1) {
        const next = expects.getProperty(core.atom.atomFromUInt32(index));
        defer next.free(rt);
        try expects.defineOwnProperty(rt, core.atom.atomFromUInt32(index - 1), core.Descriptor.data(next, true, true, true));
    }
    expects.length -= 1;
}

const SetForEachMutation = enum {
    add_after_begin,
    delete_then_readd,
    revisit_after_readd,
};

fn setForEachMutation(rt: *core.Runtime, globals: []globals_mod.Slot, args: []const core.Value, mode: SetForEachMutation) !core.Value {
    if (args.len < 3) return error.TypeError;
    try assertAndShiftExpected(rt, globals, args[0]);
    const value = args[0].asInt32() orelse return error.TypeError;
    const set = try expectObject(args[2]);
    if (set.class_id != core.class.ids.set) return error.TypeError;
    switch (mode) {
        .add_after_begin => {
            if (value == 1) try setAddInt(rt, set, 2);
            if (value == 2) try setAddInt(rt, set, 3);
        },
        .delete_then_readd => {
            if (value == 1) try setDeleteInt(rt, set, 2);
            if (value == 3) try setAddInt(rt, set, 2);
        },
        .revisit_after_readd => {
            if (value == 2) try setDeleteInt(rt, set, 1);
            if (value == 3) try setAddInt(rt, set, 1);
        },
    }
    return core.Value.undefinedValue();
}

fn setAddInt(rt: *core.Runtime, set: *core.Object, value: i32) !void {
    for (set.collectionEntriesSlot().*) |entry| {
        if (!entry.active) continue;
        if (entry.key.asInt32() == value) return;
    }
    try appendUnindexedCollectionEntryAndDefineSize(rt, set, .{ .key = core.Value.int32(value), .value = core.Value.undefinedValue(), .active = true });
}

fn setDeleteInt(rt: *core.Runtime, set: *core.Object, value: i32) !void {
    for (set.collectionEntriesSlot().*, 0..) |*entry, index| {
        if (!entry.active) continue;
        if (entry.key.asInt32() == value) {
            try removeUnindexedCollectionEntryAndDefineSize(rt, set, index);
            return;
        }
    }
}

fn appendUnindexedCollectionEntryAndDefineSize(rt: *core.Runtime, object: *core.Object, entry: core.object.CollectionEntry) !void {
    const pending_entry = entry;
    var entry_owned = true;
    errdefer if (entry_owned) pending_entry.destroy(rt);

    const index = try object.appendCollectionEntryUnindexed(rt, pending_entry);
    entry_owned = false;
    object.collectionActiveCountSlot().* += 1;

    var inserted = true;
    errdefer if (inserted) rollbackLastUnindexedCollectionEntry(rt, object, index);

    object.clearCollectionIndex(rt);
    try defineIntProperty(rt, object, "size", @intCast(object.collectionActiveCount()));
    inserted = false;
}

fn rollbackLastUnindexedCollectionEntry(rt: *core.Runtime, object: *core.Object, index: usize) void {
    const entries_slot = object.collectionEntriesSlot();
    std.debug.assert(index + 1 == entries_slot.*.len);
    if (!entries_slot.*[index].active) return;
    const removed = entries_slot.*[index];
    entries_slot.*[index] = .{ .key = core.Value.undefinedValue(), .value = core.Value.undefinedValue(), .active = false };
    entries_slot.* = entries_slot.*.ptr[0..index];
    const active_count = object.collectionActiveCountSlot();
    if (active_count.* != 0) active_count.* -= 1;
    removed.destroy(rt);
}

fn removeUnindexedCollectionEntryAndDefineSize(rt: *core.Runtime, object: *core.Object, index: usize) !void {
    const entries = object.collectionEntriesSlot().*;
    std.debug.assert(index < entries.len);
    std.debug.assert(entries[index].active);

    const removed = entries[index];
    entries[index] = .{ .key = core.Value.undefinedValue(), .value = core.Value.undefinedValue(), .active = false };
    const active_count = object.collectionActiveCountSlot();
    const old_active_count = active_count.*;
    if (active_count.* != 0) active_count.* -= 1;
    object.clearCollectionIndex(rt);

    var committed = false;
    errdefer if (!committed) {
        object.collectionEntriesSlot().*[index] = removed;
        object.collectionActiveCountSlot().* = old_active_count;
        object.clearCollectionIndex(rt);
    };

    try defineIntProperty(rt, object, "size", @intCast(object.collectionActiveCount()));
    committed = true;
    removed.destroy(rt);
}

fn appendPairToGlobalArray(rt: *core.Runtime, globals: []globals_mod.Slot, name: []const u8, key: core.Value, value: core.Value) !void {
    var rooted_key = key;
    var rooted_value = value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_key },
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const pair = try core.Object.createArray(rt, null);
    const pair_value = pair.value();
    defer pair_value.free(rt);
    try pair.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(rooted_key, true, true, true));
    try pair.defineOwnProperty(rt, core.atom.atomFromUInt32(1), core.Descriptor.data(rooted_value, true, true, true));
    try appendToGlobalArray(rt, globals, name, pair_value);
}

fn appendToGlobalArray(rt: *core.Runtime, globals: []globals_mod.Slot, name: []const u8, value: core.Value) !void {
    var rooted_value = value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    var array_value = try globals_mod.getByName(rt, globals, name);
    if (array_value.isUndefined()) {
        array_value.free(rt);
        array_value = try getGlobalObjectProperty(rt, globals, name);
    }
    defer array_value.free(rt);
    const array = try expectArray(array_value);
    try array.defineOwnProperty(rt, core.atom.atomFromUInt32(array.length), core.Descriptor.data(rooted_value, true, true, true));
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
    const header = global_value.refHeader() orelse return error.TypeError;
    if (!global_value.isObject()) return error.TypeError;
    return @fieldParentPtr("header", header);
}

fn defineValueProperty(rt: *core.Runtime, object: *core.Object, name: []const u8, value: core.Value) !void {
    var rooted_value = value;
    var root_values = [_]core.runtime.ValueRootValue{
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
    try object.defineOwnProperty(rt, key, core.Descriptor.data(rooted_value, true, true, true));
}

fn expectArray(value: core.Value) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (!object.is_array) return error.TypeError;
    return object;
}

fn expectObject(value: core.Value) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
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
