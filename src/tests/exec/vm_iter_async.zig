const std = @import("std");
const engine = @import("quickjs_zig_engine");

const core = engine.core;
const QjsLexer = engine.frontend.zjs_lexer.Lexer;
const zjs_parser = engine.frontend.zjs_parser;
const ParseState = zjs_parser.ParseState;

const helpers = @import("zjs_vm_helpers.zig");
const parseAndRun = helpers.parseAndRun;
const parseAndRunWithTopLevelChildren = helpers.parseAndRunWithTopLevelChildren;
const parseStmtAndRun = helpers.parseStmtAndRun;
const parseStmtAndRunWithTopLevelChildren = helpers.parseStmtAndRunWithTopLevelChildren;
const expectStringBytes = helpers.expectStringBytes;
const expectSingleCodeUnit = helpers.expectSingleCodeUnit;
const objectFromValue = @import("exec_helpers.zig").objectFromValue;

test "M2.4: qjs_vm executes array for-of iterator protocol" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var sum = 0; for (let x of [1, 2, 3]) { sum = sum + x; } return sum; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 6), result.asInt32().?);
}

test "for-of does not expose cached iterator next state" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var log = [];
        \\  var it = {
        \\    i: 0,
        \\    [Symbol.iterator]: function() { return this; },
        \\    next: function() {
        \\      this.i++;
        \\      return { done: this.i > 1, value: this.i };
        \\    },
        \\  };
        \\  for (var v of it) log.push(v);
        \\  log.push(Object.getOwnPropertyNames(it).join(","));
        \\  log.push("__zjs_iterator_next" in it);
        \\  log.push(Object.getOwnPropertyDescriptor(it, "__zjs_iterator_next") === undefined);
        \\  var sealed = Object.preventExtensions({
        \\    i: 0,
        \\    [Symbol.iterator]: function() { return this; },
        \\    next: function() {
        \\      this.i++;
        \\      return { done: this.i > 1, value: this.i };
        \\    },
        \\  });
        \\  try {
        \\    for (var value of sealed) log.push("sealed:" + value);
        \\    log.push("ok:" + sealed.i);
        \\  } catch (e) {
        \\    log.push(e.name);
        \\  }
        \\  return log.join("|");
        \\})()
    );
    defer result.free(rt);
    try expectStringBytes(result, "1|i,next|false|true|sealed:1|ok:2");
}

test "array destructuring keeps iterator state internal" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var log = [];
        \\  var it = {
        \\    i: 0,
        \\    [Symbol.iterator]: function() { return this; },
        \\    next: function() {
        \\      this.i++;
        \\      return { done: this.i > 2, value: this.i };
        \\    },
        \\  };
        \\  var a, b;
        \\  [a, b] = it;
        \\  log.push(a + ":" + b);
        \\  log.push(Object.getOwnPropertyNames(it).join(","));
        \\  log.push("__zjs_dstr_iterator" in it);
        \\  log.push("__zjs_dstr_index" in it);
        \\  log.push("__zjs_dstr_done" in it);
        \\  var sealed = Object.preventExtensions({
        \\    i: 0,
        \\    [Symbol.iterator]: function() { return this; },
        \\    next: function() {
        \\      this.i++;
        \\      return { done: this.i > 2, value: this.i };
        \\    },
        \\  });
        \\  try {
        \\    var x, y;
        \\    [x, y] = sealed;
        \\    log.push("sealed:" + x + ":" + y + ":" + sealed.i);
        \\  } catch (e) {
        \\    log.push(e.name);
        \\  }
        \\  var rest;
        \\  [...rest] = "ab";
        \\  log.push(rest.join(""));
        \\  return log.join("|");
        \\})()
    );
    defer result.free(rt);
    try expectStringBytes(result, "1:2|i,next|false|false|false|sealed:1:2:2|ab");
}

test "G1/P0: qjs_vm scopes for-in lexical head and simple array binding" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ let outer = 1; var tdz = false; try { for (const outer in { outer }) {} } catch (e) { tdz = e instanceof ReferenceError; } var obj = Object.create(null); obj.key = 1; var value; for (let [x] in obj) { value = x; } return tdz && typeof x === 'undefined' && value === 'k'; })()");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "G1/P0: qjs_vm for-in array head supports defaults" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var probe; for (let [_ = probe = function(){ return 3; }] in { '': 1 }) {} return probe(); })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 3), result.asInt32().?);
}

test "G1/P0: qjs_vm rejects duplicate for-in array head bindings" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    try std.testing.expectError(error.UnexpectedToken, parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ for (let [x, x] in {}) {} })()"));
}

test "F4: qjs_vm accepts of as an ordinary binding name" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var instance = 60; var of = 6; var g = 2; return instance / of / g; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 5), result.asInt32().?);
}

