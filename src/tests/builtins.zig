const std = @import("std");
const zjs = @import("zjs");
const engine = zjs;

const core = zjs.core;
const op = zjs.bytecode.opcode.op;

const exec_test = @import("exec.zig");
const helpers = exec_test.helpers;
const vm_helpers = exec_test.vm_helpers;

const makeFunction = helpers.makeFunction;
const runFunction = helpers.runFunction;
const countJob = helpers.countJob;
const countJobArgs = helpers.countJobArgs;
const objectFromValue = helpers.objectFromValue;
const expectActiveSetStrings = helpers.expectActiveSetStrings;

test "native handler realm readers have an explicit observable or synthetic authority" {
    const Entry = struct {
        name: []const u8,
        source: []const u8,
        synthetic_global_reads: usize,
        synthetic_globals_reads: usize = 0,
    };
    const entries = [_]Entry{
        .{ .name = "array", .source = @embedFile("../exec/array_builtin_ops.zig"), .synthetic_global_reads = 1 },
        .{ .name = "atomics", .source = @embedFile("../exec/atomics_ops.zig"), .synthetic_global_reads = 0 },
        .{ .name = "object", .source = @embedFile("../exec/object_builtin_ops.zig"), .synthetic_global_reads = 1, .synthetic_globals_reads = 1 },
        .{ .name = "math", .source = @embedFile("../exec/math_ops.zig"), .synthetic_global_reads = 2 },
        .{ .name = "number", .source = @embedFile("../exec/number_ops.zig"), .synthetic_global_reads = 1 },
        .{ .name = "uri", .source = @embedFile("../exec/uri_ops.zig"), .synthetic_global_reads = 1 },
        .{ .name = "promise", .source = @embedFile("../exec/promise_builtin_ops.zig"), .synthetic_global_reads = 0 },
        .{ .name = "function", .source = @embedFile("../exec/function_ops.zig"), .synthetic_global_reads = 0 },
        .{ .name = "reflect", .source = @embedFile("../exec/reflect_proxy_ops.zig"), .synthetic_global_reads = 0 },
        .{ .name = "json", .source = @embedFile("../exec/json_ops.zig"), .synthetic_global_reads = 1 },
        .{ .name = "string", .source = @embedFile("../exec/string_builtin_ops.zig"), .synthetic_global_reads = 4 },
        .{ .name = "date", .source = @embedFile("../exec/date_ops.zig"), .synthetic_global_reads = 2 },
        .{ .name = "collection", .source = @embedFile("../exec/collection_ops.zig"), .synthetic_global_reads = 2, .synthetic_globals_reads = 1 },
        .{ .name = "regexp", .source = @embedFile("../exec/regexp_ops.zig"), .synthetic_global_reads = 1 },
    };

    for (entries) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, entry.source, "callableRealm(host_call)") != null);
        const globals_reads = std.mem.count(u8, entry.source, "host_call.globals");
        const global_prefix_reads = std.mem.count(u8, entry.source, "host_call.global");
        try std.testing.expectEqual(entry.synthetic_globals_reads, globals_reads);
        try std.testing.expectEqual(entry.synthetic_global_reads, global_prefix_reads - globals_reads);
        if (entry.synthetic_global_reads != 0 or entry.synthetic_globals_reads != 0) {
            try std.testing.expect(std.mem.indexOf(u8, entry.source, "host_call.func_obj") != null);
        }
        _ = entry.name;
    }

    const promise_source = @embedFile("../core/promise.zig");
    const array_source = @embedFile("../exec/array_builtin_ops.zig");
    const module_graph_source = @embedFile("../exec/module_graph.zig");
    const raw_data_factory = "core.function.nativeDataFunction(";
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, promise_source, raw_data_factory));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, array_source, raw_data_factory));
    // W1b3d2 moved dynamic-import scheduling to a typed job payload, so no
    // scheduler or user-visible path retains the raw callable-data factory.
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, module_graph_source, raw_data_factory));
}

test "dense array writer readers retain their semantic guard class" {
    const WriterClass = enum {
        own_overwrite,
        create_data_property,
        prewalk_set,
        already_walked_set,
        qjs_bulk_set,
        zjs_bulk_set,
    };
    const Reader = struct {
        class: WriterClass,
        source: []const u8,
        needle: []const u8,
        count: usize,
    };

    const object_source = @embedFile("../core/object.zig");
    const runtime_source = @embedFile("../core/runtime.zig");
    const core_array_source = @embedFile("../core/array.zig");
    const array_builtin_source = @embedFile("../exec/array_builtin_ops.zig");
    const array_ops_source = @embedFile("../exec/array_ops.zig");
    const json_ops_source = @embedFile("../exec/json_ops.zig");
    const object_ops_source = @embedFile("../exec/object_ops.zig");
    const string_ops_source = @embedFile("../exec/string_ops.zig");
    const vm_literal_source = @embedFile("../exec/vm_literal.zig");
    const readers = [_]Reader{
        .{ .class = .own_overwrite, .source = array_ops_source, .needle = ".setFastArrayElementDup(rt, index, value)", .count = 2 },
        .{ .class = .create_data_property, .source = core_array_source, .needle = ".initDenseArrayLiteralValuesAssumingEmpty(rt, values)", .count = 1 },
        .{ .class = .create_data_property, .source = core_array_source, .needle = ".appendDenseArrayLiteralIndex(rt,", .count = 1 },
        .{ .class = .create_data_property, .source = array_builtin_source, .needle = ".appendDenseArrayDefineIndex(rt,", .count = 1 },
        .{ .class = .create_data_property, .source = array_ops_source, .needle = ".appendDenseArrayDefineIndex(rt,", .count = 2 },
        .{ .class = .create_data_property, .source = array_ops_source, .needle = "out.?.defineDenseArrayDataPropertyUnchecked(ctx.runtime,", .count = 1 },
        .{ .class = .create_data_property, .source = array_ops_source, .needle = "out.?.defineDenseArrayDataProperty(ctx.runtime,", .count = 1 },
        .{ .class = .create_data_property, .source = json_ops_source, .needle = ".appendDenseArrayLiteralIndex(", .count = 3 },
        .{ .class = .create_data_property, .source = string_ops_source, .needle = ".appendDenseArrayDefineIndex(rt,", .count = 1 },
        .{ .class = .create_data_property, .source = string_ops_source, .needle = ".appendDenseArrayDefineIndexOwned(rt,", .count = 1 },
        .{ .class = .create_data_property, .source = string_ops_source, .needle = ".initDenseArrayIndexZeroAssumingEmpty(rt,", .count = 1 },
        .{ .class = .create_data_property, .source = vm_literal_source, .needle = ".defineDenseArrayDataProperty(ctx.runtime,", .count = 1 },
        .{ .class = .prewalk_set, .source = array_ops_source, .needle = ".appendDenseArrayIndex(rt,", .count = 2 },
        .{ .class = .prewalk_set, .source = object_ops_source, .needle = ".appendDenseArrayIndex(ctx.runtime,", .count = 1 },
        .{ .class = .already_walked_set, .source = object_source, .needle = "try self.defineOwnDataPropertyForSetKnownNoOwn(rt, atom_id, new_value);", .count = 1 },
        .{ .class = .qjs_bulk_set, .source = array_ops_source, .needle = ".appendDenseArrayValues(ctx.runtime,", .count = 1 },
        .{ .class = .zjs_bulk_set, .source = array_ops_source, .needle = "object.defineDenseArrayDataPropertyUnchecked(ctx.runtime,", .count = 1 },
        .{ .class = .zjs_bulk_set, .source = array_ops_source, .needle = "object.defineDenseArrayDataProperty(ctx.runtime,", .count = 1 },
        .{ .class = .zjs_bulk_set, .source = array_ops_source, .needle = "arrayPrototypeChainHasNoIndexedProperties(object)", .count = 2 },
        .{ .class = .zjs_bulk_set, .source = object_source, .needle = "if (!arrayPrototypeChainAllowsBulkIndexedSet(proto))", .count = 3 },
    };
    for (readers) |reader| {
        try std.testing.expectEqual(reader.count, std.mem.count(u8, reader.source, reader.needle));
        _ = reader.class;
    }

    // Only the two QuickJS-aligned pre-walk append consumers consult the
    // direct %Array.prototype% marker. The runtime-wide sticky approximation
    // is deliberately absent.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, object_source, "if (!self.canExtendFastArray())"));
    try std.testing.expect(std.mem.indexOf(u8, object_source, "is_std_array_prototype") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime_source, "any_prototype_may_have_indexed_properties") == null);
}

// ================== builtins_async.zig ==================

test "Engine eval executes allocator-backed wide Math min max calls" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [96]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(Math.min(9, 8, 7, 6, 5, 4));
        \\print(Math.max(4, 5, 6, 7, 8, 9));
        \\print(Math.abs());
        \\print(Math.abs(undefined));
        \\print(Math.abs(null));
        \\print(Math.abs(true));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("4\n9\nNaN\nNaN\n0\n1\n", stream.buffered());
}

test "bare Math scalar fallback shares qjs edge semantics" {
    const math = engine.exec.math_ops;

    const rounded = try math.call(4, &.{core.JSValue.float64(-0.1)});
    try std.testing.expect(std.math.isNegativeZero(rounded));

    const powered = try math.call(6, &.{
        core.JSValue.int32(-1),
        core.JSValue.float64(std.math.inf(f64)),
    });
    try std.testing.expect(std.math.isNan(powered));

    const minimum = try math.call(7, &.{
        core.JSValue.int32(0),
        core.JSValue.float64(-0.0),
    });
    const maximum = try math.call(8, &.{
        core.JSValue.float64(-0.0),
        core.JSValue.int32(0),
    });
    try std.testing.expect(std.math.isNegativeZero(minimum));
    try std.testing.expect(!std.math.isNegativeZero(maximum));
    try std.testing.expectError(error.TypeError, math.call(9, &.{}));
}

test "Math min max induction range fast path preserves observable method lookup" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let minSum = 0;
        \\for (let i = 0; i < 1000; i++) minSum += Math.min(i, 50);
        \\print(minSum);
        \\let maxSum = 0;
        \\for (let i = -3; i < 1000; i++) maxSum += Math.max(i, 4);
        \\print(maxSum);
        \\let reversed = 0;
        \\for (let i = -5; i < 5; i++) reversed += Math.min(2, i);
        \\print(reversed);
        \\let savedMin = Math.min;
        \\let calls = 0;
        \\Math.min = function(a, b) { calls++; return b - a; };
        \\let slow = 0;
        \\for (let i = 0; i < 1000; i++) slow += Math.min(i, 3);
        \\Math.min = savedMin;
        \\print(calls, slow);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("48725\n499522\n-8\n1000 -496500\n", stream.buffered());
}

test "induction int32 sum range fast path preserves safe number results" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let sum = 0;
        \\for (let i = 0; i < 60000; i++) sum += i;
        \\print(sum);
        \\let large = 0;
        \\for (let i = 0; i < 1000000; i++) large += i;
        \\print(large, typeof large);
        \\let offset = 10;
        \\for (let i = -3; i < 4; i++) offset += i;
        \\print(offset);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1799970000\n499999500000 number\n10\n", stream.buffered());
}

test "latin1 string literal append range fast path preserves fallbacks" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [192]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let s = "a";
        \\for (let i = 0; i < 5; i++) s += "xy";
        \\print(s);
        \\let skipped = "z";
        \\for (let i = 3; i < 1; i++) skipped += "x";
        \\print(skipped);
        \\let calls = 0;
        \\let dynamic = { toString: function() { calls++; return "q"; } };
        \\for (let i = 0; i < 4; i++) dynamic += "x";
        \\print(calls, dynamic);
        \\let wide = "";
        \\for (let i = 0; i < 3; i++) wide += "é";
        \\print(wide.length, wide.charCodeAt(0), wide.charCodeAt(1), wide.charCodeAt(2));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("axyxyxyxyxy\nz\n1 qxxxx\n3 233 233 233\n", stream.buffered());
}

test "latin1 string literal append range fast path collapses loop opcodes" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let s = "";
        \\for (let i = 0; i < 2000; i++) s += "x";
        \\print(s.length);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("2000\n", stream.buffered());
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.add]);
}

test "latin1 string literal append range fast path accepts i8 loop limits" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let s = "";
        \\for (let i = 0; i < 50; i++) s += "x";
        \\print(s.length);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("50\n", stream.buffered());
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.add]);
}

test "host output Number static literal fast path materializes lazy constructor" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(Number.parseInt("12345", 10));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("12345\n", stream.buffered());
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.get_field2]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.call1]);
}

test "empty script eval uses root entry without user call opcodes" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    const result = try js.eval("");
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    // The root evaluator is not a bytecode `call` instruction, so entering its
    // generic VM path does not increment the user-call profile counters.
    try std.testing.expectEqual(@as(u64, 0), profile.totalOpcodeCount());
    try std.testing.expectEqual(@as(u64, 0), profile.call_frame_count);
}

test "short BigInt induction sum range fast path preserves exact results" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [192]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let x = 0n;
        \\for (let i = 0n; i < 10000n; i++) x += i;
        \\print(x, typeof x);
        \\let y = 10n;
        \\for (let i = -3n; i < 4n; i++) y += i;
        \\print(y);
        \\let large = 9223372036854775806n;
        \\for (let i = 0n; i < 3n; i++) large += i;
        \\print(large);
        \\let skipped = 7n;
        \\for (let i = 5n; i < 3n; i++) skipped += i;
        \\print(skipped);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("49995000 bigint\n10\n9223372036854775809\n7\n", stream.buffered());
}

test "simple numeric bytecode call range fast path preserves side effect fallback" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function add(a, b) { return a + b; }
        \\let direct = 0;
        \\for (let i = 0; i < 1000; i++) direct += add(i, 1);
        \\print(direct);
        \\function make(x) { return function(y) { return x + y; }; }
        \\const closure = make(1);
        \\let closed = 0;
        \\for (let i = 0; i < 1000; i++) closed += closure(i);
        \\print(closed);
        \\let calls = 0;
        \\function observed(a, b) { calls++; return a + b; }
        \\let slow = 0;
        \\for (let i = 0; i < 1000; i++) slow += observed(i, 1);
        \\print(calls, slow);
        \\function aliasCase() {
        \\  let captured = 1;
        \\  const reader = function(y) { return captured + y; };
        \\  for (let i = 0; i < 5; i++) captured += reader(i);
        \\  return captured;
        \\}
        \\print(aliasCase());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("500500\n500500\n1000 500500\n58\n", stream.buffered());
}

test "invariant int32 property and dense array range fast path preserves observable reads" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [192]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let own = { a: 1, b: 2 };
        \\let ownSum = 0;
        \\for (let i = 0; i < 1000; i++) ownSum += own.a;
        \\print(ownSum);
        \\let proto = { a: 7 };
        \\let child = Object.create(proto);
        \\let protoSum = 0;
        \\for (let i = 0; i < 1000; i++) protoSum += child.a;
        \\print(protoSum);
        \\let tab = [3];
        \\let arraySum = 0;
        \\for (let i = 0; i < 1000; i++) arraySum += tab[0];
        \\print(arraySum);
        \\let calls = 0;
        \\let guarded = {};
        \\Object.defineProperty(guarded, "a", { get: function() { calls++; return 2; } });
        \\let guardedSum = 0;
        \\for (let i = 0; i < 1000; i++) guardedSum += guarded.a;
        \\print(calls, guardedSum);
        \\let arrayCalls = 0;
        \\Object.defineProperty(Array.prototype, "0", { get: function() { arrayCalls++; return 4; }, configurable: true });
        \\let hole = [];
        \\let holeSum = 0;
        \\for (let i = 0; i < 1000; i++) holeSum += hole[0];
        \\delete Array.prototype[0];
        \\print(arrayCalls, holeSum);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1000\n7000\n3000\n1000 2000\n1000 4000\n", stream.buffered());
}

test "dense array modulo field range fast path preserves observable reads" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const a = { x: 1, y: 0 };
        \\const b = { y: 0, x: 2 };
        \\const c = { z: 0, x: 3 };
        \\const arr = [a, b, c];
        \\let s = 0;
        \\for (let i = 0; i < 1000; i++) s += arr[i % 3].x;
        \\print(s);
        \\let calls = 0;
        \\const guarded = {};
        \\Object.defineProperty(guarded, "x", { get: function() { calls++; return 5; } });
        \\const observed = [{ x: 1 }, guarded, { x: 3 }];
        \\let observedSum = 0;
        \\for (let i = 0; i < 9; i++) observedSum += observed[i % 3].x;
        \\print(calls, observedSum);
        \\const signed = [{ x: 1 }, { x: -2 }, { x: 3 }];
        \\let signedSum = 0;
        \\for (let i = 0; i < 6; i++) signedSum += signed[i % 3].x;
        \\print(signedSum);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1999\n3 27\n4\n", stream.buffered());
}

test "dense array length indexed sum range fast path preserves observable reads" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const direct = [];
        \\for (let i = 0; i < 1000; i++) direct[i] = i;
        \\let directSum = 0;
        \\for (let i = 0; i < direct.length; i++) directSum += direct[i];
        \\print(directSum);
        \\const signed = [-2, 3, -4];
        \\let signedSum = 0;
        \\for (let i = 0; i < signed.length; i++) signedSum += signed[i];
        \\print(signedSum);
        \\let calls = 0;
        \\Object.defineProperty(Array.prototype, "0", { get: function() { calls++; return 5; }, configurable: true });
        \\const hole = [, 2];
        \\let holeSum = 0;
        \\for (let i = 0; i < hole.length; i++) holeSum += hole[i];
        \\delete Array.prototype[0];
        \\print(calls, holeSum);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("499500\n-3\n1 7\n", stream.buffered());
}

test "array named property simple set cache observes prototype changes" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let first = [1];
        \\first.a = 1;
        \\print(first.a);
        \\let setterCount = 0;
        \\Object.defineProperty(Array.prototype, "a", {
        \\  set: function(v) { setterCount = v; },
        \\  configurable: true
        \\});
        \\let second = [2];
        \\second.a = 7;
        \\print(second.a);
        \\print(setterCount);
        \\delete Array.prototype.a;
        \\let third = [3];
        \\third.a = 9;
        \\print(third.a);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\nundefined\n7\n9\n", stream.buffered());
}

test "Array.prototype.push fast path observes inherited indexed setter" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [96]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let seen = 0;
        \\Object.defineProperty(Array.prototype, "2", {
        \\  set: function(v) { seen = v; },
        \\  configurable: true
        \\});
        \\let array = [1, 2];
        \\let result = array.push(3);
        \\print(seen);
        \\print(result);
        \\print(array.length);
        \\print(array[2]);
        \\print(Object.prototype.hasOwnProperty.call(array, "2"));
        \\delete Array.prototype[2];
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3\n3\n3\nundefined\nfalse\n", stream.buffered());
}

