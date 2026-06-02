const std = @import("std");
const engine = @import("quickjs_zig_engine");

const core = engine.core;
const op = engine.bytecode.opcode.op;

const helpers = @import("exec_helpers.zig");
const makeFunction = helpers.makeFunction;
const runFunction = helpers.runFunction;
test "Engine eval allows sloppy arguments binding assignment" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\arguments = 4;
        \\print(arguments);
        \\var eval;
        \\for ([arguments = 5, eval = 6] of [[]]) {
        \\  print(arguments, eval);
        \\}
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("4\n5 6\n", stream.buffered());
}

test "Engine eval advances simple array assignment elisions" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var nextCount = 0;
        \\var returnCount = 0;
        \\var x;
        \\var iterable = {};
        \\var iterator = {
        \\  next: function() {
        \\    nextCount += 1;
        \\    return { done: nextCount > 1, value: 7 };
        \\  },
        \\  return: function() {
        \\    returnCount += 1;
        \\    return {};
        \\  }
        \\};
        \\iterable[Symbol.iterator] = function() {
        \\  return iterator;
        \\};
        \\for ([x, ,] of [iterable]) {}
        \\print(x, nextCount, returnCount);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("7 2 0\n", stream.buffered());
}

test "Engine eval advances elisions without reading values" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var count = 0;
        \\var g = function*() {
        \\  count += 1;
        \\  yield;
        \\  count += 1;
        \\  yield;
        \\  count += 1;
        \\};
        \\var counter = 0;
        \\for ([,,] of [g()]) {
        \\  print(count);
        \\  counter += 1;
        \\}
        \\print(counter);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("2\n1\n", stream.buffered());
}

test "Engine eval assigns simple array pattern member targets in for-of heads" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var target = {};
        \\for ([target.value] of [[41]]) {}
        \\print(target.value);
        \\var closeCount = 0;
        \\var throwing = {
        \\  set value(_) {
        \\    throw new Error("setter");
        \\  }
        \\};
        \\var outer = {};
        \\outer[Symbol.iterator] = function() {
        \\  return {
        \\    next: function() {
        \\      return { done: false, value: [1] };
        \\    },
        \\    return: function() {
        \\      closeCount += 1;
        \\      return {};
        \\    }
        \\  };
        \\};
        \\try {
        \\  for ([throwing.value] of outer) {}
        \\} catch (e) {
        \\  print(e.name, closeCount);
        \\}
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("41\nError 1\n", stream.buffered());
}

test "Engine eval assigns simple array rest targets in for-of heads" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var count = 0;
        \\var g = function*() {
        \\  count += 1;
        \\  yield "a";
        \\  count += 1;
        \\  yield "b";
        \\  count += 1;
        \\};
        \\var rest;
        \\for ([...rest] of [g()]) {
        \\  print(count, rest.length, rest[0], rest[1]);
        \\}
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3 2 a b\n", stream.buffered());
}

test "Engine eval assigns simple array rest member targets in for-of heads" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var target = {};
        \\for ([...target.values] of [[4, 3, 2]]) {}
        \\print(target.values.length, target.values[0], target.values[2]);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3 4 2\n", stream.buffered());
}

test "Engine eval assigns computed array targets in for-of heads" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var key = "slot";
        \\var target = {};
        \\for ([target[key], ...target["rest"]] of [[5, 6, 7]]) {}
        \\print(target.slot, target.rest.length, target.rest[0], target.rest[1]);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("5 2 6 7\n", stream.buffered());
}

test "Engine eval assigns object literal member targets in for-of heads" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var setValue = 0;
        \\for ([{
        \\  get y() { throw new Error("getter"); },
        \\  set y(value) { setValue = value; }
        \\}.y = 42] of [[undefined]]) {}
        \\print(setValue);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("42\n", stream.buffered());
}

test "Engine eval closes destructuring iterators on generator return" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var closed = 0;
        \\var iterator = {
        \\  next() { return { done: false, value: undefined }; },
        \\  return() { closed += 1; return {}; }
        \\};
        \\var iterable = {};
        \\iterable[Symbol.iterator] = function() { return iterator; };
        \\function* g() { for ([{} = yield] of [iterable]) {} }
        \\var iter = g();
        \\print(iter.next().done, closed);
        \\print(iter.return(123).value, closed);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false 0\n123 1\n", stream.buffered());
}

test "Engine eval closes object computed destructuring targets on generator return" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var closed = 0;
        \\var iterator = { return() { closed += 1; return {}; } };
        \\var iterable = {};
        \\iterable[Symbol.iterator] = function() { return iterator; };
        \\function* g() { for ([{}[yield]] of [iterable]) {} }
        \\var iter = g();
        \\print(iter.next().done, closed);
        \\print(iter.return(1).done, closed);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false 0\ntrue 1\n", stream.buffered());
}

test "Engine eval binds const array rest in for-of heads" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\for (const [, ...values] of [[7, 8, 9]]) {
        \\  print(values.length, values[0], values[1]);
        \\}
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("2 8 9\n", stream.buffered());
}

test "Engine eval binds nested const array patterns in for-of heads" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\for (const [[x], ...[y, z]] of [[[1], 2, 3]]) {
        \\  print(x, y, z);
        \\}
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1 2 3\n", stream.buffered());
}

