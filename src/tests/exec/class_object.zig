const std = @import("std");
const engine = @import("quickjs_zig_engine");

const core = engine.core;
const op = engine.bytecode.opcode.op;

const helpers = @import("exec_helpers.zig");
const makeFunction = helpers.makeFunction;
const runFunction = helpers.runFunction;
test "Engine eval keeps catch destructuring parameter scope lexical" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var probeBefore = function() { return x; };
        \\var probeTry, probeParam;
        \\var x = "outside";
        \\try {
        \\  probeTry = function() { return x; };
        \\  throw ["inside"];
        \\} catch ([x, _ = probeParam = function() { return x; }]) {}
        \\print(probeBefore());
        \\print(probeTry());
        \\print(probeParam());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("outside\noutside\ninside\n", stream.buffered());
}

test "Engine eval rejects return outside function bodies" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    try std.testing.expectError(error.SyntaxError, js.eval("return;"));
    try std.testing.expectError(error.SyntaxError, js.eval("try { return 1; } catch (e) {}"));
    var output_buffer: [16]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("function f() { return 3; } print(f());", &stream);
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3\n", stream.buffered());
}

test "Function lexical constructor metadata is internal" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function C() {
        \\  return () => new.target;
        \\}
        \\var arrow = new C();
        \\assert.sameValue("__zjs_arrow_new_target" in arrow, false);
        \\function Fake() {}
        \\arrow.__zjs_arrow_new_target = Fake;
        \\assert.sameValue(arrow(), C);
        \\
        \\class Base {
        \\  constructor() {
        \\    this.tag = "base";
        \\  }
        \\}
        \\class Other {
        \\  constructor() {
        \\    this.tag = "other";
        \\  }
        \\}
        \\class Derived extends Base {
        \\  constructor() {
        \\    super();
        \\  }
        \\}
        \\assert.sameValue("__zjs_super_constructor" in Derived, false);
        \\Derived.__zjs_super_constructor = Other;
        \\var derived = new Derived();
        \\assert.sameValue(derived.tag, "base");
        \\assert.sameValue(derived instanceof Base, true);
        \\assert.sameValue(derived instanceof Derived, true);
        \\
        \\var arrowSuperResult;
        \\class DerivedArrow extends Base {
        \\  constructor() {
        \\    var callSuper = () => super();
        \\    assert.sameValue("__zjs_arrow_constructor_this" in callSuper, false);
        \\    callSuper.__zjs_arrow_constructor_this = {};
        \\    arrowSuperResult = callSuper();
        \\    return arrowSuperResult;
        \\  }
        \\}
        \\var arrowDerived = new DerivedArrow();
        \\assert.sameValue(arrowDerived, arrowSuperResult);
        \\assert.sameValue(arrowDerived.tag, "base");
        \\assert.sameValue(arrowDerived instanceof Base, true);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Destructuring helpers are internal and cannot be shadowed" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const absence_result = try js.eval(
        \\var helperNames = [
        \\  "__zjs_dstr_get",
        \\  "__zjs_dstr_elide",
        \\  "__zjs_dstr_rest",
        \\  "__zjs_dstr_obj_rest",
        \\  "__zjs_dstr_close",
        \\  "__zjs_dstr_require_iterator"
        \\];
        \\for (var i = 0; i < helperNames.length; i++) {
        \\  assert.sameValue(helperNames[i] in globalThis, false);
        \\  assert.sameValue(Object.getOwnPropertyDescriptor(globalThis, helperNames[i]), undefined);
        \\}
    );
    defer absence_result.free(js.runtime);
    try std.testing.expect(absence_result.isUndefined());

    const result = try js.eval(
        \\var calls = 0;
        \\function hijack() { calls++; return 99; }
        \\var __zjs_dstr_get = hijack;
        \\var __zjs_dstr_elide = hijack;
        \\var __zjs_dstr_rest = hijack;
        \\var __zjs_dstr_obj_rest = hijack;
        \\var __zjs_dstr_close = hijack;
        \\var __zjs_dstr_require_iterator = hijack;
        \\
        \\var [x, , ...rest] = [1, 2, 3, 4];
        \\assert.sameValue(x, 1);
        \\assert.sameValue(rest.length, 2);
        \\assert.sameValue(rest[0], 3);
        \\assert.sameValue(rest[1], 4);
        \\
        \\var { a, ...objRest } = { a: 1, b: 2, c: 3 };
        \\assert.sameValue(a, 1);
        \\assert.sameValue(objRest.b, 2);
        \\assert.sameValue(objRest.c, 3);
        \\
        \\var closed = false;
        \\function* values() {
        \\  try {
        \\    yield 5;
        \\    yield 6;
        \\  } finally {
        \\    closed = true;
        \\  }
        \\}
        \\var [g] = values();
        \\assert.sameValue(g, 5);
        \\assert.sameValue(closed, true);
        \\assert.sameValue(calls, 0);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Var destructuring bindings are hoisted for closure capture" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var readCaptured = function() { return captured; };
        \\var { captured } = { captured: 7 };
        \\assert.sameValue(readCaptured(), 7);
        \\
        \\var arr = [];
        \\var { proxy, revoke } = Proxy.revocable(arr, {
        \\  get: function(target, key, receiver) {
        \\    assert.sameValue(target, arr);
        \\    assert.sameValue(key, "length");
        \\    assert.sameValue(receiver, proxy);
        \\    assert.sameValue(typeof revoke, "function");
        \\    revoke();
        \\    return 0;
        \\  }
        \\});
        \\assert.sameValue(JSON.stringify({ a: 0 }, proxy), "{}");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Engine eval scopes class static await binding early errors to function boundaries" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    try std.testing.expectError(error.SyntaxError, js.eval("class C { static { function await() {} } }"));
    try std.testing.expectError(error.SyntaxError, js.eval("class C { static { let await; } }"));
    try std.testing.expectError(error.SyntaxError, js.eval("class C { static { const await = 0; } }"));
    const result = try js.eval("class C { static { (() => { function await() {} }); } }");
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
    const let_result = try js.eval("class D { static { (() => { let await; const alsoAwait = 1; }); } }");
    defer let_result.free(js.runtime);
    try std.testing.expect(let_result.isUndefined());
    const const_result = try js.eval("class E { static { (() => { const await = 0; }); } }");
    defer const_result.free(js.runtime);
    try std.testing.expect(const_result.isUndefined());
}