test "array dense writers distinguish own Set holes and CreateDataProperty" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    function hasOwn(object, key) {
        \\        return Object.prototype.hasOwnProperty.call(object, key);
        \\    }
        \\    var payload = { marker: "payload" };
        \\    var owners = [Array.prototype, Object.prototype];
        \\    for (var ownerIndex = 0; ownerIndex < owners.length; ownerIndex++) {
        \\        var owner = owners[ownerIndex];
        \\        var seen;
        \\        Object.defineProperty(owner, "1", {
        \\            set: function (value) { seen = value; },
        \\            configurable: true
        \\        });
        \\        try {
        \\            var existing = [0, 1];
        \\            existing[1] = payload;
        \\            assert.sameValue(seen, undefined);
        \\            assert.sameValue(existing[1], payload);
        \\            assert.sameValue(hasOwn(existing, "1"), true);
        \\            var hole = new Array(2);
        \\            hole[1] = payload;
        \\            assert.sameValue(seen, payload);
        \\            assert.sameValue(hasOwn(hole, "1"), false);
        \\            assert.sameValue(hole.length, 2);
        \\            seen = undefined;
        \\            var defined = new Array(2);
        \\            Object.defineProperty(defined, "1", {
        \\                value: payload,
        \\                writable: true,
        \\                enumerable: true,
        \\                configurable: true
        \\            });
        \\            assert.sameValue(seen, undefined);
        \\            assert.sameValue(defined[1], payload);
        \\            assert.sameValue(hasOwn(defined, "1"), true);
        \\
        \\            var literal = [0, payload];
        \\            var constructed = new Array(0, payload);
        \\            var fromResult = Array.from([0, payload]);
        \\            var ofResult = Array.of(0, payload);
        \\            var mapped = [0, 1].map(function () { return payload; });
        \\            var created = [literal, constructed, fromResult, ofResult, mapped];
        \\            for (var createdIndex = 0; createdIndex < created.length; createdIndex++) {
        \\                assert.sameValue(created[createdIndex][1], payload);
        \\                assert.sameValue(hasOwn(created[createdIndex], "1"), true);
        \\            }
        \\            assert.sameValue(seen, undefined);
        \\        } finally {
        \\            delete owner[1];
        \\        }
        \\    }
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "push splice fill and unshift preserve prototype and payload semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    function hasOwn(object, key) {
        \\        return Object.prototype.hasOwnProperty.call(object, key);
        \\    }
        \\    function run(owner, payload) {
        \\        var seen;
        \\        Object.defineProperty(owner, "1", {
        \\            set: function (value) { seen = value; },
        \\            configurable: true
        \\        });
        \\        try {
        \\            var pushed = [10];
        \\            assert.sameValue(pushed.push(payload), 2);
        \\            assert.sameValue(seen, payload);
        \\            assert.sameValue(hasOwn(pushed, "1"), false);
        \\            assert.sameValue(pushed.length, 2);
        \\
        \\            seen = undefined;
        \\            var spliced = [10];
        \\            var removed = spliced.splice(1, 0, payload);
        \\            assert.sameValue(removed.length, 0);
        \\            assert.sameValue(seen, payload);
        \\            assert.sameValue(hasOwn(spliced, "1"), false);
        \\            assert.sameValue(spliced.length, 2);
        \\
        \\            seen = undefined;
        \\            var filled = new Array(2);
        \\            filled[0] = 10;
        \\            assert.sameValue(filled.fill(payload, 1, 2), filled);
        \\            assert.sameValue(seen, payload);
        \\            assert.sameValue(hasOwn(filled, "1"), false);
        \\            assert.sameValue(filled.length, 2);
        \\
        \\            seen = undefined;
        \\            var unshifted = [10];
        \\            assert.sameValue(unshifted.unshift(payload), 2);
        \\            assert.sameValue(seen, 10);
        \\            assert.sameValue(unshifted[0], payload);
        \\            assert.sameValue(hasOwn(unshifted, "1"), false);
        \\            assert.sameValue(unshifted.length, 2);
        \\        } finally {
        \\            delete owner[1];
        \\        }
        \\    }
        \\
        \\    var owners = [Array.prototype, Object.prototype];
        \\    var payloads = [{ marker: "object" }, Symbol("symbol payload")];
        \\    for (var ownerIndex = 0; ownerIndex < owners.length; ownerIndex++) {
        \\        for (var payloadIndex = 0; payloadIndex < payloads.length; payloadIndex++) {
        \\            run(owners[ownerIndex], payloads[payloadIndex]);
        \\        }
        \\    }
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "array indexed setter guards follow the receiver realm" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    function hasOwn(object, key) {
        \\        return Object.prototype.hasOwnProperty.call(object, key);
        \\    }
        \\    var other = $262.createRealm().global;
        \\    var payload = { marker: "cross-realm" };
        \\    var localSeen;
        \\    Object.defineProperty(Array.prototype, "1", {
        \\        set: function (value) { localSeen = value; },
        \\        configurable: true
        \\    });
        \\    try {
        \\        var foreignClean = other.eval("[10]");
        \\        assert.sameValue(other.Array.prototype.push.call(foreignClean, payload), 2);
        \\        assert.sameValue(localSeen, undefined);
        \\        assert.sameValue(foreignClean[1], payload);
        \\        assert.sameValue(hasOwn(foreignClean, "1"), true);
        \\
        \\        var localPolluted = [10];
        \\        assert.sameValue(other.Array.prototype.push.call(localPolluted, payload), 2);
        \\        assert.sameValue(localSeen, payload);
        \\        assert.sameValue(hasOwn(localPolluted, "1"), false);
        \\    } finally {
        \\        delete Array.prototype[1];
        \\    }
        \\
        \\    var foreignSeen;
        \\    other.Object.defineProperty(other.Object.prototype, "1", {
        \\        set: function (value) { foreignSeen = value; },
        \\        configurable: true
        \\    });
        \\    try {
        \\        var localClean = [10];
        \\        assert.sameValue(Array.prototype.push.call(localClean, payload), 2);
        \\        assert.sameValue(foreignSeen, undefined);
        \\        assert.sameValue(localClean[1], payload);
        \\        assert.sameValue(hasOwn(localClean, "1"), true);
        \\
        \\        var foreignPolluted = other.eval("[10]");
        \\        assert.sameValue(Array.prototype.push.call(foreignPolluted, payload), 2);
        \\        assert.sameValue(foreignSeen, payload);
        \\        assert.sameValue(hasOwn(foreignPolluted, "1"), false);
        \\    } finally {
        \\        delete other.Object.prototype[1];
        \\    }
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "array dense append guard distinguishes custom proxy and null prototypes" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    function hasOwn(object, key) {
        \\        return Object.prototype.hasOwnProperty.call(object, key);
        \\    }
        \\    var customPayload = { marker: "custom" };
        \\    var customSeen;
        \\    var customPrototype = Object.create(Array.prototype);
        \\    Object.defineProperty(customPrototype, "1", {
        \\        set: function (value) { customSeen = value; },
        \\        configurable: true
        \\    });
        \\    var customArray = [10];
        \\    Object.setPrototypeOf(customArray, customPrototype);
        \\    assert.sameValue(Array.prototype.push.call(customArray, customPayload), 2);
        \\    assert.sameValue(customSeen, customPayload);
        \\    assert.sameValue(hasOwn(customArray, "1"), false);
        \\    var proxyPayload = Symbol("proxy payload");
        \\    var proxyKeys = [];
        \\    var proxySeen;
        \\    var proxyPrototype = new Proxy(Array.prototype, {
        \\        set: function (target, key, value, receiver) {
        \\            proxyKeys.push(String(key));
        \\            proxySeen = value;
        \\            return Reflect.set(target, key, value, receiver);
        \\        }
        \\    });
        \\    var proxyArray = [10];
        \\    Object.setPrototypeOf(proxyArray, proxyPrototype);
        \\    assert.sameValue(Array.prototype.push.call(proxyArray, proxyPayload), 2);
        \\    assert.sameValue(proxyKeys.join(","), "1");
        \\    assert.sameValue(proxySeen, proxyPayload);
        \\    assert.sameValue(proxyArray[1], proxyPayload);
        \\    assert.sameValue(hasOwn(proxyArray, "1"), true);
        \\    var nullPayload = { marker: "null" };
        \\    var nullArray = [10];
        \\    Object.setPrototypeOf(nullArray, null);
        \\    assert.sameValue(Array.prototype.push.call(nullArray, nullPayload), 2);
        \\    assert.sameValue(nullArray[1], nullPayload);
        \\    assert.sameValue(hasOwn(nullArray, "1"), true);
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "standard Array prototype guard publication and invalidation are realm local" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const setup = try js.eval(
        \\globalThis.__arrayGuardOther = $262.createRealm().global;
        \\globalThis.__arrayGuardPrototypeMutation = $262.createRealm().global;
        \\globalThis.__arrayGuardFailedPrototypeMutation = $262.createRealm().global;
        \\globalThis.__arrayGuardOomMutation = $262.createRealm().global;
    );
    setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const other_key = try js.runtime.internAtom("__arrayGuardOther");
    defer js.runtime.atoms.free(other_key);
    const other_value = try global.getProperty(other_key);
    defer other_value.free(js.runtime);
    const other_global = try core.Object.expect(other_value);
    const prototype_mutation_key = try js.runtime.internAtom("__arrayGuardPrototypeMutation");
    defer js.runtime.atoms.free(prototype_mutation_key);
    const prototype_mutation_value = try global.getProperty(prototype_mutation_key);
    defer prototype_mutation_value.free(js.runtime);
    const prototype_mutation_global = try core.Object.expect(prototype_mutation_value);
    const failed_prototype_mutation_key = try js.runtime.internAtom("__arrayGuardFailedPrototypeMutation");
    defer js.runtime.atoms.free(failed_prototype_mutation_key);
    const failed_prototype_mutation_value = try global.getProperty(failed_prototype_mutation_key);
    defer failed_prototype_mutation_value.free(js.runtime);
    const failed_prototype_mutation_global = try core.Object.expect(failed_prototype_mutation_value);
    const oom_mutation_key = try js.runtime.internAtom("__arrayGuardOomMutation");
    defer js.runtime.atoms.free(oom_mutation_key);
    const oom_mutation_value = try global.getProperty(oom_mutation_key);
    defer oom_mutation_value.free(js.runtime);
    const oom_mutation_global = try core.Object.expect(oom_mutation_value);

    const local_array_value = global.cachedRealmValue(js.runtime, .array_prototype) orelse return error.TestUnexpectedResult;
    const other_array_value = other_global.cachedRealmValue(js.runtime, .array_prototype) orelse return error.TestUnexpectedResult;
    const prototype_mutation_array_value = prototype_mutation_global.cachedRealmValue(js.runtime, .array_prototype) orelse return error.TestUnexpectedResult;
    const failed_prototype_mutation_array_value = failed_prototype_mutation_global.cachedRealmValue(js.runtime, .array_prototype) orelse return error.TestUnexpectedResult;
    const oom_mutation_array_value = oom_mutation_global.cachedRealmValue(js.runtime, .array_prototype) orelse return error.TestUnexpectedResult;
    const oom_mutation_object_value = oom_mutation_global.cachedRealmValue(js.runtime, .object_prototype) orelse return error.TestUnexpectedResult;
    const local_array = try core.Object.expect(local_array_value);
    const other_array = try core.Object.expect(other_array_value);
    const prototype_mutation_array = try core.Object.expect(prototype_mutation_array_value);
    const failed_prototype_mutation_array = try core.Object.expect(failed_prototype_mutation_array_value);
    const oom_mutation_array = try core.Object.expect(oom_mutation_array_value);
    const oom_mutation_object = try core.Object.expect(oom_mutation_object_value);
    try std.testing.expect(local_array.isStandardArrayPrototype());
    try std.testing.expect(other_array.isStandardArrayPrototype());
    try std.testing.expect(prototype_mutation_array.isStandardArrayPrototype());
    try std.testing.expect(failed_prototype_mutation_array.isStandardArrayPrototype());
    try std.testing.expect(oom_mutation_array.isStandardArrayPrototype());

    // Force the property mutation to allocate by sharing the current shape.
    // Guard invalidation must happen before that allocation and remain sticky
    // even though the indexed property itself is rolled back on OOM.
    const pinned_oom_shape = oom_mutation_object.shape_ref;
    pinned_oom_shape.retain();
    defer js.runtime.shapes.release(pinned_oom_shape);
    const index_zero = core.atom.atomFromUInt32(0);
    js.runtime.setMemoryLimit(js.runtime.memory.allocated_bytes);
    defer js.runtime.setMemoryLimit(null);
    try std.testing.expectError(
        error.OutOfMemory,
        oom_mutation_object.defineOwnProperty(
            js.runtime,
            index_zero,
            core.Descriptor.data(core.JSValue.int32(1), true, true, true),
        ),
    );
    js.runtime.setMemoryLimit(null);
    try std.testing.expect(!oom_mutation_object.hasOwnProperty(index_zero));
    try std.testing.expect(!oom_mutation_array.isStandardArrayPrototype());
    try std.testing.expect(local_array.isStandardArrayPrototype());
    try std.testing.expect(other_array.isStandardArrayPrototype());

    // QuickJS's realm guard invalidation is deliberately narrower than the
    // full ArrayIndex grammar: only tagged integer atoms (0...INT32_MAX)
    // poison the marker. A high index string and a non-canonical numeric name
    // still update ordinary lookup summaries without disabling dense append.
    const mutate_other_high_or_named = try js.eval(
        \\__arrayGuardOther.Object.defineProperty(__arrayGuardOther.Object.prototype, "2147483648", { value: 1, configurable: true });
        \\delete __arrayGuardOther.Object.prototype["2147483648"];
        \\__arrayGuardOther.Object.defineProperty(__arrayGuardOther.Array.prototype, "2147483648", { value: 1, configurable: true });
        \\delete __arrayGuardOther.Array.prototype["2147483648"];
        \\__arrayGuardOther.Object.defineProperty(__arrayGuardOther.Object.prototype, "01", { value: 1, configurable: true });
        \\delete __arrayGuardOther.Object.prototype["01"];
        \\__arrayGuardOther.Object.defineProperty(__arrayGuardOther.Array.prototype, "named", { value: 1, configurable: true });
        \\delete __arrayGuardOther.Array.prototype.named;
        \\var __arrayGuardSymbol = __arrayGuardOther.Symbol("guard");
        \\__arrayGuardOther.Object.defineProperty(__arrayGuardOther.Array.prototype, __arrayGuardSymbol, { value: 1, configurable: true });
        \\delete __arrayGuardOther.Array.prototype[__arrayGuardSymbol];
    );
    mutate_other_high_or_named.free(js.runtime);
    try std.testing.expect(other_array.isStandardArrayPrototype());

    const mutate_local = try js.eval(
        \\Object.defineProperty(Array.prototype, "0", { value: 1, configurable: true });
        \\delete Array.prototype[0];
    );
    mutate_local.free(js.runtime);
    try std.testing.expect(!local_array.isStandardArrayPrototype());
    try std.testing.expect(other_array.isStandardArrayPrototype());
    try std.testing.expect(prototype_mutation_array.isStandardArrayPrototype());

    const mutate_other = try js.eval(
        \\__arrayGuardOther.eval("Object.defineProperty(Object.prototype, '0', { value: 2, configurable: true }); delete Object.prototype[0];");
    );
    mutate_other.free(js.runtime);
    try std.testing.expect(!local_array.isStandardArrayPrototype());
    try std.testing.expect(!other_array.isStandardArrayPrototype());
    try std.testing.expect(prototype_mutation_array.isStandardArrayPrototype());

    const retain_same_prototype = try js.eval(
        \\__arrayGuardPrototypeMutation.Object.setPrototypeOf(
        \\    __arrayGuardPrototypeMutation.Array.prototype,
        \\    __arrayGuardPrototypeMutation.Object.getPrototypeOf(__arrayGuardPrototypeMutation.Array.prototype)
        \\);
    );
    retain_same_prototype.free(js.runtime);
    try std.testing.expect(prototype_mutation_array.isStandardArrayPrototype());

    const reject_prototype_mutation = try js.eval(
        \\__arrayGuardFailedPrototypeMutation.Object.preventExtensions(__arrayGuardFailedPrototypeMutation.Array.prototype);
        \\var __arrayGuardMutationRejected = false;
        \\try {
        \\    __arrayGuardFailedPrototypeMutation.Object.setPrototypeOf(__arrayGuardFailedPrototypeMutation.Array.prototype, null);
        \\} catch (error) {
        \\    __arrayGuardMutationRejected = error.name === "TypeError";
        \\}
        \\if (!__arrayGuardMutationRejected) throw new Error("expected cross-realm TypeError");
    );
    reject_prototype_mutation.free(js.runtime);
    try std.testing.expect(failed_prototype_mutation_array.isStandardArrayPrototype());

    const mutate_prototype = try js.eval(
        \\__arrayGuardPrototypeMutation.Object.setPrototypeOf(__arrayGuardPrototypeMutation.Array.prototype, null);
    );
    mutate_prototype.free(js.runtime);
    try std.testing.expect(!prototype_mutation_array.isStandardArrayPrototype());
}

test "Array.prototype.push field2 fast path preserves observable guards" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let fast = [];
        \\for (let i = 0; i < 8; i++) fast.push(i);
        \\print(fast.length, fast[0], fast[7]);
        \\print(eval("let completion=[]; for (let i=0; i<4; i++) completion.push(i);"));
        \\print(eval("let skipped=[]; for (let i=4; i<4; i++) skipped.push(i);"));
        \\let saved = Array.prototype.push;
        \\try {
        \\  let calls = 0;
        \\  Array.prototype.push = function(v) { calls++; return 123; };
        \\  let custom = [];
        \\  print(custom.push(9), custom.length, calls);
        \\  let customLoop = [];
        \\  for (let i = 0; i < 3; i++) customLoop.push(i);
        \\  print(customLoop.length, calls);
        \\} finally {
        \\  Array.prototype.push = saved;
        \\}
        \\let own = [];
        \\own.push = function(v) { return 77; };
        \\print(own.push(1), own.length);
        \\let locked = [];
        \\Object.defineProperty(locked, "length", { writable: false });
        \\try { locked.push(1); print("locked-ok"); } catch (e) { print(e instanceof TypeError, locked.length); }
        \\let lockedLoop = [];
        \\Object.defineProperty(lockedLoop, "length", { writable: false });
        \\try { for (let i = 0; i < 2; i++) lockedLoop.push(i); print("locked-loop-ok"); } catch (e) { print(e instanceof TypeError, lockedLoop.length); }
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("8 0 7\n4\nundefined\n123 0 1\n0 4\n77 0\ntrue 0\ntrue 0\n", stream.buffered());
}

test "RegExp literal test range fast path preserves observable guards" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let c = 0;
        \\for (let i = 0; i < 8; i++) if (/a+b/.test("aaab")) c++;
        \\print(c);
        \\let miss = 0;
        \\for (let i = 0; i < 8; i++) if (/z+/.test("aaab")) miss++;
        \\print(miss);
        \\let saved = RegExp.prototype.test;
        \\try {
        \\  let calls = 0;
        \\  RegExp.prototype.test = function(s) { calls++; return false; };
        \\  let custom = 0;
        \\  for (let i = 0; i < 3; i++) if (/a+b/.test("aaab")) custom++;
        \\  print(custom, calls);
        \\} finally {
        \\  RegExp.prototype.test = saved;
        \\}
        \\let globalFlag = 0;
        \\for (let i = 0; i < 3; i++) if (/a/g.test("a")) globalFlag++;
        \\print(globalFlag);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("8\n0\n0 3\n3\n", stream.buffered());
}

test "sparse array literal fast paths preserve holes and length semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [160]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\"use strict";
        \\let a = [1, , 3];
        \\print(a.length, 0 in a, 1 in a, 2 in a, a[1] === undefined);
        \\let b = [, ,];
        \\print(b.length, 0 in b, 1 in b);
        \\let c = [1];
        \\Object.defineProperty(c, "0", { configurable: false });
        \\try { c.length = 0; print("shrink-ok"); } catch (e) { print("shrink-err"); }
        \\print(c.length, c[0]);
        \\c.length = 2;
        \\print(c.length, c[0]);
        \\let calls = 0;
        \\function sideEffect() { calls++; return 3; }
        \\let sum = 0;
        \\for (let i = 0; i < 4; i++) { const d = [1, , sideEffect()]; sum += d.length; }
        \\print(sum, calls);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3 true false true true\n2 false false\nshrink-err\n1 1\n2 1\n12 4\n", stream.buffered());
}

test "sparse array literal length add range fast path collapses loop opcodes" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let s = 0;
        \\for (let i = 0; i < 50000; i++) { const a = [1, , 3]; s += a.length; }
        \\print(s);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("150000\n", stream.buffered());
    try std.testing.expect(profile.totalOpcodeCount() <= 20);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.array_from]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.define_field]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.get_length]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.add]);
}

test "array for-of fast path preserves iterator observability" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let s = 0;
        \\for (let x of [1, 2, 3]) s += x;
        \\print(s);
        \\let a = [1, , 3];
        \\Object.prototype[1] = 9;
        \\let inherited = 0;
        \\for (let x of a) inherited += x;
        \\delete Object.prototype[1];
        \\print(inherited);
        \\let calls = 0;
        \\const proto = Object.getPrototypeOf([][Symbol.iterator]());
        \\const saved = proto.next;
        \\proto.next = function() { calls++; return saved.call(this); };
        \\let patched = 0;
        \\for (let x of [4, 5]) patched += x;
        \\proto.next = saved;
        \\print(patched, calls);
        \\let keys = "";
        \\for (let k of [10, 20].keys()) keys += k;
        \\print(keys);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("6\n13\n9 3\n01\n", stream.buffered());
}

test "dense array indexed append range preserves ordinary set guards" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let fast = [];
        \\for (let i = 0; i < 8; i++) fast[i] = i;
        \\let sum = 0;
        \\for (let i = 0; i < fast.length; i++) sum += fast[i];
        \\print(fast.length, sum, fast[7]);
        \\print(eval("let completionArray=[]; for (let i=0; i<4; i++) completionArray[i]=i;"));
        \\print(eval("let skippedArray=[]; for (let i=4; i<4; i++) skippedArray[i]=i;"));
        \\print(eval("let contentArray=[]; for (let i=0; i<4; i++) contentArray[i]=i; contentArray.join(',');"));
        \\let masked = [];
        \\let maskedSum = 0;
        \\for (let i = 0; i < 8; i++) masked[i] = (i * 7) & 255;
        \\for (let i = 0; i < masked.length; i++) maskedSum += masked[i];
        \\print(masked.length, masked[0], masked[7], maskedSum);
        \\function varMasked() {
        \\  var values = [];
        \\  for (var i = 0; i < 8; i++) values[i] = (i * 7) & 255;
        \\  return values.length + ":" + values[0] + ":" + values[7];
        \\}
        \\print(varMasked());
        \\let seen = "";
        \\Object.defineProperty(Array.prototype, "0", {
        \\  set: function(v) { seen += v + ":"; },
        \\  get: function() { return 99; },
        \\  configurable: true
        \\});
        \\let guarded = [];
        \\for (let i = 0; i < 2; i++) guarded[i] = i;
        \\print(seen);
        \\print(guarded.length);
        \\print(guarded[0]);
        \\print(Object.prototype.hasOwnProperty.call(guarded, "0"));
        \\let maskedGuarded = [];
        \\for (let i = 0; i < 2; i++) maskedGuarded[i] = (i * 7) & 255;
        \\print(seen);
        \\print(maskedGuarded.length);
        \\print(maskedGuarded[0]);
        \\print(Object.prototype.hasOwnProperty.call(maskedGuarded, "0"));
        \\print(maskedGuarded[1]);
        \\function varMaskedGuarded() {
        \\  var values = [];
        \\  for (var i = 0; i < 2; i++) values[i] = (i * 7) & 255;
        \\  print(seen);
        \\  print(values.length);
        \\  print(values[0]);
        \\  print(Object.prototype.hasOwnProperty.call(values, "0"));
        \\  print(values[1]);
        \\}
        \\varMaskedGuarded();
        \\let overwrite = [0,1,2,3,4,5,6,7];
        \\for (let i = 0; i < 1000; i++) overwrite[i & 7] = i;
        \\print(overwrite[0], overwrite[7], overwrite.join(","));
        \\print(eval("let overwriteEval=[0,1,2,3,4,5,6,7]; for (let i=0; i<10; i++) overwriteEval[i&7]=i;"));
        \\let guardedOverwrite = [,1,2,3,4,5,6,7];
        \\for (let i = 0; i < 8; i++) guardedOverwrite[i & 7] = i;
        \\print(seen);
        \\print(guardedOverwrite.length);
        \\print(guardedOverwrite[0]);
        \\print(Object.prototype.hasOwnProperty.call(guardedOverwrite, "0"));
        \\print(guardedOverwrite[7]);
        \\delete Array.prototype[0];
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("8 28 7\n3\nundefined\n0,1,2,3\n8 0 49 196\n8:0:49\n0:\n2\n99\nfalse\n0:0:\n2\n99\nfalse\n7\n0:0:0:\n2\n99\nfalse\n7\n992 999 992,993,994,995,996,997,998,999\n9\n0:0:0:0:\n8\n99\nfalse\n7\n", stream.buffered());
}

test "array map simple callback range preserves closed induction and completion" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const a = [1,2,3,4,5,6,7,8,9,10];
        \\let out;
        \\for (let i = 0; i < 100; i++) out = a.map(x => x + 1);
        \\print(out.length, out[0], out[9]);
        \\print(eval("const e=[1,2]; let r; for (let j=0; j<4; j++) r=e.map(x=>x+1);"));
        \\print(eval("const s=[1,2]; let r; for (let k=4; k<4; k++) r=s.map(x=>x+1);"));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("10 2 11\n2,3\nundefined\n", stream.buffered());
}

test "global var induction add range preserves completion" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var sum = 0;
        \\for (var i = 0; i < 1000; i++) sum += i;
        \\print(sum, i);
        \\print(eval("var evalSum=0; for (var j=0; j<4; j++) evalSum += j;"));
        \\print(eval("var skippedSum=0; for (var k=4; k<4; k++) skippedSum += k;"));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("499500 1000\n6\nundefined\n", stream.buffered());
}

test "global write induction range preserves strict writable semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\"use strict";
        \\var g = -1;
        \\for (let i = 0; i < 1000; i++) g = i;
        \\print(g);
        \\var skipped = 7;
        \\for (let j = 5; j < 5; j++) skipped = j;
        \\print(skipped);
        \\Object.defineProperty(globalThis, "roGlobalLoop", { value: 1, writable: false, configurable: true });
        \\try {
        \\  for (let k = 0; k < 3; k++) roGlobalLoop = k;
        \\} catch (e) {
        \\  print(e.name, roGlobalLoop);
        \\}
        \\delete globalThis.roGlobalLoop;
        \\print(eval("var eg = -1; for (let i = 0; i < 4; i++) eg = i;"));
        \\print(eval("var eg2 = -1; for (let j = 4; j < 4; j++) eg2 = j;"));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("999\n7\nTypeError 1\n3\nundefined\n", stream.buffered());
}

test "short BigInt induction add range preserves completion" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let x = 0n;
        \\for (let i = 0n; i < 4n; i++) x += i;
        \\print(x);
        \\print(eval("let y=0n; for (let j=0n; j<4n; j++) y += j;"));
        \\print(eval("let z=0n; for (let k=4n; k<4n; k++) z += k;"));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("6\n6\nundefined\n", stream.buffered());
}

const EscapedEvalImportHost = struct {
    expected_referrer: []const u8,
    saw_expected_referrer: bool = false,
};

fn escapedEvalImportResolve(
    ptr: *anyopaque,
    specifier: []const u8,
    referrer: ?[]const u8,
    allocator: std.mem.Allocator,
) anyerror!helpers.TestEngine.HostHooks.ResolvedModule {
    const host: *EscapedEvalImportHost = @ptrCast(@alignCast(ptr));
    const dep_path = "/fixture/scripts/dep.js";
    if (std.mem.eql(u8, specifier, "./dep.js")) {
        host.saw_expected_referrer = if (referrer) |path|
            std.mem.eql(u8, path, host.expected_referrer)
        else
            false;
    } else if (!std.mem.eql(u8, specifier, dep_path)) {
        return error.ModuleNotFound;
    }
    return .{
        .specifier = try allocator.dupe(u8, specifier),
        .path = try allocator.dupe(u8, dep_path),
        .kind = .esm,
    };
}

