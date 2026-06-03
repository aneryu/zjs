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
test "M3.1 F4: Object prototype Annex B accessors are callable" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var o = {}; var g = function(){ return 7; }; o.__defineGetter__('x', g); return o.__lookupGetter__('x') === g; })()");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: Object prototype __proto__ accessor mutates ordinary prototypes" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var o = {}; var p = {}; o.__proto__ = p; return Object.getPrototypeOf(o) === p; })()");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: Object prototype methods handle null and primitive wrappers" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var n = new Object(3); return Object.prototype.toString.call(null) + '|' + Object.prototype.toString.call(n) + '|' + n.valueOf(); })()");
    defer result.free(rt);
    try expectStringBytes(result, "[object Null]|[object Number]|3");
}

test "M3.1 F4: Object.defineProperty reads accessor descriptors through VM semantics" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var o = {}; Object.defineProperty(o, 'x', { get: function(){ return 3; }, enumerable: 12 }); var d = Object.getOwnPropertyDescriptor(o, 'x'); return o.x + '|' + (typeof d.get) + '|' + d.enumerable; })()");
    defer result.free(rt);
    try expectStringBytes(result, "3|function|true");
}

test "M3.1 F4: Object.defineProperty rejects mixed data and accessor descriptors" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ try { Object.defineProperty({}, 'x', { get: function(){}, value: 1 }); return 'bad'; } catch (e) { return e.name; } })()");
    defer result.free(rt);
    try expectStringBytes(result, "TypeError");
}

test "M3.1 F4: Object.defineProperty observes descriptor proxy fields in spec order" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var log = [];
        \\  function LoggingProxy(target) {
        \\    return new Proxy(target, {
        \\      has: function(t, id) { log.push("has " + id); return id in t; },
        \\      get: function(t, id) { log.push("get " + id); return t[id]; }
        \\    });
        \\  }
        \\  function run(obj) {
        \\    log = [];
        \\    Object.defineProperty(obj, "x", new LoggingProxy({
        \\      enumerable: true,
        \\      configurable: true,
        \\      value: 3,
        \\      writable: true
        \\    }));
        \\    return log.join("|");
        \\  }
        \\  return run({}) + "\n" + run([]) + "\n" + run(new Proxy({}, {}));
        \\})()
    );
    defer result.free(rt);
    const expected = "has enumerable|get enumerable|has configurable|get configurable|has value|get value|has writable|get writable|has get|has set";
    try expectStringBytes(result, expected ++ "\n" ++ expected ++ "\n" ++ expected);
}

test "M3.1 F4: Object.defineProperties boxes primitive properties argument" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var o = {}; var same = Object.defineProperties(o, false) === o; Object.defineProperties(o, { a: { value: 4, enumerable: 12 } }); return same + '|' + o.a + '|' + Object.keys(o)[0]; })()");
    defer result.free(rt);
    try expectStringBytes(result, "true|4|a");
}

test "M3.1 F4: Object.create applies descriptor properties through VM semantics" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var p = { p: 1 }; var o = Object.create(p, { x: { get: function(){ return 5; }, enumerable: 12 } }); return (Object.getPrototypeOf(o) === p) + '|' + o.x + '|' + Object.keys(o)[0]; })()");
    defer result.free(rt);
    try expectStringBytes(result, "true|5|x");
}

test "M3.1 F4: Object.create boxes primitive properties argument" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var p = {}; var o = Object.create(p, Symbol('s')); return Object.getPrototypeOf(o) === p && Object.getOwnPropertySymbols(o).length === 0; })()");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: Date internal slots are hidden from Object.create descriptors" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var props = new Date(0); props.prop = { value: 12, enumerable: true }; var o = Object.create({}, props); return Object.keys(props).join(',') + '|' + o.hasOwnProperty('prop') + '|' + o.prop; })()");
    defer result.free(rt);
    try expectStringBytes(result, "prop|true|12");
}