test "Engine eval routes labelled break and continue inside statement boundary" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var block = 0;
        \\label_block: { block = 1; break label_block; block = 2; }
        \\print(block);
        \\var count = 0;
        \\outer: for (var i = 0; i < 3; i++) {
        \\  for (var j = 0; j < 3; j++) {
        \\    count++;
        \\    continue outer;
        \\  }
        \\}
        \\print(i, count);
        \\var object = {p1: 1, p2: 1};
        \\var result = 0;
        \\label_for_in: for (var key in object) {
        \\  result += object[key];
        \\  break label_for_in;
        \\}
        \\print(result);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\n3 3\n1\n", stream.buffered());
    try std.testing.expectError(error.SyntaxError, js.eval("outer: while (false) { function nestedBreak() { break outer; } }"));
    try std.testing.expectError(error.SyntaxError, js.eval("outer: while (false) { class C { static { continue outer; } } }"));
}

test "Engine eval concatenates ordinary arrays" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var left = new Array("Saab", "Volvo");
        \\var right = new Array("Mercedes", "Jeep");
        \\var e = left.concat(right);
        \\print(e[0], e[1], e[2], e[3], e.length);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("Saab Volvo Mercedes Jeep 4\n", stream.buffered());
}

test "Engine eval reverses and sorts ordinary arrays" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var values = [3, 10, 2];
        \\print(values.reverse() === values, values.join(","));
        \\print(values.sort() === values, values.join(","));
        \\var ranked = [4,3,2,1,4,3,2,1,4,3,2,1];
        \\ranked.sort(function(x, y) {
        \\  if (x > y) return -1;
        \\  if (x < y) return 1;
        \\  return 0;
        \\});
        \\print(ranked.join(","));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true 2,10,3\ntrue 10,2,3\n4,4,4,3,3,3,2,2,2,1,1,1\n", stream.buffered());
}

test "Engine eval calls dense array element functions without corrupting method stack" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var direct = [function() { return 1; }];
        \\print(typeof direct[0], direct[0]());
        \\let f = [undefined, undefined, undefined];
        \\for (let x of [1, 2, 3]) {
        \\  f[x - 1] = function() { return x; };
        \\}
        \\print(f[0](), f[1](), f[2]());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("function 1\n1 2 3\n", stream.buffered());
}

