//! Synthetic `c_closure` callback bodies used by collection adapters and tests.
//!
//! Each object owns its numeric `__closure_*` state as ordinary properties;
//! call arguments and global slots are borrowed, while returned heap values
//! carry an owned reference. This is not bytecode closure construction, which
//! remains in the core function representation and VM call machinery. The
//! numeric fixture cases stay local to this module and are dispatched through
//! `call.zig` and `collection_adapter.zig`.

const core = @import("../core/root.zig");
const iterator_ops = @import("iterator_ops.zig");
const bytecode = @import("../bytecode.zig");
const globals_mod = core.global_slots;
const value_ops = @import("value_ops.zig");
const std = @import("std");

pub const LogMode = enum { initial, again };

pub fn create(rt: *core.JSRuntime, kind: i32, value: i32, b: i32, c: i32) !core.JSValue {
    const object = try core.Object.create(rt, core.class.ids.c_closure, null);
    errdefer core.Object.destroyFromHeader(rt, object.gcHeader());
    try defineIntProperty(rt, object, "__closure_kind", kind);
    try defineIntProperty(rt, object, "__closure_value", value);
    try defineIntProperty(rt, object, "__closure_b", b);
    try defineIntProperty(rt, object, "__closure_c", c);
    return object.value();
}

pub fn call(rt: *core.JSRuntime, closure_value: core.JSValue, args: []const core.JSValue, globals: []globals_mod.Slot) !core.JSValue {
    return callWithThis(rt, closure_value, core.JSValue.undefinedValue(), args, globals);
}

