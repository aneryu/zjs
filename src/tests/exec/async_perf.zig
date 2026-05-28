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
    try std.testing.expectEqualStrings("0\n10\n30\n55\n35\n10\n4\ntrue\nfalse\ntrue\nfalse\n", stream.buffered());
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