test "Engine eval splits strings with ordinary separators" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var parts = "one.two.".split(".");
        \\print(parts[0], parts[1], parts[2], parts.length);
        \\var chars = "abc".split("", 2);
        \\print(chars[0], chars[1], chars.length);
        \\var whole = "abc".split();
        \\print(whole[0], whole.length);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("one two  3\na b 2\nabc 1\n", stream.buffered());
}

test "Engine eval executes microbench-compatible loop fixtures" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let empty = 0;
        \\for (let i = 0; i < 10; i++) {
        \\}
        \\print(empty);
        \\let obj = { a: 1, b: 2 };
        \\let propSum = 0;
        \\for (let i = 0; i < 10; i++) propSum += obj.a;
        \\print(propSum);
        \\let tab = [3];
        \\let arraySum = 0;
        \\for (let i = 0; i < 10; i++) arraySum += tab[0];
        \\print(arraySum);
        \\function f(x) { return x + 1; }
        \\let callSum = 0;
        \\for (let i = 0; i < 10; i++) callSum += f(i);
        \\print(callSum);
        \\let minSum = 0;
        \\for (let i = 0; i < 10; i++) minSum += Math.min(i, 5);
        \\print(minSum);
        \\function arithmeticLoop(iterations) {
        \\  var acc = 0;
        \\  for (var i = 0; i < iterations; i++) {
        \\    acc = (acc + ((i * 13) ^ (i >>> 1))) | 0;
        \\  }
        \\  return acc;
        \\}
        \\print(arithmeticLoop(10));
        \\function arithmeticWideProduct() {
        \\  var acc = 0;
        \\  var i = 2147483647;
        \\  acc = (acc + ((i * 2147483647) ^ (i >>> 0))) | 0;
        \\  return acc;
        \\}
        \\print(arithmeticWideProduct());
        \\let s = "";
        \\for (let i = 0; i < 10; i++) s += "x";
        \\print(s.length);
        \\let typed = new Int32Array(new ArrayBuffer(16));
        \\print(typed.length);
        \\let map = new Map();
        \\map.set("a", 1);
        \\print(map.delete("a"));
        \\print(map.has("a"));
        \\let weak = new WeakMap();
        \\let key = {};
        \\weak.set(key, 2);
        \\print(weak.delete(key));
        \\print(weak.has(key));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("0\n10\n30\n55\n35\n585\n2147483647\n10\n4\ntrue\nfalse\ntrue\nfalse\n", stream.buffered());
}

test "Engine declared global reads install property inline cache" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var x = 1;
        \\let s = 0;
        \\for (let i = 0; i < 20; i++) s += x;
        \\print(s);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("20\n", stream.buffered());
    try std.testing.expect(profile.totalIcHit() >= 10);
    try std.testing.expect(profile.totalIcMiss() <= 3);
}

test "Engine global int32 stack binary declaration stores before put_var" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var lhs = 131072;
        \\var x = 0xA0;
        \\for (var i = 0; i < 40; i++) {
        \\  var out = lhs + ((x & 63) * 64) + (i & 63);
        \\}
        \\print(out);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("133159\n", stream.buffered());
    try std.testing.expect(profile.count[op.put_var] <= 5);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.add]);
}

test "Engine same global int32 derived declarations fuse second source read" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var index = 131136;
        \\for (var i = 0; i < 40; i++) {
        \\  var L = ((index - 0x10000) & 0x03FF) + 0xDC00;
        \\  var H = (((index - 0x10000) >> 10) & 0x03FF) + 0xD800;
        \\}
        \\print(H, L);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("55360 56384\n", stream.buffered());
    try std.testing.expect(profile.count[op.get_var] <= 90);
    try std.testing.expect(profile.count[op.put_var] <= 5);
}

test "Engine URI-shaped global int32 loops fuse goto16 tail while profiling" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function decimalToPercentHexString(n) {
        \\  var hex = "0123456789ABCDEF";
        \\  return "%" + hex[(n >> 4) & 0xf] + hex[n & 0xf];
        \\}
        \\var count = 0;
        \\for (var repeat = 0; repeat < 1; repeat++) {
        \\  for (var indexB3 = 0x80; indexB3 <= 0x81; indexB3++) {
        \\    var hexB1_B2_B3 = "%F0%A0" + decimalToPercentHexString(indexB3);
        \\    for (var indexB4 = 0x80; indexB4 <= 0x81; indexB4++) {
        \\      var hexB1_B2_B3_B4 = hexB1_B2_B3 + decimalToPercentHexString(indexB4);
        \\      var index = (0xF0 & 0x07) * 0x40000 + (0xA0 & 0x3F) * 0x1000 + (indexB3 & 0x3F) * 0x40 + (indexB4 & 0x3F);
        \\      var L = ((index - 0x10000) & 0x03FF) + 0xDC00;
        \\      var H = (((index - 0x10000) >> 10) & 0x03FF) + 0xD800;
        \\      if (decodeURI(hexB1_B2_B3_B4) === String.fromCharCode(H, L)) count++;
        \\    }
        \\  }
        \\}
        \\print(count);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("4\n", stream.buffered());
    try std.testing.expect(profile.count[op.get_var] <= 20);
    try std.testing.expect(profile.count[op.push_i16] <= 6);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.goto16]);
}