test "M2.4: qjs_vm collection constructors call bytecode adders" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var key = {}; var value = {}; var seen = 0; var original = WeakMap.prototype.set; WeakMap.prototype.set = function(k, v) { seen = (k === key && v === value) ? 1 : 0; return original.call(this, k, v); }; var wm = new WeakMap([[key, value]]); return seen && wm.get(key) === value; })()");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M2.4: qjs_vm WeakMap getOrInsertComputed calls bytecode callback once" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var wm = new WeakMap(); var key = {}; var calls = 0; var first = wm.getOrInsertComputed(key, function(k) { calls = calls + (k === key ? 1 : 100); return 42; }); var second = wm.getOrInsertComputed(key, function() { calls = calls + 10; return 1; }); return first === 42 && second === 42 && wm.get(key) === 42 && calls === 1; })()");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M2.4: qjs_vm WeakMap getOrInsertComputed rejects primitive keys before callback" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var wm = new WeakMap(); var called = 0; for (let key of [1, false, undefined, \"x\", null]) { assert.throws(TypeError, function(){ wm.getOrInsertComputed(key, function(){ called = 1; return 0; }); }); } return called === 0; })()");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M2.4: qjs_vm constructs member Function and uses constructor realm prototype" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var other = $262.createRealm().global; var C = new other.Function(); C.prototype = null; var wm = Reflect.construct(WeakMap, [], C); return Object.getPrototypeOf(wm) === other.WeakMap.prototype; })()");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "G1/P4: qjs_vm dynamic constructor falls back to realm Object prototype" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var other = $262.createRealm().global; other.shared = null; var C = new other.Function('shared = this;'); C.prototype = null; new C(); return Object.getPrototypeOf(other.shared) === other.Object.prototype; })()");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "G1/P0: qjs_vm indirect eval uses escaped realm global" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var x = 'outside'; var result; var eval = $262.createRealm().global.eval; eval('var x = \"inside\";'); result = x; return result === 'outside'; })()");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "G1/P0: qjs_vm cross-realm eval keeps lexical const in the eval realm" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  const outer = 0;
        \\  const hidden = 2;
        \\  var other = $262.createRealm().global;
        \\  other.eval("try { outer = 1; } catch(e) { globalThis.outerError = e.name; }");
        \\  other.eval("function f(){ try { return hidden; } catch(e) { return e.name; } } globalThis.f = f;");
        \\  var realm = $262.createRealm();
        \\  var first = realm.evalScript("const k = 0; try { k = 1; 'no'; } catch(e) { e.name; }");
        \\  var second = realm.evalScript("k");
        \\  var third = realm.evalScript("try { k = 2; 'no'; } catch(e) { e.name; }");
        \\  return outer === 0 &&
        \\    other.outer === 1 &&
        \\    other.f() === "ReferenceError" &&
        \\    first === "TypeError" &&
        \\    second === 0 &&
        \\    third === "TypeError";
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "G1/P0: qjs_vm cross-realm eval for-await uses target realm promise" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(async function(){
        \\  var log = [];
        \\  var other = $262.createRealm().global;
        \\  other.log = log;
        \\  other.eval("async function run(iter) { for await (const value of iter) { log.push(value); break; } }");
        \\  var iter = {
        \\    i: 0,
        \\    [Symbol.iterator]: function() {
        \\      log.push("sync");
        \\      return this;
        \\    },
        \\    next: function() {
        \\      this.i++;
        \\      return { value: Promise.resolve("v" + this.i), done: false };
        \\    },
        \\    return: function() {
        \\      log.push("close");
        \\      return { done: true };
        \\    },
        \\  };
        \\  var promise = other.run(iter);
        \\  var targetPromise = Object.getPrototypeOf(promise) === other.Promise.prototype;
        \\  await promise;
        \\  return targetPromise &&
        \\    log.length === 3 &&
        \\    log[0] === "sync" &&
        \\    log[1] === "v1" &&
        \\    log[2] === "close";
        \\})()
    );
    defer result.free(rt);
    const promise = objectFromValue(result);
    try std.testing.expectEqual(core.class.ids.promise, promise.class_id);
    try engine.exec.zjs_vm.drainPendingPromiseJobs(ctx, null, ctx.cached_global.?);
    const settled = promise.promiseResult().?;
    try std.testing.expectEqual(true, settled.asBool().?);
}