test "M3.1 F4: Date internal slot ignores public __date properties" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var d = new Date(0);
        \\  d.__date_ms = 86400000;
        \\  d.__date_year = 2000;
        \\  return d.getTime() + "|" +
        \\    d.getFullYear() + "|" +
        \\    Object.keys(d).join(",") + "|" +
        \\    Object.getOwnPropertyNames(d).join(",");
        \\})()
    );
    defer result.free(rt);
    try expectStringBytes(result, "0|1970|__date_ms,__date_year|__date_ms,__date_year");
}

test "M3.1 F4: Object.hasOwn checks boxed own properties only" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var parent = { inherited: 1 };
        \\  var child = Object.create(parent);
        \\  child.own = 2;
        \\  var sym = Symbol("s");
        \\  child[sym] = 3;
        \\  var nullThrows = false;
        \\  try {
        \\    Object.hasOwn(null, "x");
        \\  } catch (e) {
        \\    nullThrows = e.constructor === TypeError;
        \\  }
        \\  return Object.hasOwn(child, "own") &&
        \\    !Object.hasOwn(child, "inherited") &&
        \\    Object.hasOwn(child, sym) &&
        \\    Object.hasOwn("abc", "1") &&
        \\    nullThrows;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: Object.getOwnPropertyDescriptors includes strings and symbols" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var sym = Symbol("d");
        \\  var obj = {};
        \\  Object.defineProperty(obj, "hidden", { value: 1, enumerable: false });
        \\  obj.visible = 2;
        \\  obj[sym] = 3;
        \\  var descs = Object.getOwnPropertyDescriptors(obj);
        \\  var str = Object.getOwnPropertyDescriptors("ab");
        \\  function fakeObject() {}
        \\  fakeObject.keys = Object.keys;
        \\  fakeObject.getOwnPropertyDescriptors = Object.getOwnPropertyDescriptors;
        \\  var oldObject = Object;
        \\  Object = fakeObject;
        \\  var tamperOk = Object.keys(Object.getOwnPropertyDescriptors("a")).length === 2;
        \\  Object = oldObject;
        \\  var reflectKeys = Reflect.ownKeys(descs);
        \\  return Object.getPrototypeOf(descs) === Object.prototype &&
        \\    descs.hidden.enumerable === false &&
        \\    descs.visible.value === 2 &&
        \\    descs[sym].value === 3 &&
        \\    str[1].value === "b" &&
        \\    tamperOk &&
        \\    reflectKeys.length === 3 &&
        \\    reflectKeys[2] === sym;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: Object entries statics box primitive receivers" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  function fakeObject() {}
        \\  fakeObject.keys = Object.keys;
        \\  fakeObject.values = Object.values;
        \\  fakeObject.entries = Object.entries;
        \\  var oldObject = Object;
        \\  Object = fakeObject;
        \\  var keys = Object.keys("ab");
        \\  var values = Object.values("ab");
        \\  var entries = Object.entries("ab");
        \\  var nums = Object.keys(0);
        \\  Object = oldObject;
        \\  return keys.length === 2 && keys[1] === "1" &&
        \\    values.length === 2 && values[1] === "b" &&
        \\    entries.length === 2 && entries[0][0] === "0" && entries[0][1] === "a" &&
        \\    nums.length === 0;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: Object entries statics merge dense and property array indices" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var dense = [1, 2, 3];
        \\  Object.defineProperty(dense, 0, { writable: false });
        \\  var sparse = [];
        \\  sparse[2] = 3;
        \\  Object.defineProperty(sparse, 0, { value: 1, enumerable: true, configurable: true });
        \\  var desc = Object.getOwnPropertyDescriptor(dense, "0");
        \\  return Object.keys(dense).join("|") + ":" +
        \\    Object.values(dense).join("|") + ":" +
        \\    JSON.stringify(Object.entries(dense)) + ":" +
        \\    Object.keys(sparse).join("|") + ":" +
        \\    desc.value + ":" +
        \\    desc.enumerable + ":" +
        \\    desc.configurable + ":" +
        \\    desc.writable;
        \\})()
    );
    defer result.free(rt);
    try expectStringBytes(result, "0|1|2:1|2|3:[[\"0\",1],[\"1\",2],[\"2\",3]]:0|2:1:true:true:false");
}