fn escapedEvalImportLoad(
    _: *anyopaque,
    resolved: helpers.TestEngine.HostHooks.ResolvedModule,
    allocator: std.mem.Allocator,
) anyerror!helpers.TestEngine.HostHooks.LoadedModule {
    const dep_path = "/fixture/scripts/dep.js";
    if (!std.mem.eql(u8, resolved.path, dep_path)) return error.ModuleNotFound;
    return .{
        .source = "export const answer = 42;",
        .path = try allocator.dupe(u8, dep_path),
        .kind = .esm,
        .owned = false,
    };
}

test "escaped direct eval function keeps script referrer for dynamic import" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const root_path = "/fixture/scripts/main.mjs";
    var host = EscapedEvalImportHost{ .expected_referrer = root_path };
    const hooks = helpers.TestEngine.HostHooks{
        .ptr = &host,
        .resolveModule = escapedEvalImportResolve,
        .loadModule = escapedEvalImportLoad,
    };

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithHostHooks(
        \\var escaped;
        \\function createLoader() {
        \\  escaped = eval("eval(\"(function load(){ return import('./dep.js'); })\")");
        \\}
        \\createLoader();
        \\escaped().then(
        \\  function(namespace) { print(namespace.answer); },
        \\  function(error) { print(error.name); }
        \\);
    ,
        &stream,
        root_path,
        hooks,
        std.testing.allocator,
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expect(host.saw_expected_referrer);
    try std.testing.expectEqualStrings("42\n", stream.buffered());
}

test "escaped direct eval function keeps eval stack filename" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [1]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileWithOutputMode(
        \\function createThrower() {
        \\  return eval("(function evalThrower(){ throw new Error('boom'); })");
        \\}
        \\var escaped = createThrower();
        \\var stack;
        \\try { escaped(); } catch (error) { stack = error.stack; }
        \\assert.sameValue(typeof stack, "string");
        \\assert.sameValue(stack.indexOf("<eval>") >= 0, true);
    ,
        &stream,
        .script,
        "/fixture/scripts/original.js",
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("", stream.buffered());
}

test "Engine eval executes simple direct eval strings" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const x = 1;
        \\console.log(eval("x + 1"));
        \\console.log(eval("2 + 2"));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("2\n4\n", stream.buffered());
}

test "Engine script parse errors are never converted to source-shaped completions" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [1]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    try std.testing.expectError(error.SyntaxError, js.evalWithOutput("1 2", &stream));
    try std.testing.expectEqualStrings("", stream.buffered());
}

test "direct and indirect eval regexp literals share the generic parser semantics" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function checkPair(exact, terminated) {
        \\  assert.sameValue(exact.source, terminated.source);
        \\  assert.sameValue(exact.flags, terminated.flags);
        \\  assert.sameValue(exact !== terminated, true);
        \\  assert.sameValue(Object.getPrototypeOf(exact), Object.getPrototypeOf(terminated));
        \\}
        \\checkPair(eval("/a/gi"), eval("/a/gi;"));
        \\const indirect = (0, eval);
        \\checkPair(indirect("/b/m"), indirect("/b/m;"));
        \\for (const source of ["/(/", "/(/;"]) {
        \\  let syntax = false;
        \\  try { eval(source); } catch (error) { syntax = error instanceof SyntaxError; }
        \\  assert.sameValue(syntax, true);
        \\}
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "direct eval expression completion does not depend on a source terminator" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function probe() {
        \\  assert.sameValue(eval('"value"'), eval('"value";'));
        \\  assert.sameValue(eval("this"), eval("this;"));
        \\}
        \\probe.call({ marker: 1 });
        \\const sloppy = (function named() {
        \\  const exact = eval("named = 0");
        \\  const terminated = eval("named = 0;");
        \\  return [exact, terminated, typeof named];
        \\})();
        \\assert.sameValue(sloppy[0], 0);
        \\assert.sameValue(sloppy[1], 0);
        \\assert.sameValue(sloppy[2], "function");
        \\for (const source of ["named = 0", "named = 0;"]) {
        \\  let typeError = false;
        \\  try { (function named() { "use strict"; eval(source); })(); }
        \\  catch (error) { typeError = error instanceof TypeError; }
        \\  assert.sameValue(typeError, true);
        \\}
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "test262 frontmatter comments do not change engine strict mode" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [8]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\/*---
        \\flags: [onlyStrict]
        \\---*/
        \\function acceptsEval(eval) { return eval; }
        \\print(acceptsEval(1));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\n", stream.buffered());
}

test "Engine eval executes declaration-only side effects" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [192]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\delete globalThis.evalDeclOnlyVar;
        \\delete globalThis.evalDeclOnlyFunc;
        \\const indirectEval = (0, eval);
        \\print(indirectEval("var evalDeclOnlyVar;"));
        \\print("evalDeclOnlyVar" in globalThis, globalThis.evalDeclOnlyVar);
        \\print(indirectEval("function evalDeclOnlyFunc(){}"));
        \\print(typeof evalDeclOnlyFunc, typeof globalThis.evalDeclOnlyFunc);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("undefined\ntrue undefined\nundefined\nfunction function\n", stream.buffered());
}

test "Engine direct eval follows resolved intrinsic eval binding" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var a = 9;
        \\function directArg(eval, s) {
        \\  var a = 1;
        \\  return eval(s);
        \\}
        \\function directVar(f, s) {
        \\  var eval = f;
        \\  var a = 1;
        \\  return eval(s);
        \\}
        \\function directWith(obj, s) {
        \\  var f;
        \\  with (obj) {
        \\    f = function () {
        \\      var a = 1;
        \\      return eval(s);
        \\    };
        \\  }
        \\  return f();
        \\}
        \\function directSpread(eval, s) {
        \\  var a = 1;
        \\  return eval(...[s]);
        \\}
        \\function notIntrinsic(eval) {
        \\  try { return eval(); } catch (e) { return e.name; }
        \\}
        \\function notIntrinsicSpread(eval) {
        \\  try { return eval(...[]); } catch (e) { return e.name; }
        \\}
        \\print(directArg(eval, "a+1"));
        \\print(directVar(eval, "a+1"));
        \\print(directWith(this, "a+1"));
        \\print(directWith({ eval: eval, a: -1000 }, "a+1"));
        \\print(directSpread(eval, "a+1"));
        \\print(notIntrinsic(""));
        \\print(notIntrinsicSpread(""));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("2\n2\n2\n2\n2\nTypeError\nTypeError\n", stream.buffered());
}

test "Engine parenthesized eval preserves only grouping directness" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var t = "global";
        \\function group() {
        \\  var t = "local";
        \\  return (eval)("t");
        \\}
        \\function comma() {
        \\  var t = "local";
        \\  return (1, eval)("t");
        \\}
        \\function ternaryTrue() {
        \\  var t = "local";
        \\  return (true ? eval : null)("t");
        \\}
        \\function ternaryFalse() {
        \\  var t = "local";
        \\  return (0 ? null : eval)("t");
        \\}
        \\function logicalOr() {
        \\  var t = "local";
        \\  return (0 || eval)("t");
        \\}
        \\function logicalAnd() {
        \\  var t = "local";
        \\  return (1 && eval)("t");
        \\}
        \\function nullish() {
        \\  var t = "local";
        \\  return (null ?? eval)("t");
        \\}
        \\print(group());
        \\print(comma());
        \\print(ternaryTrue());
        \\print(ternaryFalse());
        \\print(logicalOr());
        \\print(logicalAnd());
        \\print(nullish());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("local\nglobal\nglobal\nglobal\nglobal\nglobal\nglobal\n", stream.buffered());
}

test "Engine direct eval assignment reference timing matches QuickJS" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function testAssignment() {
        \\  var x = 0;
        \\  var innerX = (function() {
        \\    x = (eval("var x;"), 1);
        \\    return x;
        \\  })();
        \\  print(innerX, x);
        \\}
        \\function testCompoundAssignment() {
        \\  var x = 3;
        \\  var innerX = (function() {
        \\    x *= (eval("var x = 2;"), 4);
        \\    return x;
        \\  })();
        \\  print(innerX, x);
        \\}
        \\function testLogicalAssignment() {
        \\  var x = 0;
        \\  var innerX = (function() {
        \\    x ||= (eval("var x;"), 1);
        \\    return x;
        \\  })();
        \\  print(innerX, x);
        \\}
        \\testAssignment();
        \\testCompoundAssignment();
        \\testLogicalAssignment();
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    // Pinned QuickJS resolves these dynamic references to the binding created
    // by the direct eval: `1 0`, `12 3`, and `1 0`, respectively.
    try std.testing.expectEqualStrings("1 0\n12 3\n1 0\n", stream.buffered());
}

test "Engine assignment RHS regexp and division follow eval reference timing" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var r;
        \\r = /\S+/g;
        \\print(r.test("a"));
        \\var out;
        \\out = "a".replace(/\S+/g, "test262");
        \\print(out);
        \\var match;
        \\match = "abc".match(/(?<word>\w+)/);
        \\print(match.groups.word);
        \\function testDivisionEval() {
        \\  var x = 10;
        \\  var innerX = (function() {
        \\    x = 20 / eval("var x = 2; 2");
        \\    return x;
        \\  })();
        \\  print(innerX, x);
        \\}
        \\testDivisionEval();
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    // Pinned QuickJS prints `10 10`: the assignment updates eval's local `x`,
    // while the outer function binding remains unchanged.
    try std.testing.expectEqualStrings("true\ntest262\nabc\n10 10\n", stream.buffered());
}

test "Engine eval inherits caller scope through nested direct eval" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [16]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var condition = 0;
        \\var evaluated = eval("while (condition < 5) eval(\"condition++\");");
        \\print(condition, evaluated);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("5 4\n", stream.buffered());
}

test "Engine strict direct eval updates visible parameter refs" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function assign(code, p) {
        \\  "use strict";
        \\  eval(code);
        \\  return p;
        \\}
        \\print(assign("p = 2", 17));
        \\function read(code, p) {
        \\  "use strict";
        \\  return eval(code);
        \\}
        \\print(read("p + 0", 17));
        \\function nested(code, p) {
        \\  "use strict";
        \\  function inner() { eval(code); }
        \\  inner();
        \\  return p;
        \\}
        \\print(nested("p = 2", 17));
        \\function strictArgs(code, p) {
        \\  "use strict";
        \\  eval(code);
        \\  return arguments[1];
        \\}
        \\print(strictArgs("p = 2", 17));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("2\n17\n2\n17\n", stream.buffered());
}

test "Engine direct eval captures outer names only mentioned in eval source" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function outer(a) {
        \\  let x = 3;
        \\  var y = 4;
        \\  return function() {
        \\    return eval("a + x + y");
        \\  };
        \\}
        \\print(outer(2)());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("9\n", stream.buffered());
}

test "Engine direct eval prefers an inner lexical declared before a later outer shadow" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function outer() {
        \\  let target;
        \\  { let x = 1; target = function() { return eval("x"); }; }
        \\  let x = 2;
        \\  return target();
        \\}
        \\print(outer());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\n", stream.buffered());
}

test "Engine closure prefers an inner lexical declared before a later outer shadow" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function outer() {
        \\  let target;
        \\  { let x = 1; target = function() { return x; }; }
        \\  let x = 2;
        \\  return target();
        \\}
        \\print(outer());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\n", stream.buffered());
}

test "Engine direct eval closures bind visible caller metadata" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function localLexical() {
        \\  let x = 1;
        \\  const y = 2;
        \\  var read = eval("(function(){ return x + y; })");
        \\  x = 10;
        \\  return read();
        \\}
        \\function parameter(p) {
        \\  var read = eval("(function(){ return p; })");
        \\  p = 3;
        \\  return read();
        \\}
        \\function callerClosureRef() {
        \\  let x = 5;
        \\  return function() {
        \\    var read = eval("(function(){ return x; })");
        \\    x = 6;
        \\    return read();
        \\  };
        \\}
        \\function callerClosureWrite() {
        \\  let x = 1;
        \\  return function() {
        \\    eval("x = 8");
        \\    return x;
        \\  };
        \\}
        \\function hiddenSibling() {
        \\  var keep;
        \\  { const hidden = 1; keep = function(){ return hidden; }; }
        \\  {
        \\    let visible = 2;
        \\    var read = eval("(function(){ return typeof hidden + ':' + visible; })");
        \\    return read() + ':' + keep();
        \\  }
        \\}
        \\print(localLexical());
        \\print(parameter(1));
        \\print(callerClosureRef()());
        \\print(callerClosureWrite()());
        \\print(hiddenSibling());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("12\n3\n6\n8\nundefined:2:1\n", stream.buffered());
}

test "Engine direct eval only exposes lexicals visible at call site" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function afterBlock() {
        \\  { let hidden = 1; }
        \\  return eval("typeof hidden");
        \\}
        \\function siblingBlock() {
        \\  { let a = 1; }
        \\  { let b = 2; return eval("typeof a + String.fromCharCode(58) + b"); }
        \\}
        \\function currentAndOuterBlock() {
        \\  let outer = 3;
        \\  { let inner = 4; return eval("outer + inner"); }
        \\}
        \\function readAfterBlock() {
        \\  { let hidden = 1; }
        \\  try { return eval("hidden"); } catch (e) { return e.name; }
        \\}
        \\var arrowAfterBlock = () => {
        \\  { let hidden = 1; }
        \\  return eval("typeof hidden");
        \\};
        \\print(afterBlock());
        \\print(siblingBlock());
        \\print(currentAndOuterBlock());
        \\print(readAfterBlock());
        \\print(arrowAfterBlock());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("undefined\nundefined:2\n7\nReferenceError\nundefined\n", stream.buffered());
}

test "Engine eval executes control-flow smoke fixtures" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let sum = 0;
        \\for (let i = 0; i < 5; i++) sum += i;
        \\print(sum);
        \\let i = 0;
        \\while (i < 3) { i++; }
        \\print(i);
        \\function classify(n) {
        \\  if (n < 0) return 'neg';
        \\  if (n === 0) return 'zero';
        \\  return 'pos';
        \\}
        \\print(classify(-1), classify(0), classify(1));
        \\let out = '';
        \\switch (2) {
        \\  case 1: out = 'one'; break;
        \\  case 2: out = 'two'; break;
        \\  default: out = 'other';
        \\}
        \\print(out);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("10\n3\nneg zero pos\ntwo\n", stream.buffered());
}

test "Engine direct eval private names require lexical class scope" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function evil() { return eval("this.#x"); }
        \\class C {
        \\  #x = 7;
        \\  good() { return eval("this.#x"); }
        \\  bad(fn) { return fn.call(this); }
        \\}
        \\var c = new C();
        \\print(c.good());
        \\try {
        \\  print(c.bad(evil));
        \\} catch (e) {
        \\  print(e.name);
        \\}
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("7\nSyntaxError\n", stream.buffered());
}

test "Engine eval boxes primitive with objects and catches nullish with" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var foo = 1;
        \\with (2) { foo = 42; }
        \\print(foo);
        \\with (true) { foo = 43; }
        \\print(foo);
        \\with ("str") { foo = length; }
        \\print(foo);
        \\try { with (null) { foo = 1; } } catch (e) { print(e.name); }
        \\try { with (undefined) { foo = 1; } } catch (e) { print(e.name); }
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("42\n43\n3\nTypeError\nTypeError\n", stream.buffered());
}

test "Engine eval assigns through with object references" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var obj = { test262id: 1 };
        \\with (obj) { test262id = 2; }
        \\print(obj.test262id);
        \\try { print(test262id); } catch (e) { print(e.name); }
        \\var callee = 0, b;
        \\var arg = { callee: "a" };
        \\var result = (function() {
        \\  with (arguments) {
        \\    callee = 1;
        \\    b = true;
        \\  }
        \\  return arguments;
        \\})(arg);
        \\print(callee, arg.callee, result.callee, this.b);
        \\var a = 1;
        \\var outer = { a: 2, inner: { a: 3 } };
        \\with (outer) {
        \\  with (inner) {
        \\    var nested = function() { return a; };
        \\  }
        \\}
        \\print(nested());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("2\nReferenceError\n0 a 1 true\n3\n", stream.buffered());
}

test "Engine dynamic environment nested with resolves outer object" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var nestedWithValue = "global";
        \\var outer = { nestedWithValue: "outer" };
        \\var inner = {};
        \\with (outer) {
        \\  with (inner) {
        \\    print(nestedWithValue);
        \\  }
        \\}
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("outer\n", stream.buffered());
}

test "Engine dynamic environment direct eval inside with resolves active object" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var evalWithValue = "global";
        \\function readEvalWithValue() {
        \\  var evalWithValue = "local";
        \\  var object = { evalWithValue: "with" };
        \\  with (object) {
        \\    return eval("evalWithValue");
        \\  }
        \\}
        \\print(readEvalWithValue());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("with\n", stream.buffered());
}

test "Engine ordered dynamic environment closure tracks nested with objects" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function makeOrderedWithState() {
        \\  var outer = { orderedWithValue: "outer" };
        \\  var inner = { orderedWithValue: "inner" };
        \\  var read;
        \\  with (outer) {
        \\    with (inner) {
        \\      read = function() { return orderedWithValue; };
        \\    }
        \\  }
        \\  return { read: read, inner: inner };
        \\}
        \\var state = makeOrderedWithState();
        \\print(state.read());
        \\state.inner.orderedWithValue = "mutated";
        \\print(state.read());
        \\delete state.inner.orderedWithValue;
        \\print(state.read());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("inner\nmutated\nouter\n", stream.buffered());
}

test "Engine ordered dynamic environment eval closure tracks nested with objects" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var outer = { orderedEvalWithValue: "outer" };
        \\var inner = { orderedEvalWithValue: "inner" };
        \\function makeOrderedEvalWithReader() {
        \\  with (outer) {
        \\    with (inner) {
        \\      return eval("(function() { return orderedEvalWithValue; })");
        \\    }
        \\  }
        \\}
        \\var readOrderedEvalWithValue = makeOrderedEvalWithReader();
        \\print(readOrderedEvalWithValue());
        \\inner.orderedEvalWithValue = "mutated";
        \\print(readOrderedEvalWithValue());
        \\delete inner.orderedEvalWithValue;
        \\print(readOrderedEvalWithValue());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("inner\nmutated\nouter\n", stream.buffered());
}

test "Engine direct eval keeps internal completion slots out of with objects" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var withTarget = { value: 1 };
        \\with (withTarget) { print(eval("value")); }
        \\print(Object.keys(withTarget).join(","), withTarget["<ret>"]);
        \\var proxyTarget = { value: 2 };
        \\var withProxy = new Proxy(proxyTarget, {
        \\  has: function(target, key) {
        \\    if (key === "<ret>") throw new Error("internal binding leaked");
        \\    return Reflect.has(target, key);
        \\  },
        \\  set: function(target, key, value, receiver) {
        \\    if (key === "<ret>") throw new Error("internal binding leaked");
        \\    return Reflect.set(target, key, value, receiver);
        \\  }
        \\});
        \\with (withProxy) { print(eval("value")); }
        \\print(Object.keys(proxyTarget).join(","));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\nvalue undefined\n2\nvalue\n", stream.buffered());
}

test "Engine ordered dynamic environment later eval captures earlier eval var" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function makeEarlierEvalVarReader() {
        \\  eval("var earlierEvalValue = 'earlier';");
        \\  return eval("(function() { return earlierEvalValue; })");
        \\}
        \\var readEarlierEvalValue = makeEarlierEvalVarReader();
        \\print(readEarlierEvalValue());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("earlier\n", stream.buffered());
}

test "Engine ordered dynamic environment eval var shadows captured outer lexical" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function grand() {
        \\  let x = "grand";
        \\  return function parent() {
        \\    var child = function() { return x; };
        \\    eval("var x = 'eval';");
        \\    return child;
        \\  };
        \\}
        \\print(grand()()());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("eval\n", stream.buffered());
}

test "Engine parameter dynamic environment ordinary closure prefers body eval var" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function makeBodyEvalOrdinaryReader(_ = eval("var x = 'arg';")) {
        \\  eval("var x = 'body';");
        \\  var read = function() { return x; };
        \\  return read;
        \\}
        \\var readBodyEvalOrdinary = makeBodyEvalOrdinaryReader();
        \\print(readBodyEvalOrdinary());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("body\n", stream.buffered());
}

test "Engine parameter dynamic environment eval closure prefers body eval var" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function makeBodyEvalDirectReader(_ = eval("var x = 'arg';")) {
        \\  eval("var x = 'body';");
        \\  return eval("(function() { return x; })");
        \\}
        \\var readBodyEvalDirect = makeBodyEvalDirectReader();
        \\print(readBodyEvalDirect());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("body\n", stream.buffered());
}

test "Engine parameter dynamic environment closures retain argument eval var" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function makeArgumentEvalReaders(_ = eval("var x = 'arg';")) {
        \\  var ordinary = function() { return x; };
        \\  var direct = eval("(function() { return x; })");
        \\  return [ordinary, direct];
        \\}
        \\var argumentEvalReaders = makeArgumentEvalReaders();
        \\print(argumentEvalReaders[0](), argumentEvalReaders[1]());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("arg arg\n", stream.buffered());
}

test "Engine parameter dynamic environment delete removes argument eval var" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function deleteArgumentEvalVar(
        \\  _ = eval("var x = 'arg'; print(delete x, typeof x);")
        \\) {
        \\  print(typeof x);
        \\}
        \\deleteArgumentEvalVar();
        \\print(typeof x);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true undefined\nundefined\nundefined\n", stream.buffered());
}

test "Engine dynamic environment eval var object yields to nearer lexical closure" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function makeEscapingReader() {
        \\  eval("var evalShadowValue = 'eval';");
        \\  print(evalShadowValue);
        \\  return (function() {
        \\    let evalShadowValue = "lexical";
        \\    return function() { return evalShadowValue; };
        \\  })();
        \\}
        \\var readEscapingValue = makeEscapingReader();
        \\print(readEscapingValue());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("eval\nlexical\n", stream.buffered());
}

test "Engine nested direct eval forwards named function bindings as ordinary variables" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var sloppyRef = function SloppyName() {
        \\  return function() {
        \\    eval("SloppyName = 1");
        \\    return SloppyName;
        \\  };
        \\};
        \\print(sloppyRef()() === sloppyRef);
        \\var strictRef = function StrictName() {
        \\  "use strict";
        \\  return function() {
        \\    try {
        \\      eval("StrictName = 1");
        \\    } catch (err) {
        \\      print(err.name);
        \\    }
        \\    return StrictName;
        \\  };
        \\};
        \\print(strictRef()() === strictRef);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    // QuickJS normalizes an unscoped named-function row when an ordinary
    // descendant forwards it to direct eval. Both sloppy and inherited-strict
    // eval writes therefore update the forwarded cell instead of preserving
    // the original immutable function-name binding.
    try std.testing.expectEqualStrings("false\nfalse\n", stream.buffered());
}

test "Engine dynamic environment nested no-op eval preserves function binding" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function readRetainedEvalFunction() {
        \\  eval("function retainedEvalFunction() { return 'retained'; } eval('');");
        \\  return retainedEvalFunction();
        \\}
        \\print(readRetainedEvalFunction());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("retained\n", stream.buffered());
}