test "G1/P0: qjs_vm cross-realm async generator yield-star uses target realm promise" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(async function(){
        \\  var log = [];
        \\  var other = $262.createRealm().global;
        \\  other.log = log;
        \\  other.eval("async function* values(iter) { return yield* iter; }");
        \\  var iter = {
        \\    i: 0,
        \\    [Symbol.iterator]: function() {
        \\      log.push("sync");
        \\      return this;
        \\    },
        \\    next: function(value) {
        \\      log.push("next:" + value);
        \\      this.i++;
        \\      return { value: "v" + this.i, done: false };
        \\    },
        \\    return: function(value) {
        \\      log.push("return:" + value);
        \\      return { value: "closed", done: true };
        \\    },
        \\  };
        \\  var generator = other.values(iter);
        \\  var firstPromise = generator.next("ignored");
        \\  var firstTargetPromise = Object.getPrototypeOf(firstPromise) === other.Promise.prototype;
        \\  var first = await firstPromise;
        \\  var returnPromise = generator.return("stop");
        \\  var returnTargetPromise = Object.getPrototypeOf(returnPromise) === other.Promise.prototype;
        \\  var done = await returnPromise;
        \\  return firstTargetPromise &&
        \\    returnTargetPromise &&
        \\    first.value === "v1" &&
        \\    first.done === false &&
        \\    done.value === "closed" &&
        \\    done.done === true &&
        \\    log.length === 3 &&
        \\    log[0] === "sync" &&
        \\    log[1] === "next:undefined" &&
        \\    log[2] === "return:stop";
        \\})()
    );
    defer result.free(rt);
    const promise = objectFromValue(result);
    try std.testing.expectEqual(core.class.ids.promise, promise.class_id);
    try engine.exec.zjs_vm.drainPendingPromiseJobs(ctx, null, ctx.cached_global.?);
    const settled = promise.promiseResult().?;
    try std.testing.expectEqual(true, settled.asBool().?);
}

test "G1/P0: qjs_vm scopes class declarations in switch case block" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ try { switch (0) { default: class X {} } X; return false; } catch (e) { return e instanceof ReferenceError; } })()");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "G1/P0: qjs_vm scopes function declarations in switch case block" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ try { switch (0) { default: async function *x() {} } x; return false; } catch (e) { return e instanceof ReferenceError; } })()");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: qjs_vm ignores non-object __proto__ initializer values" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var obj = { __proto__: 1 }; return !obj.hasOwnProperty(\"__proto__\") && Object.getPrototypeOf(obj) === Object.prototype; })()");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: qjs_vm object literal defines own property over inherited readonly" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ Object.defineProperty(Object.prototype, \"prop\", { value: 100, writable: false, configurable: true }); var obj = { prop: 12 }; return obj.hasOwnProperty(\"prop\") && obj.prop === 12; })()");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: qjs_vm preserves computed property evaluation order" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var counter = 0; var obj = { [++counter]: ++counter, [++counter]: ++counter, [++counter]: ++counter }; var keys = Object.getOwnPropertyNames(obj); return keys[0] === \"1\" && obj[1] === 2 && keys[1] === \"3\" && obj[3] === 4 && keys[2] === \"5\" && obj[5] === 6; })()");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: qjs_vm stringifies non-canonical numeric accessor names" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var value; var obj = { get [0.0000001]() { return 7; }, set [0.0000001](v) { value = v; } }; obj[\"1e-7\"] = 9; return obj[\"1e-7\"] === 7 && value === 9; })()");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: qjs_vm throws when computed accessor key cannot convert to property key" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    try std.testing.expectError(error.TypeError, parseAndRunWithTopLevelChildren(rt, ctx, "({ get [Object.create(null)]() { return 1; } })"));
}

test "M3.1 F4: qjs_vm propagates constructed Test262Error" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    try std.testing.expectError(error.Test262Error, parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ throw new Test262Error(); })()"));
}

test "M3.1 F4: qjs_vm assert.throws executes bytecode callbacks" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var thrower = function(){ throw new Test262Error(); }; assert.throws(Test262Error, function(){ ({ get [thrower()]() {} }); }); return 1; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 1), result.asInt32().?);
}

test "M3.1 F4: bytecode function prototype exposes constructor" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ function Test262Error(message) { this.message = message || \"\"; } var err = new Test262Error(); return err.constructor === Test262Error && err.constructor.name === \"Test262Error\"; })()");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: bitwise operators use ToPrimitive number order" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var trace = \"\"; var lhs = { valueOf: function(){ trace += \"l\"; return Symbol(\"x\"); } }; var rhs = { valueOf: function(){ trace += \"r\"; return 1; } }; try { lhs & rhs; } catch (e) { return trace === \"l\" && e instanceof TypeError && (~-5.4321 === ~-5) && (~new Number(-0.1) === -1); } return false; })()");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: script label resolution converges for large shift if chains" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var source = std.ArrayList(u8).empty;
    defer source.deinit(std.testing.allocator);

    for (0..256) |_| {
        try source.appendSlice(std.testing.allocator, "if (-2097152 << 6 !== -134217728) { throw 1; }\n");
    }

    const result = try js.eval(source.items);
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "M3.1 F4: qjs_vm assert.throws runs callback before matching TypeError" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var called = 0; var badKey = Object.create(null); assert.throws(TypeError, function(){ called = 1; ({ get [badKey]() {} }); }); return called; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 1), result.asInt32().?);
}

test "M3.1 F4: direct eval writes caller local object binding" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var o; eval(\"o = {x: 7};\"); return o.x; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 7), result.asInt32().?);
}