pub fn callWithThis(rt: *core.JSRuntime, closure_value: core.JSValue, this_value: core.JSValue, args: []const core.JSValue, globals: []globals_mod.Slot) !core.JSValue {
    const closure = try expectClosure(closure_value);
    const kind = try closureKind(rt, closure_value);
    switch (kind) {
        1 => {
            const value = try getIntProperty(rt, closure, "__closure_value");
            return core.JSValue.int32(value);
        },
        2 => {
            if (args.len != 0) return error.TypeError;
            const value = try getIntProperty(rt, closure, "__closure_value") + 1;
            try defineIntProperty(rt, closure, "__closure_value", value);
            return core.JSValue.int32(value);
        },
        3 => {
            if (args.len != 1) return error.TypeError;
            const captured = try getIntProperty(rt, closure, "__closure_value");
            const arg = args[0].asInt32() orelse return error.TypeError;
            return core.JSValue.int32(captured + arg);
        },
        5 => {
            if (args.len != 1) return error.TypeError;
            const d = args[0].asInt32() orelse return error.TypeError;
            const b = try getIntProperty(rt, closure, "__closure_b");
            const c = try getIntProperty(rt, closure, "__closure_c");
            try appendLog(rt, globals, .again, 0, b, c, d);
            return core.JSValue.undefinedValue();
        },
        6 => {
            if (args.len != 1) return error.TypeError;
            const multiplier = try getIntProperty(rt, closure, "__closure_value");
            const arg = args[0].asInt32() orelse return error.TypeError;
            return core.JSValue.int32(arg * multiplier);
        },
        7 => return error.TypeError,
        8 => return error.SyntaxError,
        9 => return error.RangeError,
        10 => return error.EvalError,
        11 => return error.ReferenceError,
        12 => return error.JSException,
        13 => return core.JSValue.undefinedValue(),
        14 => return core.JSValue.nullValue(),
        15 => {
            if (args.len < 1) return error.TypeError;
            const string = args[0].asStringBody() orelse return error.TypeError;
            return core.JSValue.int32(@intCast(string.len()));
        },
        16 => {
            if (args.len < 1) return error.TypeError;
            const value = args[0].asInt32() orelse return error.TypeError;
            return try value_ops.createStringValue(rt, if (@mod(value, 2) == 0) "even" else "odd");
        },
        17 => {
            if (args.len < 1) return error.TypeError;
            return args[0];
        },
        18 => {
            if (args.len < 1) return error.TypeError;
            const char = args[0].asStringBody() orelse return error.TypeError;
            const threshold = try core.string.String.createUtf8(rt, "\xF0\x9F\x99\x8F");
            const text = if (char.compare(threshold) < 0) "before" else "after";
            return try value_ops.createStringValue(rt, text);
        },
        19 => {
            try incrementGlobalInt(rt, globals, "calls");
            return core.JSValue.nullValue();
        },
        20 => return try value_ops.createStringValue(rt, "key"),
        29 => return try value_ops.createStringValue(rt, "valid"),
        30 => {
            if (args.len < 2) return error.TypeError;
            try incrementGlobalInt(rt, globals, "counter");
            try appendPairToGlobalArray(rt, globals, "results", args[0], args[1]);
            try appendToGlobalArray(rt, globals, "_this", this_value);
            return core.JSValue.undefinedValue();
        },
        31 => {
            try incrementGlobalInt(rt, globals, "count");
            return error.TypeError;
        },
        32 => {
            try incrementGlobalInt(rt, globals, "count");
            return error.JSException;
        },
        33 => {
            if (args.len < 1) return error.TypeError;
            try globals_mod.setExistingByName(rt, globals, "canonicalKey", args[0]);
            return core.JSValue.undefinedValue();
        },
        34 => return core.JSValue.int32(3),
        35 => return core.JSValue.undefinedValue(),
        36 => return try value_ops.createStringValue(rt, "string"),
        37 => {
            try incrementGlobalInt(rt, globals, "callbackCalls");
            return error.JSException;
        },
        38 => {
            try setGlobalMapString(rt, globals, 1, "mutated");
            return error.JSException;
        },
        39 => {
            try setGlobalMapString(rt, globals, 3, "mutated");
            return error.JSException;
        },
        40 => {
            try incrementGlobalInt(rt, globals, "count");
            return core.JSValue.undefinedValue();
        },
        41 => return error.JSException,
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
            const value = args[0].asInt32() orelse return error.JSException;
            if (value == 1) return core.JSValue.boolean(false);
            if (value == 2) return core.JSValue.boolean(true);
            return error.JSException;
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
            return core.JSValue.undefinedValue();
        },
        48 => {
            if (args.len < 1) return error.TypeError;
            try appendToGlobalArray(rt, globals, "added", args[0]);
            return core.JSValue.undefinedValue();
        },
        49 => {
            if (args.len < 1) return error.TypeError;
            try assertAndShiftExpected(rt, globals, args[0]);
            return core.JSValue.undefinedValue();
        },
        56 => return setForEachMutation(rt, globals, args, .add_after_begin),
        57 => return setForEachMutation(rt, globals, args, .delete_then_readd),
        58 => return setForEachMutation(rt, globals, args, .revisit_after_readd),
        50 => {
            try incrementGlobalInt(rt, globals, "counter");
            return core.JSValue.undefinedValue();
        },
        61 => {
            try incrementGlobalInt(rt, globals, "counter");
            return error.JSException;
        },
        62 => {
            if (args.len < 1) return error.TypeError;
            const value = args[0].asInt32() orelse return error.JSException;
            if (value == 1 or value == 2) return core.JSValue.boolean(true);
            return error.JSException;
        },
        63 => {
            if (args.len < 1) return error.TypeError;
            const value = args[0].asInt32() orelse return error.JSException;
            if (value == 1 or value == 2) return core.JSValue.boolean(false);
            return error.JSException;
        },
        64 => {
            if (args.len < 1) return error.TypeError;
            if (args[0].asInt32()) |value| return core.JSValue.boolean(value == 4 or value == 5 or value == 6);
            const string = args[0].asStringBody() orelse return core.JSValue.boolean(false);
            return core.JSValue.boolean(string.eqlBytes("a") or string.eqlBytes("b") or string.eqlBytes("c") or string.eqlBytes("x"));
        },
        21 => {
            if (args.len < 2) return error.TypeError;
            try appendRecordToGlobalArray(rt, globals, "results", args[0], args[1], if (args.len >= 3) args[2] else core.JSValue.undefinedValue());
            return core.JSValue.undefinedValue();
        },
        22 => {
            if (args.len < 1) return error.TypeError;
            try appendToGlobalArray(rt, globals, "results", args[0]);
            return core.JSValue.undefinedValue();
        },
        26 => {
            var value = if (this_value.isUndefined()) try globals_mod.getByName(rt, globals, "globalThis") else this_value;
            if (value.isUndefined()) {
                value = (try getGlobalThisObject(rt, globals)).value();
            }
            try appendToGlobalArray(rt, globals, "_this", value);
            return core.JSValue.undefinedValue();
        },
        27 => {
            try appendToGlobalArray(rt, globals, "_this", this_value);
            return core.JSValue.undefinedValue();
        },
        23...25 => {
            if (args.len < 2) return error.TypeError;
            try appendRecordToGlobalArray(rt, globals, "results", args[0], args[1], if (args.len >= 3) args[2] else core.JSValue.undefinedValue());
            try incrementGlobalInt(rt, globals, "count");
            return core.JSValue.undefinedValue();
        },
        else => return error.TypeError,
    }
}

