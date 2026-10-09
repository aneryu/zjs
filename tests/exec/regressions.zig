//! Exec integration tests: regressions.
const std = @import("std");
const zjs = @import("zjs");
const engine = zjs;
const core = zjs.core;
const helpers = @import("../harness.zig");
const op = zjs.bytecode.opcode.op;
const common = @import("common.zig");
const InterruptTestState = common.InterruptTestState;

test "an Atomics.waitAsync promise fulfills like any other promise" {
    // Every reaction runs, in order, and `await` on it resumes the module
    // body. The module graph's scheduler delivers the notify completion.
    try expectModuleGraphPrints(&.{},
        \\const ia = new Int32Array(new SharedArrayBuffer(16));
        \\const r = Atomics.waitAsync(ia, 0, 0);
        \\r.value.then(v => print("A", v));
        \\r.value.then(v => print("B", v));
        \\r.value.then(v => print("C", v)).then(() => print("C2"));
        \\Promise.all([r.value]).then(v => print("all", v[0]));
        \\Atomics.notify(ia, 0);
        \\print("await", await r.value);
    ,
        \\A ok
        \\B ok
        \\C ok
        \\await ok
        \\C2
        \\all ok
        \\
    );
}

test "engine-built rejected promises follow RejectPromise and Promise.any uses the intrinsic AggregateError" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    js.context.setTrackUnhandledRejections(true);
    // An async generator method called on a bad receiver returns a promise
    // the engine builds already rejected: it is tracked like any rejection,
    // and subscribing to it reports it handled.
    _ = try js.eval("globalThis.p = Object.getPrototypeOf(async function* () {}).prototype.next.call({});");
    try std.testing.expect(js.context.hasUnhandledRejection());
    _ = try js.eval("p.catch(() => {});");
    try std.testing.expect(!js.context.hasUnhandledRejection());

    _ = try js.eval(
        \\const Intrinsic = AggregateError;
        \\globalThis.AggregateError = function () {};
        \\Promise.any([]).catch(e => { globalThis.aggregate = e; });
    );
    try js.runJobs();
    _ = try js.eval(
        \\assert.sameValue(Object.getPrototypeOf(aggregate), Intrinsic.prototype);
        \\assert.sameValue(Array.isArray(aggregate.errors), true);
    );
}

test "Proxy ownKeys, for-in and with follow the spec lookup order" {
    try helpers.expectPrints(
        \\var log = [];
        \\// [[OwnPropertyKeys]] reads every target key before checking invariants.
        \\var t = {}; Object.defineProperty(t, "x", { value: 1 }); t.y = 2;
        \\var inner = new Proxy(t, { getOwnPropertyDescriptor(tt, k) {
        \\  log.push(k); if (k === "y") throw new RangeError("y"); return Reflect.getOwnPropertyDescriptor(tt, k); } });
        \\try { Reflect.ownKeys(new Proxy(inner, { ownKeys() { return []; } })); } catch (e) { log.push(e.name); }
        \\print(log.join());
        \\// A listed key with no property does not hide the prototype's.
        \\var keys = [];
        \\for (var k in new Proxy(Object.create({ x: 1 }), { ownKeys() { return ["x"]; } })) keys.push(k);
        \\print(keys.join());
        \\// `this` and `new.target` never consult a with object.
        \\var seen = [];
        \\var env = new Proxy({ this: 1 }, { has(target, key) { seen.push(String(key)); return false; } });
        \\var kind = (function () { with (env) { return typeof this; } }).call({});
        \\function F() { with (env) { this.hasTarget = new.target !== void 0; } }
        \\print(kind, new F().hasTarget, seen.join("|"));
    ,
        \\x,y,RangeError
        \\x
        \\object true 
        \\
    );
}

test "native constructors, toString names and construct errors" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    const result = try js.eval(
        \\// A constructor-only native called inside another native construct is
        \\// still a call, not a construct.
        \\var inner;
        \\var holder = { D: DOMException };
        \\new DOMException({ toString() { try { holder.D("x"); inner = "no throw"; } catch (e) { inner = e.name; } return "m"; } });
        \\assert.sameValue(inner, "TypeError");
        \\// toString names a built-in by [[InitialName]], not its current name.
        \\Object.defineProperty(Math.max, "name", { value: "renamed" });
        \\assert(String(Math.max).startsWith("function max("));
        \\assert(String(Object.getOwnPropertyDescriptor(Map.prototype, "size").get).startsWith("function get size("));
        \\assert.throws(TypeError, () => new Number(Symbol()));
        \\try { new Number(Symbol()); } catch (e) { assert.sameValue(e.message, "cannot convert symbol to number"); }
        \\try { new DataView(); } catch (e) { assert.sameValue(e.message.length > 0, true); }
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "parameter initializers see the parameter-scope arguments through classes and eval" {
    try helpers.expectPrints(
        \\function withEval(a = class {}) { return eval("1"); }
        \\function withArrow(a = class {}, b = () => arguments) { return b().length; }
        \\function evalInArrow(p = 1, q = () => eval("arguments.length")) { return q(); }
        \\function same(a, q = () => eval("arguments")) { return q() === arguments; }
        \\print(withEval(), withArrow(undefined, undefined), evalInArrow(7, undefined, 9), same(1));
    ,
        \\1 2 3 true
        \\
    );
}

test "RegExp string protocol keeps unclamped positions and ToStrings fallback patterns" {
    try helpers.expectPrints(
        \\var r = /./g, n = 0;
        \\var results = [Object.assign(["XYZ"], { index: 2 }), Object.assign([""], { index: 3 })];
        \\r.exec = () => n < 2 ? results[n++] : null;
        \\print(RegExp.prototype[Symbol.replace].call(r, "abc", "[$&]"));
        \\var m = /a/g; Object.defineProperty(m, Symbol.match, { value: undefined });
        \\print(JSON.stringify("x/a/gxa".match(m)));
        \\var s = /a/g; Object.defineProperty(s, Symbol.search, { value: undefined });
        \\print("xa/a/g".search(s));
        \\try { Array.prototype.toString.call(null); } catch (e) { print(e.message); }
    ,
        \\ab[XYZ]
        \\["/a/g"]
        \\2
        \\cannot convert undefined or null to object
        \\
    );
}

test "function expression names, Annex B block functions and var arguments resolve per spec" {
    try helpers.expectPrints(
        \\// The name's environment is outside the parameters and vars.
        \\print((function x(x) { eval(""); return x; })(5), (function x() { var x = 6; eval(""); return x; })());
        \\// Only the function's own eval var object may shadow its name.
        \\with ({ a: 3 }) print((function a() { return eval("typeof a"); })());
        \\print((function b() { eval("var b = 1"); return typeof b; })());
        \\// A same-scope redefinition does not bypass an enclosing let.
        \\{ let c = 5; { function c() {} function c() {} } }
        \\print(typeof c);
        \\(function (x = 1) { var arguments = 2; var arguments; print(arguments); })();
        \\try { eval("if (1) function q() { try {} catch ([e]) { function e() {} } }"); print("accepted"); } catch (e) { print(e.name); }
        \\// Eval inside a catch block sees a `with` in that block first.
        \\try { throw 7; } catch (b) { with ({ b: 3 }) { print(eval("b")); } }
        \\// Strict parameter initializers share the arguments object.
        \\print((function () { "use strict"; return (function (x = eval("arguments")) { return x.length; })(undefined, 2, 3); })());
        \\// A closure made by eval finds the nearer let before the with object,
        \\// and a catch parameter before the eval's own var.
        \\with ({ f: 1 }) { let f = 5; print(eval("(function () { print; return f; })()")); }
        \\(function () { try { throw 7; } catch (b) { eval("var b = 2; (function () { print(b); })();"); } })();
    ,
        \\5 6
        \\function
        \\number
        \\undefined
        \\2
        \\SyntaxError
        \\3
        \\3
        \\5
        \\2
        \\
    );

    // Script code copies a block `function arguments` to a var (B.3.2.2).
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    _ = try js.eval("{ function arguments() {} } assert.sameValue(typeof arguments, 'function');");
}

test "String.prototype.repeat follows the spec count checks and names its RangeErrors" {
    try helpers.expectPrints(
        \\print(JSON.stringify("".repeat(2 ** 31)), JSON.stringify("ab".repeat(2.9)), JSON.stringify("ab".repeat(NaN)));
        \\for (const [s, n] of [["a", -1], ["", Infinity], ["ab", 1e300]]) {
        \\  try { s.repeat(n); } catch (e) { print(e.name, e.message); }
        \\}
    ,
        \\"" "abab" ""
        \\RangeError invalid repeat count
        \\RangeError invalid repeat count
        \\RangeError invalid string length
        \\
    );
}

test "Array and String index arguments of any magnitude do not overflow" {
    try helpers.expectPrints(
        \\print([1].at(1e300), [1].at(-1e300), new Uint8Array(3).at(2 ** 63), JSON.stringify([[1]].flat(1e300)));
        \\print(JSON.stringify(["a".charAt(1e300), "abc".slice(-1e300), "abc".substring(0, 1e300), "abc".substr(1e300), "abc".substr(0, 1e300), "abc".substr(-1e300, 2)]));
    ,
        \\undefined undefined undefined [1]
        \\["","abc","abc","","abc","ab"]
        \\
    );
}

test "Proxy invariants call IsExtensible on a proxy target and order getOwnPropertyDescriptor steps" {
    try helpers.expectPrints(
        \\const inner = new Proxy(Object.preventExtensions({ a: 1 }), {});
        \\try { Reflect.defineProperty(new Proxy(inner, { defineProperty() { return true; } }), "b", { value: 1 }); } catch (e) { print(e.name); }
        \\try { Reflect.has(new Proxy(inner, { has() { return false; } }), "a"); } catch (e) { print(e.name); }
        \\function run(result) {
        \\  const log = [];
        \\  const target = new Proxy({}, {
        \\    getOwnPropertyDescriptor(t, k) { log.push("gopd"); return Reflect.getOwnPropertyDescriptor(t, k); },
        \\    isExtensible(t) { log.push("isExtensible"); return Reflect.isExtensible(t); },
        \\  });
        \\  try { Object.getOwnPropertyDescriptor(new Proxy(target, { getOwnPropertyDescriptor() { return result; } }), "x"); } catch (e) { log.push(e.name); }
        \\  print(log.join());
        \\}
        \\run(undefined); run(1); run({ value: 1, configurable: true });
    ,
        \\TypeError
        \\TypeError
        \\gopd
        \\TypeError
        \\gopd,isExtensible
        \\
    );
}

test "Iterator.prototype constructor setter ignores prototype properties" {
    try helpers.expectPrints(
        \\const IP = Iterator.prototype, set = Object.getOwnPropertyDescriptor(IP, "constructor").set;
        \\const o = Object.create(IP); o.constructor = 5;
        \\const d = Object.getOwnPropertyDescriptor(o, "constructor"); print(d.value, d.enumerable);
        \\try { IP.constructor = {}; } catch (e) { print(e.name); }
        \\const n = Object.create(IP); Object.defineProperty(n, "constructor", { value: 1, writable: false, configurable: true });
        \\try { set.call(n, 2); } catch (e) { print(e.name, n.constructor); }
        \\const t = {}; set.call(t); print("constructor" in t, IP.constructor === Iterator);
    ,
        \\5 true
        \\TypeError
        \\TypeError 1
        \\true true
        \\
    );
}

test "Reflect.set on a typed array index honors a proxy receiver's own descriptor" {
    try helpers.expectPrints(
        \\function run(gopd, defineResult) {
        \\  const log = [];
        \\  const r = new Proxy({}, {
        \\    getOwnPropertyDescriptor() { log.push("gopd"); return gopd; },
        \\    defineProperty(t, k, d) { log.push("define " + Object.keys(d).join("+")); if (defineResult) Reflect.defineProperty(t, k, d); return defineResult; },
        \\  });
        \\  print(Reflect.set(new Uint8Array(1), "0", 1, r), log.join(" | "));
        \\}
        \\run({ get() {}, configurable: true }, true);
        \\run(undefined, false);
        \\run({ value: 5, writable: true, configurable: true }, true);
        \\run({ value: 5, writable: false, configurable: true }, true);
    ,
        \\false gopd
        \\false gopd | define value+writable+enumerable+configurable
        \\true gopd | define value
        \\false gopd
        \\
    );
}

test "Uint8Array base64 and hex methods reject a view its resizable buffer no longer covers" {
    try helpers.expectPrints(
        \\const ab = new ArrayBuffer(8, { maxByteLength: 16 }), ta = new Uint8Array(ab, 4);
        \\ab.resize(2);
        \\for (const f of [() => ta.toHex(), () => ta.toBase64(), () => ta.setFromHex("00"), () => ta.setFromBase64("AA==")]) {
        \\  try { f(); } catch (e) { print(e.name, e.message); }
        \\}
    ,
        \\TypeError ArrayBuffer is detached or resized
        \\TypeError ArrayBuffer is detached or resized
        \\TypeError ArrayBuffer is detached or resized
        \\TypeError ArrayBuffer is detached or resized
        \\
    );
}

test "CreateDataProperty on typed arrays converts values through valueOf" {
    try helpers.expectPrints(
        \\print(new Uint8Array(1).map(() => ({ valueOf() { return 5; } }))[0]);
        \\print(new BigInt64Array(1).map(() => ({ valueOf() { return 3n; } }))[0]);
        \\const a = [1, 2, 3]; a.constructor = { [Symbol.species]: function () { return new Uint8Array(1); } };
        \\try { a.map(x => x); } catch (e) { print(e.name, e.message); }
        \\const d = new Uint8Array(1); Object.defineProperties(d, { 0: { value: { valueOf() { return 9; } } } }); print(d[0]);
        \\const ta = new Uint8Array(1);
        \\JSON.parse('{"a":1,"b":[5]}', function (k, v) { if (k === "a") this.b = ta; if (k === "0" && this === ta) return { valueOf() { return 7; } }; return v; });
        \\print(ta[0]);
    ,
        \\5
        \\3n
        \\TypeError cannot define typed array element
        \\9
        \\7
        \\
    );
}

test "ArrayBuffer, DataView, and typed array views follow the spec check order" {
    try helpers.expectPrints(
        \\const ab = new ArrayBuffer(8, { maxByteLength: 16 });
        \\const tracking = new DataView(ab, 4), fixed = new DataView(ab, 0, 8);
        \\ab.resize(2);
        \\for (const f of [() => tracking.getInt8(0), () => fixed.getInt8(10)]) { try { f(); } catch (e) { print(e.name); } }
        \\let calls = 0; const count = { valueOf() { calls++; return 1; } };
        \\try { new ArrayBuffer(8).resize(count); } catch (e) { print(e.name, calls); }
        \\const detached = new ArrayBuffer(1, { maxByteLength: 8 }); detached.transfer();
        \\try { detached.resize(-1); } catch (e) { print(e.name); }
        \\try { new Uint16Array(new ArrayBuffer(8), 1, count); } catch (e) { print(e.name, e.message, calls); }
        \\const gone = new ArrayBuffer(8); gone.transfer();
        \\try { new DataView(gone, 0, { valueOf() { throw new SyntaxError(); } }); } catch (e) { print(e.name); }
        \\const src = new ArrayBuffer(8, { maxByteLength: 16 }); new Uint8Array(src).set([1, 2, 3, 4, 5, 6, 7, 8]);
        \\src.constructor = { [Symbol.species]: function (n) { src.resize(3); return new ArrayBuffer(n); } };
        \\print([...new Uint8Array(src.slice(1, 7))].join());
        \\const view = new Uint8Array(new ArrayBuffer(8, { maxByteLength: 16 }), 6, 2); view.buffer.resize(4);
        \\let species; view.constructor = { [Symbol.species]: function (...a) { species = a.slice(1); return new Uint8Array(1); } };
        \\print(view.subarray().length, species.join());
        \\const a = [1, 2]; a.constructor = { [Symbol.species]: () => Object.defineProperty({}, "length", { value: 0, writable: false }) };
        \\a.constructor[Symbol.species] = function () { return Object.defineProperty({}, "length", { value: 0, writable: false }); };
        \\try { a.slice(0, 1); } catch (e) { print(e.name); }
    ,
        \\TypeError
        \\TypeError
        \\TypeError 0
        \\RangeError
        \\RangeError invalid offset 0
        \\TypeError
        \\2,3,0,0,0,0
        \\1 6,0
        \\TypeError
        \\
    );
}

test "RegExp rejects oversized classes and applies the Annex B decimal escape fallback" {
    try helpers.expectPrints(
        \\const half = (k) => String.fromCodePoint(...Array.from({ length: 35000 }, (_, i) => 0x10000 + 2 * (i + k)));
        \\try { new RegExp("[" + half(0) + half(35000) + "]", "u"); } catch (e) { print(e.name); }
        \\print(new RegExp("\\4294967296").test('"94967296'), /(a)\9999999999/.test("a9999999999"));
        \\try { new RegExp("\\4294967296", "u"); } catch (e) { print(e.name); }
    ,
        \\SyntaxError
        \\true true
        \\SyntaxError
        \\
    );
}

test "BigInt toString emits chunked digits correctly in every radix" {
    try helpers.expectPrints(
        \\const out = [];
        \\for (const v of [2n ** 64n, -(2n ** 70n), 10n ** 40n + 7n, 3n ** 100n]) for (const r of [2, 3, 7, 16, 36]) out.push(v.toString(r));
        \\print(out.join("|"));
    ,
        \\10000000000000000000000000000000000000000000000000000000000000000|11112220022122120101211020120210210211221|45012021522523134134602|10000000000000000|3w5e11264sgsg|-10000000000000000000000000000000000000000000000000000000000000000000000|-101210022122111122111122201121110200210100021|-6106454640561632563653142|-400000000000000000|-6x5kxtvuwilukg|1110101100011001010011111000111000011010111001010010010111111101010111011100111110101011000010000000000000000000000000000000000000111|211112220011011200002021020221120011011121010121200011122112122221112100221111011122|162311002124535240363254156332200436351052226344|1d6329f1c35ca4bfabb9f5610000000007|cde0suu7bcgsn5rimwenzyeepz|101101001000110010100111100101001100111001101110110100001010110010110110100000111110111011101011101011010010100011111010101010111001111001110000001001111010001|10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000|230231613340145623403214021055230445262243332056242021334|5a4653ca673768565b41f775d6947d55cf3813d1|ajmfwc7pep3zss2fwkm9zm45pd86w29
        \\
    );
}

test "JSON.parse reports nesting past the native stack as a stack overflow, not a syntax error" {
    try helpers.expectPrints(
        \\for (const reviver of [undefined, (k, v) => v]) {
        \\  try { JSON.parse("[".repeat(100000) + "]".repeat(100000), reviver); } catch (e) { print(e.name, e.message); }
        \\}
    ,
        \\InternalError stack overflow
        \\InternalError stack overflow
        \\
    );
}

test "arrow bodies and class field initializers do not inherit yield or await" {
    try helpers.expectPrints(
        \\for (const src of [
        \\  "function* g() { var f = () => { yield 1; }; }",
        \\  "function* g() { class C { x = yield 1; } }",
        \\  "async function f() { class C { x = await 1; } }",
        \\]) {
        \\  try { new Function(src); print("accepted"); } catch (e) { print(e.name); }
        \\}
        \\function* ok() { class C { w = function* () { yield 7; }; } yield* new C().w(); }
        \\print([...ok()].join());
    ,
        \\SyntaxError
        \\SyntaxError
        \\SyntaxError
        \\7
        \\
    );
}

test "TDZ ReferenceErrors name the uninitialized binding" {
    try helpers.expectPrints(
        \\for (const src of ["foo; let foo;", "{ bar = 1; let bar; }", "class K extends K {}", "{ (() => zed)(); let zed; }"]) {
        \\  try { eval(src); } catch (e) { print(e.message); }
        \\}
    ,
        \\Cannot access 'foo' before initialization
        \\Cannot access 'bar' before initialization
        \\Cannot access 'K' before initialization
        \\Cannot access 'zed' before initialization
        \\
    );
}

test "Function constructor parses parameters and body separately" {
    try helpers.expectPrints(
        \\globalThis.injected = false;
        \\for (const args of [["}); injected = true; (function(){"], ["}), (function(){ return 42"], ["a /*", "*/){ return 9"]]) {
        \\  try { Function(...args); print("accepted"); } catch (e) { print(e.name); }
        \\}
        \\print(injected, Function("a = function(){ return 7 }", "return a()")(), Function("a", "b", "return a + b")(2, 3));
    ,
        \\SyntaxError
        \\SyntaxError
        \\SyntaxError
        \\false 7 5
        \\
    );
}

test "Function.prototype.bind reads the prototype first and defines length before name" {
    try helpers.expectPrints(
        \\const log = [], proto = function () {};
        \\const p = new Proxy(function () {}, {
        \\  getPrototypeOf() { log.push("getPrototypeOf"); return proto; },
        \\  get(t, k) { log.push("get " + String(k)); return Reflect.get(t, k); },
        \\});
        \\const b = Function.prototype.bind.call(p);
        \\print(log.join(), Object.getPrototypeOf(b) === proto, Reflect.ownKeys(b).join());
    ,
        \\getPrototypeOf,get length,get name true length,name
        \\
    );
}

test "TypeScript as-expressions keep tighter operators and namespaces export destructured names" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try helpers.evalTypeScriptChecked(js,
        \\var y = 3;
        \\assert.sameValue(y as number + 1 * 2, 5);
        \\assert.sameValue(y as number - 1 as number + 10, 12);
        \\assert.sameValue(y satisfies number << 1, 6);
        \\namespace N { export const [a, b] = [1, 2]; export const { c } = { c: 3 }; const [hidden] = [0]; }
        \\assert.sameValue(N.a + N.b + N.c, 6);
        \\assert.sameValue("hidden" in N, false);
    , .{ .filename = "ts-review.ts" });
    try std.testing.expect(result.is(.undefined_value));
}

test "delete of an optional-chain private member is an early SyntaxError" {
    try helpers.expectPrints(
        \\const early = (src) => { try { new Function(src); return "ok"; } catch (e) { return e.name; } };
        \\print(early("class C { #x; m() { delete this?.#x; } }"),
        \\  early("class C { #x; m() { delete (this?.a.#x); } }"),
        \\  early("class C { #x; m() { delete this.#x; } }"));
        \\const o = { a: { b: 1 } };
        \\print(delete o?.a.b, delete o?.["a"], delete undefined?.a, JSON.stringify(o));
    ,
        \\SyntaxError SyntaxError SyntaxError
        \\true true true {}
        \\
    );
}

test "large functions compile past 65535 if statements and switch cases" {
    try helpers.expectPrints(
        \\const ifs = "let y = 0;" + "if (x) y++;".repeat(70000) + "return y;";
        \\const cases = "switch (x) {" + Array.from({ length: 20000 }, (_, i) => `case ${i}: x = -${i};`).join("") + "} return x;";
        \\print(new Function("x", ifs)(1), new Function("x", cases)(19999));
        \\if (true) function f() { return 1; } else function f() { return 2; }
        \\if (false) function g() { return 1; } else function g() { return 2; }
        \\print(f(), g());
    ,
        \\70000 -19999
        \\1 2
        \\
    );
}

test "common runtime TypeErrors and RangeErrors carry messages" {
    try helpers.expectPrints(
        \\const cases = [
        \\  "var u; u.x = 1", "var u; u['y'] = 1", "Symbol() + ''", "Symbol() * 1", "1n + 1", "+1n", "1n >>> 1n",
        \\  "[].length = -1", "Reflect.ownKeys(1)", "Reflect.construct(1)", "Object.setPrototypeOf({}, 1)",
        \\  "BigInt(1.5)", "BigInt(NaN)", "new ArrayBuffer(-1)", "new Set().union(1)", "Promise.resolve.call(1)",
        \\  "Promise.prototype.then.call(1)", "'use strict'; delete Object.prototype", "new (() => 1)", "new Math.max",
        \\  "new (class extends null {})", "class A extends 1 {}", "{ using x = 1; }", "DisposableStack.prototype.use.call({})",
        \\  "var s = new DisposableStack(); s.dispose(); s.use({})", "new DisposableStack().defer(1)",
        \\  "Date.prototype.getTime.call({})", "new Date(NaN).toISOString()",
        \\];
        \\const empty = [];
        \\for (const c of cases) {
        \\  try { (0, eval)(c); empty.push("no error: " + c); }
        \\  catch (e) { if (!e.message) empty.push(c); }
        \\}
        \\print(empty.length ? empty.join(" | ") : "ok");
    ,
        \\ok
        \\
    );
}

test "async generator drains every queued request after completion" {
    try helpers.expectPrints(
        \\var log = [];
        \\async function* g() { await null; }
        \\var it = g();
        \\it.next().then(v => log.push('1' + v.done));
        \\it.next().then(v => log.push('2' + v.done));
        \\it.return(7).then(v => log.push('3' + v.value));
        \\it.next().then(v => log.push('4' + v.done));
        \\it.throw('t').then(null, e => log.push('5' + e));
        \\async function* h() { try { yield 1; } finally { log.push('fin'); } }
        \\var j = h();
        \\j.next().then(() => log.push('a'));
        \\j.return(9).then(v => log.push('b' + v.value));
        \\j.next().then(v => log.push('c' + v.done));
        \\var p = Promise.resolve();
        \\for (var i = 0; i < 8; i++) p = p.then(() => 0);
        \\p.then(() => print(log.join()));
    ,
        \\1true,2true,a,fin,37,4true,5t,b9,ctrue
        \\
    );
}