test "Engine direct eval after with uses global var binding" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var fast = 1;
        \\var object = { fast: 10 };
        \\var seenWith = 0;
        \\with (object) {
        \\  fast = fast + 1;
        \\  seenWith = fast;
        \\}
        \\var seenAfterWith = globalThis.fast;
        \\var evalResult = 0;
        \\eval("fast = fast + 2; var evalMade = 7; evalResult = fast + globalThis.evalMade;");
        \\print(seenWith, seenAfterWith, object.fast, globalThis.fast, globalThis.evalMade, evalResult);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("11 1 11 3 7 10\n", stream.buffered());
}

test "Engine direct eval var preserves readonly global property" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\Object.defineProperty(globalThis, "roEvalVar", { value: 1, writable: false, configurable: false });
        \\eval('var roEvalVar; roEvalVar = 2; print("inside", roEvalVar, globalThis.roEvalVar);');
        \\print("after", roEvalVar, globalThis.roEvalVar);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("inside 1 1\nafter 1 1\n", stream.buffered());
}

test "Engine direct eval updates top-level lexical bindings" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let evalTopLevelLexical;
        \\eval("evalTopLevelLexical = 1; print(evalTopLevelLexical);");
        \\print(evalTopLevelLexical, globalThis.evalTopLevelLexical);
        \\const evalTopLevelConst = 2;
        \\try { eval("evalTopLevelConst = 3;"); } catch (e) { print(e.name); }
        \\print(evalTopLevelConst);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\n1 undefined\nTypeError\n2\n", stream.buffered());
}

test "Engine direct eval var bindings stay in caller function scope" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var x = "outside";
        \\(function() {
        \\  eval('var x = "inside";');
        \\  print("ordinary", x, globalThis.x);
        \\}());
        \\print("ordinaryAfter", x);
        \\
        \\var paramEvalShadow = "outside";
        \\var probe1, probe2, probeBody;
        \\(function(
        \\  _ = (eval('var paramEvalShadow = "inside";'), probe1 = function() { return paramEvalShadow; }),
        \\  _2 = (probe2 = function() { return paramEvalShadow; })
        \\) {
        \\  probeBody = function() { return paramEvalShadow; };
        \\}());
        \\print("param", probe1(), probe2(), probeBody(), globalThis.paramEvalShadow);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("ordinary inside outside\nordinaryAfter outside\nparam inside inside inside outside\n", stream.buffered());
}

test "Engine direct eval catch bindings do not escape their scopes" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(eval("try { throw 1; } catch (caughtSimple) {} typeof caughtSimple"));
        \\print(eval("try { throw [1]; } catch ([caughtPattern]) {} typeof caughtPattern"));
        \\print(eval("try { throw 1; } catch (sameName) { var sameName = 2; } typeof sameName"));
        \\print(eval("try { throw 1; } catch (caughtOther) { var hoistedOther = 2; } hoistedOther"));
        \\print(eval("var readCaught; try { throw 3; } catch (capturedCaught) { readCaught = function() { return capturedCaught; }; } readCaught()"));
        \\print((function() { try { throw 4; } catch (callerCaught) {} return eval("typeof callerCaught"); }()));
        \\print((function() { try { throw 5; } catch (visibleCaught) { return eval("visibleCaught"); } }()));
        \\print((function() { try { throw 1; } catch (sameCatchVar) { eval("var sameCatchVar = 2"); return sameCatchVar; } }()));
        \\print((function() { try { throw 1; } catch (sameCatchFn) { eval("{ function sameCatchFn() {} }"); return typeof sameCatchFn; } }()));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("undefined\nundefined\nundefined\n2\n3\nundefined\n5\n2\nfunction\n", stream.buffered());
}

test "Engine direct eval function targeting a catch binding does not create a fallback var binding" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function scenario() {
        \\  try { throw 1; } catch (caughtFunction) {
        \\    eval("function caughtFunction(){ return 2; }");
        \\    print("inside", caughtFunction());
        \\  }
        \\  try { caughtFunction(); } catch (error) { print("outside", error.name); }
        \\}
        \\scenario();
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("inside 2\noutside ReferenceError\n", stream.buffered());
}

test "Engine direct eval catch var stops at the first same-name catch binding" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var x = "global-x";
        \\var log = "";
        \\function g() {
        \\  try { throw 8; } catch (x) {
        \\    eval("var x = 42;");
        \\    log += x;
        \\  }
        \\  x = "g";
        \\  log += x;
        \\}
        \\g();
        \\print(x, log);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("g 42g\n", stream.buffered());
}

test "Engine direct eval catch var creation is idempotent and checks outer lexicals" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function preserveCatchEvalVar() {
        \\  try { throw 1; } catch (x) { eval("var x = 2"); }
        \\  x = 7;
        \\  try { throw 2; } catch (x) { eval("var x = 3"); }
        \\  return x;
        \\}
        \\function rejectCatchEvalVarPastLexical() {
        \\  let x = 1;
        \\  try { throw 2; } catch (x) {
        \\    try { eval("var x"); } catch (error) { return error.name; }
        \\  }
        \\  return "no error";
        \\}
        \\print(preserveCatchEvalVar(), rejectCatchEvalVarPastLexical());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("7 SyntaxError\n", stream.buffered());
}

test "Engine direct eval var-object force initialization mirrors QuickJS" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function scenario() {
        \\  eval("var dynamicEvalVar = 1");
        \\  print(dynamicEvalVar);
        \\  eval("var dynamicEvalVar");
        \\  print(dynamicEvalVar);
        \\}
        \\scenario();
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\nundefined\n", stream.buffered());
}

test "Engine Annex B var copy does not use global function declaration validation" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\(0, eval)('Object.defineProperty(globalThis, "annexFalseDescriptor", { value: 9, writable: false, enumerable: false, configurable: false })');
        \\try { (0, eval)('if (false) { function annexFalseDescriptor() {} }'); print("false", annexFalseDescriptor); } catch (error) { print("false", error.name); }
        \\(0, eval)('Object.defineProperty(globalThis, "annexTrueDescriptor", { value: 9, writable: false, enumerable: false, configurable: false })');
        \\try { (0, eval)('if (true) { function annexTrueDescriptor() {} }'); print("true", annexTrueDescriptor); } catch (error) { print("true", error.name); }
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false 9\ntrue 9\n", stream.buffered());
}

test "Engine strict eval declarations stay inside the eval environment" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\eval('"use strict"; var strictGlobalVar = 1;');
        \\print(typeof strictGlobalVar);
        \\(0, eval)('"use strict"; var strictIndirectVar = 1;');
        \\print(typeof strictIndirectVar);
        \\eval('"use strict"; function strictGlobalFn() {}');
        \\print(typeof strictGlobalFn);
        \\eval('"use strict"; { function strictBlockFn() {} }');
        \\print(typeof strictBlockFn);
        \\print((function(outer) { eval('"use strict"; var outer = 2;'); return outer; }(1)));
        \\print(eval('"use strict"; var strictResult = 3; strictResult'));
        \\print(typeof strictEvalGhost, eval('"use strict"; typeof strictEvalGhost'));
        \\print(typeof sloppyEvalGhost, eval('typeof sloppyEvalGhost'));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("undefined\nundefined\nundefined\nundefined\n1\n3\nundefined undefined\nundefined undefined\n", stream.buffered());
}

test "Engine indirect eval lexical declarations stay in each eval environment" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print((0, eval)('let isolatedIndirectLet = 1; class IsolatedIndirectClass {}; isolatedIndirectLet + (typeof IsolatedIndirectClass === "function")'));
        \\print(typeof isolatedIndirectLet, typeof IsolatedIndirectClass);
        \\print((0, eval)('"use strict"; let isolatedStrictLet = 2; class IsolatedStrictClass {}; isolatedStrictLet + (typeof IsolatedStrictClass === "function")'));
        \\print(typeof isolatedStrictLet, typeof IsolatedStrictClass);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("2\nundefined undefined\n3\nundefined undefined\n", stream.buffered());
}

test "Engine direct eval ignores popped shadows when capturing outer bindings" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function outer() {
        \\  let x = "outer";
        \\  return function() {
        \\    var values = [];
        \\    { let x = "inner"; values.push(eval("x")); }
        \\    values.push(eval("x"));
        \\    return values.join(" ");
        \\  };
        \\}
        \\print(outer()());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("inner outer\n", stream.buffered());
}

test "Engine direct eval closures preserve dynamic scope instances" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var iterationReaders = [];
        \\for (let iterationValue = 0; iterationValue < 3; iterationValue++) {
        \\  iterationReaders.push(eval("() => iterationValue"));
        \\}
        \\print(iterationReaders.map(function(read) { return read(); }).join(","));
        \\var catchReaders = [];
        \\for (var catchIndex = 0; catchIndex < 3; catchIndex++) {
        \\  try { throw catchIndex; } catch (caughtIteration) {
        \\    catchReaders.push(eval("() => caughtIteration"));
        \\  }
        \\}
        \\print(catchReaders.map(function(read) { return read(); }).join(","));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("0,1,2\n0,1,2\n", stream.buffered());
}

test "Engine direct eval selects the nearest private environment" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\class OuterPrivateEnvironment {
        \\  #value = 1;
        \\  readNested() {
        \\    class InnerPrivateEnvironment {
        \\      #value = 2;
        \\      read() { return eval("this.#value"); }
        \\    }
        \\    return new InnerPrivateEnvironment().read();
        \\  }
        \\}
        \\print(new OuterPrivateEnvironment().readNested());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("2\n", stream.buffered());
}

test "Engine direct eval var hoist in parameter initializer uses arg var object" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var paramEvalVar = "global";
        \\function scenario(
        \\  _ = eval("var paramEvalVar = 'eval';"),
        \\  later = paramEvalVar
        \\) {
        \\  print("later", later);
        \\  print("body", paramEvalVar);
        \\  return function() { return paramEvalVar; };
        \\}
        \\var read = scenario();
        \\print("closure", read());
        \\print("global", globalThis.paramEvalVar);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("later eval\nbody eval\nclosure eval\nglobal global\n", stream.buffered());
}

test "Engine direct eval function hoist in parameter initializer uses arg var object" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var paramEvalFn = "global";
        \\function scenario(
        \\  _ = eval("function paramEvalFn() { return 'eval'; }"),
        \\  later = paramEvalFn()
        \\) {
        \\  print("later", later);
        \\  print("body", paramEvalFn());
        \\  return function() { return paramEvalFn(); };
        \\}
        \\var read = scenario();
        \\print("closure", read());
        \\print("global", globalThis.paramEvalFn);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("later eval\nbody eval\nclosure eval\nglobal global\n", stream.buffered());
}

test "Engine parameter eval seed orders lexical parameter before arg var object" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var orderedParameter = "global";
        \\var bodyRan = false;
        \\function scenario(
        \\  _ = eval("var orderedParameter;"),
        \\  orderedParameter
        \\) {
        \\  bodyRan = true;
        \\}
        \\try { scenario(); print("no error"); } catch (error) { print(error.name); }
        \\print(bodyRan, globalThis.orderedParameter);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("SyntaxError\nfalse global\n", stream.buffered());
}

test "Engine sloppy direct eval var closures survive and reuse redeclare binding" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var readEvalVar, writeEvalVar;
        \\function scenario() {
        \\  eval('var hoistedEvalVar = 1; readEvalVar = function() { return hoistedEvalVar; }; writeEvalVar = function(value) { hoistedEvalVar = value; return hoistedEvalVar; };');
        \\  print("first", readEvalVar(), writeEvalVar(2), readEvalVar());
        \\  eval('var hoistedEvalVar; hoistedEvalVar = 5;');
        \\  print("second", hoistedEvalVar, readEvalVar());
        \\}
        \\scenario();
        \\print("after", readEvalVar(), writeEvalVar(9), readEvalVar());
        \\try { print(hoistedEvalVar); } catch (e) { print(e.name); }
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("first 1 2 2\nsecond 5 5\nafter 5 9 9\nReferenceError\n", stream.buffered());
}

test "Engine nested direct eval reuses caller eval var object" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function f() {
        \\  eval("var x = 1; eval('var y = 2; print(\"inner\", y); y = 3'); print(\"outer\", y)");
        \\  print("body", typeof x, y);
        \\}
        \\f();
        \\function g() {
        \\  var y = 0;
        \\  eval("eval('var y = 2; print(\"existing inner\", y)'); print(\"existing outer\", y)");
        \\  print("existing body", y);
        \\}
        \\g();
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "inner 2\nouter 3\nbody number 3\n" ++
            "existing inner 2\nexisting outer 2\nexisting body 2\n",
        stream.buffered(),
    );
}

test "Engine nested direct eval inherits private name environment" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\class NestedPrivateEval {
        \\  #value = 42;
        \\  read() { return eval("eval('this.#value')"); }
        \\}
        \\print(new NestedPrivateEval().read());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("42\n", stream.buffered());
}

test "Engine parameter initializer closures capture the parameter environment" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function split(a, b = () => a) { var a = 2; return [b(), a].join(","); }
        \\function update(a, b = (a = 7, () => a)) { return b(); }
        \\function forward(read = () => value, value = 10) { return read(); }
        \\print(split(1));
        \\print(update(1));
        \\print(forward());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1,2\n7\n10\n", stream.buffered());
}

test "Engine global eval nested Annex B declarations stay function local" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\eval("function outerAnnexB(){ { function leakedAnnexB(){} } }");
        \\outerAnnexB();
        \\print(typeof globalThis.leakedAnnexB);
        \\var preservedAnnexB = 1;
        \\eval("function overwriteAnnexB(){ { function preservedAnnexB(){} } }");
        \\overwriteAnnexB();
        \\print(typeof preservedAnnexB);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("undefined\nnumber\n", stream.buffered());
}

test "Engine with object arguments property shadows implicit arguments" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [16]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function withArguments() {
        \\  with ({ arguments: "object" }) return arguments;
        \\}
        \\print(withArguments(5));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("object\n", stream.buffered());
}

test "Engine direct eval in parameter initializer observes parameter TDZ" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function later(a = eval("b"), b = 1) {}
        \\function self(a = eval("a")) {}
        \\try { later(); } catch (error) { print(error.name); }
        \\try { self(); } catch (error) { print(error.name); }
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("ReferenceError\nReferenceError\n", stream.buffered());
}

test "Engine parameter initializer TDZ uses the real parameter bindings" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function later(a = b, b = 1) {}
        \\function self(a = a) {}
        \\try { later(); } catch (error) { print(error.name); }
        \\try { self(); } catch (error) { print(error.name); }
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("ReferenceError\nReferenceError\n", stream.buffered());
}

test "Engine async parameter grammar parses await only as an expression" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\async function propertyName(a = ({ await: 1 }).await) { return a; }
        \\async function nestedFunction(a = async () => await 1) { return a; }
        \\assert.sameValue(typeof propertyName, "function");
        \\assert.sameValue(typeof nestedFunction, "function");
        \\const AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
        \\const dynamicProperty = AsyncFunction("a = ({ await: 1 }).await", "return a;");
        \\const dynamicNested = AsyncFunction("a = async () => await 1", "return a;");
        \\assert.sameValue(typeof dynamicProperty, "function");
        \\assert.sameValue(typeof dynamicNested, "function");
        \\let declarationSyntax = false;
        \\try { eval("async function invalid(a = await 1) {}"); }
        \\catch (error) { declarationSyntax = error instanceof SyntaxError; }
        \\assert.sameValue(declarationSyntax, true);
        \\let constructorSyntax = false;
        \\try { AsyncFunction("a = await 1", "return a;"); }
        \\catch (error) { constructorSyntax = error instanceof SyntaxError; }
        \\assert.sameValue(constructorSyntax, true);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Engine Dynamic Function preserves typed array subclass source" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\let dynamicBodyEffects = 0;
        \\const X = Function("dynamicBodyEffects++; return class X extends Uint8Array {}")();
        \\const value = new X(2);
        \\assert.sameValue(dynamicBodyEffects, 1);
        \\assert.sameValue(X === Uint8Array, false);
        \\assert.sameValue(X.name, "X");
        \\assert.sameValue(value instanceof X, true);
        \\assert.sameValue(value instanceof Uint8Array, true);
        \\assert.sameValue(value.length, 2);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Engine direct eval callback passed to assert.throws keeps eval var scope" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function scenario() {
        \\  eval("var evalAssertVar = 42; var callback = function() { if (eval('evalAssertVar') !== 42) throw new RangeError('bad value'); throw new TypeError('expected'); };");
        \\  assert.throws(TypeError, callback);
        \\}
        \\scenario();
        \\assert.sameValue(typeof evalAssertVar, "undefined");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Engine generator created by direct eval keeps eval var scope across resume" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function scenario() {
        \\  eval("var evalGenVar = 3; var make = function*() { yield evalGenVar; evalGenVar += 4; yield eval('evalGenVar'); return evalGenVar; };");
        \\  var it = make();
        \\  var first = it.next();
        \\  assert.sameValue(first.value, 3);
        \\  assert.sameValue(first.done, false);
        \\  var second = it.next();
        \\  assert.sameValue(second.value, 7);
        \\  assert.sameValue(second.done, false);
        \\  var third = it.next();
        \\  assert.sameValue(third.value, 7);
        \\  assert.sameValue(third.done, true);
        \\  eval("evalGenVar = 11;");
        \\  var again = make();
        \\  assert.sameValue(again.next().value, 11);
        \\}
        \\scenario();
        \\assert.sameValue(typeof evalGenVar, "undefined");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Engine sloppy direct eval deleted var can be redeclared" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function deleteScenario() {
        \\  eval('var deletedEvalVar = 1;');
        \\  print("made", deletedEvalVar);
        \\  print("delete", delete deletedEvalVar);
        \\  try { print("read", deletedEvalVar); } catch (e) { print("read", e.name); }
        \\  print("typeof", typeof deletedEvalVar);
        \\  print("redeclare", eval('var deletedEvalVar = 2; deletedEvalVar'));
        \\  print("after", deletedEvalVar);
        \\}
        \\deleteScenario();
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("made 1\ndelete true\nread ReferenceError\ntypeof undefined\nredeclare 2\nafter 2\n", stream.buffered());
}

test "Engine direct eval declaration forms share the variable object" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\globalThis.evalDestructFallback = "global";
        \\function destructScenario() {
        \\  eval("var { evalDestructFallback } = { evalDestructFallback: 1 }; globalThis.readDestructFallback = () => evalDestructFallback");
        \\  print(readDestructFallback());
        \\  eval("delete evalDestructFallback");
        \\  print(readDestructFallback());
        \\}
        \\destructScenario();
        \\globalThis.evalForOfFallback = "global";
        \\function forOfScenario() {
        \\  eval("for (var evalForOfFallback of [1]) {} globalThis.readForOfFallback = () => evalForOfFallback");
        \\  print(readForOfFallback());
        \\  eval("delete evalForOfFallback");
        \\  print(readForOfFallback());
        \\}
        \\forOfScenario();
        \\globalThis.evalAnnexFallback = "global";
        \\function annexScenario() {
        \\  eval("{ function evalAnnexFallback() { return 1; } } globalThis.readAnnexFallback = () => evalAnnexFallback");
        \\  print(typeof readAnnexFallback());
        \\  eval("delete evalAnnexFallback");
        \\  print(readAnnexFallback());
        \\}
        \\annexScenario();
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\nglobal\n1\nglobal\nfunction\nglobal\n", stream.buffered());
}

test "Engine parameter and body eval variable objects stay distinct" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function splitEvalEnvironments(
        \\  _ = eval("var splitEvalValue = 1; function readParameterEvalValue() { return splitEvalValue; }"),
        \\  readParameterClosure = () => splitEvalValue
        \\) {
        \\  print("parameter", splitEvalValue, readParameterEvalValue(), readParameterClosure());
        \\  eval("var splitEvalValue = 2");
        \\  print("body", splitEvalValue, readParameterEvalValue(), readParameterClosure());
        \\}
        \\splitEvalEnvironments();
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("parameter 1 1 1\nbody 2 1 1\n", stream.buffered());
}

test "Engine sloppy direct eval function declarations conflict with body lexicals" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function check(source) {
        \\  try {
        \\    eval(source);
        \\    print("no error");
        \\  } catch (e) {
        \\    print(e.name);
        \\  }
        \\}
        \\check("function directEvalConflict(){}; let directEvalConflict");
        \\check("function directEvalConflict(){}; class directEvalConflict{}");
        \\check("function directEvalConflict(){}; let { directEvalConflict } = { directEvalConflict: 1 }");
        \\check("var directEvalConflict; class directEvalConflict{}");
        \\check("var directEvalConflict; let { directEvalConflict } = { directEvalConflict: 1 }");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("SyntaxError\nSyntaxError\nSyntaxError\nSyntaxError\nSyntaxError\n", stream.buffered());
}

test "Engine Annex B eval function hoist respects enclosing lexical bindings" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\eval("{ let blockedAnnexB = 1; { function blockedAnnexB() {} } }");
        \\print(typeof blockedAnnexB);
        \\eval("{ function allowedAnnexB() { return 1; } }");
        \\print(typeof allowedAnnexB, allowedAnnexB());
        \\eval("if (true) { function arguments() { return 3; } }");
        \\print(typeof arguments, arguments());
        \\delete globalThis.arguments;
        \\try {
        \\  (function(_ = eval("if (false) { function arguments() {} }")) {})();
        \\  print("no error");
        \\} catch (error) {
        \\  print(error.name);
        \\}
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("undefined\nfunction 1\nfunction 3\nSyntaxError\n", stream.buffered());
}

test "Engine sloppy direct eval function hoist uses var object binding" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var directEvalFn = "global";
        \\function scenario() {
        \\  eval("function directEvalFn(){ return 'first'; } function directEvalFn(){ return 'second'; }");
        \\  print(directEvalFn());
        \\  print(globalThis.directEvalFn);
        \\}
        \\scenario();
        \\print(directEvalFn);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("second\nglobal\nglobal\n", stream.buffered());
}

test "Engine direct eval var refs do not shadow global callees" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function testcase() {
        \\  var x = "local";
        \\  eval("var y = 'evalvar'; print('after var', y);");
        \\  print("done");
        \\}
        \\testcase();
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("after var evalvar\ndone\n", stream.buffered());
}

