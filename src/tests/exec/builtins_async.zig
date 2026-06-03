const std = @import("std");
const engine = @import("quickjs_zig_engine");

const core = engine.core;
const op = engine.bytecode.opcode.op;

const helpers = @import("exec_helpers.zig");
const makeFunction = helpers.makeFunction;
const runFunction = helpers.runFunction;
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