test "Engine empty int32 for loop skips checked-local induction range" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let sum = 0;
        \\for (let i = 0; i < 1000; i++) {
        \\}
        \\print(sum);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("0\n", stream.buffered());
    try std.testing.expect(profile.count[op.get_loc_check] <= 2);
    try std.testing.expect(profile.count[op.post_inc] == 0);
}

test "Engine dense array var-local indexed sum loop fuses range" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function run(iterations) {
        \\  var values = [];
        \\  for (var i = 0; i < iterations; i++) {
        \\    values[i] = (i * 7) & 255;
        \\  }
        \\  var acc = 0;
        \\  for (var j = 0; j < values.length; j++) {
        \\    acc += values[j];
        \\  }
        \\  return acc;
        \\}
        \\print(run(64));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("7200\n", stream.buffered());
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.get_array_el]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.get_length]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.get_loc0_loc1]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.post_inc]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.goto8]);
}

test "Engine int32 arithmetic var-local loop fuses range" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function arithmeticLoop(iterations) {
        \\  var acc = 0;
        \\  for (var i = 0; i < iterations; i++) {
        \\    acc = (acc + ((i * 13) ^ (i >>> 1))) | 0;
        \\  }
        \\  return acc;
        \\}
        \\print(arithmeticLoop(64));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("26208\n", stream.buffered());
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.get_loc0_loc1]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.post_inc]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.goto8]);
}

test "Engine int32 arithmetic range fusion keeps dynamic accumulator limit slow" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function run() {
        \\  var acc = 3;
        \\  for (var i = 0; i < acc; i++) {
        \\    acc = (acc + ((i * 0) ^ (i >>> 31))) | 0;
        \\  }
        \\  return acc;
        \\}
        \\print(run());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3\n", stream.buffered());
    try std.testing.expect(profile.count[op.lt] > 0);
    try std.testing.expect(profile.count[op.if_false8] > 0);
}

test "Engine object field update accumulate loop fuses range" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function objectLoop(iterations) {
        \\  var object = { a: 1, b: 2, c: 3 };
        \\  var acc = 0;
        \\  for (var i = 0; i < iterations; i++) {
        \\    object.a = (object.a + object.b + i) & 1023;
        \\    acc += object.a + object.c;
        \\  }
        \\  return acc;
        \\}
        \\print(objectLoop(64));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("24544\n", stream.buffered());
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.put_field]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.add]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.post_inc]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.goto8]);
}

test "Engine object field range fusion keeps accessor fields slow" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function run(iterations) {
        \\  var hidden = 1;
        \\  var object = { b: 2, c: 3 };
        \\  Object.defineProperty(object, "a", {
        \\    get() { return hidden; },
        \\    set(v) { hidden = v; },
        \\    configurable: true
        \\  });
        \\  var acc = 0;
        \\  for (var i = 0; i < iterations; i++) {
        \\    object.a = (object.a + object.b + i) & 1023;
        \\    acc += object.a + object.c;
        \\  }
        \\  return acc + hidden;
        \\}
        \\print(run(4));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("61\n", stream.buffered());
    try std.testing.expect(profile.count[op.get_field] > 0);
    try std.testing.expect(profile.count[op.put_field] > 0);
}

test "Engine object field range fusion keeps aliased read fields slow" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function aliasRhs(iterations) {
        \\  var object = { a: 1, c: 3 };
        \\  var acc = 0;
        \\  for (var i = 0; i < iterations; i++) {
        \\    object.a = (object.a + object.a + i) & 255;
        \\    acc += object.a + object.c;
        \\  }
        \\  return acc;
        \\}
        \\function aliasAcc(iterations) {
        \\  var object = { a: 1, b: 2 };
        \\  var acc = 0;
        \\  for (var i = 0; i < iterations; i++) {
        \\    object.a = (object.a + object.b + i) & 255;
        \\    acc += object.a + object.a;
        \\  }
        \\  return acc;
        \\}
        \\print(aliasRhs(4), aliasAcc(4));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("58 68\n", stream.buffered());
    try std.testing.expect(profile.count[op.put_field] > 0);
    try std.testing.expect(profile.count[op.add] > 0);
}

test "Engine global var property read accumulate loop fuses range" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var obj = { a: 1, b: 2, c: 3 };
        \\var sum = 0;
        \\for (var i = 0; i < 64; i++) {
        \\  sum += obj.a;
        \\}
        \\print(sum, i);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("64 64\n", stream.buffered());
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.get_field]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.add]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.goto8]);
}

test "Engine global var property read range fusion keeps accessor getter slow" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var calls = 0;
        \\var obj = {};
        \\Object.defineProperty(obj, "a", {
        \\  get() { calls++; return 1; },
        \\  configurable: true
        \\});
        \\var sum = 0;
        \\for (var i = 0; i < 4; i++) {
        \\  sum += obj.a;
        \\}
        \\print(sum, calls);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("4 4\n", stream.buffered());
    try std.testing.expect(profile.count[op.get_field] > 0);
    try std.testing.expect(profile.count[op.goto8] > 0);
}