test "Engine function global data IC preserves binding guards" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\globalThis.__zjsGlobalDataIcRead = 1;
        \\function __zjsGlobalDataIcReadFn() { return __zjsGlobalDataIcRead; }
        \\assert.sameValue(__zjsGlobalDataIcReadFn(), 1);
        \\assert.sameValue(__zjsGlobalDataIcReadFn(), 1);
        \\globalThis.__zjsGlobalDataIcRead = 7;
        \\assert.sameValue(__zjsGlobalDataIcReadFn(), 7);
        \\
        \\globalThis.__zjsGlobalDataIcAccessor = 1;
        \\function __zjsGlobalDataIcAccessorFn() { return __zjsGlobalDataIcAccessor; }
        \\assert.sameValue(__zjsGlobalDataIcAccessorFn(), 1);
        \\assert.sameValue(__zjsGlobalDataIcAccessorFn(), 1);
        \\var __zjsGlobalDataIcAccessorCalls = 0;
        \\Object.defineProperty(globalThis, "__zjsGlobalDataIcAccessor", {
        \\    get: function() { __zjsGlobalDataIcAccessorCalls++; return 42; },
        \\    configurable: true
        \\});
        \\assert.sameValue(__zjsGlobalDataIcAccessorFn(), 42);
        \\assert.sameValue(__zjsGlobalDataIcAccessorCalls, 1);
        \\delete globalThis.__zjsGlobalDataIcAccessor;
        \\
        \\let __zjsGlobalDataIcLexical = 3;
        \\globalThis.__zjsGlobalDataIcLexical = 1;
        \\function __zjsGlobalDataIcLexicalFn() { return __zjsGlobalDataIcLexical; }
        \\assert.sameValue(__zjsGlobalDataIcLexicalFn(), 3);
        \\assert.sameValue(globalThis.__zjsGlobalDataIcLexical, 1);
        \\delete globalThis.__zjsGlobalDataIcLexical;
        \\
        \\globalThis.__zjsGlobalDataIcSelf = 5;
        \\var __zjsGlobalDataIcSelfRef = function __zjsGlobalDataIcSelf() {
        \\    return __zjsGlobalDataIcSelf === __zjsGlobalDataIcSelfRef;
        \\};
        \\assert.sameValue(__zjsGlobalDataIcSelfRef(), true);
        \\assert.sameValue(globalThis.__zjsGlobalDataIcSelf, 5);
        \\delete globalThis.__zjsGlobalDataIcSelf;
        \\
        \\globalThis.__zjsGlobalDataIcEval = 1;
        \\function __zjsGlobalDataIcEvalFn() {
        \\    assert.sameValue(__zjsGlobalDataIcEval, 1);
        \\    assert.sameValue(__zjsGlobalDataIcEval, 1);
        \\    eval('var __zjsGlobalDataIcEval = 9;');
        \\    __zjsGlobalDataIcEval = 10;
        \\    return __zjsGlobalDataIcEval;
        \\}
        \\assert.sameValue(__zjsGlobalDataIcEvalFn(), 10);
        \\assert.sameValue(globalThis.__zjsGlobalDataIcEval, 1);
        \\delete globalThis.__zjsGlobalDataIcEval;
        \\
        \\globalThis.__zjsGlobalDataIcRedefine = 10;
        \\function __zjsGlobalDataIcRedefineFn() { return __zjsGlobalDataIcRedefine; }
        \\assert.sameValue(__zjsGlobalDataIcRedefineFn(), 10);
        \\assert.sameValue(__zjsGlobalDataIcRedefineFn(), 10);
        \\assert.sameValue(delete globalThis.__zjsGlobalDataIcRedefine, true);
        \\globalThis.__zjsGlobalDataIcRedefine = 22;
        \\assert.sameValue(__zjsGlobalDataIcRedefineFn(), 22);
        \\delete globalThis.__zjsGlobalDataIcRedefine;
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Engine top-level var probes preserve QuickJS global object semantics" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var reflectedVar = 1;
        \\print("desc", Object.getOwnPropertyDescriptor(globalThis, "reflectedVar").writable, Object.getOwnPropertyDescriptor(globalThis, "reflectedVar").configurable, globalThis.reflectedVar);
        \\reflectedVar = 2;
        \\print("write", globalThis.reflectedVar);
        \\globalThis.reflectedVar = 5;
        \\print("globalWrite", reflectedVar);
        \\Object.defineProperty(globalThis, "reflectedVar", { value: 9, writable: true });
        \\print("redefineData", reflectedVar);
        \\print("delete", delete reflectedVar, globalThis.reflectedVar);
        \\let reflectedVarLex = 4;
        \\print("lexical", reflectedVarLex, globalThis.reflectedVarLex);
        \\var withProbe = 1;
        \\var withObj = { withProbe: 10 };
        \\with (withObj) { withProbe = withProbe + 1; }
        \\print("with", withObj.withProbe, globalThis.withProbe);
        \\eval('var evalProbe = 7; evalProbe = evalProbe + 1; print("evalInside", evalProbe, globalThis.evalProbe);');
        \\print("evalAfter", evalProbe, globalThis.evalProbe, delete evalProbe, typeof evalProbe);
        \\Object.defineProperty(globalThis, "roStrictProbe", { value: 1, writable: false, configurable: false });
        \\try { (function(){ "use strict"; roStrictProbe = 2; })(); print("strictAssign", "noThrow"); } catch(e) { print("strictAssign", e.name, roStrictProbe); }
        \\Object.defineProperty(globalThis, "accessorEvalProbe", { get: function(){ return 1; }, configurable: true });
        \\eval('var accessorEvalProbe; accessorEvalProbe = 5; print("accessorEvalInside", accessorEvalProbe, globalThis.accessorEvalProbe);');
        \\print("accessorEvalAfter", accessorEvalProbe, globalThis.accessorEvalProbe);
        \\Object.setPrototypeOf(globalThis, { inheritedVarProbe: 9 });
        \\var inheritedVarProbe;
        \\print("inherited", Object.prototype.hasOwnProperty.call(globalThis, "inheritedVarProbe"), inheritedVarProbe, globalThis.inheritedVarProbe);
        \\Object.setPrototypeOf(globalThis, Object.prototype);
        \\try { Object.preventExtensions(globalThis); eval("var blockedVarProbe;"); print("nonExtensible", "noThrow"); } catch(e) { print("nonExtensible", e.name); }
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "desc true false 1\nwrite 2\nglobalWrite 5\nredefineData 9\ndelete false 9\nlexical 4 undefined\nwith 11 1\nevalInside 8 8\nevalAfter 8 8 true undefined\nstrictAssign TypeError 1\naccessorEvalInside 1 1\naccessorEvalAfter 1 1\ninherited true undefined undefined\nnonExtensible TypeError\n",
        stream.buffered(),
    );
}

test "Engine global function declarations publish through construction-time VarRef cells" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const indirect_result = try js.eval(
        \\(0, eval)('Object.defineProperty(globalThis, "__qjsFunctionData", { value: 1, writable: false, enumerable: false, configurable: true })');
        \\(0, eval)('function __qjsFunctionData(){ return 11; }');
        \\var dataDesc = Object.getOwnPropertyDescriptor(globalThis, "__qjsFunctionData");
        \\assert.sameValue(__qjsFunctionData(), 11);
        \\assert.sameValue(dataDesc.writable, true);
        \\assert.sameValue(dataDesc.enumerable, true);
        \\assert.sameValue(dataDesc.configurable, true);
        \\(0, eval)('Object.defineProperty(globalThis, "__qjsFunctionAccessor", { get: function(){ return 1; }, configurable: true })');
        \\(0, eval)('function __qjsFunctionAccessor(){ return 12; }');
        \\var accessorDesc = Object.getOwnPropertyDescriptor(globalThis, "__qjsFunctionAccessor");
        \\assert.sameValue(__qjsFunctionAccessor(), 12);
        \\assert.sameValue(accessorDesc.writable, true);
        \\assert.sameValue(accessorDesc.enumerable, true);
        \\assert.sameValue(accessorDesc.configurable, true);
        \\(0, eval)('Object.defineProperty(globalThis, "__qjsFunctionFixed", { value: 1, writable: true, enumerable: true, configurable: false })');
        \\(0, eval)('function __qjsFunctionFixed(){ return 13; }');
        \\var fixedDesc = Object.getOwnPropertyDescriptor(globalThis, "__qjsFunctionFixed");
        \\assert.sameValue(__qjsFunctionFixed(), 13);
        \\assert.sameValue(fixedDesc.writable, true);
        \\assert.sameValue(fixedDesc.enumerable, true);
        \\assert.sameValue(fixedDesc.configurable, false);
    );
    defer indirect_result.free(js.runtime);

    const setup_result = try js.eval(
        \\Object.defineProperty(globalThis, "__qjsScriptFunction", { value: 1, writable: false, enumerable: false, configurable: true });
    );
    defer setup_result.free(js.runtime);
    const script_result = try js.eval(
        \\function __qjsScriptFunction(){ return 14; }
        \\var scriptDesc = Object.getOwnPropertyDescriptor(globalThis, "__qjsScriptFunction");
        \\assert.sameValue(__qjsScriptFunction(), 14);
        \\assert.sameValue(scriptDesc.writable, true);
        \\assert.sameValue(scriptDesc.enumerable, true);
        \\assert.sameValue(scriptDesc.configurable, false);
    );
    defer script_result.free(js.runtime);
}

test "Engine top-level var probes preserve cross-realm global identity" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var otherRealm = $262.createRealm();
        \\    var other = otherRealm.global;
        \\    other.eval("var realmVarProbe = 1; realmVarProbe = 2;");
        \\    var desc = other.Object.getOwnPropertyDescriptor(other, "realmVarProbe");
        \\    assert.sameValue(desc.value, 2);
        \\    assert.sameValue(desc.writable, true);
        \\    assert.sameValue(desc.enumerable, true);
        \\    assert.sameValue(desc.configurable, true);
        \\    assert.sameValue(delete other.realmVarProbe, true);
        \\    assert.sameValue(other.realmVarProbe, undefined);
        \\    assert.sameValue(globalThis.realmVarProbe, undefined);
        \\
        \\    other.realmVarProbe = 3;
        \\    assert.sameValue(other.eval("realmVarProbe"), 3);
        \\    assert.sameValue(otherRealm.evalScript("var evalScriptVarProbe = 4; globalThis.evalScriptVarProbe"), 4);
        \\    assert.sameValue(other.Object.getOwnPropertyDescriptor(other, "evalScriptVarProbe").configurable, false);
        \\    assert.sameValue(globalThis.evalScriptVarProbe, undefined);
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Engine createRealm owns independent intrinsics with realm-local instanceof" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var realm = $262.createRealm();
        \\var other = realm.global;
        \\assert.sameValue(other.Array === Array, false);
        \\assert.sameValue([] instanceof Array, true);
        \\assert.sameValue(other.eval("[] instanceof Array"), true);
        \\assert.sameValue(new other.Array() instanceof other.Array, true);
        \\assert.sameValue(new other.Array() instanceof Array, false);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "cross-realm construction uses class prototype state without observable realm keys" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var R = $262.createRealm().global;
        \\    function realmKeys(value) {
        \\        return Object.getOwnPropertyNames(value).filter(function (name) {
        \\            return name.indexOf("__realm_") === 0;
        \\        });
        \\    }
        \\    var f = R.Function("return Object");
        \\    assert.sameValue(f(), R.Object);
        \\    assert.sameValue(Object.getPrototypeOf(f), R.Function.prototype);
        \\    assert.sameValue(realmKeys(R.Function).length, 0);
        \\    assert.sameValue(realmKeys(f).length, 0);
        \\    assert.sameValue(Object.keys(R.Function).filter(function (name) {
        \\        return name.indexOf("__realm_") === 0;
        \\    }).length, 0);
        \\    assert.sameValue(Object.keys(f).filter(function (name) {
        \\        return name.indexOf("__realm_") === 0;
        \\    }).length, 0);
        \\    var fakePrototype = {};
        \\    Object.defineProperty(R.Function, "__realm_Object_proto", {
        \\        value: fakePrototype,
        \\        writable: true,
        \\        enumerable: true,
        \\        configurable: true,
        \\    });
        \\    var copied = R.Function("return 1");
        \\    assert.sameValue(Object.prototype.hasOwnProperty.call(copied, "__realm_Object_proto"), false);
        \\    var gets = 0;
        \\    var newTarget = new Proxy(copied, {
        \\        get: function (target, key) {
        \\            gets++;
        \\            if (key === "prototype") return 0;
        \\            return target[key];
        \\        },
        \\    });
        \\    var value = Reflect.construct(Object, [], newTarget);
        \\    assert.sameValue(gets, 1);
        \\    assert.sameValue(Object.getPrototypeOf(value), R.Object.prototype);
        \\    assert.notSameValue(Object.getPrototypeOf(value), fakePrototype);
        \\    assert.sameValue(R.Function.__realm_Object_proto, fakePrototype);
        \\})();
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Object RegExp and TypedArray use their C function Realm state" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var R = $262.createRealm().global;
        \\    assert.sameValue(Object.getPrototypeOf(R.Object("x")), R.String.prototype);
        \\    assert.sameValue(Object.getPrototypeOf(R.Object(1)), R.Number.prototype);
        \\    assert.sameValue(Object.getPrototypeOf(R.Object(true)), R.Boolean.prototype);
        \\    assert.sameValue(Object.getPrototypeOf(R.Object(1n)), R.BigInt.prototype);
        \\    var remoteSymbol = R.Symbol("remote");
        \\    assert.sameValue(Object.getPrototypeOf(R.Object(remoteSymbol)), R.Symbol.prototype);
        \\
        \\    var originalTypeErrorPrototype = R.TypeError.prototype;
        \\    var sourceGetter = Object.getOwnPropertyDescriptor(R.RegExp.prototype, "source").get;
        \\    R.TypeError = function ReplacementTypeError() {};
        \\    var regexpError;
        \\    try { sourceGetter.call({}); } catch (error) { regexpError = error; }
        \\    assert.sameValue(Object.getPrototypeOf(regexpError), originalTypeErrorPrototype);
        \\    assert.notSameValue(Object.getPrototypeOf(regexpError), TypeError.prototype);
        \\
        \\    function NewTarget() {}
        \\    NewTarget.prototype = { marker: "result" };
        \\    var typed = Reflect.construct(R.Uint8Array, [4], NewTarget);
        \\    var bufferGetter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(R.Uint8Array.prototype), "buffer").get;
        \\    var backing = bufferGetter.call(typed);
        \\    assert.sameValue(Object.getPrototypeOf(typed), NewTarget.prototype);
        \\    assert.sameValue(Object.getPrototypeOf(backing), R.ArrayBuffer.prototype);
        \\    assert.notSameValue(Object.getPrototypeOf(backing), ArrayBuffer.prototype);
        \\})();
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine cross-realm eval keeps global lexical declarations per realm" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\let crossRealmLexicalProbe = 1;
        \\var other = $262.createRealm().global;
        \\other.eval("var crossRealmLexicalProbe = 2;");
        \\assert.sameValue(crossRealmLexicalProbe, 1);
        \\assert.sameValue(other.crossRealmLexicalProbe, 2);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "native builtin records use callee realm for errors and created objects" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var other = $262.createRealm().global;
        \\    var obj = {};
        \\    var wrapped = other.Object.create(obj);
        \\    assert.throws(TypeError, function () {
        \\        Object.setPrototypeOf(obj, wrapped);
        \\    });
        \\    assert.throws(other.TypeError, function () {
        \\        other.Object.setPrototypeOf(obj, wrapped);
        \\    });
        \\    var keys = other.Object.keys({ a: 1 });
        \\    assert.sameValue(Object.getPrototypeOf(keys), other.Array.prototype);
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "constructor static prototype and accessor handlers keep their callee realm" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var other = $262.createRealm().global;
        \\    try {
        \\        new other.Array(1.5);
        \\        throw new Test262Error("expected foreign Array constructor to throw");
        \\    } catch (error) {
        \\        assert.sameValue(Object.getPrototypeOf(error), other.RangeError.prototype);
        \\        assert.sameValue(error instanceof RangeError, false);
        \\    }
        \\    var parse = other.JSON.parse;
        \\    try {
        \\        parse("{");
        \\        throw new Test262Error("expected foreign JSON.parse to throw");
        \\    } catch (error) {
        \\        assert.sameValue(Object.getPrototypeOf(error), other.SyntaxError.prototype);
        \\        assert.sameValue(error instanceof SyntaxError, false);
        \\    }
        \\    var promise = other.Promise.resolve(1);
        \\    assert.sameValue(Object.getPrototypeOf(promise), other.Promise.prototype);
        \\    var capability = other.Promise.withResolvers();
        \\    assert.sameValue(Object.getPrototypeOf(capability.resolve), other.Function.prototype);
        \\    assert.sameValue(Object.getPrototypeOf(capability.reject), other.Function.prototype);
        \\    try {
        \\        other.Reflect.get(null, "x");
        \\        throw new Test262Error("expected foreign Reflect.get to throw");
        \\    } catch (error) {
        \\        assert.sameValue(Object.getPrototypeOf(error), other.TypeError.prototype);
        \\        assert.sameValue(error instanceof TypeError, false);
        \\    }
        \\    var toFixed = other.Number.prototype.toFixed;
        \\    try {
        \\        toFixed.call(1, -1);
        \\        throw new Test262Error("expected foreign Number.prototype.toFixed to throw");
        \\    } catch (error) {
        \\        assert.sameValue(Object.getPrototypeOf(error), other.RangeError.prototype);
        \\        assert.sameValue(error instanceof RangeError, false);
        \\    }
        \\    var toUpperCase = other.String.prototype.toUpperCase;
        \\    try {
        \\        toUpperCase.call(null);
        \\        throw new Test262Error("expected foreign String.prototype.toUpperCase to throw");
        \\    } catch (error) {
        \\        assert.sameValue(Object.getPrototypeOf(error), other.TypeError.prototype);
        \\        assert.sameValue(error instanceof TypeError, false);
        \\    }
        \\    var sourceGetter = Object.getOwnPropertyDescriptor(other.RegExp.prototype, "source").get;
        \\    try {
        \\        sourceGetter.call({});
        \\        throw new Test262Error("expected foreign RegExp source getter to throw");
        \\    } catch (error) {
        \\        assert.sameValue(Object.getPrototypeOf(error), other.TypeError.prototype);
        \\        assert.sameValue(error instanceof TypeError, false);
        \\    }
        \\    var iterator = other.eval("[1].values()");
        \\    var iteratorPrototype = other.eval("Object.getPrototypeOf([].values())");
        \\    assert.sameValue(Object.getPrototypeOf(iterator), iteratorPrototype);
        \\    assert.sameValue(Object.getPrototypeOf(iterator.next), other.Function.prototype);
        \\    assert.sameValue(Object.prototype.hasOwnProperty.call(iterator, "next"), false);
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "bound and proxy wrappers defer realm switching to the final target" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var other = $262.createRealm().global;
        \\    other.eval("globalThis.realmFunction = function () { return Array; }");
        \\    var bound = other.realmFunction.bind(null);
        \\    var proxy = new Proxy(other.realmFunction, {});
        \\    assert.sameValue(bound(), other.Array);
        \\    assert.sameValue(proxy(), other.Array);
        \\    var trapped = new Proxy(other.realmFunction, {
        \\        apply: function () { return Array; }
        \\    });
        \\    var trappedResult = trapped();
        \\    assert.sameValue(trappedResult, Array);
        \\    assert.notSameValue(trappedResult, other.Array);
        \\    var revoked = Proxy.revocable(other.realmFunction, {});
        \\    revoked.revoke();
        \\    try {
        \\        revoked.proxy();
        \\        throw new Error("expected revoked proxy call to throw");
        \\    } catch (error) {
        \\        assert.sameValue(Object.getPrototypeOf(error), TypeError.prototype);
        \\        assert.sameValue(error instanceof other.TypeError, false);
        \\    }
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Array species compares exact realm intrinsics without skipping wrapper gets" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var other = $262.createRealm().global;
        \\    other.eval("globalThis.NamedArray = function Array(length) { this.length = length; };");
        \\    function Species(length) { this.length = length; }
        \\    function identity(value) { return value; }
        \\
        \\    var namedGets = 0;
        \\    Object.defineProperty(other.NamedArray, Symbol.species, {
        \\        configurable: true,
        \\        get: function () { namedGets++; return Species; }
        \\    });
        \\    var named = [1, 2];
        \\    named.constructor = other.NamedArray;
        \\    var namedResult = named.map(identity);
        \\    assert.sameValue(namedGets, 1);
        \\    assert.sameValue(Object.getPrototypeOf(namedResult), Species.prototype);
        \\    assert.sameValue(namedResult.length, 2);
        \\
        \\    var foreignIntrinsicGets = 0;
        \\    Object.defineProperty(other.Array, Symbol.species, {
        \\        configurable: true,
        \\        get: function () { foreignIntrinsicGets++; return Species; }
        \\    });
        \\    var foreignIntrinsic = [3];
        \\    foreignIntrinsic.constructor = other.Array;
        \\    var foreignIntrinsicResult = foreignIntrinsic.map(identity);
        \\    assert.sameValue(foreignIntrinsicGets, 0);
        \\    assert.sameValue(Object.getPrototypeOf(foreignIntrinsicResult), Array.prototype);
        \\
        \\    var proxyGets = [];
        \\    var foreignArrayProxy = new Proxy(other.Array, {
        \\        get: function (target, key, receiver) {
        \\            proxyGets.push(key === Symbol.species ? "species" : String(key));
        \\            if (key === Symbol.species) return Species;
        \\            return Reflect.get(target, key, receiver);
        \\        }
        \\    });
        \\    var proxied = [4];
        \\    proxied.constructor = foreignArrayProxy;
        \\    var proxiedResult = proxied.map(identity);
        \\    assert.sameValue(proxyGets.join(","), "species");
        \\    assert.sameValue(Object.getPrototypeOf(proxiedResult), Species.prototype);
        \\
        \\    var boundGets = 0;
        \\    var foreignArrayBound = other.Array.bind(null);
        \\    Object.defineProperty(foreignArrayBound, Symbol.species, {
        \\        configurable: true,
        \\        get: function () { boundGets++; return Species; }
        \\    });
        \\    var bounded = [5];
        \\    bounded.constructor = foreignArrayBound;
        \\    var boundedResult = bounded.map(identity);
        \\    assert.sameValue(boundGets, 1);
        \\    assert.sameValue(Object.getPrototypeOf(boundedResult), Species.prototype);
        \\
        \\    var revoked = Proxy.revocable(other.Array, {});
        \\    var revokedInput = [6];
        \\    revokedInput.constructor = revoked.proxy;
        \\    revoked.revoke();
        \\    assert.throws(TypeError, function () { revokedInput.map(identity); });
        \\
        \\    var activeGets = 0;
        \\    var activeHolder = {};
        \\    Object.defineProperty(activeHolder, Symbol.species, {
        \\        get: function () { activeGets++; return Array; }
        \\    });
        \\    var active = [7];
        \\    active.constructor = activeHolder;
        \\    var activeResult = active.map(identity);
        \\    assert.sameValue(activeGets, 1);
        \\    assert.sameValue(Object.getPrototypeOf(activeResult), Array.prototype);
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Array species does not confuse a foreign native named Array with the intrinsic" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const setup = try js.eval(
        \\globalThis.__arraySpeciesRealmHandle = $262.createRealm();
        \\globalThis.__arraySpeciesForeignGlobal = __arraySpeciesRealmHandle.global;
        \\globalThis.__arraySpeciesResultCtor = function Species(length) { this.length = length; };
    );
    setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const foreign_global_atom = try js.runtime.internAtom("__arraySpeciesForeignGlobal");
    defer js.runtime.atoms.free(foreign_global_atom);
    const foreign_global_value = try global.getProperty(foreign_global_atom);
    defer foreign_global_value.free(js.runtime);
    const foreign_global = try core.Object.expect(foreign_global_value);
    const foreign_realm = js.runtime.contextForGlobalIncludingConstructing(foreign_global) orelse return error.TestUnexpectedResult;

    // Before the identity fix this ordinary C_FUNCTION was suppressed solely
    // because its internal dispatch name happened to be "Array". It owns the
    // foreign FunctionRealm, but it is not that realm's intrinsic %Array%.
    const fake_array = try core.function.nativeFunction(foreign_realm, "Array", 1);
    defer fake_array.free(js.runtime);
    const fake_array_object = try core.Object.expect(fake_array);
    const species_ctor_atom = try js.runtime.internAtom("__arraySpeciesResultCtor");
    defer js.runtime.atoms.free(species_ctor_atom);
    const species_ctor = try global.getProperty(species_ctor_atom);
    defer species_ctor.free(js.runtime);
    const species_atom = core.atom.predefinedId("Symbol.species", .symbol) orelse return error.TestUnexpectedResult;
    try fake_array_object.defineOwnProperty(js.runtime, species_atom, core.Descriptor.data(species_ctor, true, false, true));

    const fake_array_atom = try js.runtime.internAtom("__arraySpeciesNamedNative");
    defer js.runtime.atoms.free(fake_array_atom);
    try global.defineOwnProperty(js.runtime, fake_array_atom, core.Descriptor.data(fake_array, true, false, true));

    const result = try js.eval(
        \\var input = [1, 2];
        \\input.constructor = __arraySpeciesNamedNative;
        \\var output = input.map(function (value) { return value; });
        \\assert.sameValue(Object.getPrototypeOf(output), __arraySpeciesResultCtor.prototype);
        \\assert.sameValue(output.length, 2);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "TypedArray iterator methods accept cross-realm typed array receivers" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var other = $262.createRealm().global;
        \\    var local = new Uint8Array([42, 36]);
        \\    var remote = new other.Uint8Array([42, 36]);
        \\    assert.sameValue([...Uint8Array.prototype.values.call(remote)].toString(), "42,36");
        \\    assert.sameValue([...other.Uint8Array.prototype.values.call(local)].toString(), "42,36");
        \\    assert.sameValue([...Uint8Array.prototype.keys.call(remote)].toString(), "0,1");
        \\    assert.sameValue([...other.Uint8Array.prototype.entries.call(local)].toString(), "0,42,1,36");
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "TypedArray iterator methods reject proxy-wrapped shared typed array receivers" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function (global) {
        \\    const {Object, Reflect, SharedArrayBuffer, WeakMap} = global;
        \\    const {apply: Reflect_apply, construct: Reflect_construct} = Reflect;
        \\    const {get: WeakMap_prototype_get, has: WeakMap_prototype_has} = WeakMap.prototype;
        \\    const sharedConstructors = new WeakMap();
        \\    function sharedConstructor(baseConstructor) {
        \\        class SharedTypedArray extends Object.getPrototypeOf(baseConstructor) {
        \\            constructor(...args) {
        \\                var array = Reflect_construct(baseConstructor, args);
        \\                var {buffer, byteOffset, length} = array;
        \\                var sharedBuffer = new SharedArrayBuffer(buffer.byteLength);
        \\                var sharedArray = Reflect_construct(baseConstructor, [sharedBuffer, byteOffset, length], new.target);
        \\                for (var i = 0; i < length; i++) sharedArray[i] = array[i];
        \\                return sharedArray;
        \\            }
        \\        }
        \\        sharedConstructors.set(SharedTypedArray, baseConstructor);
        \\        return SharedTypedArray;
        \\    }
        \\    function isSharedConstructor(constructor) {
        \\        return Reflect_apply(WeakMap_prototype_has, sharedConstructors, [constructor]);
        \\    }
        \\    var constructors = [Uint8Array];
        \\    if (typeof SharedArrayBuffer === "function") constructors.push(sharedConstructor(Uint8Array));
        \\    for (var constructor of constructors) {
        \\        if (isSharedConstructor(constructor)) {
        \\            assert.sameValue(Reflect_apply(WeakMap_prototype_get, sharedConstructors, [constructor]), Uint8Array);
        \\        }
        \\        var invalidReceiver = new Proxy(new constructor(), {});
        \\        assert.throws(TypeError, function () {
        \\            constructor.prototype.values.call(invalidReceiver);
        \\        });
        \\    }
        \\})(this);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Engine eval assigns missing with references through outer scope" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var obj = {};
        \\with (obj) { missingWithTarget = "global"; }
        \\print(missingWithTarget);
        \\print(obj.missingWithTarget);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("global\nundefined\n", stream.buffered());
}