fn closureKind(rt: *core.JSRuntime, closure_value: core.JSValue) !i32 {
    const closure = try expectClosure(closure_value);
    return getIntProperty(rt, closure, "__closure_kind");
}

pub fn appendLog(rt: *core.JSRuntime, globals: []globals_mod.Slot, mode: LogMode, a: i32, b: i32, c: i32, d: i32) !void {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    const existing = try globals_mod.getByName(rt, globals, "log_str");
    if (existing.isString()) try value_ops.appendRawString(rt, &buffer, existing);
    if (mode == .initial) try appendIntField(rt, &buffer, "a=", a);
    try appendIntField(rt, &buffer, "b=", b);
    try appendIntField(rt, &buffer, "c=", c);
    try appendIntField(rt, &buffer, "d=", d);
    try appendIntField(rt, &buffer, "x=", 10);

    const value = try value_ops.createStringValue(rt, buffer.items);
    try globals_mod.setExistingByName(rt, globals, "log_str", value);
}

fn expectClosure(value: core.JSValue) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    const closure = core.Object.fromHeader(header);
    if (closure.class_id != core.class.ids.c_closure) return error.TypeError;
    return closure;
}

fn defineIntProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: i32) !void {
    const key = try rt.internAtom(name);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(value), true, true, true));
}

fn getIntProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8) !i32 {
    const key = try rt.internAtom(name);
    const value = try object.getProperty(key);
    return value.asInt32() orelse error.TypeError;
}

fn incrementGlobalInt(rt: *core.JSRuntime, globals: []globals_mod.Slot, name: []const u8) !void {
    const existing = try globals_mod.getByName(rt, globals, name);
    const current = existing.asInt32() orelse return error.TypeError;
    try globals_mod.setExistingByName(rt, globals, name, core.JSValue.int32(current + 1));
}

fn iteratorFactory(rt: *core.JSRuntime, shape: i32) !core.JSValue {
    const iterator = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, iterator.gcHeader());

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
    try defineValueProperty(rt, iterator, "next", next);

    const return_kind: ?i32 = switch (shape) {
        3, 4, 5, 8 => 40,
        6 => 7,
        else => null,
    };
    if (return_kind) |kind| {
        const return_fn = try create(rt, kind, 0, 0, 0);
        try defineValueProperty(rt, iterator, "return", return_fn);
    }

    return iterator.value();
}

fn iteratorNextGlobalValue(rt: *core.JSRuntime, closure: *core.Object, globals: []globals_mod.Slot, name: []const u8) !core.JSValue {
    if (try iteratorNextDoneIfConsumed(rt, closure)) |done| return done;
    const value = try globals_mod.getByName(rt, globals, name);
    return iteratorResult(rt, value, false);
}

fn iteratorNextEmptyArray(rt: *core.JSRuntime, closure: *core.Object) !core.JSValue {
    if (try iteratorNextDoneIfConsumed(rt, closure)) |done| return done;
    const value = try core.Object.createArray(rt, null);
    return iteratorResult(rt, value.value(), false);
}

fn iteratorNextNull(rt: *core.JSRuntime, closure: *core.Object) !core.JSValue {
    if (try iteratorNextDoneIfConsumed(rt, closure)) |done| return done;
    return iteratorResult(rt, core.JSValue.nullValue(), false);
}