test "builtins consume iterables through one Iterator Record" {
    try helpers.expectPrints(
        \\function mk(log, opts) {
        \\  let i = 0;
        \\  const it = {
        \\    get next() { log.push("N"); return function () {
        \\      log.push("n");
        \\      if (opts.throwNext) throw "t";
        \\      if (i++ >= 2) return { done: true };
        \\      return opts.badValue ? { done: false, get value() { throw "v"; } } : { done: false, value: [String(i), i] };
        \\    }; },
        \\    return() { log.push("r"); return {}; },
        \\  };
        \\  return { [Symbol.iterator]() { return it; } };
        \\}
        \\const users = { Map: x => new Map(x), Set: x => new Set(x), fromEntries: x => Object.fromEntries(x),
        \\  groupBy: x => Object.groupBy(x, v => v[0]), mapGroupBy: x => Map.groupBy(x, v => v), from: x => Array.from(x),
        \\  mapThrows: x => Array.from(x, () => { throw 0; }) };
        \\for (const [name, f] of Object.entries(users)) {
        \\  const out = [];
        \\  for (const opts of [{}, { throwNext: true }, { badValue: true }]) {
        \\    const log = [];
        \\    try { f(mk(log, opts)); } catch (e) {}
        \\    out.push(log.join(""));
        \\  }
        \\  print(name, out.join(" "));
        \\}
        \\function* g() { yield ["a", 1]; }
        \\const own = g(); own[Symbol.iterator] = () => [["b", 2]][Symbol.iterator]();
        \\print(JSON.stringify(Object.fromEntries(own)));
        \\const order = [];
        \\Array.from.call(function () { order.push("C"); }, { [Symbol.iterator]() { order.push("I"); return [][Symbol.iterator](); } });
        \\let reads = 0; const inst = Object.create(Iterator.prototype, { next: { get() { reads++; return () => ({ done: true }); } } });
        \\print(order.join(""), Iterator.from(inst) === inst, reads);
    ,
        \\Map Nnnn Nn Nn
        \\Set Nnnn Nn Nn
        \\fromEntries Nnnn Nn Nn
        \\groupBy Nnnn Nn Nn
        \\mapGroupBy Nnnn Nn Nn
        \\from Nnnn Nn Nn
        \\mapThrows Nnr Nn Nn
        \\{"b":2}
        \\CI true 1
        \\
    );
}

test "Date.parse applies the UTC offset before TimeClip and rejects trailing garbage" {
    try helpers.expectPrints(
        \\print(Date.parse('-271821-04-20T00:30:00.000+01:00'), Date.parse('+275760-09-12T23:30:00.000-01:00'));
        \\print(Date.parse('-271821-04-19T23:00:00.000-01:00'), Date.parse('+275760-09-13T01:00:00.000+01:00'));
        \\print(Date.parse('Jan 1 2000 UTC' + ' '.repeat(200)), Date.parse('Jan 1 2000 UTC' + ' '.repeat(120) + 'junk'));
        \\const msg = (f) => { try { f(); } catch (e) { return e.message; } };
        \\print(msg(() => Date.prototype.getTime.call({})), msg(() => new Date(NaN).toISOString()));
    ,
        \\NaN NaN
        \\-8640000000000000 8640000000000000
        \\946684800000 NaN
        \\not a Date object Date value is NaN
        \\
    );
}

test "AsyncDisposableStack awaits null resources once and before sync disposal" {
    try helpers.expectPrints(
        \\var n = 0, log = [];
        \\function tick() { if (n < 8) { n++; Promise.resolve().then(tick); } }
        \\Promise.resolve().then(tick);
        \\var s = new AsyncDisposableStack(); s.use(null); s.use(null); s.use(null);
        \\s.disposeAsync().then(() => log.push('nulls:' + n));
        \\var t = new AsyncDisposableStack();
        \\t.use({ [Symbol.dispose]() { log.push('sync:' + n); } });
        \\t.use(null);
        \\t.disposeAsync().then(() => log.push('mixed:' + n));
        \\AsyncDisposableStack.prototype.disposeAsync.call({}).catch(e => log.push(e.message));
        \\var p = Promise.resolve();
        \\for (var i = 0; i < 6; i++) p = p.then(() => 0);
        \\p.then(() => print(log.join()));
    ,
        \\sync:0,not an AsyncDisposableStack,nulls:2,mixed:2
        \\
    );
}

test "deep bound and proxy chains throw instead of exhausting the native stack" {
    // A native-stack depth test: 120k live chain objects make every stress
    // collection O(heap), which turned test-gc-stress from ~1 min into ~28.
    if (core.gc.forensics.stressing()) return error.SkipZigTest;
    try helpers.expectPrints(
        \\const safe = (f) => { try { f(); return "ok"; } catch (e) { return e instanceof InternalError ? "ok" : e.name; } };
        \\var b = function () {}; for (var i = 0; i < 20000; i++) b = b.bind();
        \\var p = function () {}; for (var i = 0; i < 100000; i++) p = new Proxy(p, {});
        \\print([() => b(), () => new b(), () => ({}) instanceof b, () => Reflect.construct(Object, [], b),
        \\  () => p(), () => new p(), () => p.x, () => Object.getPrototypeOf(p), () => Array.isArray(p)].map(safe).join());
        \\print(b.name.length);
        \\function T() {} Object.defineProperty(T, Symbol.hasInstance, { value: () => true });
        \\function B() {} const BB = B.bind(); Object.setPrototypeOf(BB, null);
        \\print(({}) instanceof T.bind(), new B() instanceof BB);
    ,
        \\ok,ok,ok,ok,ok,ok,ok,ok,ok
        \\120001
        \\true true
        \\
    );
}

test "500-deep parenthesized, array and object nesting parses within the default native stack" {
    // Each nesting level costs one pass through the expression grammar;
    // binary precedence levels used to take a native frame each, which
    // capped parenthesization near 330 levels.
    const depth = 500;
    try helpers.expectPrints(
        "print(" ++ "(" ** depth ++ "1" ++ ")" ** depth ++ ", " ++
            "[" ** depth ++ "]" ** depth ++ ".length, " ++
            "typeof " ++ "{a:" ** depth ++ "1" ++ "}" ** depth ++ ");",
        "1 1 object\n",
    );
}

test "Array methods are generic over String receivers and RegExp fast paths keep legacy statics" {
    try helpers.expectPrints(
        \\const A = Array.prototype;
        \\print(JSON.stringify([A.slice.call("abc", 1), A.toReversed.call("abc"), A.with.call("abc", 0, "w"), A.slice.call(function (a, b) {})]));
        \\const msg = (f) => { try { f(); return "ok"; } catch (e) { return e.message; } };
        \\print(msg(() => A.push.call("abc", 1)), "|", msg(() => A.pop.call("abc")), "|", msg(() => Uint8Array.prototype.at.call(1)));
        \\/(a)(b)/.test("xaby"); print(RegExp.$1, RegExp.$2, RegExp.leftContext);
        \\"xabyAB".replace(/(a)(b)/gi, "q"); print(RegExp.$1, RegExp.leftContext);
        \\print(JSON.stringify([new RegExp("a\u2028b").source, new RegExp("\\\n").source]));
    ,
        \\[["b","c"],["c","b","a"],["w","b","c"],[null,null]]
        \\'length' is read-only | could not delete property | not a TypedArray
        \\a b x
        \\A xaby
        \\["a\\u2028b","\\n"]
        \\
    );
}