test "Engine eval resolves var initializer targets through with before RHS" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var obj = { test262id: 1 };
        \\with (obj) {
        \\  var test262id = delete obj.test262id;
        \\}
        \\print(obj.test262id);
        \\print(test262id);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\nundefined\n", stream.buffered());
}

test "Engine eval hoists top-level block var declarations to global object" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var obj = {};
        \\var readFoo = function() { return foo; };
        \\with (obj) { var foo = "global"; }
        \\print(foo);
        \\print(readFoo());
        \\print(obj.foo);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("global\nglobal\nundefined\n", stream.buffered());
}

test "Engine eval keeps function var declarations local under captured with" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var obj = { value: "outer" };
        \\with (obj) {
        \\  var f = function() {
        \\    var value = "local";
        \\    print(value);
        \\  };
        \\  f();
        \\}
        \\print(obj.value);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("local\nouter\n", stream.buffered());
}

test "Engine eval resets if-statement completion like QuickJS" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(eval("1; if (true) { }"));
        \\print(eval("2; if (true) { 3; }"));
        \\print(eval("2; if (false) { 3; }"));
        \\print(eval("2; if (false) { 3; } else { 4; }"));
        \\print(eval("2; if (false) { 3; } else { }"));
        \\print(eval("8; do { 9; if (true) { 10; continue; } 11; } while (false)"));
        \\print(eval("12; do { 13; if (true) { continue; } 14; } while (false)"));
        \\print(eval("1; while (false) { }"));
        \\print(eval("var count2 = 2; 2; while (count2 -= 1) { 3; }"));
        \\print(eval("4; while (true) { break; }"));
        \\print(eval("5; while (true) { 6; break; }"));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("undefined\n3\nundefined\n4\nundefined\n10\nundefined\nundefined\n3\nundefined\n6\n", stream.buffered());
}

test "Engine eval resets switch completion and falls through cases" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(eval("1; switch (0) { case 1: 2; }"));
        \\print(eval("1; switch (1) { case 1: }"));
        \\print(eval("1; switch ('a') { case 'a': 2; default: 3; }"));
        \\print(eval("5; switch ('b') { case 'a': case 'b': 6; }"));
        \\print(eval("7; switch (4) { default: 8; break; case 4: 9; }"));
        \\print(eval("2; switch ('a') { default: case 'b': { 3; break; } }"));
        \\print(eval("5; do { switch ('a') { default: case 'b': { 6; continue; } } } while (false)"));
        \\print(eval("1; switch ('a') { default: case 'b': 2; case 'c': 3; break; }"));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("undefined\nundefined\n3\n6\n9\n3\n6\n3\n", stream.buffered());
}

test "host print call keeps aliasing and override semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print("a", 1, true);
        \\var p = print;
        \\p("b");
        \\print = function(value) { return "override:" + value; };
        \\print("c");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("a 1 true\nb\n", stream.buffered());
}

// ================== collection_typedarray.zig ==================

test "TypedArray array-like construction does not replay coercions after fast path bailout" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var calls = 0;
        \\var value = {
        \\  valueOf: function() {
        \\    calls++;
        \\    return 7;
        \\  }
        \\};
        \\var source = {};
        \\source.length = 2;
        \\source[0] = value;
        \\source.x = 1;
        \\source[1] = 8;
        \\var typed = new Int8Array(source);
        \\assert.sameValue(calls, 1);
        \\assert.sameValue(typed[0], 7);
        \\assert.sameValue(typed[1], 8);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "TypedArray defineProperty value conversion may detach buffer" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var ta = new Int8Array([17]);
        \\assert.sameValue(Reflect.defineProperty(ta, 0, {
        \\    value: {
        \\        valueOf: function() {
        \\            ta.buffer.transfer();
        \\            return 42;
        \\        }
        \\    }
        \\}), true);
        \\assert.sameValue(ta[0], undefined);
        \\
        \\var big = new BigInt64Array([17n]);
        \\assert.sameValue(Reflect.defineProperty(big, 0, {
        \\    value: {
        \\        valueOf: function() {
        \\            big.buffer.transfer();
        \\            return 42n;
        \\        }
        \\    }
        \\}), true);
        \\assert.sameValue(big[0], undefined);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "TypedArray and species accessors follow inherited QuickJS shape" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var typedDesc = Object.getOwnPropertyDescriptor(TypedArray, Symbol.species);
        \\assert.sameValue(typedDesc.set, undefined);
        \\assert.sameValue(typeof typedDesc.get, "function");
        \\assert.sameValue(typedDesc.enumerable, false);
        \\assert.sameValue(typedDesc.configurable, true);
        \\assert.sameValue(typedDesc.get.length, 0);
        \\assert.sameValue(typedDesc.get.name, "get [Symbol.species]");
        \\assert.sameValue(Object.hasOwn(typedDesc.get, "call"), false);
        \\assert.sameValue(typedDesc.get.call(Uint8Array), Uint8Array);
        \\assert.sameValue(Object.hasOwn(Uint8Array, Symbol.species), false);
        \\assert.sameValue(Object.hasOwn(Float16Array, Symbol.species), false);
        \\assert.sameValue(Uint8Array[Symbol.species], Uint8Array);
        \\assert.sameValue(Float16Array[Symbol.species], Float16Array);
        \\var arrayGetter = Object.getOwnPropertyDescriptor(Array, Symbol.species).get;
        \\assert.sameValue(Object.hasOwn(arrayGetter, "call"), false);
        \\assert.sameValue(arrayGetter.call(Array), Array);
        \\for (var C of [Promise, Map, Set]) {
        \\    var getter = Object.getOwnPropertyDescriptor(C, Symbol.species).get;
        \\    assert.sameValue(Object.hasOwn(getter, "call"), false);
        \\    assert.sameValue(getter.call(C), C);
        \\}
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Well-known symbol method aliases share lazy native identity" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(Array.prototype[Symbol.iterator], Array.prototype.values);
        \\assert.sameValue(Array.prototype[Symbol.iterator].name, "values");
        \\assert.sameValue([1, 2][Symbol.iterator]().next().value, 1);
        \\
        \\assert.sameValue(TypedArray.prototype[Symbol.iterator], TypedArray.prototype.values);
        \\assert.sameValue(TypedArray.prototype[Symbol.iterator].name, "values");
        \\assert.sameValue(new Uint8Array([3, 4])[Symbol.iterator]().next().value, 3);
        \\
        \\assert.sameValue(Map.prototype[Symbol.iterator], Map.prototype.entries);
        \\assert.sameValue(Map.prototype[Symbol.iterator].name, "entries");
        \\assert.sameValue(new Map([["k", 5]])[Symbol.iterator]().next().value[1], 5);
        \\
        \\assert.sameValue(Set.prototype.keys, Set.prototype.values);
        \\assert.sameValue(Set.prototype[Symbol.iterator], Set.prototype.values);
        \\assert.sameValue(Set.prototype.keys.name, "values");
        \\assert.sameValue(new Set([6])[Symbol.iterator]().next().value, 6);
        \\
        \\assert.sameValue(DisposableStack.prototype[Symbol.dispose], DisposableStack.prototype.dispose);
        \\assert.sameValue(DisposableStack.prototype[Symbol.dispose].name, "dispose");
        \\
        \\assert.sameValue(AsyncDisposableStack.prototype[Symbol.asyncDispose], AsyncDisposableStack.prototype.disposeAsync);
        \\assert.sameValue(AsyncDisposableStack.prototype[Symbol.asyncDispose].name, "disposeAsync");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Lazy standard native accessors preserve descriptors and receiver markers" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var symbolDesc = Object.getOwnPropertyDescriptor(Symbol.prototype, "description");
        \\assert.sameValue(typeof symbolDesc.get, "function");
        \\assert.sameValue(symbolDesc.get.name, "get description");
        \\assert.sameValue(symbolDesc.get.length, 0);
        \\assert.sameValue(symbolDesc.set, undefined);
        \\assert.sameValue(symbolDesc.enumerable, false);
        \\assert.sameValue(symbolDesc.configurable, true);
        \\assert.sameValue(symbolDesc.get.call(Symbol("lazy-symbol")), "lazy-symbol");
        \\
        \\var mapSizeDesc = Object.getOwnPropertyDescriptor(Map.prototype, "size");
        \\assert.sameValue(typeof mapSizeDesc.get, "function");
        \\assert.sameValue(mapSizeDesc.get.name, "get size");
        \\assert.sameValue(mapSizeDesc.get.length, 0);
        \\assert.sameValue(mapSizeDesc.set, undefined);
        \\assert.sameValue(mapSizeDesc.get.call(new Map([["k", 1]])), 1);
        \\assert.throws(TypeError, function() { mapSizeDesc.get.call(new Set([1])); });
        \\
        \\var setSizeDesc = Object.getOwnPropertyDescriptor(Set.prototype, "size");
        \\assert.sameValue(typeof setSizeDesc.get, "function");
        \\assert.sameValue(setSizeDesc.get.name, "get size");
        \\assert.sameValue(setSizeDesc.get.length, 0);
        \\assert.sameValue(setSizeDesc.set, undefined);
        \\assert.sameValue(setSizeDesc.get.call(new Set([1, 2])), 2);
        \\assert.throws(TypeError, function() { setSizeDesc.get.call(new Map()); });
        \\
        \\var disposedDesc = Object.getOwnPropertyDescriptor(DisposableStack.prototype, "disposed");
        \\assert.sameValue(typeof disposedDesc.get, "function");
        \\assert.sameValue(disposedDesc.get.name, "get disposed");
        \\assert.sameValue(disposedDesc.get.length, 0);
        \\assert.sameValue(disposedDesc.set, undefined);
        \\assert.sameValue(disposedDesc.get.call(new DisposableStack()), false);
        \\assert.throws(TypeError, function() { disposedDesc.get.call({}); });
        \\
        \\var asyncDisposedDesc = Object.getOwnPropertyDescriptor(AsyncDisposableStack.prototype, "disposed");
        \\assert.sameValue(typeof asyncDisposedDesc.get, "function");
        \\assert.sameValue(asyncDisposedDesc.get.name, "get disposed");
        \\assert.sameValue(asyncDisposedDesc.get.length, 0);
        \\assert.sameValue(asyncDisposedDesc.set, undefined);
        \\assert.sameValue(asyncDisposedDesc.get.call(new AsyncDisposableStack()), false);
        \\assert.throws(TypeError, function() { asyncDisposedDesc.get.call({}); });
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Map and Set size live on prototype getter rather than instances" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const mapDescriptor = Object.getOwnPropertyDescriptor(Map.prototype, "size");
        \\assert.sameValue(typeof mapDescriptor.get, "function");
        \\assert.sameValue(mapDescriptor.enumerable, false);
        \\assert.sameValue(mapDescriptor.configurable, true);
        \\const map = new Map();
        \\assert.sameValue(Object.hasOwn(map, "size"), false);
        \\assert.sameValue(map.size, 0);
        \\map.set("key", "value");
        \\assert.sameValue(map.size, 1);
        \\map.delete("key");
        \\assert.sameValue(map.size, 0);
        \\Object.defineProperty(map, "size", { value: 99 });
        \\assert.sameValue(Object.hasOwn(map, "size"), true);
        \\assert.sameValue(map.size, 99);
        \\const set = new Set();
        \\assert.sameValue(Object.hasOwn(set, "size"), false);
        \\set.add(1);
        \\assert.sameValue(set.size, 1);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "typed array instances keep concrete class identity" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var int32 = new Int32Array(new ArrayBuffer(16));
        \\assert.sameValue(Object.getPrototypeOf(int32), Int32Array.prototype);
        \\assert.sameValue(Object.prototype.toString.call(int32), "[object Int32Array]");
        \\var uint8 = new Uint8Array(4);
        \\assert.sameValue(Object.getPrototypeOf(uint8), Uint8Array.prototype);
        \\assert.sameValue(Object.prototype.toString.call(uint8), "[object Uint8Array]");
        \\var float64 = new Float64Array([1, 2]);
        \\assert.sameValue(Object.getPrototypeOf(float64), Float64Array.prototype);
        \\assert.sameValue(Object.prototype.toString.call(float64), "[object Float64Array]");
        \\var big = new BigUint64Array([1n]);
        \\assert.sameValue(Object.getPrototypeOf(big), BigUint64Array.prototype);
        \\assert.sameValue(Object.prototype.toString.call(big), "[object BigUint64Array]");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp lazy native accessors preserve descriptor and mutation semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var sourceDesc = Object.getOwnPropertyDescriptor(RegExp.prototype, "source");
        \\assert.sameValue(typeof sourceDesc.get, "function");
        \\assert.sameValue(sourceDesc.get.name, "get source");
        \\assert.sameValue(sourceDesc.get.length, 0);
        \\assert.sameValue(sourceDesc.set, undefined);
        \\assert.sameValue(sourceDesc.enumerable, false);
        \\assert.sameValue(sourceDesc.configurable, true);
        \\assert.sameValue(sourceDesc.get.call(/ab+c/i), "ab+c");
        \\assert.sameValue(/ab+c/i.source, "ab+c");
        \\assert.sameValue(/ab+c/i.flags, "i");
        \\
        \\var speciesDesc = Object.getOwnPropertyDescriptor(RegExp, Symbol.species);
        \\assert.sameValue(typeof speciesDesc.get, "function");
        \\assert.sameValue(speciesDesc.get.name, "get [Symbol.species]");
        \\assert.sameValue(speciesDesc.get.length, 0);
        \\assert.sameValue(speciesDesc.set, undefined);
        \\assert.sameValue(speciesDesc.get.call(RegExp), RegExp);
        \\
        \\(function() {
        \\  "use strict";
        \\  var threw = false;
        \\  try { RegExp.prototype.unicodeSets = 1; } catch (e) { threw = e instanceof TypeError; }
        \\  assert.sameValue(threw, true);
        \\})();
        \\var unicodeSetsDesc = Object.getOwnPropertyDescriptor(RegExp.prototype, "unicodeSets");
        \\assert.sameValue(typeof unicodeSetsDesc.get, "function");
        \\assert.sameValue(unicodeSetsDesc.set, undefined);
        \\
        \\Object.defineProperty(RegExp.prototype, "dotAll", {});
        \\var dotAllDesc = Object.getOwnPropertyDescriptor(RegExp.prototype, "dotAll");
        \\assert.sameValue(typeof dotAllDesc.get, "function");
        \\assert.sameValue(dotAllDesc.set, undefined);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Buffer and TypedArray lazy native accessors preserve descriptor semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var buffer = new ArrayBuffer(8);
        \\var byteLengthDesc = Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, "byteLength");
        \\assert.sameValue(typeof byteLengthDesc.get, "function");
        \\assert.sameValue(byteLengthDesc.get.name, "get byteLength");
        \\assert.sameValue(byteLengthDesc.get.length, 0);
        \\assert.sameValue(byteLengthDesc.set, undefined);
        \\assert.sameValue(byteLengthDesc.get.call(buffer), 8);
        \\assert.sameValue(buffer.byteLength, 8);
        \\
        \\var arrayBufferSpecies = Object.getOwnPropertyDescriptor(ArrayBuffer, Symbol.species);
        \\assert.sameValue(typeof arrayBufferSpecies.get, "function");
        \\assert.sameValue(arrayBufferSpecies.get.name, "get [Symbol.species]");
        \\assert.sameValue(arrayBufferSpecies.get.call(ArrayBuffer), ArrayBuffer);
        \\
        \\(function() {
        \\  "use strict";
        \\  var threw = false;
        \\  try { ArrayBuffer.prototype.resizable = 1; } catch (e) { threw = e instanceof TypeError; }
        \\  assert.sameValue(threw, true);
        \\})();
        \\
        \\var view = new DataView(buffer, 2, 4);
        \\var viewOffsetDesc = Object.getOwnPropertyDescriptor(DataView.prototype, "byteOffset");
        \\assert.sameValue(typeof viewOffsetDesc.get, "function");
        \\assert.sameValue(viewOffsetDesc.get.name, "get byteOffset");
        \\assert.sameValue(viewOffsetDesc.set, undefined);
        \\assert.sameValue(viewOffsetDesc.get.call(view), 2);
        \\
        \\var typed = new Uint8Array(buffer);
        \\var typedLengthDesc = Object.getOwnPropertyDescriptor(TypedArray.prototype, "length");
        \\assert.sameValue(typeof typedLengthDesc.get, "function");
        \\assert.sameValue(typedLengthDesc.get.name, "get length");
        \\assert.sameValue(typedLengthDesc.set, undefined);
        \\assert.sameValue(typedLengthDesc.get.call(typed), 8);
        \\var tagDesc = Object.getOwnPropertyDescriptor(TypedArray.prototype, Symbol.toStringTag);
        \\assert.sameValue(typeof tagDesc.get, "function");
        \\assert.sameValue(tagDesc.get.name, "get [Symbol.toStringTag]");
        \\assert.sameValue(tagDesc.set, undefined);
        \\assert.sameValue(tagDesc.get.call(typed), "Uint8Array");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "standard constructors publish final prototype graphs and eager metadata" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function assertDataDescriptor(object, key, value, writable, enumerable, configurable) {
        \\    var descriptor = Object.getOwnPropertyDescriptor(object, key);
        \\    assert.sameValue(descriptor.value, value);
        \\    assert.sameValue(descriptor.writable, writable);
        \\    assert.sameValue(descriptor.enumerable, enumerable);
        \\    assert.sameValue(descriptor.configurable, configurable);
        \\}
        \\
        \\var constructors = [
        \\    [Object, "Object", 1, Function.prototype, null],
        \\    [Function, "Function", 1, Function.prototype, Object.prototype],
        \\    [Array, "Array", 1, Function.prototype, Object.prototype],
        \\    [Error, "Error", 1, Function.prototype, Object.prototype],
        \\    [TypeError, "TypeError", 1, Error, Error.prototype],
        \\    [Map, "Map", 0, Function.prototype, Object.prototype],
        \\    [Int8Array, "Int8Array", 3, TypedArray, TypedArray.prototype]
        \\];
        \\for (var entry of constructors) {
        \\    var constructor = entry[0];
        \\    assert.sameValue(Object.getPrototypeOf(constructor), entry[3]);
        \\    assert.sameValue(Object.getPrototypeOf(constructor.prototype), entry[4]);
        \\    assertDataDescriptor(constructor, "name", entry[1], false, false, true);
        \\    assertDataDescriptor(constructor, "length", entry[2], false, false, true);
        \\    assertDataDescriptor(constructor, "prototype", constructor.prototype, false, false, false);
        \\    assertDataDescriptor(constructor.prototype, "constructor", constructor, true, false, true);
        \\}
        \\assert.sameValue(typeof Function.prototype, "function");
        \\assert.sameValue(Function.prototype.name, "");
        \\assert.sameValue(Function.prototype.length, 0);
        \\assert.sameValue(Object.getPrototypeOf(Function.prototype), Object.prototype);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Promise constructor resolve and reject functions inherit Function.prototype" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var resolveFunction;
        \\var rejectFunction;
        \\new Promise(function(resolve, reject) {
        \\    resolveFunction = resolve;
        \\    rejectFunction = reject;
        \\});
        \\assert.sameValue(Object.getPrototypeOf(resolveFunction), Function.prototype);
        \\assert.sameValue(Object.getPrototypeOf(rejectFunction), Function.prototype);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "C function data callbacks are callable but not constructors" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var resolveFunction;
        \\var rejectFunction;
        \\new Promise(function(resolve, reject) {
        \\    resolveFunction = resolve;
        \\    rejectFunction = reject;
        \\});
        \\var capabilityExecutor;
        \\function CapabilityConstructor(executor) {
        \\    capabilityExecutor = executor;
        \\    executor(function() {}, function() {});
        \\}
        \\CapabilityConstructor.resolve = function(value) { return value; };
        \\Promise.resolve.call(CapabilityConstructor, 1);
        \\var revokeFunction = Proxy.revocable({}, {}).revoke;
        \\var callbacks = [resolveFunction, rejectFunction, capabilityExecutor, revokeFunction];
        \\for (var callback of callbacks) {
        \\    assert.sameValue(typeof callback, "function");
        \\    assert.throws(TypeError, function() { new callback(); });
        \\    assert.throws(TypeError, function() { Reflect.construct(callback, []); });
        \\    var wrapped = new Proxy(callback, {});
        \\    assert.throws(TypeError, function() { new wrapped(); });
        \\}
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Promise resolving functions keep internal state off user properties" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var savedResolve;
        \\var savedReject;
        \\var promise = new Promise(function(resolve, reject) {
        \\    savedResolve = resolve;
        \\    savedReject = reject;
        \\});
        \\assert.sameValue("__zjs_promise_target" in savedResolve, false);
        \\assert.sameValue("__zjs_promise_reject" in savedResolve, false);
        \\assert.sameValue("__zjs_promise_state" in savedResolve, false);
        \\assert.sameValue(Object.getOwnPropertyDescriptor(savedResolve, "__zjs_promise_target"), undefined);
        \\savedResolve.__zjs_promise_target = null;
        \\savedResolve.__zjs_promise_reject = true;
        \\savedResolve.__zjs_promise_state = null;
        \\savedResolve(42);
        \\savedReject("ignored");
        \\promise.then(
        \\    function(value) { assert.sameValue(value, 42); },
        \\    function(reason) { throw new Test262Error("unexpected rejection: " + reason); }
        \\);
        \\var rejectOnly;
        \\var rejected = new Promise(function(resolve, reject) {
        \\    rejectOnly = reject;
        \\});
        \\rejectOnly.__zjs_promise_target = null;
        \\rejectOnly("bad");
        \\rejected.then(
        \\    function(value) { throw new Test262Error("unexpected fulfillment: " + value); },
        \\    function(reason) { assert.sameValue(reason, "bad"); }
        \\);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Promise self-resolution rejects with the caller realm TypeError" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var resolveFunction;
        \\var promise = new Promise(function(resolve) {
        \\    resolveFunction = resolve;
        \\});
        \\promise.then(undefined, function(reason) {
        \\    print(reason.name, reason.constructor === TypeError, reason instanceof TypeError);
        \\});
        \\resolveFunction(promise);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("TypeError true true\n", stream.buffered());
}