test "Engine eval exposes Array iterator prototype methods" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var array = ["a", , "c"];
        \\print(Array.prototype[Symbol.iterator] === Array.prototype.values);
        \\var values = "";
        \\for (var value of array.values()) values += String(value) + ",";
        \\print(values);
        \\var keys = "";
        \\for (var key of array.keys()) keys += key + ",";
        \\print(keys);
        \\var entries = "";
        \\for (var entry of array.entries()) entries += entry[0] + ":" + String(entry[1]) + ",";
        \\print(entries);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\na,undefined,c,\n0,1,2,\n0:a,1:undefined,2:c,\n", stream.buffered());
}

test "Array.prototype.splice consults custom species for max safe delete count" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function StopSplice() {}
        \\var traps = [];
        \\var targetLength;
        \\var target = new Proxy([], {
        \\  defineProperty: function(t, pk, desc) {
        \\    traps.push("target.[[DefineProperty]]:" + String(pk));
        \\    if (pk === "0" || pk === "1") {
        \\      return Reflect.defineProperty(t, pk, desc);
        \\    }
        \\    throw new StopSplice();
        \\  }
        \\});
        \\var array = ["no-hole", , "stop"];
        \\array.constructor = {
        \\  [Symbol.species]: function(n) {
        \\    targetLength = n;
        \\    return target;
        \\  }
        \\};
        \\var source = new Proxy(array, {
        \\  get: function(t, pk, r) {
        \\    traps.push("source.[[Get]]:" + String(pk));
        \\    if (pk === "length") return Math.pow(2, 53) + 2;
        \\    return Reflect.get(t, pk, r);
        \\  },
        \\  has: function(t, pk) {
        \\    traps.push("source.[[Has]]:" + String(pk));
        \\    return Reflect.has(t, pk);
        \\  }
        \\});
        \\assert.throws(StopSplice, function() {
        \\  Array.prototype.splice.call(source, 0, Math.pow(2, 53) + 4);
        \\});
        \\assert.sameValue(targetLength, Math.pow(2, 53) - 1);
        \\assert.sameValue(traps.join("|"), [
        \\  "source.[[Get]]:length",
        \\  "source.[[Get]]:constructor",
        \\  "source.[[Has]]:0",
        \\  "source.[[Get]]:0",
        \\  "target.[[DefineProperty]]:0",
        \\  "source.[[Has]]:1",
        \\  "source.[[Has]]:2",
        \\  "source.[[Get]]:2",
        \\  "target.[[DefineProperty]]:2",
        \\].join("|"));
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Engine eval array iterator next observes accessors and iterator kind" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var array = [0];
        \\Object.defineProperty(array, "0", {
        \\  get: function() {
        \\    print("get");
        \\    return 7;
        \\  }
        \\});
        \\for (var value of array.values()) print(value);
        \\for (var key of array.keys()) print(key);
        \\for (var entry of array.entries()) print(entry[0], entry[1]);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("get\n7\n0\nget\n0 7\n", stream.buffered());
}

test "Engine eval iterates mapped and unmapped arguments objects" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function mapped() {
        \\  var out = "";
        \\  for (var value of arguments) out += String(value) + ",";
        \\  print(out);
        \\}
        \\function unmapped() {
        \\  "use strict";
        \\  var out = "";
        \\  for (var value of arguments) out += String(value) + ",";
        \\  print(out);
        \\}
        \\mapped(0, "a", true);
        \\unmapped(1, "b", false);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("0,a,true,\n1,b,false,\n", stream.buffered());
}

test "Engine eval mapped arguments iteration observes parameter aliases" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function alias(a, b, c) {
        \\  var out = "";
        \\  for (var value of arguments) {
        \\    out += value + ",";
        \\    a = b;
        \\    b = c;
        \\    c = 1;
        \\  }
        \\  print(out);
        \\}
        \\function mutate(a, b, c) {
        \\  arguments[1] = 6;
        \\  delete arguments[0];
        \\  arguments[0] = 9;
        \\  print(a, b, arguments[0]);
        \\}
        \\alias(1, 2, 3);
        \\mutate(4, 5, 6);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1,3,1,\n4 6 9\n", stream.buffered());
}