fn iteratorNextValueGetterThrows(rt: *core.JSRuntime, closure: *core.Object) !core.JSValue {
    if (try iteratorNextDoneIfConsumed(rt, closure)) |done| return done;
    const result = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, result.gcHeader());
    const getter = try create(rt, 12, 0, 0, 0);
    const value_key = core.atom.ids.value;
    try result.defineOwnProperty(rt, value_key, core.Descriptor.accessor(getter, core.JSValue.undefinedValue(), true, true));
    try defineValueProperty(rt, result, "done", core.JSValue.boolean(false));
    return result.value();
}

fn iteratorNextDoneIfConsumed(rt: *core.JSRuntime, closure: *core.Object) !?core.JSValue {
    const consumed = try getIntProperty(rt, closure, "__closure_value");
    if (consumed != 0) return try iteratorResult(rt, core.JSValue.undefinedValue(), true);
    try defineIntProperty(rt, closure, "__closure_value", 1);
    return null;
}

/// Borrowing wrapper over the single `CreateIterResultObject` owner: unlike the
/// other wrappers, this file's callers keep their reference to `value`. The
/// synthetic closure iterators carry no realm handle, so the result has no
/// prototype.
fn iteratorResult(rt: *core.JSRuntime, value: core.JSValue, done: bool) !core.JSValue {
    return iterator_ops.createIteratorResult(rt, null, value, done);
}

test "closure iteratorResult roots direct function bytecode value while creating result" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const fb = try bytecode.FunctionBytecode.createFixture(rt, .{ .cpool_count = 1 });
    var fb_published = false;
    errdefer if (!fb_published) fb.destroyUnpublishedFixture(rt);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-closure-iterator-result-bytecode-symbol");
    fb.cpoolSlice()[0] = try rt.takeSymbolValue(symbol_atom);
    fb.publishFixtureNoFail(rt);
    fb_published = true;

    const result_value = core.JSValue.functionBytecode(&fb.header);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const iterator_result_value = try iteratorResult(rt, result_value, false);
    const iterator_result = try expectObject(iterator_result_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const value_atom = try rt.internAtom("value");
    {
        const stored = try iterator_result.getProperty(value_atom);
        try std.testing.expect(stored.same(result_value));
    }

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

const TestFunctionBytecodeValue = struct {
    value: core.JSValue,
    symbol_atom: core.Atom,
};

fn createTestFunctionBytecodeValue(rt: *core.JSRuntime, symbol_name: []const u8) !TestFunctionBytecodeValue {
    const fb = try bytecode.FunctionBytecode.createFixture(rt, .{ .cpool_count = 1 });
    var fb_published = false;
    errdefer if (!fb_published) fb.destroyUnpublishedFixture(rt);
    const symbol_atom = try rt.atoms.newValueSymbol(symbol_name);
    fb.cpoolSlice()[0] = try rt.takeSymbolValue(symbol_atom);
    fb.publishFixtureNoFail(rt);
    fb_published = true;

    return .{
        .value = core.JSValue.functionBytecode(&fb.header),
        .symbol_atom = symbol_atom,
    };
}

fn expectObjectPropertySame(rt: *core.JSRuntime, object: *core.Object, name: []const u8, expected: core.JSValue) !void {
    const atom_id = try rt.internAtom(name);
    const stored = try object.getProperty(atom_id);
    try std.testing.expect(stored.same(expected));
}

fn expectArrayIndexSame(_: *core.JSRuntime, array: *core.Object, index: u32, expected: core.JSValue) !void {
    const stored = try array.getProperty(core.atom.atomFromUInt32(index));
    try std.testing.expect(stored.same(expected));
}

test "appendRecordToGlobalArray roots direct function bytecode fields while creating record" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const results_name = try rt.internAtom("results");
    const results = try core.Object.createArray(rt, null);
    var globals = [_]globals_mod.Slot{
        .{ .name = results_name, .value = results.value() },
    };

    const record_value = try createTestFunctionBytecodeValue(rt, "gc-closure-record-value-bytecode-symbol");
    const record_key = try createTestFunctionBytecodeValue(rt, "gc-closure-record-key-bytecode-symbol");
    const record_this = try createTestFunctionBytecodeValue(rt, "gc-closure-record-this-bytecode-symbol");

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    try appendRecordToGlobalArray(rt, &globals, "results", record_value.value, record_key.value, record_this.value);

    try std.testing.expect(rt.atoms.name(record_value.symbol_atom) != null);
    try std.testing.expect(rt.atoms.name(record_key.symbol_atom) != null);
    try std.testing.expect(rt.atoms.name(record_this.symbol_atom) != null);

    {
        const stored_record_value = try results.getProperty(core.atom.atomFromUInt32(0));
        const stored_record = try expectObject(stored_record_value);
        try expectObjectPropertySame(rt, stored_record, "value", record_value.value);
        try expectObjectPropertySame(rt, stored_record, "key", record_key.value);
        try expectObjectPropertySame(rt, stored_record, "thisArg", record_this.value);
    }

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(record_value.symbol_atom) == null);
    try std.testing.expect(rt.atoms.name(record_key.symbol_atom) == null);
    try std.testing.expect(rt.atoms.name(record_this.symbol_atom) == null);
}