test "cross-realm promise resolving data function keeps caller realm" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var other = $262.createRealm().global;
        \\    other.eval(
        \\        "globalThis.promise = new Promise(function(resolve) { " +
        \\        "globalThis.resolvePromise = resolve; });"
        \\    );
        \\    try {
        \\        new other.resolvePromise();
        \\        throw new Test262Error("expected resolving function construction to fail");
        \\    } catch (error) {
        \\        assert.sameValue(Object.getPrototypeOf(error), TypeError.prototype);
        \\        assert.sameValue(error instanceof other.TypeError, false);
        \\    }
        \\    other.promise.then(undefined, function(reason) {
        \\        assert.sameValue(Object.getPrototypeOf(reason), TypeError.prototype);
        \\        assert.sameValue(reason instanceof other.TypeError, false);
        \\    });
        \\    other.resolvePromise(other.promise);
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Promise.resolve rejects self-resolution from custom capability" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var resolve;
        \\var reject;
        \\var promise = new Promise(function(_resolve, _reject) {
        \\    resolve = _resolve;
        \\    reject = _reject;
        \\});
        \\function P(executor) {
        \\    executor(resolve, reject);
        \\    return promise;
        \\}
        \\Promise.resolve.call(P, promise).then(
        \\    function() { throw new Test262Error("should reject"); },
        \\    function(reason) { assert.sameValue(reason.constructor, TypeError); }
        \\);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Promise.resolve returns an identity match before constructor validation" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var receiver = {};
        \\var constructorGets = 0;
        \\var promise = Promise.resolve(1);
        \\Object.defineProperty(promise, "constructor", {
        \\    configurable: true,
        \\    get: function() {
        \\        constructorGets++;
        \\        return receiver;
        \\    }
        \\});
        \\assert.sameValue(Promise.resolve.call(receiver, promise), promise);
        \\assert.sameValue(constructorGets, 1);
        \\var dataPromise = Promise.resolve(2);
        \\dataPromise.constructor = receiver;
        \\assert.sameValue(Promise.resolve.call(receiver, dataPromise), dataPromise);
        \\dataPromise.constructor = null;
        \\assert.throws(TypeError, function() {
        \\    Promise.resolve.call(receiver, dataPromise);
        \\});
        \\var proxyPromise = Promise.resolve(3);
        \\var originalPrototype = Object.getPrototypeOf(proxyPromise);
        \\var proxyConstructorGets = 0;
        \\Object.setPrototypeOf(proxyPromise, new Proxy(originalPrototype, {
        \\    get: function(target, key, receiverValue) {
        \\        if (key === "constructor") proxyConstructorGets++;
        \\        return Reflect.get(target, key, receiverValue);
        \\    }
        \\}));
        \\assert.sameValue(Promise.resolve(proxyPromise), proxyPromise);
        \\assert.sameValue(proxyConstructorGets, 1);
        \\var throwingPromise = Promise.resolve(4);
        \\Object.defineProperty(throwingPromise, "constructor", {
        \\    get: function() { throw new Error("constructor sentinel"); }
        \\});
        \\assert.throws(Error, function() {
        \\    Promise.resolve(throwingPromise);
        \\});
        \\assert.throws(TypeError, function() {
        \\    Promise.resolve.call(receiver, Promise.resolve(5));
        \\});
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Promise capability executor keeps internal slot off user properties" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function C(executor) {
        \\    assert.sameValue(typeof executor, "function");
        \\    assert.sameValue("__zjs_promise_capability_slot" in executor, false);
        \\    assert.sameValue(Object.getOwnPropertyDescriptor(executor, "__zjs_promise_capability_slot"), undefined);
        \\    assert.sameValue(executor.__zjs_promise_capability_slot, undefined);
        \\    executor.__zjs_promise_capability_slot = null;
        \\    executor(
        \\        function(value) { print("resolve", value); },
        \\        function(reason) { print("reject", reason); }
        \\    );
        \\    print("executor ok");
        \\}
        \\C.resolve = function(value) { return value; };
        \\Promise.resolve.call(C, 1);
        \\print("done");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("executor ok\nresolve 1\ndone\n", stream.buffered());
    try std.testing.expect(!js.context.hasException());
}

test "Promise combinator element callbacks inherit Function.prototype" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var resolveElementFunction;
        \\var rejectElementFunction;
        \\var resolveThenable = {
        \\    then: function(fulfill) {
        \\        resolveElementFunction = fulfill;
        \\    }
        \\};
        \\var rejectThenable = {
        \\    then: function(_, reject) {
        \\        rejectElementFunction = reject;
        \\    }
        \\};
        \\function NotPromise(executor) {
        \\    executor(function() {}, function() {});
        \\}
        \\NotPromise.resolve = function(v) { return v; };
        \\Promise.all.call(NotPromise, [resolveThenable]);
        \\Promise.allSettled.call(NotPromise, [rejectThenable]);
        \\assert.sameValue(Object.getPrototypeOf(resolveElementFunction), Function.prototype);
        \\assert.sameValue(Object.getPrototypeOf(rejectElementFunction), Function.prototype);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Promise combinator callbacks keep internal state off user properties" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var saved;
        \\var p0 = new Promise(function() {});
        \\p0.then = function(onFulfilled, onRejected) {
        \\    saved = onFulfilled;
        \\    return Promise.prototype.then.call(this, onFulfilled, onRejected);
        \\};
        \\var all = Promise.all([p0]);
        \\assert.sameValue("__zjs_promise_comb_mode" in saved, false);
        \\assert.sameValue("__zjs_promise_comb_state" in saved, false);
        \\assert.sameValue("__zjs_promise_comb_index" in saved, false);
        \\assert.sameValue("__zjs_promise_comb_called" in saved, false);
        \\assert.sameValue(Object.getOwnPropertyDescriptor(saved, "__zjs_promise_comb_mode"), undefined);
        \\assert.sameValue(saved.__zjs_promise_comb_mode, undefined);
        \\saved.__zjs_promise_comb_called = 1;
        \\saved.__zjs_promise_comb_state = null;
        \\saved.__zjs_promise_comb_index = 99;
        \\saved("ok");
        \\all.then(
        \\    function(values) { assert.sameValue(values[0], "ok"); },
        \\    function(reason) { throw new Test262Error("unexpected rejection: " + reason); }
        \\);
        \\
        \\var onFulfilled;
        \\var onRejected;
        \\var p1 = new Promise(function() {});
        \\p1.then = function(fulfill, reject) {
        \\    onFulfilled = fulfill;
        \\    onRejected = reject;
        \\    return Promise.prototype.then.call(this, fulfill, reject);
        \\};
        \\var settled = Promise.allSettled([p1]);
        \\assert.sameValue("__zjs_promise_comb_mode" in onFulfilled, false);
        \\assert.sameValue("__zjs_promise_comb_mode" in onRejected, false);
        \\onFulfilled.__zjs_promise_comb_called = 1;
        \\onRejected.__zjs_promise_comb_called = 1;
        \\onRejected("bad");
        \\onFulfilled("ignored");
        \\settled.then(
        \\    function(values) {
        \\        assert.sameValue(values[0].status, "fulfilled");
        \\        assert.sameValue(values[0].value, "ignored");
        \\        assert.sameValue(values[0].reason, undefined);
        \\    },
        \\    function(reason) { throw new Test262Error("unexpected rejection: " + reason); }
        \\);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "pending Promise.then reactions run after deferred settlement" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var resolve;
        \\var p = new Promise(function(r) { resolve = r; });
        \\var q = p.then(function(v) { print("first", v); return v + "!"; });
        \\p.then(function(v) { print("second", v); });
        \\q.then(function(v) { print("chain", v); });
        \\resolve("ok");
        \\print("after resolve");
        \\
        \\var reject;
        \\var bad = new Promise(function(resolve, r) { reject = r; });
        \\bad.then(null, function(reason) { print("caught", reason); return "handled"; })
        \\   .then(function(v) { print("recovered", v); });
        \\reject("boom");
        \\print("after reject");
        \\
        \\var passResolve;
        \\var pass = new Promise(function(r) { passResolve = r; });
        \\pass.then().then(function(v) { print("pass", v); });
        \\passResolve("through");
        \\print("after pass");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "after resolve\nafter reject\nafter pass\nfirst ok\nsecond ok\ncaught boom\nchain ok!\nrecovered handled\npass through\n",
        stream.buffered(),
    );
    try std.testing.expect(!js.context.hasException());
}

test "settled Promise.then reactions run as deferred jobs" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\Promise.resolve("ok")
        \\    .then(function(v) { print("then", v); return v + "!"; })
        \\    .then(function(v) { print("chain", v); });
        \\Promise.reject("bad")
        \\    .then(undefined, function(v) { print("caught", v); return "handled"; })
        \\    .then(function(v) { print("recovered", v); });
        \\print("sync");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "sync\nthen ok\ncaught bad\nchain ok!\nrecovered handled\n",
        stream.buffered(),
    );
    try std.testing.expect(!js.context.hasException());
}

test "Promise.finally callbacks keep internal state off user properties" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var savedFulfill;
        \\var savedReject;
        \\var cleanupCount = 0;
        \\var p = new Promise(function() {});
        \\p.then = function(onFulfilled, onRejected) {
        \\    savedFulfill = onFulfilled;
        \\    savedReject = onRejected;
        \\    return Promise.prototype.then.call(this, onFulfilled, onRejected);
        \\};
        \\p.finally(function() {
        \\    cleanupCount += 1;
        \\    print("cleanup", cleanupCount);
        \\    return "cleanup-result";
        \\});
        \\assert.sameValue("__zjs_promise_finally_mode" in savedFulfill, false);
        \\assert.sameValue("__zjs_promise_finally_callback" in savedFulfill, false);
        \\assert.sameValue("__zjs_promise_finally_constructor" in savedFulfill, false);
        \\assert.sameValue("__zjs_promise_finally_mode" in savedReject, false);
        \\assert.sameValue(Object.getOwnPropertyDescriptor(savedFulfill, "__zjs_promise_finally_mode"), undefined);
        \\assert.sameValue(savedFulfill.__zjs_promise_finally_mode, undefined);
        \\savedFulfill.__zjs_promise_finally_callback = function() {
        \\    print("tampered");
        \\    return "bad";
        \\};
        \\savedFulfill.__zjs_promise_finally_payload = "bad";
        \\savedFulfill("direct");
        \\print("after direct");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("cleanup 1\nafter direct\n", stream.buffered());
    try std.testing.expect(!js.context.hasException());
}

test "Promise.allSettled reject element callback is alreadyCalled guarded" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\let rejectCallCount = 0;
        \\let returnValue = {};
        \\let error = new Test262Error();
        \\function Constructor(executor) {
        \\    function reject(value) {
        \\        assert.sameValue(value, error);
        \\        rejectCallCount += 1;
        \\        return returnValue;
        \\    }
        \\    executor(() => { throw error; }, reject);
        \\}
        \\Constructor.resolve = function(v) { return v; };
        \\Constructor.reject = function(v) { return v; };
        \\let pOnRejected;
        \\let p = {
        \\    then(onResolved, onRejected) {
        \\        pOnRejected = onRejected;
        \\        onResolved();
        \\    }
        \\};
        \\Promise.allSettled.call(Constructor, [p]);
        \\assert.sameValue(rejectCallCount, 1);
        \\assert.sameValue(pOnRejected(), undefined);
        \\assert.sameValue(rejectCallCount, 1);
        \\pOnRejected();
        \\assert.sameValue(rejectCallCount, 1);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Promise.all accepts string iterables through the built-in Promise path" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\Promise.all("ab").then(v => {
        \\    print(v.length);
        \\    print(v[0]);
        \\    print(v[1]);
        \\});
        \\print("after");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("after\n2\na\nb\n", stream.buffered());
    try std.testing.expect(!js.context.hasException());
}

test "Promise.race accepts Set iterables through the built-in Promise path" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\Promise.race(new Set([1, 2])).then(v => print(v));
        \\print("after");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("after\n1\n", stream.buffered());
    try std.testing.expect(!js.context.hasException());
}

test "Promise.allSettled accepts Set iterables through the built-in Promise path" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\Promise.allSettled(new Set([1, 2])).then(v => {
        \\    print(v.length);
        \\    print(v[0].status);
        \\    print(v[0].value);
        \\    print(v[1].status);
        \\    print(v[1].value);
        \\});
        \\print("after");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("after\n2\nfulfilled\n1\nfulfilled\n2\n", stream.buffered());
    try std.testing.expect(!js.context.hasException());
}

test "Promise keyed combinators preserve enumerable own keys" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(Promise.allKeyed.length);
        \\print(Promise.allSettledKeyed.name);
        \\var resolveFirst;
        \\var sym = Symbol("s");
        \\var input = {
        \\    first: new Promise(resolve => { resolveFirst = resolve; }),
        \\    second: Promise.resolve("two"),
        \\};
        \\input[sym] = Promise.resolve("sym");
        \\Object.defineProperty(input, "hidden", {
        \\    enumerable: false,
        \\    value: Promise.resolve("hidden"),
        \\});
        \\Promise.allKeyed(input).then(result => {
        \\    print(Object.getPrototypeOf(result) === null);
        \\    print(Object.keys(result).join("|"));
        \\    print(result.first + "|" + result.second + "|" + result[sym]);
        \\    print(result.hidden);
        \\});
        \\Promise.allSettledKeyed({
        \\    ok: Promise.resolve(1),
        \\    bad: Promise.reject("x"),
        \\}).then(result => {
        \\    print(result.ok.status + ":" + result.ok.value);
        \\    print(result.bad.status + ":" + result.bad.reason);
        \\});
        \\resolveFirst("one");
        \\print("after");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "1\nallSettledKeyed\nafter\nfulfilled:1\nrejected:x\ntrue\nfirst|second\none|two|sym\nundefined\n",
        stream.buffered(),
    );
    try std.testing.expect(!js.context.hasException());
}

test "Promise.any accepts Set iterables through the built-in Promise path" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\Promise.any(new Set([1, 2])).then(v => print(v), e => print(e.name));
        \\print("after");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("after\n1\n", stream.buffered());
    try std.testing.expect(!js.context.hasException());
}

test "Object.defineProperty returns retained target object" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const proto = Map.prototype;
        \\const returned = Object.defineProperty(proto, "sentinel", { value: 7, writable: true, configurable: true });
        \\print(returned === proto);
        \\print(Map.prototype.sentinel);
        \\const map = new Map();
        \\map.set("key", "value");
        \\print(map.get("key"));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\n7\nvalue\n", stream.buffered());
}

test "Object constructor record preserves call and construct semantics" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\const value = { marker: 1 };
        \\assert.sameValue(Object.prototype.hasOwnProperty("Object"), false);
        \\assert.sameValue(Object(value), value);
        \\assert.sameValue(Object.call(null, value), value);
        \\assert.sameValue(Object(value, 2, 3), value);
        \\assert.sameValue(Object() instanceof Object, true);
        \\assert.sameValue(Object(null) instanceof Object, true);
        \\assert.sameValue(Object(undefined) instanceof Object, true);
        \\assert.sameValue(Object(7).valueOf(), 7);
        \\assert.sameValue(Object(true).valueOf(), true);
        \\assert.sameValue(Object("z").valueOf(), "z");
        \\assert.sameValue(Object(1n).valueOf(), 1n);
        \\const symbol = Symbol("s");
        \\assert.sameValue(Object(symbol).valueOf(), symbol);
        \\const renamed = Object;
        \\const originalName = Object.getOwnPropertyDescriptor(renamed, "name");
        \\Object.defineProperty(renamed, "name", { value: "RenamedObject" });
        \\assert.sameValue(renamed(value), value);
        \\assert.sameValue(new renamed(value), value);
        \\function NewTarget() {}
        \\const reflected = Reflect.construct(renamed, [value], NewTarget);
        \\assert.sameValue(reflected === value, false);
        \\assert.sameValue(Object.getPrototypeOf(reflected), NewTarget.prototype);
        \\class ObjectSubclass extends renamed {}
        \\const subclassed = new ObjectSubclass(value);
        \\assert.sameValue(subclassed === value, false);
        \\assert.sameValue(Object.getPrototypeOf(subclassed), ObjectSubclass.prototype);
        \\Object.defineProperty(renamed, "name", originalName);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "native cproto distinguishes construct-only and callable constructors" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\assert.throws(TypeError, function() { Map(); });
        \\assert.throws(TypeError, function() { Set(); });
        \\assert.throws(TypeError, function() { WeakMap(); });
        \\assert.throws(TypeError, function() { WeakSet(); });
        \\assert.sameValue(Array(1).length, 1);
        \\assert.sameValue(String(1), "1");
        \\assert.sameValue(RegExp("x").source, "x");
        \\assert.sameValue(typeof Date(), "string");
        \\assert.sameValue(Object(null) instanceof Object, true);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "WeakMap and WeakSet accept non-registered symbols as weak keys" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const key = Symbol("weak");
        \\const other = Symbol("weak");
        \\const map = new WeakMap([[key, 1]]);
        \\assert.sameValue(map.get(key), 1);
        \\assert.sameValue(map.has(other), false);
        \\assert.sameValue(map.set(other, 2), map);
        \\assert.sameValue(map.get(other), 2);
        \\assert.sameValue(map.delete(key), true);
        \\assert.sameValue(map.has(key), false);
        \\const set = new WeakSet([key]);
        \\assert.sameValue(set.has(key), true);
        \\assert.sameValue(set.add(other), set);
        \\assert.sameValue(set.has(other), true);
        \\assert.sameValue(set.delete(key), true);
        \\assert.sameValue(set.has(key), false);
        \\assert.throws(TypeError, function () { map.set(Symbol.for("registered"), 3); });
        \\assert.throws(TypeError, function () { set.add(Symbol.for("registered")); });
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "host WeakMap mutation closure rejects registered symbol keys" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const map_value = try engine.exec.collection_ops.constructBare(rt, 3);
    defer map_value.free(rt);
    const map_object = objectFromValue(map_value);

    const closure_value = try engine.exec.closure.create(rt, 39, 0, 0, 0);
    defer closure_value.free(rt);

    const registered_atom = try rt.atoms.internGlobalSymbol("registered");
    defer rt.atoms.free(registered_atom);

    const map_name = try rt.internAtom("map");
    defer rt.atoms.free(map_name);
    const key_name = try rt.internAtom("obj3");
    defer rt.atoms.free(key_name);

    var globals = [_]engine.exec.globals.Slot{
        .{ .name = map_name, .value = map_value.dup() },
        .{ .name = key_name, .value = try rt.symbolValue(registered_atom) },
    };
    defer globals[0].value.free(rt);
    defer globals[1].value.free(rt);

    if (engine.exec.closure.call(rt, closure_value, &.{}, globals[0..])) |value| {
        defer value.free(rt);
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(error.TypeError, err);
    }
    try std.testing.expectEqual(@as(usize, 0), map_object.weakCollectionEntries().len);
}

test "host WeakMap mutation closure links entries into existing weak index" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const map_value = try engine.exec.collection_ops.constructBare(rt, 3);
    defer map_value.free(rt);
    const map_object = objectFromValue(map_value);

    var keys: [8]*core.Object = undefined;
    var key_count: usize = 0;
    defer {
        for (keys[0..key_count]) |key| key.value().free(rt);
    }

    for (&keys, 0..) |*slot, index| {
        const key = try core.Object.create(rt, core.class.ids.object, null);
        slot.* = key;
        key_count += 1;
        const result = try engine.exec.collection_ops.methodCall(rt, map_value, 1, &.{ key.value(), core.JSValue.int32(@intCast(index)) });
        result.free(rt);
    }
    try std.testing.expectEqual(@as(usize, 8), map_object.weakCollectionEntries().len);
    try std.testing.expect(map_object.collectionBucketHeads().len != 0);

    const mutation_key = try core.Object.create(rt, core.class.ids.object, null);
    defer mutation_key.value().free(rt);

    const closure_value = try engine.exec.closure.create(rt, 39, 0, 0, 0);
    defer closure_value.free(rt);

    const map_name = try rt.internAtom("map");
    defer rt.atoms.free(map_name);
    const key_name = try rt.internAtom("obj3");
    defer rt.atoms.free(key_name);

    var globals = [_]engine.exec.globals.Slot{
        .{ .name = map_name, .value = map_value.dup() },
        .{ .name = key_name, .value = mutation_key.value().dup() },
    };
    defer globals[0].value.free(rt);
    defer globals[1].value.free(rt);

    try std.testing.expectError(error.JSException, engine.exec.closure.call(rt, closure_value, &.{}, globals[0..]));

    try std.testing.expectEqual(@as(usize, 9), map_object.weakCollectionEntries().len);
    const get_result = try engine.exec.collection_ops.methodCall(rt, map_value, 2, &.{mutation_key.value()});
    defer get_result.free(rt);
    try helpers.expectStringValueBytes(get_result, "mutated");
}

// Test-side stand-in for the retired engine `__setlike_mode` fixture: a
// CallbackHost whose `keys` call mutates the base set mid-operation (delete
// "b"/"c", re-add "b", add "d") before returning the real key array
// ["x","b","c","c"]. The set-like object itself is a plain object carrying
// real `size`/`has`/`keys` properties.
fn symmetricDifferenceMutatingKeysHost(
    rt: *core.JSRuntime,
    callback: core.JSValue,
    this_value: core.JSValue,
    args: []const core.JSValue,
    globals: []engine.exec.globals.Slot,
) core.host_function.CallbackError!core.JSValue {
    _ = callback;
    _ = this_value;
    return symmetricDifferenceMutatingKeysImpl(rt, args, globals) catch |err| return @errorCast(err);
}