test "Engine global dense array modulo field read loop fuses range" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var objects = [
        \\  { a: 1, b: 2 },
        \\  { b: 2, a: 1 },
        \\  { c: 3, a: 1, b: 2 },
        \\];
        \\var sum = 0;
        \\for (var i = 0; i < 64; i++) {
        \\  sum += objects[i % 3].a;
        \\}
        \\print(sum, i);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("64 64\n", stream.buffered());
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.get_array_el]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.get_field]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.mod]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.add]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.goto8]);
}

test "Engine global dense array modulo field read range fusion keeps accessor slow" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var calls = 0;
        \\var withAccessor = { b: 2 };
        \\Object.defineProperty(withAccessor, "a", {
        \\  get() { calls++; return 1; },
        \\  configurable: true
        \\});
        \\var objects = [
        \\  { a: 1, b: 2 },
        \\  withAccessor,
        \\  { c: 3, a: 1, b: 2 },
        \\];
        \\var sum = 0;
        \\for (var i = 0; i < 6; i++) {
        \\  sum += objects[i % 3].a;
        \\}
        \\print(sum, calls);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("6 2\n", stream.buffered());
    try std.testing.expect(profile.count[op.get_array_el] > 0);
    try std.testing.expect(profile.count[op.get_field] > 0);
    try std.testing.expect(profile.count[op.goto8] > 0);
}

test "Engine empty int32 for loop keeps const update errors observable" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\try {
        \\  for (const i = 0; i < 2; i++) {
        \\  }
        \\  print("ok");
        \\} catch (e) {
        \\  print(e.name);
        \\}
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("TypeError\n", stream.buffered());
}

test "Engine local field reads fuse through data property inline cache" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function run() {
        \\  var object = { a: 1, b: 2 };
        \\  var sum = 0;
        \\  for (var i = 0; i < 20; i++) sum += object.a + object.b;
        \\  return sum;
        \\}
        \\print(run());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("60\n", stream.buffered());
    try std.testing.expect(profile.totalIcHit() >= 30);
    try std.testing.expect(profile.count[op.get_field] <= 2);
}

test "Engine local arg branch and dropped post update tail fuse" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function step(value) {
        \\  return value + 1;
        \\}
        \\function run(limit) {
        \\  var i = 0;
        \\  var acc = 0;
        \\  while (i < limit) {
        \\    acc = step(acc);
        \\    i++;
        \\  }
        \\  return acc + i;
        \\}
        \\print(run(12));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("24\n", stream.buffered());
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.lt]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.if_false8]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.post_inc]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.goto8]);
}

test "Engine local arg branch keeps object coercion observable" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var calls = 0;
        \\var limit = {
        \\  valueOf() {
        \\    calls++;
        \\    return 3;
        \\  }
        \\};
        \\function run(limit) {
        \\  var i = 0;
        \\  while (i < limit) {
        \\    i++;
        \\  }
        \\  return i;
        \\}
        \\print(run(limit), calls);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3 4\n", stream.buffered());
    try std.testing.expect(profile.count[op.lt] > 0);
    try std.testing.expect(profile.count[op.if_false8] > 0);
}

test "Engine local arg branch reads updated argument slots" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function run(limit) {
        \\  var i = 0;
        \\  while (i < limit) {
        \\    limit = 1;
        \\    i++;
        \\  }
        \\  return i;
        \\}
        \\print(run(3));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\n", stream.buffered());
}

test "Engine dropped local post update folds target local arg branch" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function run(limit) {
        \\  var i = 0;
        \\  while (i < limit) {
        \\    i++;
        \\  }
        \\  return i;
        \\}
        \\print(run(12));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("12\n", stream.buffered());
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.lt]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.if_false8]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.post_inc]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.goto8]);
    try std.testing.expect(profile.count[op.get_loc0] <= 14);
}

test "Engine String.fromCharCode int32 method calls fuse before call_method" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function run() {
        \\  var out = "";
        \\  for (var i = 0; i < 40; i++) {
        \\    out += String.fromCharCode(97 + (i % 26));
        \\  }
        \\  return out;
        \\}
        \\print(run().length);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("40\n", stream.buffered());
    try std.testing.expect(profile.count[op.get_field2] <= 2);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.call_method]);
    try std.testing.expect(profile.count[op.get_var] <= 2);
    try std.testing.expect(profile.count[op.add] <= 2);
}

test "Engine String.fromCharCode append fusion keeps patched method observable" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var saved = String.fromCharCode;
        \\var calls = 0;
        \\String.fromCharCode = function(n) { calls++; return "x"; };
        \\var out = "";
        \\for (var i = 0; i < 4; i++) {
        \\  out += String.fromCharCode(65 + i);
        \\}
        \\String.fromCharCode = saved;
        \\print(out, calls);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("xxxx 4\n", stream.buffered());
}

test "Engine String.fromCharCode append fusion keeps named function shadow observable" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var run = function String() {
        \\  try {
        \\    var out = "";
        \\    for (var i = 0; i < 4; i++) {
        \\      out += String.fromCharCode(65 + i);
        \\    }
        \\    return out;
        \\  } catch (e) {
        \\    return e.name;
        \\  }
        \\};
        \\print(run());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("TypeError\n", stream.buffered());
}