test "Engine eval arguments iteration observes own iterator overrides" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function printSpread(label, args) {
        \\  var out = label + ":";
        \\  for (var value of args) out += value + ",";
        \\  print(out);
        \\}
        \\function mapped(a, b, c) {
        \\  arguments[Symbol.iterator] = function*() {
        \\    yield 40;
        \\    yield 50;
        \\    yield 60;
        \\  };
        \\  printSpread("mapped", arguments);
        \\}
        \\function unmapped([a], b, c) {
        \\  arguments[Symbol.iterator] = function*() {
        \\    yield 70;
        \\    yield 80;
        \\    yield 90;
        \\  };
        \\  printSpread("unmapped", arguments);
        \\}
        \\mapped(10, 20, 30);
        \\unmapped([10], 20, 30);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("mapped:40,50,60,\nunmapped:70,80,90,\n", stream.buffered());
}

test "Engine eval iterates generators directly in for-of" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function* values() {
        \\  yield 1;
        \\  yield 2;
        \\}
        \\function* guarded() {
        \\  yield 1;
        \\  throw new Error("unreachable");
        \\}
        \\var sum = 0;
        \\for (var value of values()) sum += value;
        \\print(sum);
        \\var count = 0;
        \\for (var item of guarded()) {
        \\  count++;
        \\  break;
        \\}
        \\print(count);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3\n1\n", stream.buffered());
}

test "Engine eval top-level var for-of updates closure-visible binding" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var x;
        \\var f = function() { print("f", x); };
        \\for (var x of [true, false]) {
        \\  print("top", x);
        \\  f();
        \\}
        \\globalThis.x = "global";
        \\print("after", x);
        \\f();
        \\var y;
        \\var g = function() { print("g", y); };
        \\for (var [y] of [[1], [2]]) {
        \\  g();
        \\}
        \\print("after-y", y);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("top true\nf true\ntop false\nf false\nafter global\nf global\ng 1\ng 2\nafter-y 2\n", stream.buffered());
}

test "Engine eval assigns simple array patterns in for-of heads" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var first, second;
        \\for ([first, second] of [[1, 2], [3, 4]]) {
        \\  print(first, second);
        \\}
        \\print(first, second);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1 2\n3 4\n3 4\n", stream.buffered());
}

test "Engine eval assigns simple array pattern defaults in for-of heads" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var x, y, flag, counter = 0;
        \\for ([x = 10, y = 11] of [[2], []]) {
        \\  print(x, y);
        \\}
        \\for ([flag = "x" in {}] of [[]]) {
        \\  print(flag);
        \\}
        \\try {
        \\  for ([x = later] of [[]]) counter += 1;
        \\} catch (e) {
        \\  print(e.name, counter);
        \\}
        \\let later;
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("2 11\n10 11\nfalse\nReferenceError 0\n", stream.buffered());
}

test "Engine eval checks empty and elision array patterns in for-of heads" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var counter = 0;
        \\try {
        \\  for ([] of [1]) counter += 1;
        \\} catch (e) {
        \\  print(e.name, counter);
        \\}
        \\var value;
        \\for ([, value] of [[1, 2]]) print(value);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("TypeError 0\n2\n", stream.buffered());
}

test "Engine eval closes for-of iterator when member head assignment throws" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var callCount = 0;
        \\var bodyCount = 0;
        \\var iterable = {};
        \\var target = {
        \\  set attr(_) {
        \\    throw new Error("boom");
        \\  }
        \\};
        \\iterable[Symbol.iterator] = function() {
        \\  return {
        \\    next: function() {
        \\      return { done: false, value: 1 };
        \\    },
        \\    return: function() {
        \\      callCount += 1;
        \\      return {};
        \\    }
        \\  };
        \\};
        \\try {
        \\  for (target.attr of iterable) {
        \\    bodyCount += 1;
        \\  }
        \\} catch (e) {
        \\  print(e.name, bodyCount, callCount);
        \\}
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("Error 0 1\n", stream.buffered());
}