test "appendWeakMapAdderRecord roots direct function bytecode fields while creating record" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const results_name = try rt.internAtom("results");
    const results = try core.Object.createArray(rt, null);
    var globals = [_]globals_mod.Slot{
        .{ .name = results_name, .value = results.value() },
    };

    const record_key = try createTestFunctionBytecodeValue(rt, "gc-closure-weakmap-record-key-bytecode-symbol");
    const record_value = try createTestFunctionBytecodeValue(rt, "gc-closure-weakmap-record-value-bytecode-symbol");
    const record_this = try createTestFunctionBytecodeValue(rt, "gc-closure-weakmap-record-this-bytecode-symbol");

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    try appendWeakMapAdderRecord(rt, &globals, record_key.value, record_value.value, record_this.value);

    try std.testing.expect(rt.atoms.name(record_key.symbol_atom) != null);
    try std.testing.expect(rt.atoms.name(record_value.symbol_atom) != null);
    try std.testing.expect(rt.atoms.name(record_this.symbol_atom) != null);

    {
        const stored_record_value = try results.getProperty(core.atom.atomFromUInt32(0));
        const stored_record = try expectObject(stored_record_value);
        try expectObjectPropertySame(rt, stored_record, "_this", record_this.value);
        try expectObjectPropertySame(rt, stored_record, "key", record_key.value);
        try expectObjectPropertySame(rt, stored_record, "value", record_value.value);
    }

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(record_key.symbol_atom) == null);
    try std.testing.expect(rt.atoms.name(record_value.symbol_atom) == null);
    try std.testing.expect(rt.atoms.name(record_this.symbol_atom) == null);
}

test "appendPairToGlobalArray roots direct function bytecode entries while creating pair" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const results_name = try rt.internAtom("results");
    const results = try core.Object.createArray(rt, null);
    var globals = [_]globals_mod.Slot{
        .{ .name = results_name, .value = results.value() },
    };

    const pair_key = try createTestFunctionBytecodeValue(rt, "gc-closure-pair-key-bytecode-symbol");
    const pair_value = try createTestFunctionBytecodeValue(rt, "gc-closure-pair-value-bytecode-symbol");

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    try appendPairToGlobalArray(rt, &globals, "results", pair_key.value, pair_value.value);

    try std.testing.expect(rt.atoms.name(pair_key.symbol_atom) != null);
    try std.testing.expect(rt.atoms.name(pair_value.symbol_atom) != null);

    {
        const stored_pair_value = try results.getProperty(core.atom.atomFromUInt32(0));
        const stored_pair = try core.array.expectArray(stored_pair_value);
        try expectArrayIndexSame(rt, stored_pair, 0, pair_key.value);
        try expectArrayIndexSame(rt, stored_pair, 1, pair_value.value);
    }

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(pair_key.symbol_atom) == null);
    try std.testing.expect(rt.atoms.name(pair_value.symbol_atom) == null);
}

test "appendToGlobalArray roots direct function bytecode value while appending" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const results_name = try rt.internAtom("results");
    const results = try core.Object.createArray(rt, null);
    var globals = [_]globals_mod.Slot{
        .{ .name = results_name, .value = results.value() },
    };

    const item = try createTestFunctionBytecodeValue(rt, "gc-closure-global-array-value-bytecode-symbol");

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    try appendToGlobalArray(rt, &globals, "results", item.value);

    try std.testing.expect(rt.atoms.name(item.symbol_atom) != null);
    try expectArrayIndexSame(rt, results, 0, item.value);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(item.symbol_atom) == null);
}