test "Engine String.prototype.slice const local store fuses before call_method" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function run() {
        \\  var text = "abcdefghijklmnopqrstuvwxyz";
        \\  for (var i = 0; i < 20; i++) {
        \\    text = text.slice(1);
        \\  }
        \\  return text;
        \\}
        \\print(run());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("uvwxyz\n", stream.buffered());
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.get_field2]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.call_method]);
}

test "Engine String.prototype.slice const local store keeps patched method slow" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var calls = 0;
        \\var saved = String.prototype.slice;
        \\String.prototype.slice = function(start) {
        \\  calls++;
        \\  return "x" + start;
        \\};
        \\var text = "abcd";
        \\for (var i = 0; i < 4; i++) {
        \\  text = text.slice(1);
        \\}
        \\String.prototype.slice = saved;
        \\print(text, calls);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("x1 4\n", stream.buffered());
    try std.testing.expect(profile.count[op.call_method] > 0);
}

test "Engine string length gt const slice branch fuses local store" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function run() {
        \\  var text = "abcdef";
        \\  for (var i = 0; i < 20; i++) {
        \\    if (text.length > 4) text = text.slice(2);
        \\  }
        \\  return text.length;
        \\}
        \\print(run());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("4\n", stream.buffered());
    try std.testing.expect(profile.count[op.get_length] <= 1);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.get_field2]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.call_method]);
}

test "Engine string length gt const slice branch keeps patched method slow" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var saved = String.prototype.slice;
        \\var calls = 0;
        \\String.prototype.slice = function(start) {
        \\  calls++;
        \\  return "x" + start;
        \\};
        \\function run() {
        \\  var text = "abcdef";
        \\  if (text.length > 4) text = text.slice(2);
        \\  return text;
        \\}
        \\print(run(), calls);
        \\String.prototype.slice = saved;
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("x2 1\n", stream.buffered());
    try std.testing.expect(profile.count[op.call_method] > 0);
}

test "Engine String.fromCharCode append fusion writes back sliced Latin1 strings" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function run() {
        \\  var out = "abcdef";
        \\  out = out.slice(2);
        \\  for (var i = 0; i < 4; i++) {
        \\    out += String.fromCharCode(97 + (i % 26));
        \\  }
        \\  return out;
        \\}
        \\print(run());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("cdefabcd\n", stream.buffered());
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.get_field2]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.call_method]);
}

test "Engine String.fromCharCode append folds following length slice branch" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function run(limit) {
        \\  var out = "";
        \\  for (var i = 0; i < limit; i++) {
        \\    out += String.fromCharCode(97 + (i % 26));
        \\    if (out.length > 4) out = out.slice(2);
        \\  }
        \\  return out;
        \\}
        \\print(run(20));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("qrst\n", stream.buffered());
    try std.testing.expect(profile.count[op.get_loc0] <= 24);
    try std.testing.expect(profile.count[op.get_loc1] <= 2);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.get_length]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.gt]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.lt]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.if_false8]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.post_inc]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.goto8]);
}

test "Engine percent-hex simple string call add-store preserves lhs binding" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function percentHex(n) {
        \\  var hex = "0123456789ABCDEF";
        \\  return "%" + hex[(n >> 4) & 0xf] + hex[n & 0xf];
        \\}
        \\var prefix = "%F0%A0";
        \\var out = "";
        \\for (var i = 0x80; i < 0x84; i++) {
        \\  out = prefix + percentHex(i);
        \\}
        \\print(prefix);
        \\print(out);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("%F0%A0\n%F0%A0%83\n", stream.buffered());
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.put_ref_value]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.add]);
}

test "Engine percent-hex global string declaration initializer skips closure call" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function percentHex(n) {
        \\  var hex = "0123456789ABCDEF";
        \\  return "%" + hex[(n >> 4) & 0xf] + hex[n & 0xf];
        \\}
        \\var prefix = "%F0%A0";
        \\var out = "";
        \\for (var i = 0x80; i < 0x84; i++) {
        \\  var next = prefix + percentHex(i);
        \\  out = next;
        \\}
        \\print(prefix);
        \\print(out);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("%F0%A0\n%F0%A0%83\n", stream.buffered());
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.get_var_ref0]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.add]);
}

test "Engine percent-hex literal declaration initializer skips closure call" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function percentHex(n) {
        \\  var hex = "0123456789ABCDEF";
        \\  return "%" + hex[(n >> 4) & 0xf] + hex[n & 0xf];
        \\}
        \\var out = "";
        \\for (var i = 0x80; i < 0x84; i++) {
        \\  var next = "%F0%A0" + percentHex(i);
        \\  out = next;
        \\}
        \\print(out);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("%F0%A0%83\n", stream.buffered());
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.get_var_ref0]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.add]);
}

test "Engine Math min max primitive method calls fuse before call_method" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function run() {
        \\  var min = 0;
        \\  var max = 0;
        \\  for (var i = 0; i < 40; i++) {
        \\    min = Math.min(i, 5);
        \\    max = Math.max(i, 5);
        \\  }
        \\  return min + max;
        \\}
        \\print(run());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("44\n", stream.buffered());
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.call_method]);
}