test "Engine eval does not close for-of iterator when next or value throws" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var nextReturnCount = 0;
        \\var nextBodyCount = 0;
        \\var nextIterable = {};
        \\nextIterable[Symbol.iterator] = function() {
        \\  return {
        \\    next: function() {
        \\      throw new Test262Error();
        \\    },
        \\    return: function() {
        \\      nextReturnCount += 1;
        \\      return {};
        \\    }
        \\  };
        \\};
        \\assert.throws(Test262Error, function() {
        \\  for (var x of nextIterable) {
        \\    nextBodyCount += 1;
        \\  }
        \\});
        \\var valueReturnCount = 0;
        \\var valueBodyCount = 0;
        \\var valueIterable = {};
        \\valueIterable[Symbol.iterator] = function() {
        \\  return {
        \\    next: function() {
        \\      return {
        \\        done: false,
        \\        get value() {
        \\          throw new Test262Error();
        \\        }
        \\      };
        \\    },
        \\    return: function() {
        \\      valueReturnCount += 1;
        \\      return {};
        \\    }
        \\  };
        \\};
        \\assert.throws(Test262Error, function() {
        \\  for (var y of valueIterable) {
        \\    valueBodyCount += 1;
        \\  }
        \\});
        \\print(nextBodyCount, nextReturnCount, valueBodyCount, valueReturnCount);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("0 0 0 0\n", stream.buffered());
}

test "Engine eval ignores spoofed async iterator marker during sync IteratorClose" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var log = [];
        \\var iterator = {
        \\  __zjs_async_iterator: true,
        \\  [Symbol.iterator]: function() {
        \\    return this;
        \\  },
        \\  next: function() {
        \\    return { done: false, value: 1 };
        \\  },
        \\  return: function() {
        \\    log.push("return");
        \\    return Promise.reject("bad");
        \\  }
        \\};
        \\try {
        \\  for (var value of iterator) break;
        \\  log.push("ok");
        \\} catch (e) {
        \\  log.push("throw:" + e);
        \\}
        \\print(log.join(","));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("return,ok\n", stream.buffered());
}

test "Engine eval caches for-of next method from iterator prologue" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var iterable = {};
        \\var iterator = {};
        \\var iterationCount = 0;
        \\var loadNextCount = 0;
        \\iterable[Symbol.iterator] = function() {
        \\  return iterator;
        \\};
        \\function next() {
        \\  if (iterationCount) return { done: true };
        \\  return { value: 45, done: false };
        \\}
        \\Object.defineProperty(iterator, "next", {
        \\  get: function() {
        \\    loadNextCount += 1;
        \\    return next;
        \\  },
        \\  configurable: true
        \\});
        \\for (var x of iterable) {
        \\  print(x);
        \\  Object.defineProperty(iterator, "next", {
        \\    get: function() {
        \\      throw new Error("next reloaded");
        \\    }
        \\  });
        \\  iterationCount += 1;
        \\}
        \\print(iterationCount, loadNextCount);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("45\n1 1\n", stream.buffered());
}

test "Engine eval propagates nested for-of body throw without restarting callback" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function Test262Error(message) { this.message = message || ""; }
        \\var iterationCount = 0;
        \\var iterable = {};
        \\iterable[Symbol.iterator] = function() {
        \\  return {
        \\    next: function() { return { done: false, value: null }; },
        \\    get return() { throw { name: "inner error" }; }
        \\  };
        \\};
        \\function probe(callback) {
        \\  try { callback(); } catch (thrown) { print(thrown.constructor === Test262Error, iterationCount); return; }
        \\  print("no throw");
        \\}
        \\probe(function() {
        \\  for (var x of iterable) {
        \\    iterationCount += 1;
        \\    throw new Test262Error("outer");
        \\  }
        \\});
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true 1\n", stream.buffered());
}

test "Engine eval does not close for-of iterator for throws caught inside loop body" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function* values() {
        \\  yield 1;
        \\  yield 1;
        \\}
        \\var caught = 0;
        \\for (var x of values()) {
        \\  try {
        \\    throw new Error();
        \\  } catch (err) {
        \\    caught++;
        \\    continue;
        \\  }
        \\}
        \\print(caught);
        \\var closed = 0;
        \\var iter = {
        \\  next: function() { return { done: false, value: 1 }; },
        \\  return: function() { closed++; return {}; }
        \\};
        \\var iterable = {};
        \\iterable[Symbol.iterator] = function() { return iter; };
        \\try {
        \\  for (var y of iterable) throw new Error();
        \\} catch (err) {}
        \\print(closed);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("2\n1\n", stream.buffered());
}

