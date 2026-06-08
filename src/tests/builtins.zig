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
    var js = try engine.harness.Engine.init(std.testing.allocator);
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
    var js = try engine.harness.Engine.init(std.testing.allocator);
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

    var output_buffer: [160]u8 = undefined;
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

test "dense array indexed append range preserves ordinary set guards" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let fast = [];
        \\for (let i = 0; i < 8; i++) fast[i] = i;
        \\let sum = 0;
        \\for (let i = 0; i < fast.length; i++) sum += fast[i];
        \\print(fast.length, sum, fast[7]);
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
        \\delete Array.prototype[0];
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("8 28 7\n8 0 49 196\n8:0:49\n0:\n2\n99\nfalse\n0:0:\n2\n99\nfalse\n7\n0:0:0:\n2\n99\nfalse\n7\n", stream.buffered());
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

test "Engine direct eval RHS keeps initial assignment reference" {
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
    try std.testing.expectEqualStrings("undefined 1\n2 12\nundefined 1\n", stream.buffered());
}

test "Engine direct eval RHS scanner preserves regexp literals" {
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
    try std.testing.expectEqualStrings("true\ntest262\nabc\n2 10\n", stream.buffered());
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

test "Engine direct eval var shadows readonly global property" {
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
    try std.testing.expectEqualStrings("inside 2 1\nafter 1 1\n", stream.buffered());
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
    var js = try engine.harness.Engine.init(std.testing.allocator);
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

    const map_value = try engine.builtins.collection.construct(rt, 3);
    defer map_value.free(rt);
    const map_object = objectFromValue(map_value);

    const closure_value = try engine.exec.closure.create(rt, 39, 0, 0, 0);
    defer closure_value.free(rt);

    const registered_name = try std.fmt.allocPrint(rt.memory.allocator, "{s}registered", .{engine.builtins.symbol.registry_prefix});
    defer rt.memory.allocator.free(registered_name);
    const registered_atom = try rt.atoms.internSymbol(registered_name);
    defer rt.atoms.free(registered_atom);

    const map_name = try rt.internAtom("map");
    defer rt.atoms.free(map_name);
    const key_name = try rt.internAtom("obj3");
    defer rt.atoms.free(key_name);

    var globals = [_]engine.exec.globals.Slot{
        .{ .name = map_name, .value = map_value.dup() },
        .{ .name = key_name, .value = core.JSValue.symbol(registered_atom) },
    };
    defer globals[0].value.free(rt);

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

    const map_value = try engine.builtins.collection.construct(rt, 3);
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
        const result = try engine.builtins.collection.methodCall(rt, map_value, 1, &.{ key.value(), core.JSValue.int32(@intCast(index)) });
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
    const get_result = try engine.builtins.collection.methodCall(rt, map_value, 2, &.{mutation_key.value()});
    defer get_result.free(rt);
    try helpers.expectStringValueBytes(get_result, "mutated");
}

test "Set.prototype.symmetricDifference tracks receiver mutations without fixture skips" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const base_set_value = try engine.builtins.collection.construct(rt, 2);
    defer base_set_value.free(rt);
    const base_set = objectFromValue(base_set_value);

    inline for (.{ "a", "b", "c", "d", "e", "q" }) |name| {
        const value = (try core.string.String.createUtf8(rt, name)).value();
        defer value.free(rt);
        const out = try engine.builtins.collection.methodCall(rt, base_set_value, 6, &.{value});
        out.free(rt);
    }

    const setlike = try core.Object.create(rt, core.class.ids.object, null);
    const setlike_value = setlike.value();
    defer setlike_value.free(rt);

    const size_key = try rt.internAtom("size");
    defer rt.atoms.free(size_key);
    try setlike.defineOwnProperty(rt, size_key, core.Descriptor.data(core.JSValue.int32(4), true, true, true));

    const mode_key = try rt.internAtom("__setlike_mode");
    defer rt.atoms.free(mode_key);
    try setlike.defineOwnProperty(rt, mode_key, core.Descriptor.data(core.JSValue.int32(5), true, true, true));

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

    const result_value = try engine.builtins.collection.methodCallWithGlobals(rt, base_set_value, 20, &.{setlike_value}, globals[0..]);
    defer result_value.free(rt);
    const result_set = objectFromValue(result_value);

    try expectActiveSetStrings(result_set, &.{ "a", "c", "d", "e", "q", "x" });
    try expectActiveSetStrings(base_set, &.{ "a", "d", "e", "q", "b" });
}

test "host map closure releases appended value when entry allocation fails" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const map_value = try engine.builtins.collection.construct(rt, 1);
    defer map_value.free(rt);
    const map_object = objectFromValue(map_value);

    inline for (.{ 10, 11, 12, 13, 14, 15, 16, 17 }) |key| {
        const result = try engine.builtins.collection.methodCall(rt, map_value, 1, &.{ core.JSValue.int32(key), core.JSValue.int32(key) });
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

    const map_value = try engine.builtins.collection.construct(rt, 1);
    defer map_value.free(rt);
    const map_object = objectFromValue(map_value);

    const first_set = try engine.builtins.collection.methodCall(rt, map_value, 1, &.{ core.JSValue.int32(1), core.JSValue.int32(11) });
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

test "invalid opcode reports invalid bytecode without context exception" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    var function = try makeFunction(rt, &.{250});
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
    while (object.properties.len < object.property_capacity or object.shape_ref.prop_count < object.shape_ref.props.len) : (index += 1) {
        if (index > 512) return error.TestUnexpectedResult;
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "fill_{d}", .{index});
        const atom_id = try rt.internAtom(name);
        errdefer rt.atoms.free(atom_id);
        try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(core.JSValue.int32(@intCast(index)), true, true, true));
        rt.atoms.free(atom_id);
    }
}