test "appendArrayValue roots direct function bytecode value while appending" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const array = try core.Object.createArray(rt, null);

    const item = try createTestFunctionBytecodeValue(rt, "gc-closure-array-value-bytecode-symbol");

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    try appendArrayValue(rt, array, item.value);

    try std.testing.expect(rt.atoms.name(item.symbol_atom) != null);
    try expectArrayIndexSame(rt, array, 0, item.value);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(item.symbol_atom) == null);
}

fn arrayFromShape(rt: *core.JSRuntime, shape: i32) !core.JSValue {
    const array = try core.Object.createArray(rt, null);
    errdefer core.Object.destroyFromHeader(rt, array.gcHeader());
    switch (shape) {
        0 => {},
        1 => try appendArrayValue(rt, array, core.JSValue.int32(1)),
        23 => {
            try appendArrayValue(rt, array, core.JSValue.int32(2));
            try appendArrayValue(rt, array, core.JSValue.int32(3));
        },
        234 => {
            try appendArrayValue(rt, array, core.JSValue.int32(2));
            try appendArrayValue(rt, array, core.JSValue.int32(3));
            try appendArrayValue(rt, array, core.JSValue.int32(4));
        },
        100 => try appendArrayValue(rt, array, core.JSValue.int32(0)),
        101 => {
            const a_value = try value_ops.createStringValue(rt, "a");
            const b_value = try value_ops.createStringValue(rt, "b");
            try appendArrayValue(rt, array, a_value);
            try appendArrayValue(rt, array, b_value);
        },
        102 => {
            const a_value = try value_ops.createStringValue(rt, "a");
            const b_value = try value_ops.createStringValue(rt, "b");
            const c_value = try value_ops.createStringValue(rt, "c");
            try appendArrayValue(rt, array, a_value);
            try appendArrayValue(rt, array, b_value);
            try appendArrayValue(rt, array, c_value);
        },
        103 => {
            const x_value = try value_ops.createStringValue(rt, "x");
            const b_value = try value_ops.createStringValue(rt, "b");
            try appendArrayValue(rt, array, x_value);
            try appendArrayValue(rt, array, b_value);
            try appendArrayValue(rt, array, b_value);
        },
        104 => {
            const x_value = try value_ops.createStringValue(rt, "x");
            const b_value = try value_ops.createStringValue(rt, "b");
            const c_value = try value_ops.createStringValue(rt, "c");
            try appendArrayValue(rt, array, x_value);
            try appendArrayValue(rt, array, b_value);
            try appendArrayValue(rt, array, c_value);
            try appendArrayValue(rt, array, c_value);
        },
        else => return error.TypeError,
    }
    return array.value();
}

fn appendArrayValue(rt: *core.JSRuntime, array: *core.Object, value: core.JSValue) !void {
    var rooted_value = value;
    var root_frame = core.runtime.rootValues(.{&rooted_value});
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    if (!array.isArray()) return error.TypeError;
    try array.defineOwnProperty(rt, core.atom.atomFromUInt32(array.arrayLength()), core.Descriptor.data(rooted_value, true, true, true));
}

fn setGlobalMapString(rt: *core.JSRuntime, globals: []globals_mod.Slot, key_int: i32, bytes: []const u8) !void {
    const map_value = try globals_mod.getByName(rt, globals, "map");
    const map_object = try expectObject(map_value);
    if (map_object.class_id == core.class.ids.weakmap) return setGlobalWeakMapString(rt, globals, map_object, key_int, bytes);
    if (map_object.class_id != core.class.ids.map) return error.TypeError;
    const key = core.JSValue.int32(key_int);
    const value = try value_ops.createStringValue(rt, bytes);
    for (map_object.collectionEntriesSlot().*) |*entry| {
        if (!entry.active) continue;
        if (entry.key.asInt32() == key_int) {
            const next_value = value;
            entry.value = next_value;
            return;
        }
    }
    try appendUnindexedCollectionEntryAndDefineSize(rt, map_object, .{ .key = key, .value = value, .active = true });
}