test "class and Object edge semantics from the class/Object review" {
    try helpers.expectPrints(
        \\const name = (f) => { try { return f(); } catch (e) { return e.name + ":" + e.message; } };
        \\class A { constructor() { Object.defineProperty(this, "x", { value: 0 }); } }
        \\class B extends A { x = 1; }
        \\print(name(() => new B()));
        \\let setterHit = false;
        \\const recv = { set x(v) { setterHit = true; } };
        \\class S { m() { super.x = 1; } }
        \\print(name(() => S.prototype.m.call(recv)), setterHit);
        \\class P { #x; static f(o) { return #x in o in { true: 1 }; } static g(o) { return #x in o < 2; } }
        \\print(P.f(new P()), P.g(new P()));
        \\const E = eval("(class { async\nm() {} })"); print(Object.keys(new E()).join(), typeof E.prototype.m);
        \\print(name(() => eval("class eval {}")).split(":")[0]);
        \\const a = []; a[4294967294] = 1; a[100] = 1; Object.defineProperty(a, 1000, { value: 1, configurable: false });
        \\a.length = 5; print(a.length, Object.getOwnPropertyNames(a).join());
        \\let conversions = 0; const ro = [1]; Object.defineProperty(ro, "length", { writable: false });
        \\ro.length = { valueOf() { conversions++; return 1; } }; print(conversions);
        \\const rab = new ArrayBuffer(4, { maxByteLength: 8 });
        \\print(Reflect.preventExtensions(new Uint8Array(rab)), Reflect.preventExtensions(new Uint8Array(new ArrayBuffer(4))));
        \\print(name(() => Object.keys()), "|", name(() => Object.defineProperty({}, "a", 1)));
    ,
        \\TypeError:cannot redefine property
        \\TypeError:cannot set property 'x' false
        \\true true
        \\async function
        \\SyntaxError
        \\1001 100,1000,length
        \\0
        \\false true
        \\TypeError:cannot convert undefined or null to object | TypeError:property descriptor must be an object
        \\
    );
}

test "Set.prototype.symmetricDifference sees receiver mutations from set-like keys" {
    try helpers.expectPrints(
        \\const base = new Set(["a", "b", "c"]);
        \\const setLike = { size: 3, has() { return false; }, keys() {
        \\  base.delete("b"); base.add("q");
        \\  const it = ["c", "d", "e", "x"][Symbol.iterator](); return { next: () => it.next() };
        \\} };
        \\print([...base.symmetricDifference(setLike)].join(), [...base].join());
    ,
        \\a,q,d,e,x a,c,q
        \\
    );
}

test "parser reserved-word and optional-chain early errors plus collection constructor iteration" {
    try helpers.expectPrints(
        \\const parses = (src) => { try { (0, eval)(src); return "ok"; } catch (e) { return e.name; } };
        \\print(["new a?.b()", "new a?.b", "new a()?.b"].map((s) => parses("var a = function () { return {}; }; " + s)).join());
        \\print(["function let(){}", "(function static(){})", "var static = 1; ({static})", "var {package} = {package:1}",
        \\  "async function f(){ (function await(){}); }", "(async function await(){})", "function f(package){ 'use strict'; }",
        \\  "function yield(){ 'use strict'; }"].map(parses).join());
        \\const message = (src) => { try { (0, eval)(src); return "ok"; } catch (e) { return e.message; } };
        \\print(message("break;"), "|", message("({__proto__:1, __proto__:2})"));
        \\let seen;
        \\const proto = Object.getPrototypeOf([][Symbol.iterator]());
        \\proto.return = function () { seen = this.next(); return {}; };
        \\try { new WeakSet([{ a: 1 }, 1, { c: 3 }]); } catch (e) { print(e.message); }
        \\delete proto.return;
        \\print(JSON.stringify(seen.value));
    ,
        \\SyntaxError,SyntaxError,ok
        \\ok,ok,ok,ok,ok,SyntaxError,SyntaxError,SyntaxError
        \\'break' outside of a loop or switch | duplicate __proto__ property in object literal
        \\invalid value used in weak set
        \\{"c":3}
        \\
    );
}

test "scope and BigInt review regressions" {
    try helpers.expectPrints(
        \\const fs = [];
        \\for (let i = 0; i < 3; i++) { fs.push(() => i); continue; }
        \\outer: for (let j = 0; j < 2; j++) { for (;;) { fs.push(() => j); continue outer; } }
        \\print(fs.map((f) => f()).join());
        \\const log = [];
        \\const p = new Proxy({ x: 1 }, { has: (t, k) => k === "x", deleteProperty(t, k) { log.push("del:" + k); return false; } });
        \\with (p) { log.push(delete x); }
        \\print(log.join());
        \\const message = (f) => { try { f(); return "ok"; } catch (e) { return e.name + ":" + e.message; } };
        \\print(message(() => { with (null) {} }), "|", message(() => { const { a } = null; }));
        \\print(BigInt.asUintN(65, -2n), BigInt.asUintN(129, -2n) === 2n ** 129n - 2n);
        \\const a = new BigInt64Array(new SharedArrayBuffer(8)); Atomics.store(a, 0, 2n ** 64n + 1n); print(a[0]);
        \\print((-7n) >> 1n, (-(2n ** 128n) + 1n) >> 64n, BigInt("0x" + "f".repeat(40)).toString(16).length, (255n).toString(2));
        \\print((12n).toLocaleString(), message(() => (1n).toString(37)), "|", message(() => JSON.stringify(1n)));
    ,
        \\0,1,2,0,1
        \\del:x,false
        \\TypeError:cannot convert undefined or null to object | TypeError:cannot convert undefined or null to object
        \\36893488147419103230n true
        \\1n
        \\-4n -18446744073709551616n 40 11111111
        \\12 RangeError:radix must be between 2 and 36 | TypeError:BigInt value can't be serialized in JSON
        \\
    );
}

test "Array and RegExp review regressions" {
    try helpers.expectPrints(
        \\const message = (f) => { try { f(); return "ok"; } catch (e) { return e.name + ":" + e.message; } };
        \\const cyclic = [1]; cyclic.push(cyclic);
        \\print(message(() => cyclic.flat(Infinity)));
        \\const log = [];
        \\print(message(() => Array.prototype.with.call({ length: 2 ** 32 }, { valueOf() { log.push("valueOf"); return 0; } }, 0)), log.join());
        \\print(message(() => [1].sort(1)), "|", message(() => [1].flatMap(1)), "|", message(() => [1, 2].with(2, 0)));
        \\print(message(() => Array.prototype.push.call({ length: 2 ** 53 - 1 }, 1)));
        \\const re = (source, flags) => message(() => new RegExp(source, flags));
        \\print(re("(?<a>x)|(?<a>y)"), re("(?:(?<a>x)|b)(?<a>c)"), re("(?<a>x)(?:y|(?<a>z))"), re("(?<a>x)" + "|x".repeat(256) + "|(?<a>y)"));
        \\print(re("[\\!\\&\\~]", "v"), re("[\\!]", "u"));
        \\print(re("[^\\q{ab}--\\q{ab}]", "v"), re("[^\\q{a|b}--\\q{a}]", "v"));
        \\print(re("(a)".repeat(300)), "|", re("a", "gg"));
        \\const detached = new ArrayBuffer(8); detached.transfer();
        \\print(message(() => ArrayBuffer.prototype.slice.call({})), "|", message(() => detached.slice()), "|", message(() => new ArrayBuffer(8, { maxByteLength: 16 }).resize(32)));
        \\const buffer = new ArrayBuffer(8); buffer.constructor = { [Symbol.species]: function () { return buffer; } };
        \\print(message(() => buffer.slice()), "|", message(() => new Uint8Array(4).set([1], -1)), "|", message(() => new Uint8Array(4).set()));
        \\print(message(() => new DataView(new ArrayBuffer(4), 5)), "|", message(() => Array.prototype.join.call(null)));
    ,
        \\InternalError:stack overflow
        \\RangeError:invalid array length valueOf
        \\TypeError:not a function | TypeError:not a function | RangeError:invalid array index
        \\TypeError:array length would exceed 2^53 - 1
        \\ok SyntaxError:invalid regular expression SyntaxError:invalid regular expression ok
        \\ok SyntaxError:invalid regular expression
        \\SyntaxError:invalid regular expression ok
        \\SyntaxError:regular expression is too complex | SyntaxError:invalid regular expression flags
        \\TypeError:method called on incompatible receiver | TypeError:ArrayBuffer is detached | RangeError:invalid array buffer length
        \\TypeError:species constructor returned an incompatible object | RangeError:offset is out of bounds | TypeError:cannot convert undefined or null to object
        \\RangeError:offset is out of bounds | TypeError:cannot convert undefined or null to object
        \\
    );
}

test "Await delivers PromiseResolve throws to the awaiting frame" {
    try helpers.expectPrints(
        \\const poisoned = Promise.resolve();
        \\Object.defineProperty(poisoned, "constructor", { get() { throw new Error("cg"); } });
        \\async function f() { try { await poisoned; } catch (e) { print("caught " + e.message); } return "ok"; }
        \\f().then((v) => print("resolved " + v), (e) => print("rejected " + e.message));
        \\async function loop() { let n = 0; while (n < 3) { try { await poisoned; } catch { n++; } } return n; }
        \\loop().then((n) => print("loop " + n));
        \\const message = (g) => { try { g(); return "ok"; } catch (e) { return e.name + ":" + e.message; } };
        \\print(message(() => Promise.all.call(function (ex) { ex(() => {}, () => {}); ex(() => {}, () => {}); }, [])));
        \\print(message(() => Promise.withResolvers.call(function (ex) { ex(1, 2); })));
    ,
        \\caught cg
        \\TypeError:promise capability executor already called
        \\TypeError:promise resolve or reject function is not callable
        \\resolved ok
        \\loop 3
        \\
    );

    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    const result = try js.evalModule(
        \\const poisoned = Promise.resolve();
        \\Object.defineProperty(poisoned, "constructor", { get() { throw new Error("cg"); } });
        \\let caught = "";
        \\try { await poisoned; } catch (e) { caught = e.message; }
        \\assert.sameValue(caught, "cg");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "String review regressions" {
    try helpers.expectPrints(
        \\let s = "";
        \\for (let i = 0; i < 20000; i++) s = (i & 1) ? s + String.fromCharCode(98 + i % 20) : "é" + s;
        \\let h = 0;
        \\for (let j = 0; j < s.length; j++) h = (h * 31 + s.charCodeAt(j)) | 0;
        \\print(s.length, h, s.slice(0, 3), s.slice(-3));
        \\try { eval("`${1}`;\n\"x\".concat(" + "1,".repeat(65533) + "1);"); } catch (e) { print(e.name + ":" + e.message); }
    ,
        \\20000 332754192 ééé qsu
        \\SyntaxError:stack overflow
        \\
    );
}

test "Iterator, Number and exponent review regressions" {
    try helpers.expectPrints(
        \\const message = (f) => { try { f(); return "ok"; } catch (e) { return e.name + ":" + e.message; } };
        \\const log = [];
        \\const source = () => ({ __proto__: Iterator.prototype, next() { log.push("next"); return { done: false, value: 1 }; }, return() { log.push("return"); return {}; } });
        \\print(message(() => source().flatMap(() => "ab").next()), log.join());
        \\log.length = 0;
        \\print(message(() => source().flatMap(() => ({ [Symbol.iterator]() { return { next() { throw new Error("inner"); } }; } })).next()), log.join());
        \\function* g() { yield it.next(); } const it = g();
        \\print(message(() => it.next()), "|", message(() => Iterator.from(1)), "|", message(() => { for (const x of { [Symbol.iterator]() { return { next() { return { done: false }; }, return() { return 1; } }; } }) break; }));
        \\print(message(() => Number.prototype.valueOf.call("x")), Math.pow(10, 308) === 1e308, 10 ** -300 === 1e-300, (-8) ** (1 / 3), 1 ** Infinity);
        \\print(message(() => eval("(async function () { await 2 ** 3; })")), eval("var await = 3; await ** 2"));
    ,
        \\TypeError:value is not iterable next,return
        \\Error:inner next,return
        \\TypeError:cannot invoke a running generator | TypeError:value is not iterable | TypeError:iterator must return an object
        \\TypeError:not a number true true NaN NaN
        \\SyntaxError:expected ';', got '**' 9
        \\
    );
}

test "destructuring, Object and parser message review regressions" {
    try helpers.expectPrints(
        \\const message = (f) => { try { f(); return "ok"; } catch (e) { return e.name + ":" + e.message; } };
        \\print(JSON.stringify({ ..."ab", x: 1 }), JSON.stringify({ ...5, ...true }));
        \\var y; [(y) = function () {}] = []; var z; ({ a: (z) = function () {} } = {});
        \\print(JSON.stringify(y.name), JSON.stringify(z.name));
        \\print(Reflect.get({ undefined: 7 }), Reflect.has({ undefined: 1 }), Reflect.deleteProperty({}), message(() => Reflect.get()));
        \\const log = [];
        \\const p = new Proxy({ a: 1 }, { isExtensible(t) { log.push("ie"); return Reflect.isExtensible(t); }, ownKeys(t) { log.push("keys"); return Reflect.ownKeys(t); } });
        \\print(Object.isFrozen(p), log.join());
        \\print(message(() => Object.defineProperty({}, "a", { get: 1 })), "|", message(() => Object.defineProperty({}, "a", { get() {}, value: 1 })));
        \\print(message(() => Symbol.keyFor("x")), "|", message(() => (function () { "use strict"; }).caller));
        \\for (const src of ["let q; let q;", "L: L: ;", "(function (x = 1, x) {})"]) print(message(() => eval(src)));
    ,
        \\{"0":"a","1":"b","x":1} {}
        \\"" ""
        \\7 true true TypeError:not an object
        \\false ie
        \\TypeError:getter or setter is not a function | TypeError:cannot have a getter or setter and a value or writable
        \\TypeError:not a symbol | TypeError:'caller', 'callee' and 'arguments' are restricted in this context
        \\SyntaxError:redeclaration of 'q'
        \\SyntaxError:duplicate label 'L'
        \\SyntaxError:duplicate parameter 'x'
        \\
    );
}

test "shortened branches never fuse an operand byte that looks like lt/eq" {
    // Local slots 161 (op.lt) and 167 (op.eq) put the opcode's byte value in
    // the get_loc8 operand right before a wide if_false that layout shrinks.
    try helpers.expectPrints(
        \\for (const slot of [161, 167]) {
        \\  const names = Array.from({ length: slot + 2 }, (_, i) => "v" + i);
        \\  const body = "var a, " + names.map((n) => n + " = 1").join(", ") + ";\n" +
        \\    "if (v" + (slot - 1) + ") { " + "a = 1; ".repeat(20) + "return 'taken'; } return 'NOT taken';";
        \\  print(slot, Function(body)());
        \\}
    ,
        \\161 taken
        \\167 taken
        \\
    );
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn tzset() void;

test "Date local time resolves DST transitions and second-precision offsets" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    // A calendar sweep, not a GC test: 70k Date objects under stress take minutes.
    if (core.gc.forensics.stressing()) return error.SkipZigTest;
    const saved = std.c.getenv("TZ");
    var saved_copy: [256]u8 = undefined;
    const saved_z: ?[:0]const u8 = if (saved) |value| blk: {
        const text = std.mem.span(value);
        if (text.len >= saved_copy.len) return error.SkipZigTest;
        @memcpy(saved_copy[0..text.len], text);
        saved_copy[text.len] = 0;
        break :blk saved_copy[0..text.len :0];
    } else null;
    defer {
        if (saved_z) |value| _ = setenv("TZ", value.ptr, 1) else _ = unsetenv("TZ");
        tzset();
    }
    const cases = [_]struct { zone: [:0]const u8, expected: []const u8 }{
        .{ .zone = "America/New_York", .expected = "3:0 2:0 true -5364644638000\n" },
        .{ .zone = "Australia/Lord_Howe", .expected = "1:59 2:45 -660 true\n" },
    };
    for (cases) |case| {
        _ = setenv("TZ", case.zone.ptr, 1);
        tzset();
        const source = if (std.mem.eql(u8, case.zone, "America/New_York"))
            \\const hm = (d) => d.getHours() + ":" + d.getMinutes();
            \\let roundTrip = true;
            \\for (let t = Date.UTC(2020, 0, 1); t < Date.UTC(2021, 0, 1); t += 15 * 60000) {
            \\  const d = new Date(t);
            \\  const back = new Date(d.getFullYear(), d.getMonth(), d.getDate(), d.getHours(), d.getMinutes());
            \\  if (hm(back) !== hm(d) || back.getTime() > t) roundTrip = false;
            \\}
            \\print(hm(new Date(2020, 2, 8, 3, 0)), hm(new Date(2020, 10, 1, 2, 0)), roundTrip, new Date(1800, 0, 1).getTime());
        else
            \\const hm = (d) => d.getHours() + ":" + d.getMinutes();
            \\let roundTrip = true;
            \\for (let t = Date.UTC(2020, 0, 1); t < Date.UTC(2021, 0, 1); t += 15 * 60000) {
            \\  const d = new Date(t);
            \\  const back = new Date(d.getFullYear(), d.getMonth(), d.getDate(), d.getHours(), d.getMinutes());
            \\  if (hm(back) !== hm(d) || back.getTime() > t) roundTrip = false;
            \\}
            \\const gap = new Date(2020, 9, 4, 2, 15);
            \\print(hm(new Date(2020, 9, 4, 1, 59)), hm(gap), gap.getTimezoneOffset(), roundTrip);
        ;
        try helpers.expectPrints(source, case.expected);
    }
}

test "Date.parse trims white space and Atomics/buffer review regressions" {
    try helpers.expectPrints(
        \\const message = (f) => { try { f(); return "ok"; } catch (e) { return e.name + ":" + e.message; } };
        \\print(new Date(Date.parse("\t2020-06-15")).toISOString(), new Date(Date.parse("2020-06-15 ")).toISOString(), new Date(Date.parse(".2020-06-15Z")).getUTCFullYear());
        \\print(message(() => Date.prototype.toJSON.call({ valueOf() { return 1; } })));
        \\const b = new ArrayBuffer(16, { maxByteLength: 32 }); const a = new Int32Array(b, 8); b.resize(4);
        \\let converted = false;
        \\print(message(() => Atomics.load(a, { valueOf() { converted = true; return 0; } })), converted);
        \\const b2 = new ArrayBuffer(16, { maxByteLength: 32 }); const a2 = new Int32Array(b2);
        \\print(message(() => Atomics.store(a2, 2, { valueOf() { b2.resize(4); return 1; } })));
        \\print(Object.getPrototypeOf(Atomics.waitAsync(new Int32Array(new SharedArrayBuffer(4)), 0, 1)) === Object.prototype);
        \\print(message(() => new ArrayBuffer(2 ** 40)));
    ,
        \\2020-06-15T00:00:00.000Z 2020-06-15T00:00:00.000Z 2020
        \\TypeError:not a function
        \\TypeError:TypedArray is out of bounds false
        \\RangeError:invalid array index
        \\true
        \\RangeError:invalid array buffer length
        \\
    );
}

test "Error stack, URI and microtask review regressions" {
    try helpers.expectPrints(
        \\const message = (f) => { try { f(); return "ok"; } catch (e) { return e.name + ":" + e.message; } };
        \\const d = Object.getOwnPropertyDescriptor(Error.prototype, "stack");
        \\print(message(() => d.get.call(1)), "|", message(() => { new Error().stack = 1; }), "|", message(() => { Error.prototype.stack = "s"; }));
        \\print(message(() => decodeURIComponent("%F5%80%80%80")), "|", message(() => decodeURIComponent("%F0%80%80%AF")), decodeURIComponent("%F0%9F%98%80").length);
        \\function deep(n) { return n ? deep(n - 1) : new Error("x"); }
        \\const e = deep(5000);
        \\print(e.stack.split("\n").length <= 11, /deep/.test(e.stack));
        \\queueMicrotask(function () { "use strict"; print(this === undefined); });
    ,
        \\TypeError:not an object | TypeError:not a string | TypeError:cannot set stack on Error.prototype
        \\URIError:malformed UTF-8 | URIError:malformed UTF-8 2
        \\true true
        \\true
        \\
    );
}

test "primitive receivers and argument list review regressions" {
    try helpers.expectPrints(
        \\const message = (f) => { try { f(); return "ok"; } catch (e) { return e.name + ":" + e.message; } };
        \\String.prototype[5] = "P5"; Object.prototype[7] = "O7";
        \\print("ab"[5], ""[5], "ab"[7], "ab"[1]);
        \\delete String.prototype[5]; delete Object.prototype[7];
        \\print(Object.getOwnPropertyDescriptor(String.prototype, "length").configurable, message(() => Object.defineProperty(String.prototype, "length", { value: 1 })));
        \\Object.defineProperty(String.prototype, "kind", { get() { "use strict"; return typeof this; }, configurable: true });
        \\var { kind } = "x"; let seen; ({ kind: seen } = "y");
        \\print(kind, seen, message(() => { var { kind } = null; }));
        \\print(Object.prototype.isPrototypeOf.call(1, {}), message(() => Object.prototype.isPrototypeOf.call(undefined, {})));
        \\print(message(() => Reflect.apply(Math.max, null)), "|", message(() => Reflect.construct(Object, 1)));
    ,
        \\P5 P5 O7 b
        \\false TypeError:cannot redefine property
        \\string string TypeError:cannot convert undefined or null to object
        \\false TypeError:cannot convert undefined or null to object
        \\TypeError:argument list must be an object | TypeError:argument list must be an object
        \\
    );
}

test "RegExp API layer review regressions" {
    try helpers.expectPrints(
        \\const log = [];
        \\const result = (index) => new Proxy(Object.assign(["a"], { index, groups: undefined }), { get(t, k, r) { if (typeof k === "string") log.push(k); return Reflect.get(t, k, r); } });
        \\const re = /a/g; let n = 0;
        \\re.exec = function () { log.push("exec"); return n++ < 2 ? result(0) : null; };
        \\const calls = [];
        \\print(re[Symbol.replace]("aa", (m, i) => { calls.push(i); return "X"; }), calls.join(), log.slice(0, 5).join());
        \\const order = [];
        \\const P = { toString() { order.push("p"); return "a"; } };
        \\const NT = function () {}.bind(); Object.defineProperty(NT, "prototype", { get() { order.push("proto"); return RegExp.prototype; } });
        \\Reflect.construct(RegExp, [P], NT);
        \\const falsy = /a/gi; falsy[Symbol.match] = 0;
        \\print(order.join(), String(RegExp(falsy)), String(new RegExp({ [Symbol.match]: true, source: { toString() { return "ab"; } }, flags: "g" })));
    ,
        \\Xa 0,0 exec,0,exec,0,exec
        \\proto,p /a/gi /ab/g
        \\
    );
}

test "directive prologue, strictness boundary and TypedArray iterator review regressions" {
    try helpers.expectPrints(
        \\const run = (src) => { try { return String(eval(src)); } catch (e) { return e.name + ":" + e.message; } };
        \\print(run("'a'\n.length"), run("'x'\n+1"), run("'x'\n[0]"), run("'use strict'\n+1; var o = {}; with (o) {} 'sloppy'"));
        \\print(run("function f() { 'use strict'; }\n010"), run("class K {}\n010"), run("'use strict'; function g() {}\n010"));
        \\print(run("var a; for ([a] = [9] of [[1]]);"), run("'use strict'; with ({}) {}"));
        \\let i = 0;
        \\const it = { [Symbol.iterator]() { return { next() { return i++ < 2 ? { value: i, done: 0 } : { done: 1 }; } }; } };
        \\print(Int8Array.from(it).join());
        \\const closed = [];
        \\const bad = { [Symbol.iterator]() { return { next() { throw new Error("boom"); }, return() { closed.push("return"); return {}; } }; } };
        \\print(run("new Int8Array(bad)"), run("Int8Array.from(bad)"), closed.length);
    ,
        \\1 x1 x sloppy
        \\8 8 SyntaxError:octal literals are not allowed in strict mode
        \\SyntaxError:invalid left-hand side in for-in/of SyntaxError:'with' is not allowed in strict mode
        \\1,2
        \\Error:boom Error:boom 0
        \\
    );
}

test "JSON source records, revoked IsArray and eval shadowing review regressions" {
    try helpers.expectPrints(
        \\const message = (f) => { try { f(); return "ok"; } catch (e) { return e.name + ":" + e.message; } };
        \\const seen = [];
        \\JSON.parse('{"a":1,"a":2}', function (k, v, c) { if (k === "a") seen.push(c.source); return v; });
        \\const { proxy, revoke } = Proxy.revocable([], {}); revoke();
        \\print(seen.join(), message(() => Array.isArray(proxy)));
        \\print((function nf() { eval("var nf = 1"); return nf; })(), (function nf() { eval("var nf"); return typeof nf; })());
        \\print((function nf() { var g = () => nf; eval("var nf = 3"); return g(); })(), (function nf() { eval("var nf = 1"); nf = 5; return eval("nf"); })());
        \\print((function nf() { return typeof nf; })(), (function nf() { "use strict"; return typeof nf; })());
        \\print(message(() => eval("class K { x = arguments; }")));
    ,
        \\2 TypeError:revoked proxy
        \\1 undefined
        \\3 5
        \\function function
        \\SyntaxError:'arguments' is not allowed in class field initializer or static initialization block
        \\
    );
}

test "TypedArray exotic methods through Reflect/Proxy, IteratorClose and SpeciesConstructor review regressions" {
    try helpers.expectPrints(
        \\const message = (f) => { try { f(); return "ok"; } catch (e) { return e.name + ":" + e.message; } };
        \\const ta = new Int8Array(2); const p = new Proxy(ta, {});
        \\Object.prototype["1.5"] = "P"; Object.prototype[5] = "P";
        \\print(Reflect.deleteProperty(ta, "1"), delete p[0], String(Reflect.get(ta, "1.5")), String(p[5]), Reflect.set(p, "1.5", 1));
        \\delete Object.prototype["1.5"]; delete Object.prototype[5];
        \\print(Reflect.defineProperty(p, "0", { value: 5 }), ta[0], Reflect.defineProperty(p, "5", { value: 1 }), Reflect.ownKeys(ta).join());
        \\print(message(() => Iterator.prototype.every.call({ next() { return { done: false, value: 1 }; }, return() { return 1; } }, () => false)));
        \\print(message(() => Array.from({ [Symbol.iterator]() { return { next() { return { done: false, value: 1 }; }, return() { throw new Error("RET"); } }; } }, () => { throw new Error("MAP"); })));
        \\const ab = new ArrayBuffer(8); ab.constructor = undefined;
        \\const saved = globalThis.ArrayBuffer; globalThis.ArrayBuffer = function () { return new saved(1); };
        \\print(ab.slice(0, 4).byteLength); globalThis.ArrayBuffer = saved;
        \\const pr = Promise.resolve(); pr.constructor = { [Symbol.species]: 1 };
        \\print(message(() => pr.then()));
    ,
        \\false false undefined undefined true
        \\true 5 false 0,1
        \\TypeError:iterator must return an object
        \\Error:MAP
        \\4
        \\TypeError:not a constructor
        \\
    );
}

test "generator resume legs share the executing guard and brand check" {
    try helpers.expectPrints(
        \\const message = (f) => { try { f(); return "ok"; } catch (e) { return e.name + ":" + e.message; } };
        \\let it; const seen = [];
        \\function* g() { try { yield; } catch (e) { seen.push(message(() => it.next()), message(() => it.throw(1)), message(() => it.return())); } }
        \\it = g(); it.next(); it.throw(0); print(seen.join(" | "));
        \\const G = Object.getPrototypeOf(function* () {}).prototype;
        \\let ran = false; async function* ag() { ran = true; }
        \\print(message(() => G.next.call(ag())), message(() => G.return.call(1)), message(() => G.throw.call({})), ran);
        \\const RI = Object.getPrototypeOf(/a/g[Symbol.matchAll]("a"));
        \\print(message(() => RI.next.call((function* () { yield 1; })())));
        \\function* y() { try { yield 1; } catch (e) { yield* [5, 6]; } }
        \\const i2 = y(); i2.next(); print(JSON.stringify(i2.throw(0)), JSON.stringify(i2.next()));
        \\Object.getPrototypeOf(async function* () {}).prototype.next.call({}).catch((e) => print(e.name + ":" + e.message));
    ,
        \\TypeError:cannot invoke a running generator | TypeError:cannot invoke a running generator | TypeError:cannot invoke a running generator
        \\TypeError:not a generator TypeError:not a generator TypeError:not a generator false
        \\TypeError:next called on incompatible receiver
        \\{"value":5,"done":false} {"value":6,"done":false}
        \\TypeError:not a generator
        \\
    );
}

test "labelled break out of for await and using in switch clauses review regressions" {
    try helpers.expectPrints(
        \\async function f() {
        \\  const r = [];
        \\  l: for await (const a of [1, 2]) { r.push(a); break l; }
        \\  x: for await (const a of [1]) { for (const b of [1]) { break x; } }
        \\  y: for await (const a of [1]) { try { break y; } finally { r.push("fin"); } }
        \\  z: for await (const a of [1]) { switch (a) { case 1: break z; } }
        \\  let closed = 0;
        \\  const it = { [Symbol.asyncIterator]() { return { next() { return Promise.resolve({ done: false, value: 1 }); }, return() { closed++; return {}; } }; } };
        \\  w: for await (const a of it) break w;
        \\  return r.join() + " closed=" + closed;
        \\}
        \\f().then(print, (e) => print("ERR", e));
        \\for (const src of ["switch (0) { case 0: using x = null; }", "async function g() { switch (0) { default: await using x = null; } }", "switch (0) { case 0: { using x = null; } }"]) {
        \\  try { new Function(src); print("ok"); } catch (e) { print(e.name + ": " + e.message); }
        \\}
    ,
        \\SyntaxError: using declaration is not allowed directly in a switch clause
        \\SyntaxError: using declaration is not allowed directly in a switch clause
        \\ok
        \\1,fin closed=1
        \\
    );
}

test "AsyncGenerator return settles synchronously when PromiseResolve throws" {
    try helpers.expectPrints(
        \\const P = Promise.resolve(1);
        \\Object.defineProperty(P, "constructor", { get() { throw new Error("ctor"); } });
        \\const it = (async function* () {})();
        \\it.return(P).then(null, (e) => print("return rejected: " + e.message));
        \\it.next().then(() => print("next resolved"));
        \\Promise.resolve().then(() => print("tick1"));
    ,
        \\return rejected: ctor
        \\next resolved
        \\tick1
        \\
    );
}

test "Math.acosh below one and Math.sumPrecise cancelling to zero" {
    try helpers.expectPrints(
        \\print(Math.acosh(-1e5), Math.acosh(-65536), Math.acosh(-44400.882720947266), Math.acosh(0.5), Math.acosh(1));
        \\print(Object.is(Math.sumPrecise([-0, 1, -1]), 0), Object.is(Math.sumPrecise([1, -1, -0]), 0), Object.is(Math.sumPrecise([-0, -0]), -0));
        \\print(Object.is(Math.trunc(-0.5), -0), Math.trunc(-4.7), Math.trunc(4.7), Math.trunc(-Infinity));
    ,
        \\NaN NaN NaN NaN 0
        \\true true true
        \\true -4 4 -Infinity
        \\
    );
}

test "restricted caller/arguments lookup, catch completion, and key collection review regressions" {
    try helpers.expectPrints(
        \\const message = (f) => { try { return String(f()); } catch (e) { return e.name + ":" + e.message; } };
        \\print(message(() => (function () { "use strict"; }).caller), message(() => (function () {}).caller));
        \\const savedCaller = Object.getOwnPropertyDescriptor(Function.prototype, "caller");
        \\Object.defineProperty(Function.prototype, "caller", { get() { return "G"; }, configurable: true });
        \\const strictFn = function () { "use strict"; };
        \\print(message(() => strictFn.caller), message(() => (() => 1).caller), message(() => Reflect.get(strictFn, "caller")));
        \\Object.defineProperty(Function.prototype, "caller", savedCaller);
        \\Object.setPrototypeOf(strictFn, null); print(message(() => strictFn.caller));
        \\print(eval("try { 15; throw 0 } catch (e) {}"), eval("1; try { try { 2; throw 0 } finally { } } catch (e) {}"), eval("1; try { 2 } finally { 3 }"), eval("try { throw 0 } catch (e) { 7 }"));
        \\class B {} class D extends B { constructor() { const a = () => super(); a(); a(); } }
        \\print(message(() => new D()), message(() => +{ [Symbol.toPrimitive]() { return {}; } }), message(() => `${{ toString() { return {}; }, valueOf() { return {}; } }}`));
        \\print(message(() => Object.getOwnPropertyDescriptors(null)), message(() => Date.prototype[Symbol.toPrimitive].call({ toString: null, valueOf: null }, "number")));
        \\const ta = new Uint8Array(2); ta.x = 1; ta[Symbol.iterator] = 1;
        \\print(Reflect.ownKeys(ta).map(String).join(), Object.keys(new Array(3).fill(0)).join());
        \\const o = {}; for (let i = 0; i < 20; i++) o["k" + i] = i; let n = 0; for (const k in o) n++; print(n);
    ,
        \\TypeError:'caller', 'callee' and 'arguments' are restricted in this context undefined
        \\G G G
        \\undefined
        \\undefined undefined 2 7
        \\ReferenceError:'this' can be initialized only once TypeError:Symbol.toPrimitive must return a primitive value TypeError:cannot convert object to primitive value
        \\TypeError:cannot convert undefined or null to object TypeError:cannot convert object to primitive value
        \\0,1,x,Symbol(Symbol.iterator) 0,1,2
        \\20
        \\
    );
}

test "Array.prototype.slice defers an oversized length to ArraySpeciesCreate" {
    try helpers.expectPrints(
        \\const message = (f) => { try { return String(f()); } catch (e) { return e.name + ":" + e.message; } };
        \\let species = 0;
        \\const plain = { length: 2 ** 32 + 1, constructor: { get [Symbol.species]() { species++; return function () { return []; }; } } };
        \\print(message(() => Array.prototype.slice.call(plain)), species);
        \\let calls = 0;
        \\const Species = function () { calls++; throw new Error("species"); };
        \\const proxy = new Proxy([], {
        \\    get(target, key, receiver) {
        \\        if (key === "length") return 2 ** 32 + 1;
        \\        if (key === "constructor") return { [Symbol.species]: Species };
        \\        return Reflect.get(target, key, receiver);
        \\    },
        \\});
        \\print(message(() => Array.prototype.slice.call(proxy)), calls);
        \\print(message(() => new Array(-1)), message(() => new Array(2 ** 32)));
    ,
        \\RangeError:invalid array length 0
        \\Error:species 1
        \\RangeError:invalid array length RangeError:invalid array length
        \\
    );
}

test "Array.from lengths, sparse backward walks, sort order and generic splice review regressions" {
    try helpers.expectPrints(
        \\const message = (f) => { try { return String(f()); } catch (e) { return e.name + ":" + e.message; } };
        \\let seen; function C(n) { seen = n; throw 0; }
        \\message(() => Array.from.call(C, { length: 2 ** 31 })); print(seen);
        \\message(() => Array.from.call(C, { length: 2 ** 32 })); print(seen);
        \\print(message(() => Array.from({ length: 2 ** 32 })));
        \\const a = [1, 2, 3, 4];
        \\print(message(() => a.fill(9, 0, { valueOf() { a.length = 1; Object.defineProperty(a, "length", { writable: false }); return 4; } })), a.length);
        \\const o = { length: 2 ** 32 + 1 }; Object.defineProperty(o, 3, { get() { return "ok"; } });
        \\print(Array.prototype.reduceRight.call(o, (acc, v) => acc + v, ""));
        \\const d = { length: 2 ** 32 + 1, 1: "b", 2: "c", 3: "d" };
        \\print(Array.prototype.reduceRight.call(d, (acc, v, i) => { delete d[1]; return acc + v + i; }, ""));
        \\Object.prototype[2] = "P";
        \\print(Array.prototype.reduceRight.call({ length: 2 ** 32 + 1, 1: "b" }, (acc, v, i) => acc + v + i, ""));
        \\const b = []; b.length = 2e6; Array.prototype[5] = "x"; print(b.lastIndexOf("x"), b.lastIndexOf("P"));
        \\const u = []; u.length = 2e6; u.unshift("y"); print(Object.hasOwn(u, 6), u[6], Object.hasOwn(u, 3), u[3], u.length);
        \\delete Array.prototype[5]; delete Object.prototype[2];
        \\print(message(() => Array.prototype.reduceRight.call({ length: 2 ** 32 + 1 }, () => 0)));
        \\print(["！", "\u{1F600}", "a"].sort().join(","), ["！", "\u{1F600}"].toSorted().join(","));
        \\print(JSON.stringify(Array.prototype.splice.call({ get length() { return 3; }, set length(v) {}, 0: 1, 1: 2, 2: 3 }, 0, 1)));
        \\print(JSON.stringify(Array.prototype.splice.call({ length() {}, 0: 1 }, 0, 1)));
        \\print(message(() => Array.prototype.splice.call({ get length() { return 2; }, 0: 1, 1: 2 }, 0, 1)));
        \\class S extends Array { static get [Symbol.species]() { return function () { return [1, 2, 3, 4, 5]; }; } }
        \\print(S.from([[9]]).flat().join());
        \\let calls = 0; const ta = new Uint8Array(3); Array.prototype.fill.call(ta, { valueOf() { calls++; return 7; } }); print(calls, ta.join());
        \\print(Array.prototype.fill.call(new Uint8Array(0), Symbol()).length);
    ,
        \\2147483648
        \\4294967296
        \\RangeError:invalid array length
        \\TypeError:property is read-only 1
        \\ok
        \\d3c2
        \\P2b1
        \\5 2
        \\true x true P 2000001
        \\TypeError:empty array
        \\a,😀,！ 😀,！
        \\[1]
        \\[]
        \\TypeError:no setter for property
        \\9,2,3,4,5
        \\3 7,7,7
        \\0
        \\
    );
}

test "Promise finally receiver, async-from-sync return, rejection tracking and AsyncDisposableStack timing" {
    try helpers.expectPrints(
        \\const message = (f) => { try { return String(f()); } catch (e) { return e.name + ":" + e.message; } };
        \\Number.prototype.then = function () { return "ok"; };
        \\print(message(() => Promise.prototype.finally.call(1, () => {})), message(() => Promise.prototype.finally.call({})), message(() => Promise.prototype.catch.call({})));
        \\delete Number.prototype.then;
        \\print(message(() => DisposableStack()), message(() => AsyncDisposableStack()));
        \\const ps = []; for (let i = 0; i < 100; i++) ps.push(Promise.reject(i)); for (const p of ps) p.catch(() => {});
        \\const log = [], p = (x) => log.push(x); const a = new AsyncDisposableStack();
        \\a.defer(() => p("second")); a.use({ [Symbol.dispose]() { p("first"); throw "A"; } });
        \\a.disposeAsync().catch((e) => p("a " + e)); p("sync end");
        \\Promise.resolve().then(() => p("t1")).then(() => p("t2")).then(() => p("t3")).then(() => print(log.join("|")));
        \\Promise.allKeyed(1).catch((e) => print("allKeyed", e.name + ":" + e.message));
        \\async function* g(o) { yield* o; }
        \\const it = g({ [Symbol.iterator]() { return { next() { return { value: 1, done: false }; }, return: 1 }; } });
        \\it.next().then(() => it.return(5)).catch((e) => print("return", e.name + ":" + e.message));
    ,
        \\TypeError:not an object TypeError:not a function TypeError:not a function
        \\TypeError:must be called with new TypeError:must be called with new
        \\allKeyed TypeError:not an object
        \\first|sync end|second|t1|t2|a A|t3
        \\return TypeError:not a function
        \\
    );
}

test "parser escaped binding names, class accessor newline, top-level redeclaration, await newline and string append review regressions" {
    try helpers.expectPrints(
        \\const syntax = (src) => { try { new Function(src); return "ok"; } catch (e) { return e.name; } };
        \\print(["var f = function \\u0074his() {}", "function \\u0069f() {}", "function f(\\u0069f) {}", "(function (\\u0065num) {})", "class C { m(\\u0069f) {} }", "try {} catch (\\u0069f) {}"].map(syntax).join());
        \\print(new (eval("(class C { get\nx() { return 1; } static set\ny(v) { C.v = v; } })"))().x);
        \\print(syntax("let a = 1; function a() {}"), syntax("function a() {} var a;"), syntax("let b; { function b() {} }"));
        \\var await = 3, x; eval("await\nx"); print(await, syntax("await\n1"));
        \\let s = ""; for (let i = 0; i < 2000; i++) s = `${s}ab`; let c = ""; for (let i = 0; i < 2000; i++) c = c.concat("ab");
        \\let t = ""; const p = "x".repeat(600); for (let i = 0; i < 50; i++) { t += p; t.charCodeAt(0); t.at(-1); }
        \\print(s.length, s === c, t.length, t.codePointAt(29999));
    ,
        \\SyntaxError,SyntaxError,SyntaxError,SyntaxError,SyntaxError,SyntaxError
        \\1
        \\SyntaxError ok ok
        \\3 ok
        \\4000 true 30000 120
        \\
    );
}

test "iterator helpers complete on abrupt steps, flatMap return closes both, Iterator.from wrapper results" {
    try helpers.expectPrints(
        \\const message = (f) => { try { return String(f()); } catch (e) { return e.name + ":" + e.message; } };
        \\var i = 0, L = []; var h = { __proto__: Iterator.prototype, next() { L.push("n"); if (i++ == 1) throw 1; return { done: false, value: i }; } }.map((x) => x);
        \\h.next(); try { h.next(); } catch (e) {} print(JSON.stringify(h.next()), L.join());
        \\var c = Iterator.concat({ [Symbol.iterator]() { throw 1; } }, [7]); try { c.next(); } catch (e) {} print(JSON.stringify(c.next()));
        \\L = []; i = 0;
        \\var o = { __proto__: Iterator.prototype, next() { L.push("n"); return { done: false, value: i++ }; }, return() { L.push("r"); return {}; } };
        \\var inner = { [Symbol.iterator]() { return { next() { L.push("in"); return { done: false, value: 1 }; }, return() { L.push("inR"); throw new RangeError("inner"); } }; } };
        \\var fm = o.flatMap((x) => inner); fm.next(); try { fm.return(); } catch (e) { L.push(e.message); } print(L.join(), JSON.stringify(fm.next()));
        \\var w = Iterator.from({ next() { return 5; }, return() { return 7; } }); print(w.next(), w.return());
        \\print(message(() => Iterator.prototype.map.call(5, (x) => x)), message(() => Iterator.prototype.toArray.call(null)), message(() => [].values().reduce((a, b) => a)));
        \\print(message(() => Iterator.zip(5)), message(() => Iterator.from({ [Symbol.iterator]() { return 5; } })), message(() => Iterator.concat({ [Symbol.iterator]() { return 5; } }).next()));
    ,
        \\{"done":true} n,n
        \\{"done":true}
        \\n,in,inR,r,inner {"done":true}
        \\5 7
        \\TypeError:not an object TypeError:not an object TypeError:reduce of empty iterator with no initial value
        \\TypeError:not an object TypeError:not an object TypeError:not an object
        \\
    );
}

test "RegExp v-mode ClassSetCharacter early errors and linear alternation/lookbehind compile" {
    try helpers.expectPrints(
        \\const r = (p) => { try { new RegExp(p, "v"); return "ok"; } catch (e) { return e.name; } };
        \\print(["[\\q{a-b}]", "[\\q{(}]", "[\\q{]}]", "[\\q{a&&b}]", "[\\q{!!}]", "[a-{]", "[0-[]", "[&-(]", "[$-/]", "[1-|]"].map(r).join());
        \\print(["[\\q{abc|d}]", "[\\q{\\(}]", "[a-z]", "[\\q{a!b}]", "[a-\\{]", "[\\q{}]"].map(r).join(), /[\q{abc|d}]/v.exec("xabc")[0]);
        \\print(["[a&&&]", "[\\w&&&]", "[a&&b&&&]", "[a&&&&]"].map(r).join(), ["[a&&b]", "[a&&\\&]", "[a&&[&]]"].map(r).join());
        \\const alt = new RegExp("a|".repeat(20000) + "b"); print(alt.test("b"), alt.test("c"));
        \\const lb = new RegExp("(?<=" + "a".repeat(20000) + ")b"); print(lb.test("a".repeat(20000) + "b"), lb.test("ab"));
        \\print(JSON.stringify(/(?<=(\d+)(\d+))$/.exec("1053")), JSON.stringify(/(?<=ab|c(d)e)f/.exec("cdef")), JSON.stringify(/(x)|(y)|z/.exec("z")));
    ,
        \\SyntaxError,SyntaxError,SyntaxError,SyntaxError,SyntaxError,SyntaxError,SyntaxError,SyntaxError,SyntaxError,SyntaxError
        \\ok,ok,ok,ok,ok,ok abc
        \\SyntaxError,SyntaxError,SyntaxError,SyntaxError ok,ok,ok
        \\true false
        \\true false
        \\["","1","053"] ["f","d"] ["z",null,null]
        \\
    );
}

test "relational ToPrimitive order, Proxy trap messages, nullish base before key, JSON -0 and private setter-only read" {
    try helpers.expectPrints(
        \\const message = (f) => { try { return String(f()); } catch (e) { return e.name + ":" + e.message; } };
        \\var l = []; var A = { valueOf() { l.push("A"); return Symbol(); } }, B = { valueOf() { l.push("B"); return 1; } };
        \\try { A < B; } catch (e) { l.push(e.name); } print(l.join(), message(() => Symbol() <= { valueOf() { throw new EvalError("x"); } }));
        \\print(message(() => new (new Proxy({}, {}))()), message(() => new (new Proxy(function () {}, { construct: 5 }))()), message(() => new (new Proxy(function () {}, { construct() { return 1; } }))()));
        \\print(message(() => (new Proxy(function () {}, { apply: 5 }))()), message(() => { (new Proxy({}, { set: 5 })).x = 1; }), message(() => ({ ...new Proxy({ a: 1 }, { getOwnPropertyDescriptor: 5 }) })));
        \\var K = { toString() { l.push("tostr"); return "k"; } }; l = [];
        \\try { delete null[K]; } catch (e) { l.push(e.name); } try { null[K] = 1; } catch (e) { l.push(e.name); } print(l.join());
        \\print(Object.is(JSON.parse("[1.5,-0]")[1], -0), Object.is(JSON.parse('["\\u00e9",-0]')[1], -0), Object.is(JSON.parse("[1.5,-0]", (k, v) => v)[1], -0), Object.is(JSON.parse("-0"), -0), JSON.parse("[1.5,0,-1]").join());
        \\class C { set #s(v) {} m() { return this.#s; } } print(message(() => new C().m()));
    ,
        \\A,B,TypeError EvalError:x
        \\TypeError:not a constructor TypeError:not a function TypeError:not an object
        \\TypeError:not a function TypeError:not a function TypeError:not a function
        \\TypeError,TypeError
        \\true true true true 1.5,0,-1
        \\TypeError:'#s' was defined without a getter
        \\
    );
}

test "TypedArray copyWithin after shrink, content-type checks, transfer prototype and buffer option messages" {
    try helpers.expectPrints(
        \\const message = (f) => { try { return String(f()); } catch (e) { return e.name + ":" + e.message; } };
        \\const b = new ArrayBuffer(16, { maxByteLength: 32 }); const t = new Uint8Array(b); for (let i = 0; i < 16; i++) t[i] = i;
        \\t.copyWithin(0, -4, { valueOf() { b.resize(8); return 16; } }); print([...t].join());
        \\const c = new Uint8Array(8); c.set([1, 2, 3, 4, 5, 6, 7, 8]); c.copyWithin(1, 0, 4); print(c.join());
        \\print(message(() => new BigInt64Array(0).set(new Uint8Array(0))), message(() => new BigInt64Array(new Float64Array(0))), message(() => new Uint8Array(new BigInt64Array(0))));
        \\class B extends ArrayBuffer {} print(Object.getPrototypeOf(new B(4).transfer()) === ArrayBuffer.prototype, Object.getPrototypeOf(new B(4).transferToFixedLength()) === ArrayBuffer.prototype);
        \\print(message(() => new ArrayBuffer(4, { maxByteLength: 8 }).transfer(16)));
        \\print(message(() => Uint8Array.fromBase64("AA", { alphabet: "x" })), message(() => Uint8Array.fromHex(1)));
        \\const s = new SharedArrayBuffer(0, { maxByteLength: 1 << 20 }); s.grow(4); print(new Uint8Array(s).join());
    ,
        \\0,1,2,3,4,5,6,7
        \\1,1,2,3,4,6,7,8
        \\TypeError:cannot mix BigInt and Number typed arrays TypeError:cannot mix BigInt and Number typed arrays TypeError:cannot mix BigInt and Number typed arrays
        \\true true
        \\RangeError:invalid array buffer length
        \\TypeError:invalid option value TypeError:not a string
        \\0,0,0,0
        \\
    );
}

test "captureStackTrace receivers and proxies and AggregateError iteration" {
    try helpers.expectPrints(
        \\const message = (f) => { try { return String(f()); } catch (e) { return e.name + ":" + e.message; } };
        \\class AppError extends Error { constructor(m) { super(m); AppError.captureStackTrace(this, AppError); } }
        \\print(message(() => new AppError("x").message), message(() => { const c = Error.captureStackTrace; const o = {}; c(o); return typeof o.stack; }));
        \\const log = []; const p = new Proxy({}, { defineProperty() { log.push("dp"); throw new Error("trap"); } });
        \\print(message(() => Error.captureStackTrace(p)), log.join());
        \\for (const it of [{ [Symbol.iterator]() { return { next: 1 }; } }, { [Symbol.iterator]() { return { next() { return 1; } }; } }]) print(message(() => new AggregateError(it)));
        \\print(JSON.stringify(new AggregateError([1, 2]).errors), Array.isArray(new AggregateError(new Set([3])).errors));
    ,
        \\x string
        \\Error:trap dp
        \\TypeError:not a function
        \\TypeError:iterator must return an object
        \\[1,2] true
        \\
    );
}

test "super through proxies, OrdinarySet own descriptors, proxy invariant messages and scope review regressions" {
    try helpers.expectPrints(
        \\const message = (f) => { try { return String(f()); } catch (e) { return e.name + ":" + e.message; } };
        \\var p = new Proxy({ x: 1 }, { get(t, k, r) { return "proxied " + String(k); } }); var o = { __proto__: { __proto__: p }, m() { return super.x; } }; print(o.m());
        \\var P = new Proxy({}, { set() { return true; } }); var ro = Object.defineProperty({}, "x", { value: 1 }); Object.setPrototypeOf(ro, P);
        \\print((function () { "use strict"; return message(() => { ro.x = 2; }); })(), ro.x);
        \\var Q = new Proxy([], { set() { return true; } }); var a = [1, 2]; Object.setPrototypeOf(a, Q); a.fill(0); print(a.join());
        \\var n = Object.create(null); Reflect.set(n, "__proto__", { a: 1 }); print(Object.getPrototypeOf(n), Object.keys(n).join());
        \\print(message(() => new Proxy(Object.freeze({ x: 1 }), { get() { return 2; } }).x));
        \\var r = Proxy.revocable({ a: 1 }, { ownKeys() { r.revoke(); return ["a"]; } }); print(Reflect.ownKeys(r.proxy).join());
        \\var rf = Proxy.revocable(function () {}, {}); rf.revoke(); print(Function.prototype.toString.call(rf.proxy).includes("native code"));
        \\(function () { var h; { function f() {} h = f; } print(h === f); })();
        \\(function ({ b }) { { function b() {} } print(typeof b); })({ b: 1 });
        \\print(message(() => (function g() { (() => { "use strict"; g = 1; })(); return typeof g; })()), (function g() { (() => { g = 1; })(); return typeof g; })());
        \\try { print(eval("typeof L2")); } catch (e) { print(e.name); } let L2 = 1;
    ,
        \\proxied x
        \\TypeError:'x' is read-only 1
        \\0,0
        \\null __proto__
        \\TypeError:proxy trap result violates an invariant
        \\a
        \\true
        \\true
        \\number
        \\TypeError:'g' is read-only function
        \\ReferenceError
        \\
    );
}

test "scope re-entry after a throw, for-await completion, async-from-sync return value and sync close in async generators" {
    try helpers.expectPrints(
        \\var fs = []; for (var i = 0; i < 2; i++) { try { let v = i; fs.push(() => v); throw 0; } catch (e) {} } print(fs.map((f) => f()).join());
        \\var gs = []; for (var j = 0; j < 2; j++) { try { for (const w of [j]) { gs.push(() => w); throw 0; } } catch (e) {} } print(gs.map((f) => f()).join());
        \\var log = [];
        \\var ai = { [Symbol.asyncIterator]() { return { next() { return Promise.resolve({ done: true }); }, return() { log.push("return"); return {}; } }; } };
        \\(async () => { for await (const v of ai) {} log.push("after"); })();
        \\async function* g1() { yield* { [Symbol.iterator]() { return { next() { return { done: false, value: 1 }; } }; } }; }
        \\(async () => { const it = g1(); await it.next(); log.push(JSON.stringify(await it.return(7))); })();
        \\var sync = { [Symbol.iterator]() { return { next() { return { done: false, value: 1 }; }, return() { log.push("close"); return { then(r) { log.push("THEN"); r(); } }; } }; } };
        \\async function* g2() { for (const v of sync) { return "fr"; } }
        \\(async () => { log.push(JSON.stringify(await g2().next())); })();
        \\(async () => { for (let k = 0; k < 10; k++) await null; print(log.join(" ")); })();
    ,
        \\0,1
        \\0,1
        \\after close {"value":"fr","done":true} {"value":7,"done":true}
        \\
    );
}

test "live enumerability in Object.assign and spread, single-parameter string methods, slice length order and empty copyWithin" {
    try helpers.expectPrints(
        \\print(Object.keys(Object.assign({}, { get a() { delete this.c; return 1; }, c: 3 })).join(), JSON.stringify({ ...{ get a() { Object.defineProperty(this, "c", { enumerable: false }); return 1; }, c: 3 } }));
        \\var proto = { c: "inherited" }; var src = Object.setPrototypeOf({ get a() { delete this.c; return 1; }, c: 3 }, proto); print(JSON.stringify(Object.assign({}, src)));
        \\print("abc".charAt(1.5, Symbol()), "x".repeat(1, Symbol()), "abc".at(-1, Symbol()), "abc".codePointAt(0.5, Symbol()));
        \\var a = [1, 2, 3], log = []; a.constructor = { [Symbol.species]: function () { var t = {}; Object.defineProperty(t, "length", { set(v) { log.push(Object.keys(t).join()); } }); return t; } }; a.slice(0); print(log.join("|"));
        \\var b = new ArrayBuffer(8, { maxByteLength: 16 }), t = new Uint8Array(b, 0, 4); print(t.copyWithin(0, 0, { valueOf() { b.resize(0); return 0; } }) === t);
    ,
        \\a {"a":1}
        \\{"a":1}
        \\b x c 97
        \\0,1,2
        \\true
        \\
    );
}

test "spread call growing a leaf frame's operand stack returns through the general teardown" {
    try helpers.expectPrints(
        \\function f(a) { return a; }
        \\var a1 = [1, 2, 3, 4], a5 = [1, 2, 3, 4, 5, 6, 7, 8, 9];
        \\function g() { return f(...a1); }
        \\var o = { m(a) { return a + 1; } };
        \\function h() { return o.m(...a5); }
        \\function k() { return new Array(...a5).length; }
        \\function rest(...r) { return r.length; }
        \\function r2() { return rest(...a5, ...a5); }
        \\var total = 0; for (var i = 0; i < 50; i++) total += g() + h() + k() + r2();
        \\print(g(), h(), k(), r2(), total);
    ,
        \\1 2 9 18 1500
        \\
    );
}

test "exponent two squares exactly" {
    try helpers.expectPrints(
        \\var a = -466132836; print(a ** 2 === a * a, Math.pow(a, 2) === a * a, Object.is((-0) ** 2, 0));
    ,
        \\true true true
        \\
    );
}

test "parser fuzz regressions: yield/await operands, legacy octal member, let in patterns, early errors" {
    try helpers.expectPrints(
        \\const syntax = (src) => { try { new Function(src); return "ok"; } catch (e) { return e.name; } };
        \\var yield = 2; print(typeof yield, -yield, !yield, void yield, ~yield, yield ** 2);
        \\print(["function* g() { typeof yield; }", "function* g() { delete yield; }", "async function* g() { await yield; }", "function* g() { -yield ** 2; }"].map(syntax).join());
        \\print(017.a, 017 .toString(), 08.5, syntax("017.5"), syntax("017e1"));
        \\print(((a = 1, [let] = [2]) => let)(), (([let], a = 1) => let)([3]), (async => async + 1)(1));
        \\try { throw [4]; } catch ([let]) { print(let); }
        \\print(/\c*/.exec("\\ccc")[0], /a\c.b/.test("a\\cxb"), /\c(a)/.exec("\\ca")[1], /[\c_]/.test("\x1f"), syntax("/\\c(/"), syntax("/\\c{2,1}/"));
        \\print(["function f({ a }) { let a; }", "([a]) => { let a; }", "function f(a, { b }) { const b = 1; }", "try {} catch ({ a }) { let a; }", "try {} catch ({ a }) { var a; }"].map(syntax).join());
        \\print(["(function f({ a }) { let f; })", "function g({ a } = 1) { let arguments; }", "try {} catch (e) { var e; }", "function f({ a }) { function a() {} }"].map(syntax).join());
        \\print(["`${a}` = 1", "`${a}`++", "for (`${a}` of b);", "`a` = 1"].map(syntax).join(), `a${1}b`);
        \\print(["class A { *get x() {} }", "class A { *set x(v) {} }", "class A { async get x() {} }", "class A { static static m() {} }"].map(syntax).join());
        \\class A { *get() { yield 1; } async set() {} static static() { return 5; } }
        \\print([...new A().get()].join(), A.static());
        \\var o = { m() {} }; with (o) { f = undefined; print(f?.(), [, ...[1, 2]].length); }
        \\var c = [1], x; if (1) x = [, ...c]; print((0 ? 1 : [, ...c]).length, x.length, syntax("x = " + "`${".repeat(20000) + "1" + "}`".repeat(20000)));
    ,
        \\number -2 false undefined -3 4
        \\SyntaxError,SyntaxError,SyntaxError,SyntaxError
        \\undefined 15 8.5 SyntaxError SyntaxError
        \\2 3 2
        \\4
        \\\ccc true a true SyntaxError SyntaxError
        \\SyntaxError,SyntaxError,SyntaxError,SyntaxError,SyntaxError
        \\ok,ok,ok,ok
        \\SyntaxError,SyntaxError,SyntaxError,SyntaxError a1b
        \\SyntaxError,SyntaxError,SyntaxError,SyntaxError
        \\1 5
        \\undefined 3
        \\2 2 SyntaxError
        \\
    );
}

test "module early errors: var vs lexical names, reserved import bindings, ill-formed export names" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const invalid = [_][]const u8{
        "import a from './x.mjs'; var a;",
        "import a from './x.mjs'; { var a; }",
        "function f() {} var f;",
        "export default function f() {} for (var f;;) break;",
        "let x; { var x; }",
        "import { if } from './x.mjs';",
        "import { \"\\uD83D\" as x } from './x.mjs';",
        "var x; export { x as \"\\uDE00\" };",
    };
    for (invalid) |source| {
        var output_buffer: [64]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        try std.testing.expectError(error.SyntaxError, js.evalModuleGraph(source, &output, "early-error.mjs", std.testing.io, std.testing.allocator, 2048));
    }

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    _ = try js.evalModuleGraph(
        \\var v; var v; { function h() {} } var h;
        \\var x = 1; export { x as "\u{1F600}" };
        \\print(typeof h);
    , &output, "early-ok.mjs", std.testing.io, std.testing.allocator, 2048);
    try std.testing.expectEqualStrings("undefined\n", output.buffered());
}

test "for await break, continue and return await the iterator's return() result" {
    try helpers.expectPrints(
        \\var log = [];
        \\const later = (tag) => Promise.resolve().then(() => 0).then(() => { log.push(tag + ":settled"); return {}; });
        \\function mk(tag, ret) { return { [Symbol.asyncIterator]() { return { next() { return Promise.resolve({ value: 1, done: false }); }, return() { log.push(tag + ":return"); return ret(tag); } }; } }; }
        \\(async () => {
        \\  for await (var v of mk("brk", later)) break;
        \\  log.push("after brk");
        \\  try { for await (var v of mk("prim", () => 42)) break; } catch (e) { log.push("prim:" + e.constructor.name); }
        \\  outer: for (var i = 0; i < 1; i++) { for await (var v of mk("cont", later)) continue outer; }
        \\  log.push("after cont");
        \\  async function f() { for await (var v of mk("ret", later)) return 7; }
        \\  log.push("f=" + await f());
        \\  label: { for await (var v of mk("lbl", later)) break label; }
        \\  var n = 0; for await (var v of [1, 2, Promise.resolve(3)]) n += v;
        \\  print(log.join(), n);
        \\})();
    ,
        \\brk:return,brk:settled,after brk,prim:return,prim:TypeError,cont:return,cont:settled,after cont,ret:return,ret:settled,f=7,lbl:return,lbl:settled 6
        \\
    );
}

test "proxy [[Call]] and [[Construct]] are fixed by ProxyCreate and survive revocation" {
    try helpers.expectPrints(
        \\const r = (f) => { try { return String(f()); } catch (e) { return e.constructor.name; } };
        \\var arrow = () => 1, cls = class {}, fn = function () { return 2; }, obj = {};
        \\var P = (t) => new Proxy(t, {});
        \\var rv = Proxy.revocable(fn, {}); rv.revoke();
        \\var rv2 = Proxy.revocable(obj, {}); rv2.revoke();
        \\print([typeof P(arrow), typeof P(obj), typeof P(P(fn)), typeof rv.proxy, typeof rv2.proxy].join());
        \\print([r(() => P(arrow)()), r(() => new (P(arrow))()), r(() => P(cls)()), r(() => typeof new (P(P(cls)))()), r(() => rv.proxy()), r(() => new rv.proxy()), r(() => P(obj)()), r(() => new (P(rv.proxy))())].join());
        \\print([Reflect.construct(Object, [], P(fn)) instanceof Object, r(() => Reflect.construct(Object, [], P(arrow))), r(() => [].map.call([1], P(Math.abs)))].join());
    ,
        \\function,object,function,function,object
        \\1,TypeError,TypeError,object,TypeError,TypeError,TypeError,TypeError
        \\true,TypeError,1
        \\
    );
}

test "Date.parse terminates on long digit runs and BigInt prefixes take no sign or space" {
    try helpers.expectPrints(
        \\const r = (f) => { try { return String(f()); } catch (e) { return e.name; } };
        \\print(["1700000000000", "+1234567890", "x1234567890", "(c) 1234567890", " 1234567890 "].map(Date.parse).join());
        \\print([r(() => BigInt("0x-1")), r(() => BigInt("0x+1")), r(() => BigInt("0b 1")), r(() => BigInt("0o-10")), r(() => BigInt("0x"))].join());
        \\print("0x-1" == -1n, "0x 1" < 18n, r(() => { const a = new BigInt64Array(1); a[0] = "0x-5"; return a[0]; }));
        \\print(BigInt("0x1f"), BigInt(" -12 "), BigInt("0b101"), BigInt("  0o17\n"));
    ,
        \\NaN,NaN,NaN,NaN,NaN
        \\SyntaxError,SyntaxError,SyntaxError,SyntaxError,SyntaxError
        \\false false SyntaxError
        \\31n -12n 5n 15n
        \\
    );
}

test "writes to a const in its TDZ throw ReferenceError and closures skip environments past their binding" {
    try helpers.expectPrints(
        \\const r = (f) => { try { f(); return "ok"; } catch (e) { return e.constructor.name; } };
        \\print([r(() => { const y = (y = 1); }), r(() => { (() => { y = 1; })(); const y = 2; }), r(() => { const y = 2; y = 3; }),
        \\  r(() => { const y = 2; (() => { y = 3; })(); }), r(() => { [y] = [1]; const y = 2; }), r(() => { for (y of [1]); const y = 2; }),
        \\  r(() => { class C { m() { C = 1; } } new C().m(); })].join());
        \\var o = { z: 5 }, seen = [];
        \\with (o) { (function () { var z = 1; (function () { String(0); seen.push(z); })(); (function () { String(0); z = 2; seen.push(z); })(); })(); }
        \\function k() { eval("var w = 5"); return eval("(function () { var w = 1; return (function () { String(0); return w; })(); })()"); }
        \\print(seen.join(), o.z, k());
    ,
        \\ReferenceError,ReferenceError,TypeError,TypeError,ReferenceError,ReferenceError,TypeError
        \\1,2 5 1
        \\
    );
}

test "direct eval skips the Annex B hoist of a block function shadowed by an outer let" {
    try helpers.expectPrints(
        \\function g() { { let w = 1; eval("{ function w() {} }"); return typeof w; } }
        \\function h() { let w = 1; eval("{ function w() {} } var q = typeof w;"); return q; }
        \\function m() { eval("{ function w() {} }"); return typeof w; }
        \\function n() { { let w = 1; { eval("if (true) function w() {}"); } } return typeof w; }
        \\function b() { var w = 1; eval("{ function w() {} }"); return typeof w; }
        \\function e() { { let w = 1; try { eval("function w() {}"); } catch (err) { return err.name; } } }
        \\print([g(), h(), m(), n(), b(), e()].join());
    ,
        \\number,number,function,undefined,function,SyntaxError
        \\
    );
}

test "Set through Object.assign, typed-array prototype chains, super keys and builtin tags follow the spec" {
    try helpers.expectPrints(
        \\const r = (f) => { try { return String(f()); } catch (e) { return e.constructor.name; } };
        \\var hit = 0; var assigned = Object.assign(Object.create(new Proxy({}, { set() { hit++; return true; } })), { a: 1 });
        \\var ta = new Uint8Array(8), log = [];
        \\var mid = Object.create(ta, { 5: { set(v) { log.push(5); } }, 0: { set(v) { log.push(0); } } });
        \\var o = Object.create(mid); o[5] = 1; o[0] = 2;
        \\print(hit, Object.keys(assigned).length, log.join(), Object.keys(o).length);
        \\Object.prototype[0] = "p";
        \\var home = Object.create(new Uint8Array([9]));
        \\var sup = { __proto__: home, m() { return super[0]; } };
        \\var order = []; var target = { __proto__: null, m() { super[{ toString() { order.push("key"); return "k"; } }] = (order.push("rhs"), 1); } };
        \\print(sup.m(), r(() => target.m()), order.join());
        \\delete Object.prototype[0];
        \\class C extends Array { length = 3; }
        \\const t = (x) => Object.prototype.toString.call(x);
        \\print(r(() => new C()), t(Object.setPrototypeOf(new ArrayBuffer(1), null)), t(Object.setPrototypeOf(function* () {}, null)), t(new Proxy(() => 1, {})));
        \\var isProto = Object.prototype.isPrototypeOf; Object.setPrototypeOf(isProto, null);
        \\var frozen = Object.freeze(new Proxy({ a: 1, b: 2 }, { getOwnPropertyDescriptor(t, k) { if (k === "a") delete t.b; return Reflect.getOwnPropertyDescriptor(t, k); } }));
        \\var seen = []; String.prototype.search.call({ toString() { seen.push("toString"); return "x"; } }, { [Symbol.search](s) { seen.push(typeof s); return 0; } });
        \\print(Object.getPrototypeOf(isProto), Object.keys(frozen).join(), seen.join(), [].values().constructor === Iterator);
        \\Object.setPrototypeOf(isProto, Function.prototype);
        \\print(String(Iterator.concat([1])), Iterator.prototype[Symbol.dispose].call({ return() { return 5; } }));
    ,
        \\1 0 5,0 0
        \\9 TypeError rhs,key
        \\TypeError [object Object] [object Function] [object Function]
        \\null a object true
        \\[object Iterator Helper] undefined
        \\
    );
}

test "object model: typed-array fields and receivers, inherited array length, null class heritage, namespace key order" {
    try helpers.expectPrints(
        \\const r = (f) => { try { return String(f()); } catch (e) { return e.constructor.name; } };
        \\class F extends Uint8Array { foo = 5; }
        \\var ta = new Uint8Array(4);
        \\print(r(() => new F(2).foo), Reflect.set({}, "9", 7, ta), Reflect.set({}, "-0", 7, ta), Object.keys(ta).join());
        \\print(Reflect.set({}, "length", { valueOf() { return 2; } }, [1, 2, 3]));
        \\var ro = [1]; Object.defineProperty(ro, "length", { writable: false }); var n = 0;
        \\print(Reflect.set(ro, "length", Symbol()), Reflect.set(ro, "length", { valueOf() { n++; return 1; } }), n);
        \\var o = Object.create(Object.freeze([1, 2])); o.length = 1;
        \\print(o.length, Object.hasOwn(o, "length"), r(() => { "use strict"; var q = Object.create(Object.freeze([1])); q.length = 0; }));
        \\class S extends Uint8Array { m() { super[0] = 5; return this[0]; } }
        \\var t = new Uint8Array(2); Object.defineProperty(t, "length", { value: 7, enumerable: true });
        \\var C = function () {}; C.prototype = null; class A extends C {}
        \\print(new S(2).m(), Reflect.ownKeys(t).join(), Object.getPrototypeOf(A.prototype));
        \\var b = new ArrayBuffer(4), d = new Uint8Array(b); b.transfer();
        \\print(JSON.stringify(Array.prototype.map.call(d, (x) => x)), r(() => d.map((x) => x)));
        \\var arr = [1, 2]; Object.setPrototypeOf(arr, new Proxy(arr, {})); var ks = []; for (var k in arr) ks.push(k);
        \\print(ks.join());
    ,
        \\5 false false 0,1,2,3
        \\true
        \\false false 0
        \\2 false TypeError
        \\5 0,1,length null
        \\[] TypeError
        \\0,1
        \\
    );
}

test "indexOf, includes and sort on huge sparse arrays visit only present indices" {
    try helpers.expectPrints(
        \\var a = []; a[4294967294] = 7; a[3] = 1;
        \\print(a.indexOf(7), a.includes(7), a.indexOf(1, 4), a.includes(undefined, 4294967290), a.indexOf(9));
        \\Array.prototype[10] = 9; print(a.indexOf(9)); delete Array.prototype[10];
        \\var s = []; s[1e9] = 1; s[5] = 2; s[7] = 0; s.sort();
        \\print(Object.keys(s).join(), s.length);
    ,
        \\4294967294 true -1 true -1
        \\10
        \\0,1,2 1000000001
        \\
    );
}

test "async yield* returns the inner return value as is and routes a rejected return value to throw" {
    try helpers.expectPrints(
        \\var log = [];
        \\const inner = { [Symbol.asyncIterator]() { return { next() { return { value: 1, done: false }; }, return(v) { return { value: Promise.resolve("P"), done: true }; } }; } };
        \\const g = (async function* () { yield* inner; })();
        \\g.next().then(() => g.return(39)).then((r) => log.push(typeof r.value + ":" + (r.value instanceof Promise)));
        \\const h = (async function* () { yield* (function* () { try { yield 1; } catch (e) { log.push("inner caught " + e); yield "x"; } })(); })();
        \\h.next().then(() => h.return(Promise.reject("R"))).then((r) => log.push("ret " + r.value + " " + r.done), (e) => log.push("ret err " + e));
        \\let n = 0; (function fin() { if (n++ < 20) queueMicrotask(fin); else print(log.join("|")); })();
    ,
        \\inner caught R|object:true|ret x false
        \\
    );
}

test "TypeScript computed signatures, namespace object aliasing and shadowing, enum folding" {
    try helpers.expectPrints(
        \\class C { [Symbol.iterator](): Iterator<number>; [Symbol.iterator]() { return [1, 2][Symbol.iterator](); } }
        \\class D { ["m"](x: string): void; ["m"](x: any) { return typeof x; } static ["s"](): number; static ["s"]() { return 3; } ["x"]?(): void; }
        \\abstract class A { abstract [Symbol.toPrimitive]: number; abstract ["k"](): void; ["z"] = 1; }
        \\class B extends A { k() {} }
        \\print([...new C()].join(), new D().m(1), D.s(), "x" in new D(), JSON.stringify(Object.keys(new B())));
        \\namespace N { export const a = 1; export function f(N: number) { return N + a; } export function g({ a }: { a: number }) { return a; } export const h = function a() { return typeof a; }; }
        \\namespace Foo { export class Foo { x = 1; } }
        \\namespace M { export const M = 4; }
        \\namespace P { export const x = 1; }
        \\namespace P { const x = 2; export const y = x; }
        \\print(N.f(10), N.g({ a: 7 }), N.h(), new Foo.Foo().x, M.M, P.y);
        \\enum E { X = "a" + 1, N = NaN, K = E["N"] }
        \\let arr: Array<<T>() => T> = [];
        \\print(JSON.stringify(E), arr.length);
    ,
        \\1,2 number 3 false ["z"]
        \\11 7 function 1 4 2
        \\{"X":"a1","N":null,"NaN":"K","K":null} 0
        \\
    );
}

test "TypeScript keyword types, non-null after assertions, enum members and block enums" {
    try helpers.expectPrintsTs(
        \\let a: any = 1, b: any = 2;
        \\print(a as number < 5, a satisfies any < b, a as number!);
        \\class K<T> { v = 1; }
        \\print(new K!<number>().v);
        \\let f = (x: number)
        \\  : number => x + 1;
        \\print(f(1));
        \\namespace O { export namespace I { export const w = 1; } }
        \\namespace O { export import J = I; export const t = J.w; }
        \\print(O.t);
        \\let E = 0;
        \\{ enum E { Z } }
        \\print(E);
        \\const k = 5;
        \\enum G { A = k, B }
        \\enum H { Infinity = Math.floor(2.5), D = Infinity | 8 }
        \\enum S { A = "a", C = `x${A}` }
        \\print(G.B, H.D, JSON.stringify(S));
        \\let t: any, o: any = {};
        \\[t as any] = [1]; ({ a: o.p satisfies any } = { a: 2 }); print(t, o.p);
        \\type U = any; const q: any = 4;
        \\print([q<Array<U>> / 2][0]);
        \\namespace NS { export const x = 1; export function f() { function x() { return "local"; } return x(); } export declare let y: number; export function g() { return typeof y; } }
        \\(NS as any).y = 5;
        \\print(NS.f(), NS.g());
    ,
        \\true true 1
        \\1
        \\2
        \\1
        \\0
        \\6 10 {"A":"a","C":"xa"}
        \\1 2
        \\2
        \\local number
        \\
    );
}

test "import with only type specifiers still evaluates the module" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const modules = [_]helpers.MemoryModule{
        .{ .specifier = "./dep.ts", .path = "/fixture/dep.ts", .source = "globalThis.depRan = true; export type T = number;" },
    };
    var host = helpers.MemoryModules{ .modules = &modules };
    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    _ = try js.evalModuleGraphInMemory(
        \\import { type T } from "./dep.ts";
        \\import type { T as U } from "./missing.ts";
        \\print(globalThis.depRan === true);
    , &output, "/fixture/main.ts", &host, std.testing.allocator);
    try std.testing.expectEqualStrings("true\n", output.buffered());
}

test "TypeScript instantiation expressions before as/satisfies and a parameter named asserts" {
    try helpers.expectPrintsTs(
        \\function f<T>(x?: T) { return 1; }
        \\const g = f<number> as any; const h = f<string> satisfies Function;
        \\function p(asserts: any): asserts is number { return true as any; }
        \\function q(x: any): asserts x is string {}
        \\print(typeof g, typeof h, p(1), typeof q);
    ,
        \\function function true function
        \\
    );
}

test "RegExp Annex B class atoms, brace literals, empty property values, source escaping and astral group names" {
    try helpers.expectPrints(
        \\const r = (f) => { try { return JSON.stringify(f()); } catch (e) { return e.name; } };
        \\print([r(() => /[\c]/i.exec("c")), r(() => /[\c-e]+/.exec("cde\\")), r(() => new RegExp("[\\é]").test("é")), r(() => /[\d-a-z]/.test("m")), r(() => /[\d-a-z]/.test("z"))].join(" "));
        \\print([r(() => new RegExp("a{1,0").exec("a{1,0")), r(() => new RegExp("a{2,1}")), r(() => new RegExp("\\p{L=}", "u")), r(() => /\p{gc=Lu}/u.test("A"))].join(" "));
        \\var m = new RegExp("(?<𝒜>.)").exec("a");
        \\print(String(new RegExp("\\[/]")), m.groups["𝒜"], "a".replace(new RegExp("(?<𝒜>.)"), "[$<𝒜>]"), new RegExp("(a){100000}").test("a".repeat(100000)));
    ,
        \\["c"] ["cde\\"] true false true
        \\["a{1,0"] SyntaxError SyntaxError true
        \\/\[\/]/ a [a] true
        \\
    );
}

test "Set union and symmetricDifference rehash receiver keys a minor moved" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const nursery_enabled = js.runtime.gc.nursery.enabled;
    defer js.runtime.gc.nursery.enabled = nursery_enabled;
    js.runtime.gc.nursery.enabled = true;
    _ = try js.eval(
        \\var objs = [], s = new Set();
        \\for (let i = 0; i < 64; i++) { const o = { i }; objs.push(o); s.add(o); }
    );
    // An exact minor moves the young keys; the receiver's stored hashes stay
    // stale until its next lookup, so the copies must rehash.
    _ = try core.gc_trace_stw.collectMinor(js.runtime, .declared_only);
    const result = try js.eval(
        \\const other = { size: 0, has() { return false; }, keys() { return [].values(); } };
        \\const lost = [s.union(other), s.symmetricDifference(other)].map((r) => objs.filter((o) => !r.has(o)).length);
        \\if (lost.join() !== "0,0") throw new Error("copies lost keys: " + lost);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "repeated WeakRef deref keeps each target once" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    // The list is cleared only when a checkpoint ends, which a script's own
    // loop never reaches; alternating targets used to append per call.
    _ = try js.eval("globalThis.refs = [{}, {}, Symbol('s')].map((t) => new WeakRef(t))");
    const global = try zjs.exec.zjs_vm.contextGlobal(js.context);
    const array = core.value_semantics.objectFromValue(try global.getProperty(try js.runtime.internAtom("refs"))).?;
    js.runtime.microtasks.clearKeptObjects(js.runtime.nativeAllocator());
    for (0..1000) |_| {
        for (0..3) |index| _ = try core.value_semantics.objectFromValue(try array.getProperty(core.Atom.taggedInt(@intCast(index)))).?.weakRefDeref(js.runtime);
    }
    try std.testing.expectEqual(@as(usize, 3), js.runtime.microtasks.weakref_kept_alive.items.len);
    js.runtime.microtasks.clearKeptObjects(js.runtime.nativeAllocator());
}

test "RegExp String Iterator follows its generator shape" {
    try helpers.expectPrints(
        \\const species = (exec) => ({ [Symbol.species]: function () { return { flags: this.flags, lastIndex: 0, exec }; } });
        \\// Non-global: the one match is yielded without reading its [0].
        \\const once = /a/; once.constructor = species(() => ({ get 0() { throw new Error("read"); } }));
        \\print(RegExp.prototype[Symbol.matchAll].call(once, "a").next().done);
        \\// An abrupt completion finishes the iterator.
        \\let calls = 0;
        \\const failing = /a/g; failing.constructor = species(() => { calls++; throw new Error("boom"); });
        \\const it = RegExp.prototype[Symbol.matchAll].call(failing, "a");
        \\try { it.next(); } catch (e) { print(e.message); }
        \\print(it.next().done, calls);
        \\// `next` from inside its own exec finds it running.
        \\let inner = "", count = 0, it2;
        \\const reentrant = /a/g; reentrant.constructor = species(() => { if (count++ === 0) { try { it2.next(); } catch (e) { inner = e.constructor.name; } } return count < 3 ? ["a"] : null; });
        \\it2 = RegExp.prototype[Symbol.matchAll].call(reentrant, "a");
        \\print([...it2].length, inner);
    ,
        \\false
        \\boom
        \\true 1
        \\2 TypeError
        \\
    );
}

test "super(args) and default derived constructor chains run in the interpreter loop" {
    try helpers.expectPrints(
        \\let src = "class C0 { constructor(a) { this.v = a; this.t = new.target.name; } }\n";
        \\for (let i = 1; i <= 1000; i++) src += `class C${i} extends C${i - 1} { constructor(a) { super(a + 1); } }\n`;
        \\const o = new Function(src + "return new C1000(0);")();
        \\print(o.v, o.t);
        \\class Base { constructor(fail) { if (fail) throw new Error("base"); this.t = new.target.name; } }
        \\class Derived extends Base { constructor(fail) { try { super(fail); } catch (e) { return { caught: e.message }; } } }
        \\print(new Derived(false).t, new Derived(true).caught, Reflect.construct(Derived, [false], function F() {}).t);
        \\// Default derived constructors forward through OP_init_ctor.
        \\let defaults = "class D0 { constructor(...a) { this.a = a; } }\n";
        \\for (let i = 1; i <= 1000; i++) defaults += `class D${i} extends D${i - 1} {}\n`;
        \\print(JSON.stringify(new Function(defaults + "return new D1000(1, 2);")().a));
    ,
        \\1000 C1000
        \\Derived base F
        \\[1,2]
        \\
    );
}

test "Proxy.revocable result and a refused stack set through a Proxy" {
    try helpers.expectPrints(
        \\const r = Proxy.revocable({}, {});
        \\print(Object.getPrototypeOf(r) === Object.prototype, String(r));
        \\const setter = Object.getOwnPropertyDescriptor(Error.prototype, "stack").set;
        \\const p = new Proxy({}, { getOwnPropertyDescriptor() { return { get: undefined, set: setter, configurable: true }; }, set() { return false; } });
        \\try { setter.call(p, "x"); } catch (e) { print(e.constructor.name, e.message !== ""); }
    ,
        \\true [object Object]
        \\TypeError true
        \\
    );
}

test "Date toPrimitive accepts only the spec hints" {
    try helpers.expectPrints(
        \\const d = new Date(0);
        \\print(d[Symbol.toPrimitive]("number"), typeof d[Symbol.toPrimitive]("default"));
        \\try { d[Symbol.toPrimitive]("integer"); } catch (e) { print(e.constructor.name); }
    ,
        \\0 string
        \\TypeError
        \\
    );
}

test "JSON.stringify drops omitted object members cleanly" {
    try helpers.expectPrints(
        \\const o = { a: 1, b: undefined, c() {}, d: { e: Symbol(), f: [undefined, () => 0] }, g: 2 };
        \\print(JSON.stringify(o));
        \\print(JSON.stringify(o, null, 2));
        \\print(JSON.stringify(o, (k, v) => (k === "a" || k === "g" ? undefined : v), "-"));
        \\print(JSON.stringify({ x: undefined }, null, 2), JSON.stringify({ x: undefined, y: 1 }, ["x", "y"]));
    ,
        \\{"a":1,"d":{"f":[null,null]},"g":2}
        \\{
        \\  "a": 1,
        \\  "d": {
        \\    "f": [
        \\      null,
        \\      null
        \\    ]
        \\  },
        \\  "g": 2
        \\}
        \\{
        \\-"d": {
        \\--"f": [
        \\---null,
        \\---null
        \\--]
        \\-}
        \\}
        \\{} {"y":1}
        \\
    );
}

test "destructuring a finished generator binds undefined" {
    try helpers.expectPrints(
        \\function* g() { yield 5; return "R"; }
        \\var [a, b] = g();
        \\var [x, y = "dflt"] = g();
        \\var it = g(); it.next(); var [c = "d"] = it;
        \\var e, f; [e, f] = g();
        \\print(a, b, y, c, f);
        \\try { var [[q]] = (function* () { return "r"; })(); } catch (err) { print(err.constructor.name); }
    ,
        \\5 undefined dflt d undefined
        \\TypeError
        \\
    );
}

test "Iterator.zip closes every iterator after one's return throws" {
    try helpers.expectPrints(
        \\const make = (name, ret) => ({ [Symbol.iterator]() { return { next() { return { done: false, value: name }; }, return: ret }; } });
        \\const a = make("a", () => { print("closed a", [1, 2].join("-")); return {}; });
        \\const b = make("b", () => { throw new Error("b"); });
        \\const zipped = Iterator.zip([a, b]);
        \\zipped.next();
        \\try { zipped.return(); } catch (e) { print("caught", e.message); }
    ,
        \\closed a 1-2
        \\caught b
        \\
    );
}

test "direct eval inside with keeps with-object references" {
    try helpers.expectPrints(
        \\var o = { f() { return this === o; }, x: 1 };
        \\with (o) {
        \\  print(eval("f()"), eval("'use strict'; f()"), eval("(function () { return f(); })()"));
        \\}
        \\var x = "g";
        \\with (o) { eval("x = (delete o.x, 2)"); }
        \\print(o.x, x);
    ,
        \\true true true
        \\2 g
        \\
    );
}

test "a global lexical in its TDZ shadows a same-named global data property" {
    try helpers.expectPrints(
        \\globalThis.tdzName = 0;
        \\try { print(eval("tdzName")); } catch (e) { print(e.name, e.message); }
        \\try { print(Function("return tdzName")()); } catch (e) { print(e.name, e.message); }
        \\let tdzName = 1;
        \\print(eval("tdzName"));
    ,
        \\ReferenceError Cannot access 'tdzName' before initialization
        \\ReferenceError Cannot access 'tdzName' before initialization
        \\1
        \\
    );
}

test "stack positions stay correct inside an inlined constructor" {
    try helpers.expectPrints(
        \\function P(x, y) {
        \\  this.x = x;
        \\  this.y = y.z;
        \\}
        \\function make(a, b) {
        \\  var p = new P(a, b);
        \\  return p;
        \\}
        \\for (var i = 0; i < 100; i++) make(i, { z: 1 });
        \\try { make(1, null); } catch (e) {
        \\  print(e.stack.split("\n").slice(0, 2).map((line) => line.replace(/\(.*:(\d+:\d+)\)/, "$1")).join(" | "));
        \\}
        \\// The directive prologue sees any WhiteSpace before its terminator.
        \\try { eval("'use strict'\u3000; undeclaredByDirective = 1"); print("sloppy"); } catch (e) { print(e.name); }
    ,
        \\    at P 3:13 |     at make 6:16
        \\ReferenceError
        \\
    );
}

test "a synthesized class constructor frame points at its class" {
    try helpers.expectPrints(
        \\class A {
        \\  f = null.x;
        \\}
        \\function mk() { return new A(); }
        \\try { mk(); } catch (e) { print(e.stack.split("\n")[1].replace(/\(.*:(\d+:\d+)\)/, "$1")); }
    ,
        \\    at A 1:1
        \\
    );
}

test "Error.captureStackTrace skips frames by function identity" {
    try helpers.expectPrints(
        \\const frames = (stack) => stack.split("\n").filter(Boolean).map((line) => line.trim().split(" ")[1]).join(",");
        \\function inner(o) { Error.captureStackTrace(o); }
        \\function outer() { const o = {}; inner(o); return frames(o.stack); }
        \\print(outer());
        \\const f1 = function dup(o, f) { Error.captureStackTrace(o, f); };
        \\const f2 = function dup() {};
        \\function caller() { const o = {}; f1(o, f2); return JSON.stringify(o.stack); }
        \\print(caller());
        \\function A() { const o = {}; Error.captureStackTrace(o, A); return frames(o.stack); }
        \\function B() { return A(); }
        \\print(B());
    ,
        \\inner,outer,<eval>
        \\""
        \\B,<eval>
        \\
    );
}

test "strict-mode checks after a function body point at their cause" {
    try helpers.expectPrints(
        \\const at = (src) => { try { eval(src); } catch (e) { return e.lineNumber + ":" + e.columnNumber; } };
        \\print(at("function f(a, a) {\n  'use strict';\n}\n\nvar x;"));
        \\print(at("function eval() {\n'use strict';\n}\n\nvar x;"));
        \\print(at("function g(a = 1) {\n  'use strict';\n}\nvar y;"));
    ,
        \\1:15
        \\2:1
        \\2:3
        \\
    );
}

test "RegExp rejects Unicode binary properties ECMA-262 does not list" {
    try helpers.expectPrints(
        \\const r = (source, flags) => { try { new RegExp(source, flags); return "ok"; } catch (e) { return e.name; } };
        \\print(["\\p{IDSU}", "\\p{IDS_Unary_Operator}", "\\P{MCM}", "\\p{Modifier_Combining_Mark}", "\\p{IDSB}"].map((p) => r(p, "u") + "/" + r(p, "v")).join(" "));
    ,
        \\SyntaxError/SyntaxError SyntaxError/SyntaxError SyntaxError/SyntaxError SyntaxError/SyntaxError ok/ok
        \\
    );
}

test "String.prototype[Symbol.iterator] converts any receiver to a string" {
    try helpers.expectPrints(
        \\const it = String.prototype[Symbol.iterator].call([].values());
        \\print(it.next().value, Object.prototype.toString.call(it));
    ,
        \\[ [object String Iterator]
        \\
    );
}

test "RegExp literal search skips leading lookarounds" {
    try helpers.expectPrints(
        \\print(/(?<=\d+)x/.test("1".repeat(50000) + "x"), /(?<=^a*)b/.test("a".repeat(50000) + "b"));
        \\print(/(?<!y)x/.exec("yxax").index, /(?=x)x/.exec("abx").index, /(?<=(\d))x/.exec("a5x")[1], /(?!x)x/.test("xx"));
    ,
        \\true true
        \\3 2 5 false
        \\
    );
}

test "typed array sort, set, construct and error prototypes follow spec order" {
    try helpers.expectPrints(
        \\var ta = new Uint8Array(1 << 20).fill(7); ta[0] = 9; ta.sort(); print(ta[0], ta[ta.length - 1]);
        \\var SavedTypeError = TypeError; globalThis.TypeError = function Fake() {}; var e; try { null.x } catch (err) { e = err }
        \\globalThis.TypeError = SavedTypeError; print(Object.getPrototypeOf(e) === TypeError.prototype, e.name);
        \\var log = []; var t = new Int8Array(4); t.buffer.transfer();
        \\try { t.set([1], { valueOf() { log.push("offset"); return 0 } }); } catch (x) { log.push(x.name) } print(log.join());
        \\var n = 0; Reflect.construct(Int8Array, [new ArrayBuffer(8), { valueOf() { n++; return 0 } }, { valueOf() { n++; return 1 } }]); print(n);
        \\log = []; var nt = new Proxy(function(){}, { get(t, k) { if (k === "prototype") log.push("proto"); return Reflect.get(t, k) } });
        \\Reflect.construct(Uint8Array, [{ get [Symbol.iterator]() { log.push("iter"); return [][Symbol.iterator] }, get length() { log.push("len"); return 0 } }], nt); print(log.join());
    ,
        \\7 9
        \\true TypeError
        \\offset,TypeError
        \\2
        \\proto,iter,len
        \\
    );
}

test "immutable ArrayBuffer is not provided and typed arrays seal through their own define" {
    try helpers.expectPrints(
        \\print(["immutable", "transferToImmutable", "sliceToImmutable"].map(function (k) { return k in ArrayBuffer.prototype; }).join());
        \\for (const f of [Object.seal, Object.freeze]) { try { f(new Uint8Array(2)); } catch (e) { print(e.name); } }
        \\print(Object.isFrozen(Object.freeze(new Uint8Array(0))));
        \\var proto = new Uint8Array(1); var o = Object.create(proto);
        \\print(Reflect.set(proto, 0, 5, 1), Reflect.set(proto, 3, 5, 1), proto[0]);
    ,
        \\false,false,false
        \\TypeError
        \\TypeError
        \\true
        \\false true 0
        \\
    );
}

test "FinalizationRegistry unregister finds cells by token and id" {
    try helpers.expectPrints(
        \\var fr = new FinalizationRegistry(() => {});
        \\var t = {}, t2 = {}, a = {}, b = {}, c = {};
        \\fr.register(a, 1, t); fr.register(b, 2, t);
        \\print(fr.unregister(t), fr.unregister(t));
        \\fr.register(c, 3, t2); print(fr.unregister(t2)); fr.register(c, 4, t2); fr.register(a, 5, t2); print(fr.unregister(t2), fr.unregister(t2));
        \\var tokens = [], targets = [];
        \\for (var i = 0; i < 200; i++) { tokens.push({}); targets.push({}); fr.register(targets[i], i, tokens[i]); }
        \\var ok = 0; for (var i = 199; i >= 0; i -= 2) ok += fr.unregister(tokens[i]);
        \\for (var i = 0; i < 200; i += 2) ok += fr.unregister(tokens[i]);
        \\for (var i = 0; i < 200; i++) ok += fr.unregister(tokens[i]) ? 1000 : 0;
        \\fr.register(a, 6, t); fr.register(b, 7, tokens[5]); print(ok, fr.unregister(tokens[5]), fr.unregister(t), fr.unregister({}));
    ,
        \\true false
        \\true
        \\true false
        \\200 true true false
        \\
    );
}

test "super references, private optional calls, new super and constructor coercion order" {
    try helpers.expectPrints(
        \\class B { get g() { const t = this; return () => t; } }
        \\class C extends B { m() { return [super.g() === this, super["g"]() === this, super.g?.() === this, (super.g)() === this].join(); } }
        \\print(new C().m());
        \\class P { #m() { return this === undefined ? "U" : "ok"; } run() { const o = { c: this }; return [(o?.c.#m)(), (this?.#m)(), (o.c?.#m)()].join(); } }
        \\print(new P().run());
        \\const o = { __proto__: { F: function () { this.q = 1; } }, m() { return new super.F().q + new super["F"]().q; } };
        \\print(o.m());
        \\for (const src of ["new super()", "new super", "new super`t`"]) { try { new Function("return {m(){" + src + "}}"); print("compiled"); } catch (e) { print(e.name); } }
        \\for (const K of [Date, String]) {
        \\  const L = []; const NT = function () {}.bind();
        \\  Object.defineProperty(NT, "prototype", { get() { L.push("proto"); return K.prototype; } });
        \\  Reflect.construct(K, [{ valueOf() { L.push("arg"); return 1; }, toString() { L.push("arg"); return "s"; } }], NT);
        \\  print(L.join());
        \\}
        \\const q = new Set([0]); let n = 0; for (const x of q) { q.delete(x); if (x < 50) q.add(x + 1); n++; } print(n, q.size);
    ,
        \\true,true,true,true
        \\ok,ok,ok
        \\2
        \\SyntaxError
        \\SyntaxError
        \\SyntaxError
        \\arg,proto
        \\arg,proto
        \\51 0
        \\
    );
}

test "WeakMap ephemeron chains resolve through object and symbol keys and nested holders" {
    try helpers.expectPrints(
        \\const wm = new WeakMap();
        \\let head;
        \\{
        \\  const keys = []; for (let i = 0; i < 300; i++) keys.push(i % 3 === 1 ? Symbol("s" + i) : { i });
        \\  for (let i = keys.length - 2; i >= 0; i--) wm.set(keys[i], keys[i + 1]);
        \\  // A holder reachable only through an ephemeron value, keyed by the head.
        \\  const inner = new WeakMap(); inner.set(keys[0], { deep: 7 });
        \\  wm.set(keys[keys.length - 1], { end: true, inner });
        \\  head = keys[0];
        \\}
        \\$262.gc(); $262.gc();
        \\let n = 0, cur = head; while (wm.has(cur)) { cur = wm.get(cur); n++; }
        \\print(n, cur.end, cur.inner.get(head).deep);
    ,
        \\300 true 7
        \\
    );
}

test "Iterator.zip padding never reads a done value and Iterator.prototype.constructor is intrinsic" {
    try helpers.expectPrints(
        \\const log = [];
        \\const pad = { [Symbol.iterator]() { return { next() { return { done: true, get value() { log.push("value"); return 1; } }; } }; } };
        \\print(JSON.stringify([...Iterator.zip([[1], [2, 3]], { mode: "longest", padding: pad })]), log.length);
        \\const P = Iterator.prototype, I = Iterator; globalThis.Iterator = 5;
        \\print(P.constructor === I);
        \\globalThis.Iterator = I;
    ,
        \\[[1,2],[null,3]] 0
        \\true
        \\
    );
}

fn expectModuleGraphPrints(modules: []const helpers.MemoryModule, entry_source: []const u8, expected: []const u8) !void {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var host = helpers.MemoryModules{ .modules = modules };
    var output_buffer: [512]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    _ = try js.evalModuleGraphInMemory(entry_source, &output, "/fixture/main.mjs", &host, std.testing.allocator);
    try std.testing.expectEqualStrings(expected, output.buffered());
}

/// `count` generated modules named `./{prefix}{i}.mjs`; `source` writes
/// module `i`'s body.
fn generatedModules(
    arena: std.mem.Allocator,
    count: usize,
    comptime prefix: []const u8,
    comptime source: fn (std.mem.Allocator, usize, usize) anyerror![]const u8,
) ![]helpers.MemoryModule {
    const modules = try arena.alloc(helpers.MemoryModule, count);
    for (modules, 0..) |*module, i| module.* = .{
        .specifier = try std.fmt.allocPrint(arena, "./" ++ prefix ++ "{d}.mjs", .{i}),
        .path = try std.fmt.allocPrint(arena, "/fixture/" ++ prefix ++ "{d}.mjs", .{i}),
        .source = try source(arena, i, count),
    };
    return modules;
}

test "export star diamonds resolve once per name, not once per path" {
    // Layer i is d{2i} and d{2i+1}, each `export *` from both modules of
    // layer i + 1; the last layer re-exports one leaf, which is reachable
    // along 2^32 paths.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const layers = 32;
    const Source = struct {
        fn body(arena: std.mem.Allocator, i: usize, count: usize) ![]const u8 {
            const leaf = count - 1;
            if (i == leaf) return "export const x = 1; export const y = 2;";
            const next = 2 * (i / 2) + 2;
            if (next == leaf) return std.fmt.allocPrint(arena, "export * from './d{d}.mjs';", .{leaf});
            return std.fmt.allocPrint(arena, "export * from './d{d}.mjs'; export * from './d{d}.mjs';", .{ next, next + 1 });
        }
    };
    const modules = try generatedModules(arena_state.allocator(), 2 * layers + 1, "d", Source.body);
    try expectModuleGraphPrints(modules,
        \\import * as ns from './d0.mjs';
        \\import { x } from './d1.mjs';
        \\print(Object.keys(ns).join(), x);
    , "x,y 1\n");
}

test "export star chains deeper than the native stack resolve" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const Source = struct {
        fn body(arena: std.mem.Allocator, i: usize, count: usize) ![]const u8 {
            if (i + 1 == count) return "export const x = 42;";
            return std.fmt.allocPrint(arena, "export * from './s{d}.mjs';", .{i + 1});
        }
        fn run(modules: []const helpers.MemoryModule, result: *anyerror!void) void {
            result.* = expectModuleGraphPrints(modules,
                \\import * as ns from './s0.mjs';
                \\import { x } from './s0.mjs';
                \\print(Object.keys(ns).join(), x);
            , "x 42\n");
        }
    };
    const modules = try generatedModules(arena_state.allocator(), 5_000, "s", Source.body);
    // A 2 MiB thread stack: one native frame per chain link would overflow it.
    var result: anyerror!void = {};
    const thread = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, Source.run, .{ modules, &result });
    thread.join();
    try result;
}

test "module install keeps its resolved request names across a heap-limit collection" {
    const modules = [_]helpers.MemoryModule{
        .{ .specifier = "./dep.mjs", .path = "/fixture/dep.mjs", .source = "export const value = 'dep';" },
        .{ .specifier = "./mid.mjs", .path = "/fixture/mid.mjs", .source = "export { value } from './dep.mjs';" },
    };
    var delta: usize = 0;
    while (delta < 256 * 1024) : (delta += 1024) {
        var js = try helpers.TestEngine.init(std.testing.allocator);
        defer js.deinit();
        var host = helpers.MemoryModules{ .modules = &modules };
        var output_buffer: [256]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        js.runtime.setMemoryLimit(js.runtime.gc.heap_budget.bytes + delta);
        // Over the limit every allocation collects first, so some limit puts
        // a major between interning a resolved request name and publishing
        // the record that traces it. Only success or a clean OOM is allowed.
        _ = js.evalModuleGraphInMemory("import { value } from './mid.mjs'; print(value);", &output, "/fixture/main.mjs", &host, std.testing.allocator) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        try std.testing.expectEqualStrings("dep\n", output.buffered());
    }
}

test "assigning to a module namespace export in its TDZ throws TypeError" {
    try expectModuleGraphPrints(&.{
        .{ .specifier = "./m.mjs", .path = "/fixture/m.mjs", .source =
        \\import * as self from './m.mjs';
        \\try { self.later = 2; } catch (e) { print(e.constructor.name); }
        \\print(Reflect.set(self, 'later', 2));
        \\export let later = 1;
        },
    },
        \\import './m.mjs';
    , "TypeError\nfalse\n");
}

test "export star still reports a name two different modules provide as ambiguous" {
    try expectModuleGraphPrints(&.{
        .{ .specifier = "./a.mjs", .path = "/fixture/a.mjs", .source = "export * from './b.mjs'; export * from './c.mjs';" },
        .{ .specifier = "./b.mjs", .path = "/fixture/b.mjs", .source = "export * from './d.mjs'; export const z = 'b';" },
        .{ .specifier = "./c.mjs", .path = "/fixture/c.mjs", .source = "export * from './d.mjs'; export const z = 'c';" },
        .{ .specifier = "./d.mjs", .path = "/fixture/d.mjs", .source = "export const shared = 'd';" },
    },
        \\import * as ns from './a.mjs';
        \\print(Object.keys(ns).join(), ns.shared, 'z' in ns);
    , "shared d false\n");
}

test "module namespace auto-init builds a nested namespace without sharing its shape" {
    try expectModuleGraphPrints(&.{
        .{ .specifier = "./x.mjs", .path = "/fixture/x.mjs", .source = "export let v = 1;" },
        .{ .specifier = "./q.mjs", .path = "/fixture/q.mjs", .source = "export * as a from './x.mjs';" },
        .{ .specifier = "./p.mjs", .path = "/fixture/p.mjs", .source = "export * as a from './q.mjs';" },
    },
        \\import * as P from './p.mjs';
        \\const Q = P.a;
        \\print(Object.keys(Q).join(), Q.a.v, Object.keys(P).join());
    , "a 1 a\n");
}

test "a synchronous cycle member does not wait for its own ancestor's async dependency" {
    try expectModuleGraphPrints(&.{
        .{ .specifier = "./a.mjs", .path = "/fixture/a.mjs", .source = "import './tla.mjs'; import './b.mjs'; print('a');" },
        .{ .specifier = "./b.mjs", .path = "/fixture/b.mjs", .source = "import './a.mjs'; print('b');" },
        .{ .specifier = "./tla.mjs", .path = "/fixture/tla.mjs", .source = "print('tla start'); await 0; print('tla end');" },
    },
        \\import './a.mjs';
    , "tla start\nb\ntla end\na\n");
}

test "an import resolved through a re-export links before the exporter's own turn in a cycle" {
    try expectModuleGraphPrints(&.{
        .{ .specifier = "./a.mjs", .path = "/fixture/a.mjs", .source = "import './b.mjs'; export { x } from './c.mjs';" },
        .{ .specifier = "./b.mjs", .path = "/fixture/b.mjs", .source = "import { x } from './a.mjs'; export const f = () => x;" },
        .{ .specifier = "./c.mjs", .path = "/fixture/c.mjs", .source = "export let x = 'c';" },
    },
        \\import { x } from './a.mjs';
        \\import { f } from './b.mjs';
        \\print(x, f());
    , "c c\n");
}

test "a long static import chain loads, links and evaluates without native recursion" {
    const depth = 2000;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const modules = try arena.alloc(helpers.MemoryModule, depth);
    for (modules, 0..) |*module, index| {
        module.* = .{
            .specifier = try std.fmt.allocPrint(arena, "./m{d}.mjs", .{index}),
            .path = try std.fmt.allocPrint(arena, "/fixture/m{d}.mjs", .{index}),
            .source = if (index + 1 < depth)
                try std.fmt.allocPrint(arena, "import {{ v as w }} from './m{d}.mjs'; export const v = w + 1;", .{index + 1})
            else
                "export const v = 0;",
        };
    }
    try expectModuleGraphPrints(modules,
        \\import { v } from './m0.mjs';
        \\print(v);
    , "1999\n");
}

test "AsyncIteratorClose awaits before the object check and allSettled pairs share AlreadyCalled" {
    try helpers.expectPrints(
        \\const mk = () => ({[Symbol.asyncIterator](){ return {
        \\  next(){ return {value:1,done:false} },
        \\  return(){ return Promise.resolve(5) } } }});
        \\(async()=>{ try { for await (const x of mk()) break; print('break: no error'); } catch(e) { print('break: caught', e.constructor.name); } })();
        \\(async()=>{ try { await (async()=>{ for await (const x of mk()) return 1; })(); print('return: no error'); } catch(e) { print('return: caught', e.constructor.name); } })();
        \\(async()=>{ try { out: for (const o of [1]) { for await (const x of mk()) continue out; } print('continue-label: no error'); } catch(e) { print('continue-label: caught', e.constructor.name); } })();
        \\(async()=>{ const g = (async function*(){ for await (const x of mk()) yield x; })(); await g.next();
        \\  try { await g.return(0); print('gen.return: no error'); } catch(e) { print('gen.return: caught', e.constructor.name); } })();
        \\const C = function (ex) { ex(v => print('resolved ' + JSON.stringify(v)), e => print('rejected ' + e)); };
        \\C.resolve = v => ({ then(r, j) { r(v); j('x'); } });
        \\Promise.allSettled.call(C, [1, 2]);
    ,
        \\resolved [{"status":"fulfilled","value":1},{"status":"fulfilled","value":2}]
        \\break: caught TypeError
        \\continue-label: caught TypeError
        \\return: caught TypeError
        \\gen.return: caught TypeError
        \\
    );
}

test "Map and Set iterators keep their positions while leading tombstones are trimmed" {
    try helpers.expectPrints(
        \\let seed = 7; const rnd = n => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n; };
        \\const out = [];
        \\for (let round = 0; round < 12; round++) {
        \\  const m = rnd(2) ? new Map() : new Set(); const isMap = m instanceof Map;
        \\  const its = [];
        \\  for (let step = 0; step < 400; step++) {
        \\    const op = rnd(10), k = rnd(60);
        \\    if (op < 4) isMap ? m.set(k, step) : m.add(k);
        \\    else if (op < 7) m.delete(k);
        \\    else if (op < 8) its.push(m.keys());
        \\    else if (op < 9 && its.length) { const r = its[rnd(its.length)].next(); out.push(r.done ? 'D' : r.value); }
        \\    else if (rnd(20) === 0) m.clear();
        \\    else { const [first] = m; if (first !== undefined) m.delete(isMap ? first[0] : first); }
        \\  }
        \\  for (const it of its) { let n = 0, s = 0; for (const v of it) { n++; s += v; } out.push(n + ':' + s); }
        \\  out.push('|' + [...m.keys()].join(','));
        \\}
        \\print(out.join(' ').length, out.join(' ').slice(-200));
        \\let h = 0; for (const c of out.join(' ')) h = (h * 31 + c.charCodeAt(0)) | 0; print(h);
        \\const m = new Map(); for (let i = 0; i < 10; i++) m.set(i, i);
        \\const it = m.keys(); it.next();
        \\for (let i = 10; i < 5000; i++) { m.set(i, i); m.delete(i - 10); }
        \\print(m.size, it.next().value);
    ,
        \\859  D D D D D D D D D D D D D D D D D D D D 0:0 |25,12,16,48,56,4,32,52,20,24,0 |44,56,20,40,32 | | | |36,16,0 24 28 12 52 0 8 4 56 48 36 40 20 24 44 52 20 D D D D D D D D D 0:0 |28,4,56,40,44,8,48,24,12
        \\596751151
        \\10 4990
        \\
    );
}

test "re-entrant recursion through generators, bound functions and super() passes 64 levels" {
    try helpers.expectPrints(
        \\function* walk(n) { if (n > 0) yield* walk(n - 1); yield n; }
        \\let count = 0; for (const _ of walk(80)) count++;
        \\const o = { visit(n) { return n ? this.visit(n - 1) + 1 : 0; } }; o.visit = o.visit.bind(o);
        \\let C = class { constructor() { this.depth = 0; } };
        \\for (let i = 0; i < 80; i++) C = class extends C { constructor() { super(); this.depth++; } };
        \\print(count, o.visit(80), new C().depth);
    ,
        \\81 80 80
        \\
    );
}

test "resizable ArrayBuffer resize keeps contents, zero-fills growth and updates views" {
    try helpers.expectPrints(
        \\const ab = new ArrayBuffer(4, { maxByteLength: 1 << 20 }); const all = new Uint8Array(ab); const fixed = new Uint8Array(ab, 1, 2);
        \\all.set([1, 2, 3, 4]); ab.resize(100000); all[99999] = 9; ab.resize(3); ab.resize(8);
        \\print(all.length, [...all].join(), fixed.length, [...fixed].join(), new DataView(ab).getUint8(7));
        \\ab.resize(0); print(all.length, fixed.length); ab.resize(2); print([...all].join());
    ,
        \\8 1,2,3,0,0,0,0,0 2 2,3 0
        \\0 0
        \\0,0
        \\
    );
}

test "captures resolve the innermost binding from every start scope" {
    try helpers.expectPrints(
        \\function outer() {
        \\  let a = 'outer-a', b = 'outer-b'; const fs = [];
        \\  fs.push(() => a);
        \\  { let a = 'inner-a'; fs.push(() => a + b); { let b = 'deep-b'; fs.push(() => a + b); } fs.push(() => b); }
        \\  fs.push(() => a + b);
        \\  function g() { let a = 'g-a'; return () => a + b; }
        \\  fs.push(g());
        \\  let late = 'late';
        \\  fs.push(() => late);
        \\  return fs.map(f => f()).join(' ');
        \\}
        \\print(outer());
    ,
        \\outer-a inner-aouter-b inner-adeep-b outer-b outer-aouter-b g-aouter-b late
        \\
    );
}

test "sloppy script: nested Annex B if-functions, var/let redeclaration, duplicate parameters in eval, arrow var arguments, HTML comments, TDZ through with" {
    try helpers.expectPrints(
        \\function b() {} print(typeof b); { if (true) function b() {} } print(typeof b, "b" in globalThis);
        \\{ { if (true) function nested() {} } } print(typeof nested, "nested" in globalThis);
        \\for (const src of ["(function(b){ { var b; let b; } })", "(function(){ { function a() {} } var a; let a = 1; })", "var z; { let z; }"]) {
        \\  try { (0, eval)(src); print("ok"); } catch (e) { print(e.name); }
        \\}
        \\(function (p, p) { print(p, eval("p")); (function () { print(eval("p")); })(); })(1, 2);
        \\print((() => { var arguments; return typeof arguments; })());
        \\print(eval("'a'\n--> comment\n+1"));
        \\function tdz() { with ({}) { x = 1; } let x; } try { tdz(); } catch (e) { print(e.name); }
    ,
        \\function
        \\function true
        \\function true
        \\SyntaxError
        \\SyntaxError
        \\ok
        \\2 2
        \\2
        \\undefined
        \\a1
        \\ReferenceError
        \\
    );
}

test "iterator helper close keeps the original error; TA species content type; private add on proxies; setFromBase64 stops at a full target; drop skips without value; Iterator.from uses getPrototypeOf" {
    try helpers.expectPrints(
        \\{
        \\function src(retMode) {
        \\  return { next() { return { value: 1, done: false }; }, return() { if (retMode === 'throw') throw new RangeError('from return'); return 5; }, __proto__: Iterator.prototype };
        \\}
        \\function t(n, f) { try { f(); print(n, 'no throw'); } catch (e) { print(n, e.constructor.name + ': ' + e.message); } }
        \\t('map cb throws, return() non-object', () => src('nonobj').map(x => { throw new EvalError('cb'); }).next());
        \\t('filter cb throws, return() non-object', () => src('nonobj').filter(x => { throw new EvalError('cb'); }).next());
        \\t('flatMap cb throws, return() non-object', () => src('nonobj').flatMap(x => { throw new EvalError('cb'); }).next());
        \\t('flatMap returns primitive, return() throws', () => src('throw').flatMap(x => 'ab').next());
        \\t('flatMap returns primitive, return() non-object', () => src('nonobj').flatMap(x => 'ab').next());
        \\}
        \\{
        \\function t(name, f) { try { var r = f(); print(name, 'no throw:', Object.prototype.toString.call(r), String(r)); } catch (e) { print(name, e.constructor.name); } }
        \\function mk() { var a = new Uint8Array([1, 2, 3, 4]); a.constructor = { [Symbol.species]: BigInt64Array }; return a; }
        \\function mkb() { var a = new BigInt64Array([1n, 2n]); a.constructor = { [Symbol.species]: Uint8Array }; return a; }
        \\t('map', () => mk().map(x => true));
        \\t('filter', () => mk().filter(x => false));
        \\t('slice', () => mk().slice(0, 0));
        \\t('subarray', () => mk().subarray(0, 0));
        \\t('bigmap', () => mkb().map(x => 1n));
        \\t('bigslice', () => mkb().slice(0, 0));
        \\t('bigsubarray', () => mkb().subarray(0));
        \\}
        \\{
        \\class B { constructor(o) { return o; } }
        \\class A extends B { #p = 1; static has(o) { return #p in o; } }
        \\var p = new Proxy(Object.preventExtensions({}), { isExtensible(t) { print('isExtensible trap'); return false; } });
        \\try { new A(p); print('no throw; has =', A.has(p)); } catch (e) { print(e.constructor.name); }
        \\}
        \\{
        \\function t(s, len, lch) {
        \\  var u = new Uint8Array(len);
        \\  try { var r = u.setFromBase64(s, { lastChunkHandling: lch }); print(s, len, lch, '=> read', r.read, 'written', r.written, '[' + u + ']'); }
        \\  catch (e) { print(s, len, lch, '=>', e.constructor.name); }
        \\}
        \\t('dea', 1, 'strict');
        \\t('dea', 1, 'loose');
        \\t('AAAAdea', 4, 'strict');
        \\t('AAAAde', 4, 'strict');
        \\t('AAAAd', 4, 'strict');
        \\t('dea=', 1, 'strict');
        \\}
        \\{
        \\var i = 0;
        \\var it = { next() { var k = i++; return { done: false, get value() { print('value read for item', k); return k; } }; }, __proto__: Iterator.prototype };
        \\print('first after drop(2):', it.drop(2).next().value);
        \\}
        \\{
        \\var p = new Proxy({ next() { return { value: 1, done: true }; } }, { getPrototypeOf(t) { print('getPrototypeOf trap'); return Iterator.prototype; } });
        \\print(Iterator.from(p) === p);
        \\}
    ,
        \\map cb throws, return() non-object EvalError: cb
        \\filter cb throws, return() non-object EvalError: cb
        \\flatMap cb throws, return() non-object EvalError: cb
        \\flatMap returns primitive, return() throws TypeError: value is not iterable
        \\flatMap returns primitive, return() non-object TypeError: value is not iterable
        \\map TypeError
        \\filter TypeError
        \\slice TypeError
        \\subarray TypeError
        \\bigmap TypeError
        \\bigslice TypeError
        \\bigsubarray TypeError
        \\isExtensible trap
        \\TypeError
        \\dea 1 strict => read 0 written 0 [0]
        \\dea 1 loose => read 0 written 0 [0]
        \\AAAAdea 4 strict => read 4 written 3 [0,0,0,0]
        \\AAAAde 4 strict => SyntaxError
        \\AAAAd 4 strict => SyntaxError
        \\dea= 1 strict => read 0 written 0 [0]
        \\value read for item 2
        \\first after drop(2): 2
        \\getPrototypeOf trap
        \\true
        \\
    );
}

test "module evaluation follows the spec cycle, error and async-parent rules" {
    // scc_error
    try expectModuleGraphPrints(&.{
        .{ .specifier = "./a.mjs", .path = "/fixture/a.mjs", .source =
        \\import './b.mjs';
        \\throw new Error('A');
        },
        .{ .specifier = "./b.mjs", .path = "/fixture/b.mjs", .source =
        \\import './a.mjs';
        \\print('b ran');
        },
    },
        \\globalThis.print ??= (...a) => console.log(...a);
        \\let first;
        \\try { await import('./a.mjs'); print('a ok'); } catch (e) { first = e; print('a err', e.message); }
        \\try { await import('./b.mjs'); print('b ok'); } catch (e) { print('b err', e.message, e === first); }
    , "b ran\na err A\nb err A true\n");
    // first_rejection_wins
    try expectModuleGraphPrints(&.{
        .{ .specifier = "./fast.mjs", .path = "/fixture/fast.mjs", .source =
        \\await 0; print('fast throws'); throw new Error('FAST');
        },
        .{ .specifier = "./parent.mjs", .path = "/fixture/parent.mjs", .source =
        \\import './slow.mjs'; import './fast.mjs'; print('parent ran');
        },
        .{ .specifier = "./slow.mjs", .path = "/fixture/slow.mjs", .source =
        \\for (let i = 0; i < 20; i++) await 0; print('slow throws'); throw new Error('SLOW');
        },
    },
        \\globalThis.print ??= (...a) => console.log(...a);
        \\import('./parent.mjs').then(() => print('ok'), e => print('rejected with', e.message));
    , "fast throws\nrejected with FAST\nslow throws\n");
    // errored_dep_order
    try expectModuleGraphPrints(&.{
        .{ .specifier = "./bad.mjs", .path = "/fixture/bad.mjs", .source =
        \\throw new Error('BAD');
        },
        .{ .specifier = "./m.mjs", .path = "/fixture/m.mjs", .source =
        \\import './bad.mjs';
        \\import './other.mjs';
        \\print('m ran');
        },
        .{ .specifier = "./other.mjs", .path = "/fixture/other.mjs", .source =
        \\print('other ran');
        \\throw new Error('OTHER');
        },
    },
        \\globalThis.print ??= (...a) => console.log(...a);
        \\try { await import('./bad.mjs'); } catch (e) { print('first', e.message); }
        \\try { await import('./m.mjs'); print('m ok'); } catch (e) { print('m err', e.message); }
    , "first BAD\nm err BAD\n");
    // reimport_runs_siblings
    try expectModuleGraphPrints(&.{
        .{ .specifier = "./a.mjs", .path = "/fixture/a.mjs", .source =
        \\import './thrower.mjs';
        \\import './later.mjs';
        \\print('a ran');
        },
        .{ .specifier = "./later.mjs", .path = "/fixture/later.mjs", .source =
        \\print('later ran');
        },
        .{ .specifier = "./thrower.mjs", .path = "/fixture/thrower.mjs", .source =
        \\throw new Error('T');
        },
    },
        \\globalThis.print ??= (...a) => console.log(...a);
        \\try { await import('./a.mjs'); print('ok'); } catch (e) { print('err', e.message); }
        \\try { await import('./a.mjs'); print('ok'); } catch (e) { print('err2', e.message); }
    , "err T\nerr2 T\n");
    // scc_member_early_resolve
    try expectModuleGraphPrints(&.{
        .{ .specifier = "./a.mjs", .path = "/fixture/a.mjs", .source =
        \\import './b.mjs';
        \\import './c.mjs';
        \\print('a ran');
        },
        .{ .specifier = "./b.mjs", .path = "/fixture/b.mjs", .source =
        \\import './a.mjs';
        \\print('b ran');
        },
        .{ .specifier = "./c.mjs", .path = "/fixture/c.mjs", .source =
        \\print('c start');
        \\for (let i = 0; i < 5; i++) await 0;
        \\print('c end');
        },
    },
        \\globalThis.print ??= (...a) => console.log(...a);
        \\import('./a.mjs').then(() => print('a resolved'));
        \\import('./b.mjs').then(() => print('b resolved'));
    , "b ran\nc start\nc end\na ran\na resolved\nb resolved\n");
    // hang_reject
    try expectModuleGraphPrints(&.{
        .{ .specifier = "./m0.mjs", .path = "/fixture/m0.mjs", .source =
        \\import { x2 } from './m2.mjs';
        \\export let x0 = 0;
        },
        .{ .specifier = "./m1.mjs", .path = "/fixture/m1.mjs", .source =
        \\await Promise.reject(new Error('MR1'));
        },
        .{ .specifier = "./m2.mjs", .path = "/fixture/m2.mjs", .source =
        \\export { x0 as rx0_2 } from './m0.mjs';
        \\export * from './m1.mjs';
        \\export let x2 = 2;
        },
    },
        \\globalThis.print ??= (...a) => console.log(...a);
        \\try { await import('./m0.mjs'); print('ok'); } catch (e) { print('err', e.message); }
    , "err MR1\n");
    // An async dependency's completion reaches its synchronous parent in a
    // later reaction, after microtasks queued earlier.
    try expectModuleGraphPrints(&.{
        .{ .specifier = "./dep.mjs", .path = "/fixture/dep.mjs", .source = "print('dep start'); await 0; print('dep end'); Promise.resolve().then(() => print('dep microtask 1')).then(() => print('dep microtask 2'));" },
        .{ .specifier = "./parent.mjs", .path = "/fixture/parent.mjs", .source = "import './dep.mjs'; print('parent runs');" },
    },
        \\import './parent.mjs'; print('main runs');
    , "dep start\ndep end\ndep microtask 1\nparent runs\nmain runs\ndep microtask 2\n");
    // Await resolves a thenable once: its `then` is read by PromiseResolve,
    // not again when the module resumes.
    try expectModuleGraphPrints(&.{},
        \\let n = 0;
        \\const obj = { get then() { n++; return n === 1 ? undefined : (res) => { print('hijacked'); res('other'); }; } };
        \\const v = await Promise.resolve(obj);
        \\print(v === obj ? 'resumed with obj' : 'resumed with ' + v, n);
    , "resumed with obj 1\n");
    // An async module's completion is handled on its internal capability,
    // not through PromiseResolve: only `then` and the await read `constructor`.
    try expectModuleGraphPrints(&.{
        .{ .specifier = "./dep.mjs", .path = "/fixture/dep.mjs", .source = "await null; throw new Error('boom');" },
    },
        \\let n = 0;
        \\const orig = Promise;
        \\Object.defineProperty(Promise.prototype, 'constructor', { get() { n++; return orig; }, configurable: true });
        \\await import('./dep.mjs').then(() => print('ok'), e => print('rej', e.message, n));
    , "rej boom 2\n");
    // hang_cycle_async
    try expectModuleGraphPrints(&.{
        .{ .specifier = "./a.mjs", .path = "/fixture/a.mjs", .source = "import './tla.mjs'; import './b.mjs'; print('a');" },
        .{ .specifier = "./b.mjs", .path = "/fixture/b.mjs", .source = "import './a.mjs'; print('b');" },
        .{ .specifier = "./tla.mjs", .path = "/fixture/tla.mjs", .source = "print('tla start'); await 0; print('tla end');" },
    },
        \\import './a.mjs';
    , "tla start\nb\ntla end\na\n");
}

test "import() waiting on a context-evaluated TLA module settles when it finishes" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const dir = ".zig-cache/context-eval-self-import";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    var state = engine.exec.module_graph.DynamicImportState{
        .runtime = js.runtime,
        .output = null,
        .env = .{ .io = std.testing.io, .allocator = std.testing.allocator, .max_source_size = 4096 },
    };
    defer state.deinit();
    var loader_scope = try engine.exec.module_graph.installDynamicImport(&state);
    defer loader_scope.deinit();

    // The import job runs while the body is parked at an await, so it finds
    // the record mid-evaluation and waits on it.
    _ = try js.evalWithOptions(
        \\globalThis.fulfilled = "pending";
        \\import("./fulfilled.mjs").then(ns => { globalThis.fulfilled = "ok " + ns.v; });
        \\await 0; await 0;
        \\export const v = 7;
    , .{ .mode = .module, .filename = dir ++ "/fulfilled.mjs" });
    try std.testing.expectError(error.JSException, js.evalWithOptions(
        \\globalThis.rejected = "pending";
        \\import("./rejected.mjs").catch(e => { globalThis.rejected = "caught " + e.message; });
        \\await 0; await 0;
        \\throw new Error("boom");
    , .{ .mode = .module, .filename = dir ++ "/rejected.mjs" }));
    _ = js.context.takeException();
    try state.runJobs(js.context);
    try std.testing.expectEqual(@as(usize, 0), state.waiters.items.len);
    _ = try js.eval(
        \\assert.sameValue(globalThis.fulfilled, "ok 7");
        \\assert.sameValue(globalThis.rejected, "caught boom");
    );
}

test "top-level for await marks the module async and reads value only while not done" {
    try expectModuleGraphPrints(&.{},
        \\let n = 0;
        \\const it = { [Symbol.asyncIterator]() { return this; }, next() {
        \\  return Promise.resolve({ get done() { print("done-get"); return ++n > 1; },
        \\    get value() { print("value-get"); return n; } }); } };
        \\for await (const v of it) print("v", v);
        \\print("end");
    ,
        \\done-get
        \\value-get
        \\v 1
        \\done-get
        \\end
        \\
    );
}

test "RegExp class \\k with named groups, JS empty classes and lookbehind surrogate quantifiers" {
    try helpers.expectPrints(
        \\var r = [];
        \\["(?<a>x)[\\k]", "[\\k](?<a>x)", "(?<a>x)[\\k<a>]"].forEach(function (p) {
        \\  try { new RegExp(p); r.push("ok"); } catch (e) { r.push(e.name); }
        \\});
        \\r.push(new RegExp("[\\k]").test("k"));
        \\r.push(/a[]|b/.test("b"), /(a)[](b)|(c)/.exec("c")[3]);
        \\r.push(JSON.stringify(/(?<=😀+)x/.exec("\uD83D\uDE00\uDE00x")));
        \\r.push(JSON.stringify(/(?<=a😀*)x/.exec("a\uD83Dx")));
        \\r.push(/(?<=😀{2})x/.test("\uD83D\uDE00\uDE00x"));
        \\print(r.join(" "));
    , "SyntaxError SyntaxError SyntaxError true true c [\"x\"] [\"x\"] true\n");
}

test "%TypedArray% throws before reading newTarget.prototype" {
    try helpers.expectPrints(
        \\var TA = Object.getPrototypeOf(Int8Array), log = [];
        \\var nt = new Proxy(function () {}, { get: function (t, k) { log.push(String(k)); return t[k]; } });
        \\try { Reflect.construct(TA, [], nt); } catch (e) { log.push(e.name); }
        \\class X extends TA { constructor() { super(); } }
        \\try { new X(); } catch (e) { log.push(e.name); }
        \\class A extends Int8Array {}
        \\var a = new A(3);
        \\log.push(a.length, a instanceof A);
        \\print(log.join(","));
    , "TypeError,TypeError,3,true\n");
}

test "private in finds setter-only accessors; bare super and shorthand arguments in class initializers are early errors" {
    try helpers.expectPrints(
        \\class C {
        \\  set #s(v) {}
        \\  static set #ss(v) {}
        \\  static a(o) { return #s in o; }
        \\  static b(o) { return #ss in o; }
        \\  static c(o) { return eval('#s in o'); }
        \\}
        \\var r = [C.a(new C), C.a({}), C.b(C), C.b(new C), C.c(new C)];
        \\["class C extends Object { m() { return (super).x } }",
        \\ "class C extends Object { constructor() { (super)() } }",
        \\ "({ m() { return super?.x } })",
        \\ "class C { x = { arguments } }",
        \\ "class C { static { ({ arguments }) } }",
        \\ "class C { x = function () { return { arguments } } }",
        \\ "({ m() { return super.x + super['y'] } })"].forEach(function (src) {
        \\  try { new Function(src); r.push("ok"); } catch (e) { r.push(e.name); }
        \\});
        \\print(r.join(" "));
    , "true false true false true SyntaxError SyntaxError SyntaxError SyntaxError SyntaxError ok ok\n");
}

test "Promise.allSettled result records inherit from Object.prototype" {
    try expectModuleGraphPrints(&.{},
        \\const v = await Promise.allSettled([1, Promise.reject(2)]);
        \\print(Object.getPrototypeOf(v[0]) === Object.prototype, Object.getPrototypeOf(v[1]) === Object.prototype, String(v[0]), v[1].reason);
    ,
        \\true true [object Object] 2
        \\
    );
}

test "__defineGetter__ and __defineSetter__ use the typed array [[DefineOwnProperty]]" {
    try helpers.expectPrints(
        \\var t = new Uint8Array(3), r = [];
        \\[["0", true], ["5", false], ["-0", false], [1.5, false]].forEach(function (c) {
        \\  try { t[c[1] ? "__defineSetter__" : "__defineGetter__"](c[0], function () {}); r.push("ok"); } catch (e) { r.push(e.name); }
        \\});
        \\var o = {}; o.__defineGetter__("g", function () { return 7; });
        \\r.push(t[0], o.g);
        \\print(r.join(" "));
    , "TypeError TypeError TypeError TypeError 0 7\n");
}

test "join and JSON.stringify of a huge sparse array fail fast at the string length limit" {
    try helpers.expectPrints(
        \\var a = []; a[4294967294] = 1;
        \\var r = [];
        \\try { a.join(); } catch (e) { r.push(e.name); }
        \\try { JSON.stringify(a); } catch (e) { r.push(e.name); }
        \\r.push([1, , 3].join("-"), JSON.stringify([1, , 3]));
        \\print(r.join(" "));
    , "InternalError InternalError 1--3 [1,null,3]\n");
}

test "short forward jumps account for lowered-direct carrier growth" {
    // Each computed key lowers to a one-byte to_propkey that the final writer
    // expands to carrier + tag; around 21 of them used to push an estimated
    // 8-bit forward jump out of range ("internal compiler error").
    try helpers.expectPrints(
        \\var r = [];
        \\for (var n = 14; n <= 32; n++) {
        \\  var body = "var o = {" + Array(n).fill("[null]: null").join(", ") + "};";
        \\  try {
        \\    var f = new Function("c", "if (c) { " + body + " } return 1;");
        \\    var g = new Function("c", "var r; if (c) { " + body + " r = 1; } else { r = 2; } return r;");
        \\    r.push(f(0) + f(1) + g(0) + g(1));
        \\  } catch (e) { r.push(e.name); }
        \\}
        \\print(r.join(" "));
    , "5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5\n");
}

test "runtime errors without a local handler carry the throwing function's frame" {
    try helpers.expectPrints(
        \\function b() { var z = Symbol(); return z + 1; }
        \\function c() { var z = 1n; return z * 1; }
        \\function outer() { return b(); }
        \\var r = [];
        \\for (var fn of [b, c, outer]) {
        \\  try { fn(); } catch (e) { r.push(e.name + ":" + /at (\w+)/.exec(e.stack)[1]); }
        \\}
        \\try { outer(); } catch (e) { r.push(e.stack.includes("at outer")); }
        \\print(r.join(" "));
    , "TypeError:b TypeError:c TypeError:b true\n");
}

test "iterator helper return before start completes first; zip results have no own methods; iterator TypeErrors carry messages" {
    try helpers.expectPrints(
        \\var log = [];
        \\var base = { __proto__: Iterator.prototype, next: function () { return { done: false }; },
        \\  return: function () { log.push(JSON.stringify(h.next()), JSON.stringify(h.return())); return {}; } };
        \\var h = base.map(function (x) { return x; });
        \\log.push(JSON.stringify(h.return()));
        \\log.push(JSON.stringify(Reflect.ownKeys(Iterator.zip([[1]]))));
        \\var m = function (f) { try { f(); } catch (e) { return e.name + ":" + e.message; } };
        \\log.push(m(function () { for (var x of { [Symbol.iterator]: function () { return { next: function () { return 3; } }; } }); }));
        \\log.push(m(function () { Object.getPrototypeOf([].values()).next.call({}); }));
        \\print(log.join(" | "));
    , "{\"done\":true} | {\"done\":true} | {\"done\":true} | [] | TypeError:iterator must return an object | TypeError:method called on incompatible receiver\n");
}

test "an interrupt raised inside an iterator's return() during a throw is not swallowed" {
    if (core.gc.forensics.stressing()) return error.SkipZigTest;
    const cases = [_][]const u8{
        // for-of body throw → IteratorClose from the unwinder
        \\for (const x of spinningReturn()) throw new Error("body");
        ,
        // array destructuring whose element initializer throws
        \\const [a = (() => { throw new Error("init"); })()] = spinningReturn();
        ,
        // iterator helper whose callback throws
        \\spinningReturn().map(() => { throw new Error("callback"); }).next();
        ,
        // Iterator.prototype.some whose predicate throws
        \\spinningReturn().some(() => { throw new Error("predicate"); });
        ,
        // Object.fromEntries with a non-object entry (native close-for-throw)
        \\Object.fromEntries(spinningReturn());
        ,
        // Array.from whose mapper throws
        \\Array.from(spinningReturn(), () => { throw new Error("mapper"); });
        ,
        // Math.sumPrecise over a non-number
        \\Math.sumPrecise(spinningReturn());
    };
    inline for (cases) |body| {
        var js = try helpers.TestEngine.init(std.testing.allocator);
        defer js.deinit();
        _ = try js.eval(
            \\globalThis.caught = "none";
            \\globalThis.spinningReturn = function () {
            \\  return { __proto__: Iterator.prototype, next() { return { done: false, value: 1 }; },
            \\    return() { for (;;) {} } };
            \\};
            \\globalThis.run = function () {
            \\  try {
        ++ body ++
            \\
            \\  } catch (e) { caught = "caught " + e.message; }
            \\  return "finished";
            \\};
        );
        const global = try engine.exec.zjs_vm.contextGlobal(js.context);
        const run = try global.getProperty(try js.runtime.internAtom("run"));
        var state = InterruptTestState{ .stop = true };
        js.runtime.setInterruptHandler(InterruptTestState.poll, &state);
        defer js.runtime.setInterruptHandler(null, null);
        try std.testing.expectError(error.Interrupted, engine.exec.call_runtime.callValueOrBytecodeRoot(js.context, null, global, core.JSValue.undefinedValue(), run, &.{}, null, null));
        try std.testing.expect(js.context.exceptionIsUncatchable());
        _ = js.context.takeException();
        js.runtime.setInterruptHandler(null, null);
        const caught = try global.getProperty(try js.runtime.internAtom("caught"));
        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(js.runtime.nativeAllocator());
        try engine.exec.value_ops.appendRawString(js.runtime, &buffer, caught);
        try std.testing.expectEqualStrings("none", buffer.items);
    }
}

test "long-needle indexOf and lastIndexOf match a naive search and stay linear" {
    try helpers.expectPrints(
        \\var seed = 7; function rnd(n) { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n; }
        \\function naiveIdx(h, n, from) { for (var i = Math.max(0, from); i + n.length <= h.length; i++) if (h.substr(i, n.length) === n) return i; return -1; }
        \\function naiveLast(h, n, from) { for (var i = Math.min(from, h.length - n.length); i >= 0; i--) if (h.substr(i, n.length) === n) return i; return -1; }
        \\var alpha = ["ab", "aab", "aĀ"], bad = 0;
        \\for (var t = 0; t < 300; t++) {
        \\  var a = alpha[rnd(alpha.length)];
        \\  var mk = function (len) { var s = ""; for (var i = 0; i < len; i++) s += a[rnd(a.length)]; return s; };
        \\  var m = 64 + rnd(40), n = mk(m);
        \\  if (rnd(3) === 0) { var p = mk(1 + rnd(4)); n = p.repeat(Math.ceil(m / p.length)).slice(0, m); }
        \\  var h = mk(m + rnd(300));
        \\  if (rnd(2) === 0) { var at = rnd(h.length - m + 1); h = h.slice(0, at) + n + h.slice(at + m); }
        \\  var from = rnd(h.length + 10) - 5;
        \\  if (h.indexOf(n, from) !== naiveIdx(h, n, from) || h.lastIndexOf(n) !== naiveLast(h, n, h.length)) bad++;
        \\}
        \\var hay = "a".repeat(200000), needle = "a".repeat(20000) + "b";
        \\print(bad, hay.indexOf(needle), hay.lastIndexOf(needle), hay.includes(needle), (hay + needle).indexOf(needle));
    , "0 -1 -1 false 200000\n");
}

test "RegExp.lastParen is the last group even when it did not participate; NFC keeps U+11A7 after an LV syllable" {
    try helpers.expectPrints(
        \\var r = [];
        \\/(x)(y)?/.exec("zxz"); r.push(JSON.stringify(RegExp.lastParen));
        \\/(x)(y)?/.exec("zxyz"); r.push(RegExp.lastParen);
        \\/(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)(k)/.exec("abcdefghijk"); r.push(RegExp["$+"], RegExp.$9);
        \\var cps = function (s) { return Array.from(s, function (c) { return c.codePointAt(0).toString(16); }).join("+"); };
        \\r.push(cps("\uAC00\u11A7x".normalize("NFC")), cps("\uAC00\u11A8".normalize("NFC")));
        \\print(r.join(" "));
    , "\"\" y k i ac00+11a7+78 ac01\n");
}

test "TypedArray species defaults use the realm intrinsic, not the global binding; shift on a String wrapper names its error" {
    try helpers.expectPrints(
        \\var U = Uint8Array, ta = new U(2), r = [];
        \\globalThis.Uint8Array = function () { throw new Error("hijacked"); };
        \\[function () { return ta.toReversed(); }, function () { return ta.with(0, 1); }, function () { return ta.toSorted(); }, function () { return ta.slice(); }].forEach(function (f) {
        \\  try { r.push(Object.getPrototypeOf(f()) === U.prototype); } catch (e) { r.push(e.message); }
        \\});
        \\delete globalThis.Uint8Array;
        \\r.push(Object.getPrototypeOf(ta.map(function (x) { return x; })) === U.prototype);
        \\try { Array.prototype.shift.call("ab"); } catch (e) { r.push(e.name + ":" + e.message); }
        \\print(r.join(" "));
    , "true true true true true TypeError:property is read-only\n");
}

test "setFromBase64 follows FromBase64: read counts trailing whitespace, '=' is validated at once, result is ordinary; set orders +Infinity after bounds" {
    try helpers.expectPrints(
        \\var r = [];
        \\["Zg==\n", "Zm9v  ", "   "].forEach(function (s) { r.push(new Uint8Array(8).setFromBase64(s).read); });
        \\["ab=c", "=ab"].forEach(function (s) { try { new Uint8Array(2).setFromBase64(s); r.push("ok"); } catch (e) { r.push(e.name); } });
        \\var res = new Uint8Array(1).setFromHex("ff");
        \\r.push(Object.getPrototypeOf(res) === Object.prototype, Object.getPrototypeOf(new Uint8Array(1).setFromBase64("Zg==")) === Object.prototype);
        \\var ta = new Uint8Array(new ArrayBuffer(4, { maxByteLength: 8 }), 2, 2); ta.buffer.resize(1);
        \\try { ta.set([1], Infinity); } catch (e) { r.push(e.name); }
        \\var log = [];
        \\try { new Uint8Array(4).set({ get length() { log.push("len"); return 0; } }, Infinity); } catch (e) { log.push(e.name); }
        \\r.push(log.join("+"));
        \\print(r.join(" "));
    , "5 6 3 SyntaxError SyntaxError true true TypeError len+RangeError\n");
}

test "a bound function's combined argument list obeys the argument cap" {
    try helpers.expectPrints(
        \\function F() { return arguments.length; }
        \\var B = F.bind(null, ...Array(40000).fill(1)), r = [];
        \\try { B(...Array(40000).fill(2)); r.push("ok"); } catch (e) { r.push(e.name); }
        \\try { new (function () {}.bind(null, ...Array(40000)))(...Array(40000)); r.push("ok"); } catch (e) { r.push(e.name); }
        \\r.push(B(...Array(20000).fill(2)));
        \\print(r.join(" "));
    , "RangeError RangeError 60000\n");
}

test "for await exited by a throw awaits the iterator's return() before rethrowing" {
    try expectModuleGraphPrints(&.{},
        \\const log = [];
        \\const it = { [Symbol.asyncIterator]() { return this; },
        \\  next() { return Promise.resolve({ done: false, value: 1 }); },
        \\  return() { log.push("return"); return { then(r) { log.push("return-then"); r({}); } }; } };
        \\const throwsReturn = { [Symbol.asyncIterator]() { return this; },
        \\  next() { return Promise.resolve({ done: false, value: 1 }); },
        \\  return() { throw new Error("close"); } };
        \\Promise.resolve().then(() => log.push("t1")).then(() => log.push("t2"));
        \\try { for await (const x of it) throw new RangeError("body"); } catch (e) { log.push("caught " + e.name); }
        \\try { for await (const [a] of it) {} } catch (e) { log.push("destructure " + e.name); }
        \\try { for await (const x of throwsReturn) throw new Error("orig"); } catch (e) { log.push("kept " + e.message); }
        \\print(log.join(","));
    ,
        \\t1,return,t2,return-then,caught RangeError,return,return-then,destructure TypeError,kept orig
        \\
    );
}

test "await using awaits each resource in the function and aggregates errors" {
    try expectModuleGraphPrints(&.{},
        \\const log = [];
        \\const errStr = (e) => e instanceof SuppressedError ? "Supp(" + errStr(e.error) + "," + errStr(e.suppressed) + ")" : e.message;
        \\const A = (n, how) => ({ [Symbol.asyncDispose]() { log.push("dispose " + n);
        \\  if (how == "throw") throw new Error("A" + n); if (how == "reject") return Promise.reject(new Error("R" + n)); } });
        \\Promise.resolve().then(() => log.push("t1")).then(() => log.push("t2"));
        \\{ await using a = A(1); log.push("body"); }
        \\log.push("after");
        \\{ await using n = null; }
        \\log.push("after-null");
        \\try { { await using a = A(1, "reject"), b = A(2, "throw"); } } catch (e) { log.push(errStr(e)); }
        \\try { { await using a = A(1, "reject"), b = A(2, "reject"); throw new Error("body"); } } catch (e) { log.push(errStr(e)); }
        \\// A sync resource left after the awaited one still runs on the async path.
        \\async function mixed() { using x = { [Symbol.dispose]() { log.push("x"); throw new Error("X"); } }; await using y = A(3, "throw"); }
        \\await mixed().catch((e) => log.push(errStr(e)));
        \\print(log.join(","));
    ,
        \\body,dispose 1,t1,after,t2,after-null,dispose 2,dispose 1,Supp(R1,A2),dispose 2,dispose 1,Supp(R1,Supp(R2,body)),dispose 3,x,Supp(X,A3)
        \\
    );
}

test "tagged template objects inherit the Array.prototype of the realm that evaluates them" {
    try helpers.expectPrints(
        \\const other = $262.createRealm().global;
        \\const local = ((s) => s)`a${1}b`;
        \\const foreign = other.eval("((s) => s)`a${1}b`");
        \\const viaFunction = other.Function("return ((s) => s)`x`")();
        \\print(Object.getPrototypeOf(local) === Array.prototype,
        \\  Object.getPrototypeOf(foreign) === other.Array.prototype,
        \\  Object.getPrototypeOf(foreign.raw) === other.Array.prototype,
        \\  Object.getPrototypeOf(viaFunction) === other.Array.prototype);
    ,
        \\true true true true
        \\
    );
}

test "array-pattern elisions step the iterator without reading the result's value" {
    try helpers.expectPrints(
        \\var out = [];
        \\function mk(steps, tag) {
        \\  var i = 0;
        \\  return { [Symbol.iterator]() { return {
        \\    next() { var s = steps[i++]; if (s === "throw") throw new Error("next"); if (s === "prim") return 1;
        \\      return { done: s === "end", get value() { out.push(tag + i); return i; } }; },
        \\    return() { out.push(tag + ":return"); return {}; } }; } };
        \\}
        \\function t(f) { try { f(); } catch (e) { out.push(e.constructor.name); } }
        \\var a, b;
        \\t(() => { [a, , b] = mk(["v", "v", "v", "v"], "A"); });
        \\t(() => { [a, , b] = mk(["v", "throw"], "T"); });
        \\t(() => { [a, , b] = mk(["v", "prim"], "P"); });
        \\t(() => { [a, , , , b] = mk(["v", "end"], "E"); out.push(String(b)); });
        \\t(() => { let [x, , y] = mk(["v", "v", "v", "v"], "L"); });
        \\t(() => { (function ([x, , y]) {})(mk(["v", "v", "v", "v"], "F")); });
        \\t(() => { [, ] = mk(["v"], "S"); });
        \\print(out.join());
    ,
        \\A1,A3,A:return,T1,Error,P1,TypeError,E1,undefined,L1,L3,L:return,F1,F3,F:return,S:return
        \\
    );
}

test "a call expression as a sloppy for-in/of target is evaluated per iteration" {
    try helpers.expectPrints(
        \\var log = [];
        \\globalThis.log = log;
        \\globalThis.f = function () { log.push("f"); return {}; };
        \\globalThis.xs = function (n) { log.push("iterable"); return Array(n).fill(0); };
        \\globalThis.it = function () { return { [Symbol.iterator]() { return {
        \\  next() { log.push("next"); return { done: false, value: 1 }; },
        \\  return() { log.push("return"); return {}; } }; } }; };
        \\function t(src) { try { (0, eval)(src); } catch (e) { log.push(e.constructor.name); } }
        \\t("for (f() of xs(0));");
        \\t("for (f() in {});");
        \\t("for (f() of it());");
        \\t("for (f() in {a: 1});");
        \\print(log.join());
    ,
        \\iterable,next,f,return,ReferenceError,f,ReferenceError
        \\
    );
}

test "TypeScript enum and namespace of one name keep separate members; get<T>/set<T> methods; namespace exports infer no name" {
    try helpers.expectPrints(
        \\const A = "outer"; enum E { A }
        \\namespace E { export function fn() { return A; } }
        \\const k = 1; namespace F { export const k = 10; }
        \\enum F { V = k + 0 }
        \\enum G { X } enum G { Y = X + 1 }
        \\namespace M { export const x = 1; } namespace M { export const y = x + 1; }
        \\print(E.fn(), F.V, G.Y, M.y);
        \\const o = { get<T>() { return 1; }, set<T>(v: T) { return 2; } };
        \\print(o.get(), o.set(0));
        \\namespace N { const a = () => {}; export const fe = function () {}; export let ce = class {}; export var ar = () => {};
        \\  export const { d = () => {} } = {} as any; export const g = a; export function f() {} }
        \\print(JSON.stringify([N.fe.name, N.ce.name, N.ar.name, N.d.name, N.g.name, N.f.name]));
    ,
        \\outer 1 1 2
        \\1 2
        \\["","","","","a","f"]
        \\
    );
}

test "Date.parse reads a signed number after the year as a UTC offset, never a second year" {
    try helpers.expectPrints(
        \\const p = (s) => { const t = Date.parse(s); return Number.isNaN(t) ? "NaN" : new Date(t).toISOString(); };
        \\print(p("Jan 1 2020 GMT-0500"), p("Jan 1 2020 UTC+5"), p("Wed Jan 01 2020 GMT+0000"));
        \\print(p("Jan 1 2020 +1x"), p("Mon Jan 01 -000500 00:00:00 GMT+0000"));
    ,
        \\2020-01-01T05:00:00.000Z 2019-12-31T19:00:00.000Z 2020-01-01T00:00:00.000Z
        \\NaN -000500-01-01T00:00:00.000Z
        \\
    );
}

test "array length assignment compares its two conversions (ArraySetLength)" {
    try helpers.expectPrints(
        \\const r = (f) => { try { return String(f()); } catch (e) { return e.constructor.name; } };
        \\const seq = (...xs) => { let i = 0; return { valueOf() { return xs[i++]; } }; };
        \\print(
        \\  r(() => { const a = [1, 2, 3, 4]; a.length = seq(3, 2); return a.length; }),
        \\  r(() => { const a = [1, 2, 3, 4]; a.length = seq(2, 2); return a.length; }),
        \\  r(() => { const a = []; Object.defineProperty(a, "length", { value: seq(3, 2) }); return a.length; }),
        \\  r(() => { const a = []; Reflect.set(a, "length", seq(5, 4)); return a.length; }),
        \\  r(() => { const a = [1]; a.length = seq(-0, 0); return a.length; }));
    ,
        \\RangeError 2 RangeError RangeError 0
        \\
    );
}

test "Array length conversion runs inside [[DefineOwnProperty]] (proxies, defineProperties order)" {
    try helpers.expectPrints(
        \\const two = { valueOf() { return 2; } };
        \\const a = [1, 2, 3]; new Proxy(a, {}).length = two;
        \\const b = [1, 2, 3]; Object.defineProperty(new Proxy(b, {}), "length", { value: two });
        \\const log = [];
        \\Object.defineProperties([], { length: { value: { valueOf() { log.push("valueOf"); return 0; } } }, x: { get value() { log.push("x.value"); return 1; } } });
        \\let n = 0; const v = { valueOf() { n++; return 3; } };
        \\const p = new Proxy([1, 2, 3], { getOwnPropertyDescriptor() { return { value: v, writable: true, enumerable: false, configurable: false }; } });
        \\print(a.length, b.length, log.join(), Object.getOwnPropertyDescriptor(p, "length").value === v, n);
    ,
        \\2 2 x.value,valueOf,valueOf true 0
        \\
    );
}

test "%RegExpStringIteratorPrototype% is one per realm; literals may hold lone surrogates" {
    try helpers.expectPrints(
        \\const p1 = Object.getPrototypeOf("a".matchAll(/a/g)), p2 = Object.getPrototypeOf("a".matchAll(/a/g));
        \\p1.next = function () { return { done: true, value: undefined }; };
        \\print(p1 === p2, [..."aa".matchAll(/a/g)].length);
        \\print(eval("'\ud800'").charCodeAt(0).toString(16), eval("`\udc00`").length, Function("return '\ud800x'")().length);
    ,
        \\true 0
        \\d800 1 2
        \\
    );
}

test "%AsyncIteratorPrototype%[@@asyncDispose] resolves return()'s result through PromiseResolve" {
    try helpers.expectPrints(
        \\const d = Object.getPrototypeOf(Object.getPrototypeOf(async function* () {}.prototype))[Symbol.asyncDispose];
        \\const out = [];
        \\const show = (tag, ret) => d.call({ return() { return ret; } }).then((v) => out.push(tag + ":" + v), (e) => out.push(tag + ":" + e.constructor.name));
        \\(async () => {
        \\  await show("5", 5);
        \\  await show("p", Promise.resolve(42));
        \\  await show("then", { then(_, rej) { rej(new RangeError()); } });
        \\  print(out.join());
        \\})();
    ,
        \\5:undefined,p:undefined,then:RangeError
        \\
    );
}

test "a function declared by direct eval inside catch binds in the variable environment" {
    try helpers.expectPrints(
        \\globalThis.out = [];
        \\(0, eval)(`
        \\out.push((function(){ try { throw 1 } catch (e) { eval("function e(){}"); var inside = typeof e; } return [inside, typeof e].join("/"); })());
        \\out.push((function(){ try { throw 1 } catch (e) { { eval("async function e(){}"); } var inside = typeof e; } return [inside, typeof e].join("/"); })());
        \\out.push((function(){ try { throw 1 } catch (e) { eval("var e = 2"); var inside = e; } return [inside, typeof e].join("/"); })());
        \\`);
        \\print(out.join(" "));
    ,
        \\number/function number/function 2/undefined
        \\
    );
}

test "a blocked Array length shrink names the non-deletable element, not a read-only length" {
    try helpers.expectPrints(
        \\"use strict";
        \\const a = [1, 2, 3]; Object.seal(a);
        \\let m1; try { a.length = 0; } catch (e) { m1 = e.message; }
        \\const c = [1]; Object.defineProperty(c, "length", { writable: false });
        \\let m2; try { c.length = 0; } catch (e) { m2 = e.message; }
        \\print(m1, a.length, "|", m2);
    ,
        \\cannot delete a non-configurable array element 3 | 'length' is read-only
        \\
    );
}

test "parser: label chains, yield ASI, static-block prefixes, escaped names, non-u astral class ranges" {
    try helpers.expectPrints(
        \\const P = (s) => { try { (0, eval)("throw 0;\n" + s); return "ok"; } catch (e) { return e === 0 ? "ok" : e.name; } };
        \\print(P("l: l2: while (0) continue l;"), P("l: l2: { continue l; }"), P("l: m: l: ;"),
        \\  P("class C { static async {} }"), P("class C { static * {} }"),
        \\  P("({l\\u0065t})"), P("var {yi\\u0065ld} = {}"), P("class l\\u0065t {}"),
        \\  P("async function f(){ (function \\u0061wait(){}) }"), P("function* gg(){ (function yi\\u0065ld(){}) }"),
        \\  P("/[😀-😁]/"), P("/[a-😀]/"));
        \\const g = (0, eval)("(function*(){ var x = 5; x = yield\n+1; return x; })"); const it = g(); it.next();
        \\const G = (s) => { try { (0, eval)("(function*(){ throw 0;\n" + s + "\n})"); return "ok"; } catch (e) { return e === 0 ? "ok" : e.name; } };
        \\print(it.next(9).value, G("yield\n? 1 : 2"), G("yield\n/re/"));
        \\print(/^[😀-\uffff]$/.test("\ude50"), /^[a-😀]$/.test("\ud800"), /^[a-😀]$/.test("\ude01"));
        \\const r = [];
        \\outer: inner: for (let i = 0; i < 2; i++) { for (let j = 0; j < 2; j++) { if (j == 1) continue outer; r.push(i + "" + j); } }
        \\print(r.join());
    ,
        \\ok SyntaxError SyntaxError SyntaxError SyntaxError ok ok SyntaxError ok ok SyntaxError ok
        \\9 SyntaxError ok
        \\true true false
        \\00,10
        \\
    );
}

test "minor collections drop WeakMap entries whose keys died young" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    _ = try js.eval(
        \\globalThis.wm = new WeakMap();
        \\globalThis.kept = [];
        \\for (let i = 0; i < 200000; i++) {
        \\  const key = {};
        \\  wm.set(key, i);
        \\  if (i % 50000 === 0) kept.push(key);
        \\}
    );
    // Allocation-triggered minors run during the loop; no major is needed
    // for the dead entries to go. The kept keys still map to their values.
    try std.testing.expect(js.runtime.gcDetailedStats().counters.weak_ref_count < 20000);
    _ = try js.eval("if (kept.map((k) => wm.get(k)).join() !== '0,50000,100000,150000') throw new Error('lost a live entry');");
}

test "array element storage collects before failing a tight heap limit" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const usage = js.runtime.memoryUsage();
    js.runtime.setMemoryLimit(usage.heap_bytes + 256 * 1024);
    defer js.runtime.setMemoryLimit(null);
    // Each array is garbage after its iteration: the limit admit has to run
    // its collection retry for element storage as it does for objects.
    _ = try js.eval(
        \\var ok = 0;
        \\for (var j = 0; j < 400; j++) { var x = new Array(1000).fill(j); ok++; }
        \\if (ok !== 400) throw new Error("only " + ok);
    );
}

test "AsyncIterator.prototype[Symbol.asyncDispose] rejects a non-callable return with a message" {
    try helpers.expectPrints(
        \\const proto = Object.getPrototypeOf(Object.getPrototypeOf(Object.getPrototypeOf((async function* () {})())));
        \\proto[Symbol.asyncDispose].call({ return: 1 }).catch((e) => print(e.name + ":" + e.message));
    ,
        \\TypeError:not a function
        \\
    );
}

test "assigning a global const from a nested scope throws a read-only TypeError with a message" {
    try helpers.expectPrints(
        \\const c1 = 1;
        \\const message = (f) => { try { f(); return "no throw"; } catch (e) { return e.name + ":" + e.message; } };
        \\print(message(function () { c1 = 2; }));
        \\print(message(function () { c1++; }));
        \\print(message(function () { [c1] = [3]; }));
        \\print(message(() => eval("c1 = 4")));
        \\print(message(() => (0, eval)("c1 += 5")));
        \\print(message(() => new Function("c1 = 6")()));
        \\print((function () { try { c1 = 7; } catch (e) { return "caught " + e.message; } })(), c1);
    ,
        \\TypeError:'c1' is read-only
        \\TypeError:'c1' is read-only
        \\TypeError:'c1' is read-only
        \\TypeError:'c1' is read-only
        \\TypeError:'c1' is read-only
        \\TypeError:'c1' is read-only
        \\caught 'c1' is read-only 1
        \\
    );
}

test "an inlined constructor site reached by super() keeps the subclass as new.target" {
    // `new Base(a, b)` and `super(a, b)` share one call_constructor shape and
    // callee; once the site is specialized, the fused create-this must not
    // build the super() instance from Base.prototype.
    try helpers.expectPrints(
        \\function Base(a, b) { this.a = a; this.b = b; }
        \\class D extends Base { constructor(a, b) { const t = new Base(a, b); super(a, b); this.t = t; } }
        \\let bad = 0;
        \\for (let i = 0; i < 50; i++) {
        \\    const d = new D(i, i);
        \\    if (!(d instanceof D) || d.a !== i || !(d.t instanceof Base) || d.t instanceof D) bad++;
        \\}
        \\print(bad);
    ,
        \\0
        \\
    );
}

test "an inlined constructor site never runs a collected callee's body for a new function" {
    // The specialized site guards on the callee object's address. Once that
    // callee died, a fresh function allocated at the same address used to pass
    // the guard and run the old inlined body (this.x = a instead of b).
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    _ = try js.eval(
        \\function mk(k) { return k ? function (a, b) { this.x = a; } : function (a, b) { this.x = b; }; }
        \\function site(F, i) { return new F(i, -i); }
        \\let F = mk(1);
        \\for (let i = 0; i < 200; i++) site(F, i);
        \\F = null; $262.gc(); $262.gc();
        \\for (let round = 0; round < 3000; round++) {
        \\    if (site(mk(0), 5).x !== -5) throw new Error("stale inlined callee at round " + round);
        \\    if (round % 50 === 0) $262.gc();
        \\}
    );
    try std.testing.expect(!js.context.hasException());
}

test "Uint8Array.prototype.setFromHex checks odd length in code units, not UTF-8 bytes" {
    // FromHex step 3 rejects an odd code-unit length before writing; an even
    // length writes whole pairs up to the first non-hexit.
    try helpers.expectPrints(
        \\for (const s of ["aaé", "aaĀb", "aaÿ", "𝒜a"]) {
        \\    const u = new Uint8Array(4);
        \\    let r;
        \\    try { u.setFromHex(s); r = "ok"; } catch (e) { r = e.name; }
        \\    print(s.length, r, Array.from(u).join());
        \\}
    ,
        \\3 SyntaxError 0,0,0,0
        \\4 SyntaxError 170,0,0,0
        \\3 SyntaxError 0,0,0,0
        \\3 SyntaxError 0,0,0,0
        \\
    );
}

test "user code run by ArrayBuffer and DataView methods keeps the host output" {
    // The `.buffer` record domain used to drop the host writer, so a print()
    // from a valueOf/species callback inside these builtins went nowhere.
    try helpers.expectPrints(
        \\const v = (tag, n) => ({ valueOf() { print(tag); return n; } });
        \\const dv = new DataView(new ArrayBuffer(8));
        \\dv.getInt8(v("get", 0));
        \\dv.setInt8(0, v("set", 1));
        \\const ab = new ArrayBuffer(8, { maxByteLength: 16 });
        \\ab.resize(v("resize", 4));
        \\ab.slice(v("slice", 0));
        \\ab.transfer(v("transfer", 2));
        \\new SharedArrayBuffer(4, { maxByteLength: 8 }).grow(v("grow", 6));
    ,
        \\get
        \\set
        \\resize
        \\slice
        \\transfer
        \\grow
        \\
    );
}

test "an async generator that keeps catching failed awaits does not grow the native stack" {
    // A failed await/yield setup re-enters the body with a throw completion;
    // doing that by recursion overflowed after a few thousand iterations.
    try expectModuleGraphPrints(&.{},
        \\const bad = Promise.resolve();
        \\Object.defineProperty(bad, "constructor", { get() { throw 0; } });
        \\async function* g(n) {
        \\    let c = 0;
        \\    for (let i = 0; i < n; i++) { try { await bad; } catch { c++; } }
        \\    for (let i = 0; i < n; i++) { try { yield bad; } catch { c++; } }
        \\    yield c;
        \\}
        \\print((await g(20000).next()).value);
        \\// Every D after the first hands back a non-callable `then`, so finally's
        \\// PromiseResolve result cannot be chained.
        \\let made = 0;
        \\class D extends Promise {
        \\    constructor(ex) {
        \\        super((res, rej) => ex(res, (e) => { print(e.name + ":" + e.message); rej(e); }));
        \\        if (++made > 1) return { then: 1 };
        \\    }
        \\}
        \\const p = Promise.resolve(1);
        \\p.constructor = D;
        \\p.finally(() => {});
        \\await null; await null; await null;
    ,
        \\40000
        \\TypeError:not a function
        \\
    );
}

test "an assignment to a parameter inside a later default is visible to the body" {
    // FunctionDeclarationInstantiation: the body sees each parameter's value
    // as of the end of the parameter list (the default runs against the
    // parameter environment's binding).
    try helpers.expectPrints(
        \\function f(a, b = (a = 9)) { return a; }
        \\function f3(a, b = a = 9, c = a) { return [a, b, c].join(); }
        \\function f7(a, b = (a = 9)) { var a; return a; }
        \\function f11(a, b = eval("a = 7")) { return a; }
        \\function f12(a, { x } = (a = 2, { x: a })) { return [a, x].join(); }
        \\print(f(1), f3(1), f7(1), f11(1), f12(1));
    ,
        \\9 9,9,9 9 7 2,2
        \\
    );
}

test "lexer edge cases: long legacy octal, private name trivia, escaped surrogates, LS line numbers" {
    try helpers.expectPrints(
        "const message = (src) => { try { return String((0, eval)(src)); } catch (e) { return e.name; } };\n" ++
            // 60 legacy octal digits used to overflow a u128 accumulator.
            "print(message('0' + '7'.repeat(60)));\n" ++
            // U+00A0 / U+2028 after a private name are trivia, not identifier parts.
            "print(message('class A { #a = 1; m() { return this.#a\\u00a0; } } new A().m()'));\n" ++
            "print(message('class B { #b = 2; m() { return this.#b\\u2028; } } new B().m()'));\n" ++
            // Each identifier escape must be one code point: a surrogate pair of escapes is not.
            "print(message('var \\\\uD835\\\\uDC00 = 1'));\n" ++
            "print(message('\"\\\\uD835\\\\uDC00\".length'));\n" ++
            // A raw U+2028 inside a template ends a line for diagnostics.
            "try { (0, eval)('x = `a\\u2028b`\\n@'); } catch (e) { print(e.lineNumber); }\n",
        "1.532495540865889e+54\n1\n2\nSyntaxError\n2\n3\n",
    );
}

test "arrow and destructuring lookahead reads a regexp after a statement's paren or block" {
    try helpers.expectPrints(
        \\var f1 = (s = function (t) { if (t) /[(]/.test(t); return 1; }) => s(0);
        \\var f2 = (s = function (t) { {} /[(]/g; while (0) /"/; return 2; }) => s(0);
        \\var g; [g = function (t) { if (t) /[\]]/.test(t); }] = [];
        \\({ h = function (t) { if (t) /[}]/.test(t); } } = {});
        \\var f3 = (a = (8) / 2, b = [4][0] / 2) => a + b;
        \\print(f1(), f2(), typeof g, typeof h, f3());
    ,
        \\1 2 function function 6
        \\
    );
}

test "a parenthesized expression before a conditional or case colon is not a typed-arrow head" {
    // TypeScript's `(x): T => e` lookahead must stay off wherever a `:` can
    // follow: the then-branch of `?:` (including arrow bodies, assignments
    // and yield operands nested in it) and a case test.
    try helpers.expectPrints(
        \\var a = 0, c = 3, d, x, z;
        \\print(typeof (a ? x => (1) : z => "w"), typeof (a ? x = (c) : d => 0));
        \\print(typeof (a ? async () => (z) : d => 0), typeof (a ? x => y => (z) : d => 0));
        \\function* g(a) { return a ? yield (2) : d => 0; }
        \\print(typeof g(0).next().value);
        \\switch (1) { case (1): var k = (b) => 3; print(k()); }
    ,
        \\function function
        \\function function
        \\function
        \\3
        \\
    );
}

test "import specifiers named as, and reserved-word import attribute keys, parse" {
    try expectModuleGraphPrints(&.{
        .{ .specifier = "./y.mjs", .path = "/fixture/y.mjs", .source = "export const type = 7;" },
        .{ .specifier = "./z.mjs", .path = "/fixture/z.mjs", .source = "import v from \"./y.mjs\" with { if: \"x\" };" },
    },
        \\import { type as as } from "./y.mjs";
        \\export { as as type2 };
        \\print(as);
        \\// `if` parses as an AttributeKey; the host then rejects the unknown key.
        \\try { await import("./z.mjs"); } catch (e) { print(e.message); }
    ,
        \\7
        \\import attribute 'if' is not supported
        \\
    );
}

test "a direct eval's Annex B function copy targets the variable environment, not a catch or with" {
    // B.3.2.3: the copy is genv.SetMutableBinding on the caller's variable
    // environment; it must not resolve through a same-named catch parameter
    // or a `with` object the eval runs inside (an eval `var` still does).
    try helpers.expectPrints(
        \\(function () { try { throw 0; } catch (e) { eval("{ function e() {} }"); print(typeof e); } print(typeof e); })();
        \\(function () { var o = { f: 1 }; with (o) eval("{ function f() {} }"); print(typeof o.f, typeof f); })();
        \\(function () { try { throw 0; } catch (e) { eval("var e = 5"); print(e); } print(e); })();
        \\(function () { eval("{ function g() { return 1; } }"); print(g()); })();
    ,
        \\number
        \\function
        \\number function
        \\5
        \\undefined
        \\1
        \\
    );
}

test "global identifier resolution asks a proxy prototype has before typeof and delete" {
    // ResolveBinding runs HasProperty on the global object: `typeof` of an
    // unresolvable name is "undefined" without a [[Get]], and `delete` sees
    // the `has` trap and its exceptions. Expected output is node's.
    try helpers.expectPrints(
        \\var log = [];
        \\Object.setPrototypeOf(globalThis, new Proxy({}, {
        \\  has(t, k) { if (k === 'zq' || k === 'boom' || k === 'zz') log.push('has:' + k); if (k === 'boom') throw new RangeError('b'); return false; },
        \\  get(t, k) { if (k === 'zq' || k === 'boom' || k === 'zz') log.push('get:' + k); return 1; },
        \\}));
        \\function t(f) { try { return String(f()); } catch (e) { return e.constructor.name; } }
        \\print(t(() => typeof zq), log.join()); log = [];
        \\print(t(function () { 'use strict'; return typeof zq; }), log.join()); log = [];
        \\print(t(() => typeof boom), log.join()); log = [];
        \\print(t(() => delete boom), log.join()); log = [];
        \\print(t(() => delete zz), log.join()); log = [];
        \\print(t(() => zq), log.join()); log = [];
    ,
        \\undefined has:zq
        \\undefined has:zq
        \\RangeError has:boom
        \\RangeError has:boom
        \\true has:zz
        \\ReferenceError has:zq
        \\
    );
}

test "a private brand check in a nested class field initializer names the enclosing class's field" {
    // The class-body prescan declares only a `#x` that starts an element;
    // `v = #x in o` inside a nested class used to declare a phantom `#x`
    // there and fail to compile. Expected output is node's.
    try helpers.expectPrints(
        \\class O {
        \\  #x;
        \\  static I = class { v = #x in {}; w = () => #x in this; u = #x in new O(); };
        \\  static J = class { static v = #x in O; };
        \\}
        \\var i = new O.I();
        \\print(i.v, i.w(), i.u, O.J.v);
        \\class A { #a = 1
        \\  #b = 2; static #s
        \\  get #g() { return this.#a } set #g(v) {} async #am() {} *#gm() {} static async *#sg() {}
        \\  v = 1
        \\  #c = this.#a + this.#b
        \\  m() { return [this.#a, this.#b, this.#c, this.#g, #s in A, #am in this, #gm in this, #sg in A] }
        \\}
        \\print(new A().m().join());
        \\try { eval('class B { v = #nope in {} }'); } catch (e) { print(e.constructor.name); }
    ,
        \\false false true false
        \\1,2,3,1,true,true,true,true
        \\SyntaxError
        \\
    );
}

test "super() inside a nested class's computed key initializes the constructor's class" {
    // Each class's `<class_fields_init>` binding is its own; a nested class
    // defined in a derived constructor used to shadow the constructor's, so
    // super() there installed the nested class's fields. Expected is node's.
    try helpers.expectPrints(
        \\class P { constructor() { this.p = 1; } }
        \\class D extends P {
        \\  dField = 'D'; #dp;
        \\  constructor() {
        \\    let f;
        \\    class I { [(f = () => super(), 'k')] = 1; iField = 'I'; #ip; static has(o) { return #ip in o; } }
        \\    f(); this.hasIp = I.has(this);
        \\  }
        \\  static hasDp(o) { return #dp in o; }
        \\}
        \\var d = new D(); print(JSON.stringify(d), D.hasDp(d));
        \\class E extends P { e = 2; constructor() { class I { [super()] = 1 } } }
        \\print(JSON.stringify(new E()));
        \\class F extends P { f = 3; constructor() { eval('super()'); } }
        \\print(JSON.stringify(new F()));
        \\class G { g = 4; constructor() { class H extends P { h = 5; constructor() { (() => super())(); } } this.inner = JSON.stringify(new H()); } }
        \\print(JSON.stringify(new G()));
    ,
        \\{"p":1,"dField":"D","hasIp":false} true
        \\{"p":1,"e":2}
        \\{"p":1,"f":3}
        \\{"g":4,"inner":"{\"p\":1,\"h\":5}"}
        \\
    );
}

test "typed array writes convert each value even after the target went out of bounds" {
    // TypedArraySetElement converts before it checks the index, so a value
    // whose ToNumber/ToBigInt throws still throws once an earlier valueOf
    // detached or shrank the target. Expected output is node's.
    try helpers.expectPrints(
        \\function t(f) { try { f(); return 'ok'; } catch (e) { return e.constructor.name; } }
        \\print(t(() => { const a = new BigInt64Array(4); a.set([{ valueOf() { a.buffer.transfer(); return 1n; } }, 2]); }));
        \\print(t(() => { const u = new Int8Array(4); u.set([{ valueOf() { u.buffer.transfer(); return 1; } }, Symbol()]); }));
        \\print(t(() => { const b = new ArrayBuffer(32, { maxByteLength: 32 }), w = new BigInt64Array(b); w.set([{ valueOf() { b.resize(8); return 1n; } }, 2n, 'zz']); }));
        \\print(t(() => { let ta; function C() { ta = new Int8Array(4); return ta; } Int8Array.of.call(C, { valueOf() { ta.buffer.transfer(); return 1; } }, Symbol()); }));
        \\print(t(() => { const a = new Int8Array(2); a.set([{ valueOf() { a.buffer.transfer(); return 1; } }, 2]); }));
    ,
        \\TypeError
        \\TypeError
        \\SyntaxError
        \\TypeError
        \\ok
        \\
    );
}

test "for-in visits a prototype key whose shadowing own key was deleted before it was reached" {
    // A key deleted before it is reached is not processed (§14.7.5.9), so it
    // hides no prototype key of the same name. Expected output is node's.
    try helpers.expectPrints(
        \\var p = { b: 2 }, o = Object.create(p); o.a = 1; o.b = 1; var r = [];
        \\for (var k in o) { r.push(k); if (k == 'a') delete o.b; } print(r.join());
        \\var p2 = { b: 2 }, p1 = Object.create(p2); p1.a = 1; p1.b = 1; var o2 = Object.create(p1); r = [];
        \\for (var k in o2) { r.push(k); if (k == 'a') delete p1.b; } print(r.join());
        \\var q = { b: 2 }, o3 = Object.create(q); o3.b = 1; o3.a = 1; r = [];
        \\for (var k in o3) { r.push(k); if (k == 'b') delete o3.b; } print(r.join());
    ,
        \\a,b
        \\a,b
        \\b,a
        \\
    );
}

test "deep recursion through native callbacks allocates every frame chunk it skips" {
    // Each callback level pushes a lean entry that counts toward the
    // machine's depth without a chunk slot, so a run of them moved the next
    // slot past chunks never allocated (a Debug assertion, an undefined
    // chunk pointer in release builds).
    try helpers.expectPrints(
        \\function mk(d) { let n = { c: [] }, r = n; for (let i = 0; i < d; i++) { let m = { c: [] }; n.c.push(m); n = m; } return r; }
        \\function walk(n) { return 1 + n.c.map(walk).reduce((a, b) => a + b, 0); }
        \\for (const d of [50, 100, 150, 200, 300, 600]) { try { walk(mk(d)); } catch (e) { if (!(e instanceof InternalError)) throw e; } }
        \\print('ok');
    ,
        \\ok
        \\
    );
}

test "JavaScript sources read a < b > (c) as comparisons and reject a postfix !" {
    // Only TypeScript sources take the generic-call and non-null meanings.
    try helpers.expectPrints(
        \\var a = 1, b = 2, c = 3, f = (x) => x;
        \\function t(s) { try { return String(eval(s)); } catch (e) { return e.constructor.name; } }
        \\print(t('1 < 2 > ({})'), t('a < b > (c)'), t('[a < b, c > (a)]'), t('f < b > (c)'), t('new Object < b > (c)'));
        \\print(t('1!+1'), t('a!'), t('a! == 1'));
    ,
        \\false false true,true false false
        \\SyntaxError SyntaxError SyntaxError
        \\
    );
    try helpers.expectPrintsTs(
        \\function f<T>(x: T): T { return x; }
        \\class K<T> { v = 7; }
        \\const n: number | null = 3;
        \\print(f<number>(5), new K<string>().v, n! + 1, typeof f<string>);
    ,
        \\5 7 4 function
        \\
    );
}