test "Engine eval routes labelled control from finally across for-of cleanup" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function* once() {
        \\  yield 1;
        \\  throw new Test262Error("closed");
        \\}
        \\var breaks = 0;
        \\outerBreak:
        \\while (true) {
        \\  for (var x of once()) {
        \\    try {
        \\    } finally {
        \\      breaks++;
        \\      break outerBreak;
        \\    }
        \\  }
        \\}
        \\print(breaks);
        \\function* twice() {
        \\  yield 1;
        \\  yield 2;
        \\}
        \\var loop = true;
        \\var continues = 0;
        \\outerContinue:
        \\while (loop) {
        \\  loop = false;
        \\  for (var y of twice()) {
        \\    try {
        \\      throw new Error();
        \\    } catch (err) {
        \\    } finally {
        \\      continues++;
        \\      continue outerContinue;
        \\    }
        \\  }
        \\}
        \\print(continues);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\n1\n", stream.buffered());
}

test "Engine eval uses temporary TDZ scope for lexical for-of head expression" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let x = "outside";
        \\var probeExpr, probeDecl, probeBody;
        \\for (
        \\  let [x, _ = probeDecl = function() { return x; }]
        \\  of
        \\  (probeExpr = function() { typeof x; }, [["inside"]])
        \\) {
        \\  probeBody = function() { return x; };
        \\}
        \\try {
        \\  probeExpr();
        \\  print("expr ok");
        \\} catch (err) {
        \\  print(err.name);
        \\}
        \\print(probeDecl(), probeBody());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("ReferenceError\ninside inside\n", stream.buffered());
}

test "Engine eval rejects non-object destructuring iterator close result" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var iterable = {};
        \\var iterator = {
        \\  next: function() {
        \\    return { done: true };
        \\  },
        \\  return: function() {
        \\    return null;
        \\  }
        \\};
        \\iterable[Symbol.iterator] = function() {
        \\  return iterator;
        \\};
        \\var counter = 0;
        \\try {
        \\  for ([] of [iterable]) {
        \\    counter += 1;
        \\  }
        \\  counter += 1;
        \\} catch (e) {
        \\  print(e.name, counter);
        \\}
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("TypeError 0\n", stream.buffered());
}

test "Engine eval closes simple array assignment head iterators" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var nextCount = 0;
        \\var returnCount = 0;
        \\var item;
        \\var iterable = {};
        \\var iterator = {
        \\  next: function() {
        \\    nextCount += 1;
        \\    return { done: false, value: 42 };
        \\  },
        \\  return: function() {
        \\    returnCount += 1;
        \\    return {};
        \\  }
        \\};
        \\iterable[Symbol.iterator] = function() {
        \\  return iterator;
        \\};
        \\for ([item] of [iterable]) {}
        \\print(item, nextCount, returnCount);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("42 1 1\n", stream.buffered());
}

test "Engine eval closes destructuring assignment iterator once when target throws" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function MyError() {}
        \\var target = {
        \\  set a(v) {
        \\    throw new MyError();
        \\  }
        \\};
        \\var returnGetterCalled = 0;
        \\var iterator = {
        \\  [Symbol.iterator]: function() {
        \\    return this;
        \\  },
        \\  next: function() {
        \\    return { done: false };
        \\  },
        \\  get return() {
        \\    returnGetterCalled += 1;
        \\    throw "bad";
        \\  }
        \\};
        \\try {
        \\  ([target.a] = iterator);
        \\} catch (e) {
        \\  print(e instanceof MyError, e === "bad");
        \\}
        \\print(returnGetterCalled);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true false\n1\n", stream.buffered());
}

test "Engine eval logical assignment statements discard result without stack underflow" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var a = 0;
        \\a ||= 1;
        \\print(a);
        \\var b = 1;
        \\b &&= 2;
        \\print(b);
        \\var c = null;
        \\c ??= 3;
        \\print(c);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\n2\n3\n", stream.buffered());
}

test "Engine eval assignment expressions produce call argument values" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var a = 0;
        \\print(a ||= 1);
        \\print(a);
        \\var b = 1;
        \\print(b += 2);
        \\print(b);
        \\var o = { x: 0 };
        \\print(o.x ||= 4);
        \\print(o.x);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\n1\n3\n3\n4\n4\n", stream.buffered());
}