test "M3.1 F4: Object.fromEntries defines data properties from iterables" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var sym = Symbol("k");
        \\  var out = Object.fromEntries([["name", 1], [sym, 2]]);
        \\  var desc = Object.getOwnPropertyDescriptor(out, "name");
        \\  return out.name === 1 &&
        \\    out[sym] === 2 &&
        \\    desc.writable === true &&
        \\    desc.enumerable === true &&
        \\    desc.configurable === true;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: Object prototype statics handle primitives and topology" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var obj = {};
        \\  Object.preventExtensions(obj);
        \\  var nonExtensibleThrows = false;
        \\  try {
        \\    Object.setPrototypeOf(obj, null);
        \\  } catch (e) {
        \\    nonExtensibleThrows = e.constructor === TypeError;
        \\  }
        \\  var missingKeyDesc = Object.getOwnPropertyDescriptor({undefined: 3});
        \\  return Object.getPrototypeOf(1) === Number.prototype &&
        \\    Object.getPrototypeOf(Math) === Object.prototype &&
        \\    Object.getPrototypeOf(EvalError) === Error &&
        \\    Object.getPrototypeOf(this).isPrototypeOf(this) &&
        \\    missingKeyDesc.value === 3 &&
        \\    Object.getOwnPropertyDescriptor(1) === undefined &&
        \\    Object.hasOwn({undefined: 4}) === true &&
        \\    Object.freeze() === undefined &&
        \\    Object.seal() === undefined &&
        \\    Object.preventExtensions() === undefined &&
        \\    Object.isExtensible() === false &&
        \\    Object.isFrozen() === true &&
        \\    Object.isSealed() === true &&
        \\    Object.isExtensible(1) === false &&
        \\    Object.preventExtensions(1) === 1 &&
        \\    Object.freeze(Symbol.for("x")) === Symbol.for("x") &&
        \\    Object.setPrototypeOf("x", null) === "x" &&
        \\    nonExtensibleThrows;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: Object.groupBy creates null-prototype grouped arrays" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var obj = Object.groupBy([1, 2, 3], function(value, index) {
        \\    return value % 2 ? "odd" : "even";
        \\  });
        \\  return Object.getPrototypeOf(obj) === null &&
        \\    obj.odd.length === 2 &&
        \\    obj.odd[0] === 1 &&
        \\    obj.odd[1] === 3 &&
        \\    obj.even.length === 1 &&
        \\    obj.even[0] === 2;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: missing function arguments allocate undefined formal slots" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ function f(a, b, c) { c = 3; return b === undefined ? c : 0; } return f(1); })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 3), result.asInt32().?);
}

test "M3.1 F4: qjs_vm executes logical or assignment in computed object key" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var x = 0; var o = { [x ||= 1]: 2 }; return o[1] + x; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 3), result.asInt32().?);
}

test "M3.1 F4: qjs_vm executes indexed logical assignment in computed object key" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var a = [0]; var o = { [a[0] ||= 1]: 2 }; return o[1] + a[0]; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 3), result.asInt32().?);
}

test "M3.1 F4: qjs_vm executes logical and assignment in computed object key" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var x = 0; var o = { [x &&= 1]: 2 }; return o[0] + x; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 2), result.asInt32().?);
}

test "M3.1 F4: qjs_vm executes nullish assignment in computed object key" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var x = null; var o = { [x ??= 1]: 2 }; return o[1] + x; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 3), result.asInt32().?);
}

test "M3.1 F4: qjs_vm supports Object.create null prototype for computed accessor in" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ return ({ get [\"x\" in Object.create(null)]() { return 5; } }).false; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 5), result.asInt32().?);
}

test "M3.1 F4: qjs_vm executes unlabelled break in for loop" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var value = 0; for (; ; ) { value = 7; break; value = 1; } return value; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 7), result.asInt32().?);
}

test "M3.1 F4: qjs_vm executes object literal __proto__ null" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "Object.getPrototypeOf({__proto__: null}) === null");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}