fn setGlobalWeakMapString(rt: *core.JSRuntime, globals: []globals_mod.Slot, map_object: *core.Object, key_int: i32, bytes: []const u8) !void {
    var key_name_buf: [32]u8 = undefined;
    const key_name = std.fmt.bufPrint(&key_name_buf, "obj{d}", .{key_int}) catch unreachable;
    var key_value = try globals_mod.getByName(rt, globals, key_name);
    if (key_value.isUndefined()) {
        key_value = try getGlobalObjectProperty(rt, globals, key_name);
    }
    const value = try value_ops.createStringValue(rt, bytes);
    try core.collection.setWeakMapEntry(rt, map_object, key_value, value);
}

fn appendRecordToGlobalArray(rt: *core.JSRuntime, globals: []globals_mod.Slot, name: []const u8, value: core.JSValue, key: core.JSValue, this_arg: core.JSValue) !void {
    var rooted_value = value;
    var rooted_key = key;
    var rooted_this_arg = this_arg;
    var root_frame = core.runtime.rootValues(.{ &rooted_value, &rooted_key, &rooted_this_arg });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const record = try core.Object.create(rt, core.class.ids.object, null);
    const record_value = record.value();
    try defineValueProperty(rt, record, "value", rooted_value);
    try defineValueProperty(rt, record, "key", rooted_key);
    if (!rooted_this_arg.isUndefined()) try defineValueProperty(rt, record, "thisArg", rooted_this_arg);
    try appendToGlobalArray(rt, globals, name, record_value);
}

fn appendWeakMapAdderRecord(rt: *core.JSRuntime, globals: []globals_mod.Slot, key: core.JSValue, value: core.JSValue, this_arg: core.JSValue) !void {
    var rooted_key = key;
    var rooted_value = value;
    var rooted_this_arg = this_arg;
    var root_frame = core.runtime.rootValues(.{ &rooted_key, &rooted_value, &rooted_this_arg });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const record = try core.Object.create(rt, core.class.ids.object, null);
    const record_value = record.value();
    try defineValueProperty(rt, record, "_this", rooted_this_arg);
    try defineValueProperty(rt, record, "key", rooted_key);
    try defineValueProperty(rt, record, "value", rooted_value);
    try appendToGlobalArray(rt, globals, "results", record_value);
}

fn assertAndShiftExpected(rt: *core.JSRuntime, globals: []globals_mod.Slot, actual: core.JSValue) !void {
    const expects_value = try globals_mod.getByName(rt, globals, "expects");
    const expects = try core.array.expectArray(expects_value);
    if (expects.arrayLength() == 0) return error.JSException;
    const expected = try expects.getProperty(core.atom.atomFromUInt32(0));
    if (!actual.sameValue(expected)) return error.JSException;
    var index: u32 = 1;
    while (index < expects.arrayLength()) : (index += 1) {
        const next = try expects.getProperty(core.atom.atomFromUInt32(index));
        try expects.defineOwnProperty(rt, core.atom.atomFromUInt32(index - 1), core.Descriptor.data(next, true, true, true));
    }
    // Drop the now-duplicated tail: lower the dense extent (no-op when the
    // copy-down already converted to sparse) before lowering .length, so we
    // never leave array_length < array_count.
    const shrunk = expects.arrayLength() - 1;
    expects.truncateArrayElements(rt, shrunk);
    expects.setArrayLength(shrunk);
}

const SetForEachMutation = enum {
    add_after_begin,
    delete_then_readd,
    revisit_after_readd,
};

fn setForEachMutation(rt: *core.JSRuntime, globals: []globals_mod.Slot, args: []const core.JSValue, mode: SetForEachMutation) !core.JSValue {
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
    return core.JSValue.undefinedValue();
}

fn setAddInt(rt: *core.JSRuntime, set: *core.Object, value: i32) !void {
    for (set.collectionEntriesSlot().*) |entry| {
        if (!entry.active) continue;
        if (entry.key.asInt32() == value) return;
    }
    try appendUnindexedCollectionEntryAndDefineSize(rt, set, .{ .key = core.JSValue.int32(value), .value = core.JSValue.undefinedValue(), .active = true });
}

fn setDeleteInt(rt: *core.JSRuntime, set: *core.Object, value: i32) !void {
    for (set.collectionEntriesSlot().*, 0..) |*entry, index| {
        if (!entry.active) continue;
        if (entry.key.asInt32() == value) {
            try removeUnindexedCollectionEntryAndDefineSize(rt, set, index);
            return;
        }
    }
}