test "Engine Math min add loop fuses range from method field" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function run(iterations) {
        \\  var acc = 0;
        \\  for (var i = 0; i < iterations; i++) {
        \\    acc += Math.min(i, 50);
        \\  }
        \\  return acc;
        \\}
        \\print(run(64));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1925\n", stream.buffered());
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.call_method]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.add]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.post_inc]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.goto8]);
}

test "Engine Math min add loop keeps monkey patched method slow" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function run(iterations) {
        \\  var savedMin = Math.min;
        \\  var calls = 0;
        \\  Math.min = function(a, b) { calls++; return b - a; };
        \\  var acc = 0;
        \\  for (var i = 0; i < iterations; i++) {
        \\    acc += Math.min(i, 3);
        \\  }
        \\  Math.min = savedMin;
        \\  return acc + calls;
        \\}
        \\print(run(4));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("10\n", stream.buffered());
    try std.testing.expect(profile.count[op.call_method] > 0);
    try std.testing.expect(profile.count[op.post_inc] > 0);
}

test "Engine local simple numeric call add-store fuses before call2" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function run(n) {
        \\  function add(a, b) { return a + b; }
        \\  var acc = 0;
        \\  for (var i = 0; i < n; i++) acc += add(i, 1);
        \\  return acc;
        \\}
        \\print(run(40));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("820\n", stream.buffered());
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.call2]);
}

test "Engine global simple numeric call add-store fuses before call2" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function add(a, b) { return a + b; }
        \\var acc = 0;
        \\for (var i = 0; i < 40; i++) acc += add(i, 1);
        \\print(acc);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("820\n", stream.buffered());
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.call2]);
}

test "Engine global simple numeric call add-store fuses range before call2" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function add(a, b) { return a + b; }
        \\var acc = 0;
        \\for (var i = 0; i < 64; i++) acc += add(i, 1);
        \\print(acc);
        \\print(i);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("2080\n64\n", stream.buffered());
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.call2]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.add]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.post_inc]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.goto8]);
}

test "Engine closure simple numeric call add-store fuses before call2" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function run(n) {
        \\  function makeAdder(k) {
        \\    return function(x) { return k + x; };
        \\  }
        \\  var add = makeAdder(1);
        \\  var acc = 0;
        \\  for (var i = 0; i < n; i++) acc += add(i);
        \\  return acc;
        \\}
        \\print(run(40));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("820\n", stream.buffered());
    try std.testing.expect(profile.count[op.call1] <= 3);
}

test "Engine global closure simple numeric call add-store fuses range before call1" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function makeAdder(k) {
        \\  return function(x) { return k + x; };
        \\}
        \\var add = makeAdder(1);
        \\var acc = 0;
        \\for (var i = 0; i < 64; i++) acc += add(i);
        \\print(acc);
        \\print(i);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("2080\n64\n", stream.buffered());
    try std.testing.expect(profile.count[op.call1] <= 3);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.add]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.post_inc]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.goto8]);
}

test "Engine global closure call observes captured induction binding" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var i = 0;
        \\var add = function(x) { return i + x; };
        \\var acc = 0;
        \\for (i = 0; i < 4; i++) acc += add(i);
        \\print(acc, i);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("12 4\n", stream.buffered());
}

test "Engine non-simple local function call keeps observable side effects" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var calls = 0;
        \\function run(n) {
        \\  function add(a, b) { calls++; return a + b; }
        \\  var acc = 0;
        \\  for (var i = 0; i < n; i++) acc += add(i, 1);
        \\  return acc;
        \\}
        \\print(run(5), calls);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("15 5\n", stream.buffered());
}

test "Engine non-simple global function call keeps observable side effects" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var calls = 0;
        \\function add(a, b) { calls++; return a + b; }
        \\var acc = 0;
        \\for (var i = 0; i < 5; i++) acc += add(i, 1);
        \\print(acc, calls);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("15 5\n", stream.buffered());
}

test "Engine eval executes primitive property smoke subset" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const arr = [1, 2, 3];
        \\print(arr.length);
        \\print(typeof arr.map);
        \\print(typeof arr.toString);
        \\print("abc".length);
        \\print("abc".charAt(1));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3\nfunction\nfunction\n3\nb\n", stream.buffered());
}

test "Engine eval distinguishes loose and strict equality" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("print(1 == \"1\"); print(1 === \"1\");", &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\nfalse\n", stream.buffered());
}

test "Engine eval exposes basic console methods" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\console.log("log", 1);
        \\console.warn("warn", 2);
        \\console.error("error", 3);
        \\print(typeof console.log, console.log.length);
        \\print(typeof console.warn, console.warn.length);
        \\print(typeof console.error, console.error.length);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "log 1\nwarn 2\nerror 3\nfunction 1\nfunction 1\nfunction 1\n",
        stream.buffered(),
    );
}

test "Runtime memory limit rejects allocations beyond configured cap" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const base = rt.memory.allocated_bytes;
    rt.setMemoryLimit(base + 8);
    try std.testing.expectEqual(@as(?usize, base + 8), rt.memoryLimit());

    const allowed = try rt.memory.alloc(u8, 8);
    defer rt.memory.free(u8, allowed);
    try std.testing.expectError(error.OutOfMemory, rt.memory.alloc(u8, 1));

    rt.setMemoryLimit(null);
    try std.testing.expectEqual(@as(?usize, null), rt.memoryLimit());
    const unbounded = try rt.memory.alloc(u8, 1);
    rt.memory.free(u8, unbounded);
}