test "Engine eval class fields do not call preceding function declarations" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function Test262Error() {}
        \\function shouldNotRun() { throw "bad"; }
        \\class C {
        \\  #field = false;
        \\  field = true;
        \\  value() {
        \\    return this.field && !this.#field;
        \\  }
        \\}
        \\print(new C().value());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\n", stream.buffered());
}

test "Engine eval class field direct eval can use super property" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var executed = false;
        \\class A {}
        \\class C extends A {
        \\  x = eval("executed = true; super.x;");
        \\}
        \\new C();
        \\print(executed);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\n", stream.buffered());
}

test "Engine eval native builtin subclass constructors use new target prototype" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const SubInt8Array = class extends Int8Array {};
        \\const typed = new SubInt8Array();
        \\print(typed instanceof SubInt8Array);
        \\print(typed instanceof Int8Array);
        \\print(Object.getPrototypeOf(typed) === SubInt8Array.prototype);
        \\const SubWeakRef = class extends WeakRef {};
        \\const target = {};
        \\const ref = new SubWeakRef(target);
        \\print(ref instanceof SubWeakRef);
        \\print(ref instanceof WeakRef);
        \\print(Object.getPrototypeOf(ref) === SubWeakRef.prototype);
        \\print(ref.deref() === target);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\ntrue\ntrue\ntrue\ntrue\ntrue\ntrue\n", stream.buffered());
}

test "Engine eval super property reads consume explicit receiver" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\class B {
        \\  get x() { return 2; }
        \\  method() { return 1; }
        \\}
        \\function id(value) { return value; }
        \\class C extends B {
        \\  method() {
        \\    return id(super.x) + super.method();
        \\  }
        \\}
        \\print(new C().method());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3\n", stream.buffered());
}

test "Engine eval default derived constructors install private methods" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\class Base {
        \\  method() { return "base"; }
        \\}
        \\class Derived extends Base {
        \\  #plain() { return 4; }
        \\  #super() { return super.method(); }
        \\  plain() { return this.#plain(); }
        \\  fromSuper() { return this.#super(); }
        \\}
        \\const value = new Derived();
        \\print(value.plain());
        \\print(value.fromSuper());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("4\nbase\n", stream.buffered());
}

test "Engine eval explicit super constructors install private methods" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\class Base {
        \\  constructor(seal) {
        \\    if (seal) Object.preventExtensions(this);
        \\  }
        \\}
        \\class Derived extends Base {
        \\  constructor(seal) { super(seal); }
        \\  #method() { return 42; }
        \\  get #accessor() { return 43; }
        \\  method() { return this.#method(); }
        \\  get accessor() { return this.#accessor; }
        \\}
        \\print(new Derived(false).method());
        \\print(new Derived(false).accessor);
        \\try { new Derived(true); print("bad"); } catch (e) { print(e.name); }
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("42\n43\nTypeError\n", stream.buffered());
}

test "Engine eval private fields respect non-extensible objects" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\class NonExtensibleBase {
        \\  constructor(seal) {
        \\    if (seal) Object.preventExtensions(this);
        \\  }
        \\}
        \\class WithPrivateField extends NonExtensibleBase {
        \\  #value = 42;
        \\  value() { return this.#value; }
        \\}
        \\print(new WithPrivateField(false).value());
        \\try { new WithPrivateField(true); print("bad"); } catch (e) { print(e.name); }
        \\
        \\class OverrideBase {
        \\  constructor(value) { return value; }
        \\}
        \\class StampedPrivate extends OverrideBase {
        \\  #value = 1;
        \\  static get(value) { return value.#value; }
        \\  static inc(value) { value.#value++; }
        \\}
        \\const stamped = {};
        \\new StampedPrivate(stamped);
        \\Object.freeze(stamped);
        \\StampedPrivate.inc(stamped);
        \\print(Object.isFrozen(stamped));
        \\print(StampedPrivate.get(stamped));
        \\try { new StampedPrivate(Object.preventExtensions({})); print("bad"); } catch (e) { print(e.name); }
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("42\nTypeError\ntrue\n2\nTypeError\n", stream.buffered());
}

test "Engine eval derived constructors reject primitive explicit returns" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\class Base {}
        \\class Derived extends Base {
        \\  constructor() {
        \\    super();
        \\    return Symbol();
        \\  }
        \\}
        \\try { new Derived(); print("bad"); } catch (e) { print(e.name); }
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("TypeError\n", stream.buffered());
}