fn appendUnindexedCollectionEntryAndDefineSize(rt: *core.JSRuntime, object: *core.Object, entry: core.object.CollectionEntry) !void {
    const pending_entry = entry;

    const index = try object.appendCollectionEntryUnindexed(rt, pending_entry);
    object.collectionActiveCountSlot().* += 1;

    var inserted = true;
    errdefer if (inserted) rollbackLastUnindexedCollectionEntry(object, index);

    object.clearCollectionIndex(rt);
    try defineIntProperty(rt, object, "size", @intCast(object.collectionActiveCount()));
    inserted = false;
}

fn rollbackLastUnindexedCollectionEntry(object: *core.Object, index: usize) void {
    const entries_slot = object.collectionEntriesSlot();
    std.debug.assert(index + 1 == entries_slot.*.len);
    if (!entries_slot.*[index].active) return;
    entries_slot.*[index] = .{ .key = core.JSValue.undefinedValue(), .value = core.JSValue.undefinedValue(), .active = false };
    entries_slot.* = entries_slot.*.ptr[0..index];
    const active_count = object.collectionActiveCountSlot();
    if (active_count.* != 0) active_count.* -= 1;
}

fn removeUnindexedCollectionEntryAndDefineSize(rt: *core.JSRuntime, object: *core.Object, index: usize) !void {
    const entries = object.collectionEntriesSlot().*;
    std.debug.assert(index < entries.len);
    std.debug.assert(entries[index].active);

    const removed = entries[index];
    entries[index] = .{ .key = core.JSValue.undefinedValue(), .value = core.JSValue.undefinedValue(), .active = false };
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
}

fn appendPairToGlobalArray(rt: *core.JSRuntime, globals: []globals_mod.Slot, name: []const u8, key: core.JSValue, value: core.JSValue) !void {
    var rooted_key = key;
    var rooted_value = value;
    var root_frame = core.runtime.rootValues(.{ &rooted_key, &rooted_value });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const pair = try core.Object.createArray(rt, null);
    const pair_value = pair.value();
    try pair.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(rooted_key, true, true, true));
    try pair.defineOwnProperty(rt, core.atom.atomFromUInt32(1), core.Descriptor.data(rooted_value, true, true, true));
    try appendToGlobalArray(rt, globals, name, pair_value);
}

fn appendToGlobalArray(rt: *core.JSRuntime, globals: []globals_mod.Slot, name: []const u8, value: core.JSValue) !void {
    var rooted_value = value;
    var root_frame = core.runtime.rootValues(.{&rooted_value});
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    var array_value = try globals_mod.getByName(rt, globals, name);
    if (array_value.isUndefined()) {
        array_value = try getGlobalObjectProperty(rt, globals, name);
    }
    const array = try core.array.expectArray(array_value);
    try array.defineOwnProperty(rt, core.atom.atomFromUInt32(array.arrayLength()), core.Descriptor.data(rooted_value, true, true, true));
}

fn getGlobalObjectProperty(rt: *core.JSRuntime, globals: []globals_mod.Slot, name: []const u8) !core.JSValue {
    const global = try getGlobalThisObject(rt, globals);
    const key = try rt.internAtom(name);
    return try global.getProperty(key);
}

fn getGlobalThisObject(rt: *core.JSRuntime, globals: []globals_mod.Slot) !*core.Object {
    const global_value = try globals_mod.getByName(rt, globals, "globalThis");
    const header = global_value.refHeader() orelse return error.TypeError;
    if (!global_value.isObject()) return error.TypeError;
    return core.Object.fromHeader(header);
}

fn defineValueProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: core.JSValue) !void {
    var rooted_value = value;
    var root_frame = core.runtime.rootValues(.{&rooted_value});
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const key = try rt.internAtom(name);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(rooted_value, true, true, true));
}

const expectObject = core.value_semantics.expectObject;

fn appendIntField(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), label: []const u8, value: i32) !void {
    var int_buf: [32]u8 = undefined;
    const printed = std.fmt.bufPrint(&int_buf, "{d}", .{value}) catch unreachable;
    try buffer.appendSlice(rt.memory.allocator, label);
    try buffer.appendSlice(rt.memory.allocator, printed);
    try buffer.append(rt.memory.allocator, ',');
}