fn symmetricDifferenceMutatingKeysImpl(
    rt: *core.JSRuntime,
    args: []const core.JSValue,
    globals: []engine.exec.globals.Slot,
) !core.JSValue {
    // `has` (one argument) is never reached by symmetricDifference; only the
    // zero-argument `keys` call arrives here.
    if (args.len != 0) return core.JSValue.boolean(false);

    const base_set_value = try engine.exec.globals.getByName(rt, globals, "baseSet");
    defer base_set_value.free(rt);
    inline for (.{ "b", "c" }) |name| {
        const value = (try core.string.String.createUtf8(rt, name)).value();
        defer value.free(rt);
        const out = try engine.exec.collection_ops.methodCall(rt, base_set_value, 4, &.{value});
        out.free(rt);
    }
    inline for (.{ "b", "d" }) |name| {
        const value = (try core.string.String.createUtf8(rt, name)).value();
        defer value.free(rt);
        const out = try engine.exec.collection_ops.methodCall(rt, base_set_value, 6, &.{value});
        out.free(rt);
    }

    const array = try core.Object.createArray(rt, null);
    errdefer core.Object.destroyFromHeader(rt, &array.header);
    comptime var index: u32 = 0;
    inline for (.{ "x", "b", "c", "c" }) |name| {
        const value = (try core.string.String.createUtf8(rt, name)).value();
        defer value.free(rt);
        try array.defineOwnProperty(rt, core.atom.atomFromUInt32(index), core.Descriptor.data(value, true, true, true));
        index += 1;
    }
    return array.value();
}

test "Set.prototype.symmetricDifference tracks receiver mutations from a set-like keys call" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const base_set_value = try engine.exec.collection_ops.constructBare(rt, 2);
    defer base_set_value.free(rt);
    const base_set = objectFromValue(base_set_value);

    inline for (.{ "a", "b", "c", "d", "e", "q" }) |name| {
        const value = (try core.string.String.createUtf8(rt, name)).value();
        defer value.free(rt);
        const out = try engine.exec.collection_ops.methodCall(rt, base_set_value, 6, &.{value});
        out.free(rt);
    }

    const setlike = try core.Object.create(rt, core.class.ids.object, null);
    const setlike_value = setlike.value();
    defer setlike_value.free(rt);

    const size_key = try rt.internAtom("size");
    defer rt.atoms.free(size_key);
    try setlike.defineOwnProperty(rt, size_key, core.Descriptor.data(core.JSValue.int32(4), true, true, true));

    const noop = try engine.exec.closure.create(rt, 13, 0, 0, 0);
    defer noop.free(rt);

    const has_key = try rt.internAtom("has");
    defer rt.atoms.free(has_key);
    try setlike.defineOwnProperty(rt, has_key, core.Descriptor.data(noop, true, true, true));

    const keys_key = try rt.internAtom("keys");
    defer rt.atoms.free(keys_key);
    try setlike.defineOwnProperty(rt, keys_key, core.Descriptor.data(noop, true, true, true));

    const base_set_name = try rt.internAtom("baseSet");
    defer rt.atoms.free(base_set_name);
    var globals = [_]engine.exec.globals.Slot{
        .{ .name = base_set_name, .value = base_set_value.dup() },
    };
    defer globals[0].value.free(rt);

    const host = core.host_function.CallbackHost{
        .globals = globals[0..],
        .call = &symmetricDifferenceMutatingKeysHost,
    };
    const result_value = try engine.exec.collection_ops.methodCallWithCallbackHost(rt, base_set_value, 20, &.{setlike_value}, host);
    defer result_value.free(rt);
    const result_set = objectFromValue(result_value);

    try expectActiveSetStrings(result_set, &.{ "a", "c", "d", "e", "q", "x" });
    try expectActiveSetStrings(base_set, &.{ "a", "d", "e", "q", "b" });
}

test "host map closure releases appended value when entry allocation fails" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const map_value = try engine.exec.collection_ops.constructBare(rt, 1);
    defer map_value.free(rt);
    const map_object = objectFromValue(map_value);

    inline for (.{ 10, 11, 12, 13, 14, 15, 16, 17 }) |key| {
        const result = try engine.exec.collection_ops.methodCall(rt, map_value, 1, &.{ core.JSValue.int32(key), core.JSValue.int32(key) });
        result.free(rt);
    }
    try std.testing.expectEqual(@as(usize, 8), map_object.collectionEntries().len);
    try std.testing.expectEqual(@as(usize, 8), map_object.collectionEntriesCapacity());

    const closure_value = try engine.exec.closure.create(rt, 38, 0, 0, 0);
    defer closure_value.free(rt);

    const map_name = try rt.internAtom("map");
    defer rt.atoms.free(map_name);
    var globals = [_]engine.exec.globals.Slot{
        .{ .name = map_name, .value = map_value.dup() },
    };
    defer globals[0].value.free(rt);

    const old_bytes = rt.memory.allocated_bytes;
    const old_allocations = rt.memory.allocation_count;
    rt.setMemoryLimit(old_bytes + @sizeOf(core.string.String) + "mutated".len);
    try std.testing.expectError(error.OutOfMemory, engine.exec.closure.call(rt, closure_value, &.{}, globals[0..]));
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(old_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(old_allocations, rt.memory.allocation_count);
    try std.testing.expectEqual(@as(usize, 8), map_object.collectionEntries().len);
    try std.testing.expectEqual(@as(usize, 8), map_object.collectionActiveCount());
}

test "host map closure rolls back appended entry when size update fails" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const map_value = try engine.exec.collection_ops.constructBare(rt, 1);
    defer map_value.free(rt);
    const map_object = objectFromValue(map_value);

    const first_set = try engine.exec.collection_ops.methodCall(rt, map_value, 1, &.{ core.JSValue.int32(1), core.JSValue.int32(11) });
    first_set.free(rt);

    try fillOwnPropertyStorageForFailure(rt, map_object);
    try std.testing.expect(map_object.deleteProperty(rt, core.atom.predefinedId("size", .string).?));

    const closure_value = try engine.exec.closure.create(rt, 39, 0, 0, 0);
    defer closure_value.free(rt);

    const map_name = try rt.internAtom("map");
    defer rt.atoms.free(map_name);
    var globals = [_]engine.exec.globals.Slot{
        .{ .name = map_name, .value = map_value.dup() },
    };
    defer globals[0].value.free(rt);

    const old_len = map_object.collectionEntries().len;
    const old_active = map_object.collectionActiveCount();
    const old_bytes = rt.memory.allocated_bytes;

    rt.setMemoryLimit(old_bytes + @sizeOf(core.string.String) + "mutated".len);
    try std.testing.expectError(error.OutOfMemory, engine.exec.closure.call(rt, closure_value, &.{}, globals[0..]));
    rt.setMemoryLimit(null);

    const entries_slot = map_object.collectionEntriesSlot();
    const observed_len = entries_slot.*.len;
    const observed_active = map_object.collectionActiveCount();
    if (entries_slot.*.len > old_len) {
        entries_slot.*[old_len].destroy(rt);
        entries_slot.*[old_len] = .{ .key = core.JSValue.undefinedValue(), .value = core.JSValue.undefinedValue(), .active = false };
        entries_slot.* = entries_slot.*.ptr[0..old_len];
        map_object.collectionActiveCountSlot().* = old_active;
        map_object.clearCollectionIndex(rt);
    }

    try std.testing.expectEqual(old_len, observed_len);
    try std.testing.expectEqual(old_active, observed_active);
    try std.testing.expectEqual(old_bytes, rt.memory.allocated_bytes);
}

test "Set.prototype.union uses GetSetRecord order for set-like classes" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var observedOrder = [];
        \\function observableIterator() {
        \\  var values = ["a", "b", "c"];
        \\  var index = 0;
        \\  return {
        \\    get next() {
        \\      observedOrder.push("getting next");
        \\      return function() {
        \\        observedOrder.push("calling next");
        \\        return {
        \\          get done() {
        \\            observedOrder.push("getting done");
        \\            return index >= values.length;
        \\          },
        \\          get value() {
        \\            observedOrder.push("getting value");
        \\            return values[index++];
        \\          }
        \\        };
        \\      };
        \\    }
        \\  };
        \\}
        \\class MySetLike {
        \\  get size() {
        \\    observedOrder.push("getting size");
        \\    return {
        \\      valueOf: function() {
        \\        observedOrder.push("ToNumber(size)");
        \\        return 2;
        \\      }
        \\    };
        \\  }
        \\  get has() {
        \\    observedOrder.push("getting has");
        \\    return function() {
        \\      throw new Test262Error("union should not invoke has");
        \\    };
        \\  }
        \\  get keys() {
        \\    observedOrder.push("getting keys");
        \\    return function() {
        \\      observedOrder.push("calling keys");
        \\      return observableIterator();
        \\    };
        \\  }
        \\}
        \\var expectedOrder = [
        \\  "getting size",
        \\  "ToNumber(size)",
        \\  "getting has",
        \\  "getting keys",
        \\  "calling keys",
        \\  "getting next",
        \\  "calling next",
        \\  "getting done",
        \\  "getting value",
        \\  "calling next",
        \\  "getting done",
        \\  "getting value",
        \\  "calling next",
        \\  "getting done",
        \\  "getting value",
        \\  "calling next",
        \\  "getting done"
        \\];
        \\var combined = new Set(["a", "d"]).union(new MySetLike());
        \\assert.compareArray([...combined], ["a", "d", "b", "c"]);
        \\assert.compareArray(observedOrder, expectedOrder);
        \\var coercionCalls = 0;
        \\assert.throws(TypeError, function() {
        \\  new Set([1, 2]).union({
        \\    size: { valueOf: function() { coercionCalls++; return NaN; } },
        \\    has: function() {},
        \\    keys: function() { return observableIterator(); }
        \\  });
        \\});
        \\assert.sameValue(coercionCalls, 1);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Set.prototype.intersection consumes set-like keys as a direct iterator" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var log = [];
        \\var keysIterator = {};
        \\Object.defineProperty(keysIterator, Symbol.iterator, {
        \\  get: function() {
        \\    log.push("get @@iterator");
        \\    return function() { return keysIterator; };
        \\  }
        \\});
        \\Object.defineProperty(keysIterator, "next", {
        \\  get: function() {
        \\    log.push("get next");
        \\    return function() {
        \\      log.push("call next");
        \\      return { done: true };
        \\    };
        \\  }
        \\});
        \\var setLike = {
        \\  size: 0,
        \\  has: function() {
        \\    throw new Test262Error("intersection should not call has when other is smaller");
        \\  },
        \\  keys: function() {
        \\    log.push("call keys");
        \\    return keysIterator;
        \\  }
        \\};
        \\var result = new Set([1]).intersection(setLike);
        \\assert.compareArray([...result], []);
        \\assert.compareArray(log, ["call keys", "get next", "call next"]);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Set union methods copy receiver after reading set-like keys next" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function setLikeThatReplaces(set) {
        \\  return {
        \\    size: 0,
        \\    has: function() {
        \\      throw new Test262Error("set-like has should not be called");
        \\    },
        \\    keys: function() {
        \\      return {
        \\        get next() {
        \\          set.clear();
        \\          set.add(4);
        \\          return function() {
        \\            return { done: true };
        \\          };
        \\        }
        \\      };
        \\    }
        \\  };
        \\}
        \\var unionBase = new Set([1, 2, 3]);
        \\assert.compareArray([...unionBase.union(setLikeThatReplaces(unionBase))], [4]);
        \\var symmetricBase = new Set([1, 2, 3]);
        \\assert.compareArray([...symmetricBase.symmetricDifference(setLikeThatReplaces(symmetricBase))], [4]);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Set.prototype.difference has branch ignores entries appended by receiver mutation" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var seen = [];
        \\var set = new Set([1, 2, 3, 4]);
        \\var setLike = {
        \\  size: 100,
        \\  has: function(value) {
        \\    seen.push(value);
        \\    if (seen.length === 1) {
        \\      set.clear();
        \\      set.add(11);
        \\      set.add(22);
        \\    }
        \\    return true;
        \\  },
        \\  keys: function() {
        \\    throw new Test262Error("difference should not call keys when other is larger");
        \\  }
        \\};
        \\assert.compareArray([...set.difference(setLike)], []);
        \\assert.compareArray([...set], [11, 22]);
        \\assert.compareArray(seen, [1, 2, 3, 4]);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "URI globals use observable string coercion and reject malformed UTF-8" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var object = {
        \\  valueOf: function() { return "^"; },
        \\  toString: function() { return " "; }
        \\};
        \\assert.sameValue(encodeURI(object), "%20");
        \\assert.sameValue(encodeURIComponent(object), "%20");
        \\assert.sameValue(decodeURI({ toString: function() { return "%5E"; } }), "^");
        \\assert.sameValue(decodeURIComponent({ toString: function() { return "%5E"; } }), "^");
        \\var originalFromCharCode = String.fromCharCode;
        \\String.fromCharCode = function() { return "patched"; };
        \\assert.sameValue(decodeURI("%F0%A0%80%80") === String.fromCharCode(0xD840, 0xDC00), false);
        \\String.fromCharCode = originalFromCharCode;
        \\var threw = false;
        \\try { decodeURIComponent("%ED%A0%80"); } catch (e) { threw = e instanceof URIError; }
        \\assert.sameValue(threw, true);
        \\assert.sameValue(encodeURI(), "undefined");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "URI four byte decode range preserves globals and completion" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function decimalToPercentHexString(n) {
        \\  var hex = "0123456789ABCDEF";
        \\  return "%" + hex[(n >> 4) & 0xf] + hex[n & 0xf];
        \\}
        \\var count = 0;
        \\for (var indexB3 = 0x80; indexB3 <= 0x80; indexB3++) {
        \\  var hexB1_B2_B3 = "%F0%A0" + decimalToPercentHexString(indexB3);
        \\  for (var indexB4 = 0x80; indexB4 <= 0x83; indexB4++) {
        \\    var hexB1_B2_B3_B4 = hexB1_B2_B3 + decimalToPercentHexString(indexB4);
        \\    var index = (0xF0 & 0x07) * 0x40000 + (0xA0 & 0x3F) * 0x1000 + (indexB3 & 0x3F) * 0x40 + (indexB4 & 0x3F);
        \\    var L = ((index - 0x10000) & 0x03FF) + 0xDC00;
        \\    var H = (((index - 0x10000) >> 10) & 0x03FF) + 0xD800;
        \\    if (decodeURIComponent(hexB1_B2_B3_B4) === String.fromCharCode(H, L)) count++;
        \\  }
        \\}
        \\assert.sameValue(count, 4);
        \\assert.sameValue(indexB3, 0x81);
        \\assert.sameValue(indexB4, 0x84);
        \\assert.sameValue(hexB1_B2_B3, "%F0%A0%80");
        \\assert.sameValue(hexB1_B2_B3_B4, "%F0%A0%80%83");
        \\assert.sameValue(index, 131075);
        \\assert.sameValue(H, 55360);
        \\assert.sameValue(L, 56323);
        \\assert.sameValue(eval(`
        \\function d(n) {
        \\  var hex = "0123456789ABCDEF";
        \\  return "%" + hex[(n >> 4) & 0xf] + hex[n & 0xf];
        \\}
        \\var c = 0;
        \\for (var b3 = 0x80; b3 <= 0x80; b3++) {
        \\  var h3 = "%F0%A0" + d(b3);
        \\  for (var b4 = 0x80; b4 <= 0x83; b4++) {
        \\    var h4 = h3 + d(b4);
        \\    var cp = (0xF0 & 0x07) * 0x40000 + (0xA0 & 0x3F) * 0x1000 + (b3 & 0x3F) * 0x40 + (b4 & 0x3F);
        \\    var lo = ((cp - 0x10000) & 0x03FF) + 0xDC00;
        \\    var hi = (((cp - 0x10000) >> 10) & 0x03FF) + 0xD800;
        \\    if (decodeURI(h4) === String.fromCharCode(hi, lo)) c++;
        \\  }
        \\}
        \\`), 3);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Engine eval builds frozen tagged template objects with raw arrays" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var captured;
        \\(function(strings, value) {
        \\  captured = strings;
        \\  assert.sameValue(value, 1);
        \\})`head${1}tail`;
        \\assert.sameValue(captured[0], "head");
        \\assert.sameValue(captured[1], "tail");
        \\assert.sameValue(captured.raw[0], "head");
        \\assert.sameValue(captured.raw[1], "tail");
        \\assert.sameValue(Object.isExtensible(captured), false);
        \\assert.sameValue(Object.isExtensible(captured.raw), false);
        \\assert.sameValue(Object.getOwnPropertyDescriptor(captured, "raw").enumerable, false);
        \\assert.sameValue(Object.getOwnPropertyDescriptor(captured, "0").writable, false);
        \\assert.sameValue(Object.getOwnPropertyDescriptor(captured, "length").writable, false);
        \\assert.sameValue(Object.getOwnPropertyDescriptor(captured.raw, "length").writable, false);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Engine eval applies tagged template before new invocation" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function Constructor(value) {
        \\  print(value);
        \\}
        \\var tag = function(strings) {
        \\  print(strings[0]);
        \\  return Constructor;
        \\};
        \\var first = new tag`first`;
        \\assert.sameValue(first instanceof Constructor, true);
        \\var second = new tag`second`("arg");
        \\assert.sameValue(second instanceof Constructor, true);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("first\nundefined\nsecond\narg\n", stream.buffered());
}

test "Engine eval permits invalid escapes only in tagged template cooked values" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function(strings) {
        \\  assert.sameValue(strings[0], undefined);
        \\  assert.sameValue(strings.raw[0], "\\xg");
        \\})`\xg`;
        \\(function(strings, value) {
        \\  assert.sameValue(strings[0], undefined);
        \\  assert.sameValue(strings.raw[0], "\\u{10FFFFF}");
        \\  assert.sameValue(strings[1], "right");
        \\  assert.sameValue(value, "inner");
        \\})`\u{10FFFFF}${"inner"}right`;
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Engine eval closures inherit direct eval function declarations" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let objs = [];
        \\function tag(templateObject) {
        \\  objs.push(templateObject);
        \\}
        \\for (let a = 0; a < 2; a++) {
        \\  eval("(function(){ for (let b = 0; b < 2; b++) { tag`${a}${b}`; } })();");
        \\}
        \\print(objs.length);
        \\print(objs[0] === objs[1]);
        \\print(objs[1] === objs[2]);
        \\print(objs[2] === objs[3]);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("4\ntrue\nfalse\ntrue\n", stream.buffered());
}

test "destructured parameter default class keeps initialized parameter bindings" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\let f = ([cls = class {}, named = class Named {}]) => {
        \\  assert.sameValue(cls.name, "cls");
        \\  assert.sameValue(named.name, "Named");
        \\};
        \\f([]);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "top-level lexical destructuring reuses its predeclared global cells" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\let { first } = { first: 1 };
        \\const [second] = [2];
        \\assert.sameValue(first, 1);
        \\assert.sameValue(second, 2);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "for-of var destructuring predeclares generic binding patterns" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var seen = 0;
        \\for (var [first = 23] of [[undefined]]) seen += first;
        \\for (var { value: second } of [{ value: 19 }]) seen += second;
        \\assert.sameValue(seen, 42);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "block function closures keep the current lexical binding cells" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function outer() {
        \\  {
        \\    let z = 4;
        \\    const v = 6;
        \\    function read() { return z + v; }
        \\    assert.sameValue(read(), 10);
        \\  }
        \\}
        \\outer();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "nested assignment patterns preserve yield identifier and expression grammar" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var yield = "key";
        \\var direct = {};
        \\[[direct[yield]]] = [[22]];
        \\assert.sameValue(direct.key, 22);
        \\var suspended = {};
        \\var iterator = (function* () {
        \\  [[suspended[yield]]] = [[23]];
        \\})();
        \\assert.sameValue(iterator.next().done, false);
        \\assert.sameValue(suspended.key, undefined);
        \\assert.sameValue(iterator.next("key").done, true);
        \\assert.sameValue(suspended.key, 23);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "class field initializers inherit QuickJS arguments grammar" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\for (const source of [
        \\  "class C { static value = arguments; }",
        \\  "class C { static value = () => arguments; }",
        \\  "class C { value = arguments; }",
        \\]) {
        \\  let syntax = false;
        \\  try { eval(source); } catch (error) { syntax = error instanceof SyntaxError; }
        \\  assert.sameValue(syntax, true);
        \\}
        \\class Allowed { static method() { return arguments.length; } }
        \\assert.sameValue(Allowed.method(1, 2), 2);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "captured derived this binding can only be initialized once" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\let callSuperAgain;
        \\class Base {}
        \\class Derived extends Base {
        \\  constructor() {
        \\    super();
        \\    callSuperAgain = () => super();
        \\  }
        \\}
        \\new Derived();
        \\assert.throws(ReferenceError, callSuperAgain);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "class name binding is in TDZ throughout its heritage expression" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\for (const source of [
        \\  "class Inner extends Inner {}",
        \\  "class Inner extends (Inner) {}",
        \\  "var Outer = class Inner extends Inner {}",
        \\]) {
        \\  assert.throws(ReferenceError, () => eval(source));
        \\}
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "class static blocks use their installed receiver as the super home object" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function Parent() {}
        \\Parent.inherited = 42;
        \\let observed;
        \\class Child extends Parent {
        \\  static { observed = super.inherited; }
        \\}
        \\assert.sameValue(observed, 42);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "body function declarations reuse same-name parameter bindings" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function declarationWins(x) {
        \\  assert.sameValue(typeof x, "function");
        \\  assert.sameValue(x(), 42);
        \\  function x() { return 42; }
        \\}
        \\declarationWins();
        \\function declarationWinsArguments(arguments) {
        \\  assert.sameValue(typeof arguments, "function");
        \\  function arguments() {}
        \\}
        \\declarationWinsArguments(1);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "parameter-expression and body environments classify body functions by recorded scope" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const f = (p = eval("var arguments = 'parameter'"), read = () => arguments) => {
        \\  function arguments() { return "body"; }
        \\  assert.sameValue(arguments(), "body");
        \\  assert.sameValue(read(), "parameter");
        \\};
        \\f();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "eval source conversion combines valid UTF-16 surrogate pairs" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const rawUnicodePattern = eval(`/\uD83D\uDC38/u`);
        \\assert.sameValue(rawUnicodePattern.test("\u{1F438}"), true);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "invalid opcode reports invalid bytecode without context exception" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    helpers.registerStandardGlobalsBare(rt);
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    var function = try helpers.makeUncheckedFunction(rt, &.{255});
    defer function.deinit(rt);
    try std.testing.expectError(error.InvalidBytecode, runFunction(rt, ctx, &function));
    try std.testing.expect(!ctx.hasException());
}

test "module top-level await works in object computed property names" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalModule(
        \\let o = { [await 9]: 9 };
        \\assert.sameValue(o[await 9], 9);
        \\assert.sameValue(o[String(await 9)], 9);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "module top-level await works in class computed fields inside try" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalModule(
        \\try {
        \\  let C = class {
        \\    [await 9] = 9;
        \\    static [await 9] = 9;
        \\  };
        \\  let c = new C();
        \\  assert.sameValue(c[await 9], 9);
        \\  assert.sameValue(C[await 9], 9);
        \\  assert.sameValue(c[String(await 9)], 9);
        \\  assert.sameValue(C[String(await 9)], 9);
        \\} catch (e) {
        \\  throw e;
        \\}
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

fn fillOwnPropertyStorageForFailure(rt: *core.JSRuntime, object: *core.Object) !void {
    var index: usize = 0;
    while (object.shape_ref.prop_count < object.shape_ref.props().len or object.shape_ref.prop_count < object.shape_ref.props().len) : (index += 1) {
        if (index > 512) return error.TestUnexpectedResult;
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "fill_{d}", .{index});
        const atom_id = try rt.internAtom(name);
        errdefer rt.atoms.free(atom_id);
        try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(core.JSValue.int32(@intCast(index)), true, true, true));
        rt.atoms.free(atom_id);
    }
}