test "Atomics waitAsync exposes immediate and async result shapes" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var i32a = new Int32Array(new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT * 4));
        \\var notEqual = Atomics.waitAsync(i32a, 0, 1);
        \\print(typeof Atomics.waitAsync, Atomics.waitAsync.length);
        \\print(notEqual.async, notEqual.value);
        \\var timedOut = Atomics.waitAsync(i32a, 0, 0, 0);
        \\print(timedOut.async, timedOut.value);
        \\var asyncOk = Atomics.waitAsync(i32a, 0, 0);
        \\print(asyncOk.async, asyncOk.value instanceof Promise);
        \\print("__zjs_atomics_wait_async_promise" in asyncOk.value);
        \\print(Object.getOwnPropertyDescriptor(asyncOk.value, "__zjs_atomics_wait_async_promise") === undefined);
        \\asyncOk.value.__zjs_atomics_wait_async_promise = false;
        \\print(asyncOk.value.__zjs_atomics_wait_async_promise === false);
        \\print(delete asyncOk.value.__zjs_atomics_wait_async_promise);
        \\print("__zjs_atomics_wait_async_promise" in asyncOk.value);
        \\print(Atomics.notify(i32a, 0, 1));
        \\asyncOk.value.then(function(value) { print(value); });
        \\var finiteOk = Atomics.waitAsync(i32a, 0, 0, 10);
        \\print(finiteOk.async, finiteOk.value instanceof Promise);
        \\print(Atomics.notify(i32a, 0, 1));
        \\finiteOk.value.then(function(value) { print(value); });
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("function 4\nfalse not-equal\nfalse timed-out\ntrue true\nfalse\ntrue\ntrue\ntrue\nfalse\n1\ntrue true\n1\nok\nok\n", stream.buffered());
}

test "Atomics waitAsync supports BigInt shared typed arrays" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var b64 = new BigInt64Array(new SharedArrayBuffer(BigInt64Array.BYTES_PER_ELEMENT * 2));
        \\var notEqual = Atomics.waitAsync(b64, 0, 1n);
        \\print(notEqual.async, notEqual.value);
        \\var timedOut = Atomics.waitAsync(b64, 0, 0n, 0);
        \\print(timedOut.async, timedOut.value);
        \\var pending = Atomics.waitAsync(b64, 0, 0n);
        \\print(pending.async, pending.value instanceof Promise);
        \\print(Atomics.notify(b64, 0, 1));
        \\pending.value.then(function(value) { print(value); });
        \\try {
        \\  Atomics.waitAsync(new BigUint64Array(new SharedArrayBuffer(BigUint64Array.BYTES_PER_ELEMENT)), 0, 0n);
        \\  print("bad");
        \\} catch (error) {
        \\  print(error.name);
        \\}
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false not-equal\nfalse timed-out\ntrue true\n1\nTypeError\nok\n", stream.buffered());
}

test "Atomics waitAsync pending waiter is released on engine deinit" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var i32a = new Int32Array(new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT));
        \\var pending = Atomics.waitAsync(i32a, 0, 0);
        \\print(pending.async, pending.value instanceof Promise);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true true\n", stream.buffered());
}

test "Atomics waitAsync finite timeout settles expired waiter" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const setup = try js.evalWithOutput(
        \\var timeoutArray = new Int32Array(new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT));
        \\var timeoutResult = Atomics.waitAsync(timeoutArray, 0, 0, 1);
        \\print(timeoutResult.async, timeoutResult.value instanceof Promise);
    , &stream);
    defer setup.free(js.runtime);
    try std.testing.expect(setup.isUndefined());

    std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), std.Io.Duration.fromMilliseconds(3), .awake) catch {};
    const result = try js.evalWithOutput(
        \\timeoutResult.value.then(function(value) { print(value); });
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true true\ntimed-out\n", stream.buffered());
}

test "test262 agent setTimeout uses host timer queue" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var order = [];
        \\print(typeof setTimeout, setTimeout.length);
        \\$262.agent.setTimeout = setTimeout;
        \\$262.agent.setTimeout(function() { order.push("timer"); print(order.join(",")); }, 0);
        \\order.push("script");
        \\print(order.join(","));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("function 2\nscript\nscript,timer\n", stream.buffered());
}

test "top-level function declarations remain visible to timer callbacks" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function assert(mustBeTrue) {
        \\  if (!mustBeTrue) throw new Error("assertion failed");
        \\}
        \\assert.sameValue = function(actual, expected) {
        \\  assert(actual === expected);
        \\};
        \\setTimeout(function() {
        \\  print(typeof assert, typeof assert.sameValue);
        \\  assert.sameValue(1, 1);
        \\}, 0);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("function function\n", stream.buffered());
}

test "top-level self-referential functions remain visible to timer callbacks" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function f() {
        \\  return f;
        \\}
        \\setTimeout(function() {
        \\  print(typeof f());
        \\}, 0);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("function\n", stream.buffered());
}

test "Atomics waitAsync false timeout test262 promise chain resolves" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var i32a = new Int32Array(new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT * 4));
        \\var valueOf = { valueOf: function() { return false; } };
        \\var toPrimitive = { [Symbol.toPrimitive]: function() { return false; } };
        \\Promise.all([
        \\  Atomics.waitAsync(i32a, 0, 0, false).value,
        \\  Atomics.waitAsync(i32a, 0, 0, valueOf).value,
        \\  Atomics.waitAsync(i32a, 0, 0, toPrimitive).value,
        \\]).then(function(outcomes) {
        \\  print(outcomes[0], outcomes[1], outcomes[2]);
        \\}, function(error) {
        \\  print(error.name);
        \\});
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("timed-out timed-out timed-out\n", stream.buffered());
}

test "Atomics waitAsync true timeout test262 polling resolves" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function assert(mustBeTrue) {
        \\  if (!mustBeTrue) throw new Error("assertion failed");
        \\}
        \\assert.sameValue = function(actual, expected) {
        \\  assert(actual === expected);
        \\};
        \\var i32a = new Int32Array(new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT * 4));
        \\var outcomes = [];
        \\var start = $262.agent.monotonicNow();
        \\function wait() {
        \\  if ($262.agent.monotonicNow() - start > 1000) {
        \\    print("timeout");
        \\    return;
        \\  }
        \\  if (outcomes.length) {
        \\    assert.sameValue(outcomes[0], "timed-out");
        \\    assert.sameValue(outcomes[1], "timed-out");
        \\    assert.sameValue(outcomes[2], "timed-out");
        \\    print(outcomes.join(","));
        \\    return;
        \\  }
        \\  $262.agent.setTimeout(wait, 0);
        \\}
        \\wait();
        \\Promise.all([
        \\  Atomics.waitAsync(i32a, 0, 0, true).value,
        \\  Atomics.waitAsync(i32a, 0, 0, { valueOf: function() { return true; } }).value,
        \\  Atomics.waitAsync(i32a, 0, 0, { [Symbol.toPrimitive]: function() { return true; } }).value,
        \\]).then(function(results) {
        \\  outcomes = results;
        \\}, function(error) {
        \\  print(error.name);
        \\});
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("timed-out,timed-out,timed-out\n", stream.buffered());
}

test "Atomics waitAsync timeout runs pre-settlement then callback" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const setup = try js.evalWithOutput(
        \\var callbackArray = new Int32Array(new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT));
        \\var callbackResult = Atomics.waitAsync(callbackArray, 0, 0, 1);
        \\callbackResult.value.then(function(value) { print(value); });
        \\print(callbackResult.async, callbackResult.value instanceof Promise);
    , &stream);
    defer setup.free(js.runtime);
    try std.testing.expect(setup.isUndefined());

    std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), std.Io.Duration.fromMilliseconds(3), .awake) catch {};
    const global = try engine.exec.qjs_vm.ensureContextGlobal(js.context);
    try engine.exec.qjs_vm.drainPendingPromiseJobs(js.context, &stream, global);

    try std.testing.expectEqualStrings("true true\ntimed-out\n", stream.buffered());
}

test "test262 agent broadcast shares SharedArrayBuffer backing store" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    _ = engine.exec.qjs_vm.cleanupTest262Agents();
    const baseline_agents = engine.exec.qjs_vm.test262AgentRecordCountForTests();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\$262.agent.start("$262.agent.receiveBroadcast(function(sab) { var view = new Int32Array(sab); var old = Atomics.add(view, 0, 2); $262.agent.report(old + ':' + Atomics.load(view, 0)); $262.agent.leaving(); });");
        \\var sab = new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT);
        \\var view = new Int32Array(sab);
        \\Atomics.store(view, 0, 40);
        \\$262.agent.broadcast(sab);
        \\var report = null;
        \\for (var i = 0; i < 100 && report === null; i++) {
        \\  report = $262.agent.getReport();
        \\  if (report === null) $262.agent.sleep(1);
        \\}
        \\print(report);
        \\print(Atomics.load(view, 0));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("40:42\n42\n", stream.buffered());

    var attempts: usize = 0;
    while (engine.exec.qjs_vm.test262AgentRecordCountForTests() != baseline_agents and attempts < 100) : (attempts += 1) {
        _ = engine.exec.qjs_vm.cleanupTest262Agents();
        std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    _ = engine.exec.qjs_vm.cleanupTest262Agents();
    try std.testing.expectEqual(baseline_agents, engine.exec.qjs_vm.test262AgentRecordCountForTests());
}

test "Atomics wait honors runtime CanBlock setting for timeout paths" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    try std.testing.expect(!js.runtime.canBlock());
    try std.testing.expectError(error.TypeError, js.eval(
        \\var i32a = new Int32Array(new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT * 4));
        \\Atomics.wait(i32a, 0, 0, 0);
    ));
    if (js.context.hasException()) {
        const thrown = js.context.takeException();
        thrown.free(js.runtime);
    }

    js.runtime.setCanBlock(true);
    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var i32a = new Int32Array(new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT * 4));
        \\print(Atomics.wait(i32a, 0, 1, 0));
        \\print(Atomics.wait(i32a, 0, 0, 0));
        \\print(Atomics.wait(i32a, 0, 0, 1));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("not-equal\ntimed-out\ntimed-out\n", stream.buffered());
}
