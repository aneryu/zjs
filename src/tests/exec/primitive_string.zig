const std = @import("std");
const engine = @import("quickjs_zig_engine");

const core = engine.core;
const op = engine.bytecode.opcode.op;

const helpers = @import("exec_helpers.zig");
const makeFunction = helpers.makeFunction;
const runFunction = helpers.runFunction;
test "Engine eval executes logical and nullish smoke subset" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(true && false);
        \\print(true || false);
        \\print(null ?? "default");
        \\print(undefined ?? "default");
        \\print(0 ?? "default");
        \\print("" ?? "default");
        \\print(false ?? "default");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false\ntrue\ndefault\ndefault\n0\n\nfalse\n", stream.buffered());
}

test "Engine eval executes in and instanceof Object smoke subset" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const obj = { x: 1 };
        \\print("x" in obj);
        \\print("missing" in obj);
        \\print("toString" in obj);
        \\print(obj instanceof Object);
        \\print([] instanceof Object);
        \\print("string" instanceof Object);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\nfalse\ntrue\ntrue\ntrue\nfalse\n", stream.buffered());
}

test "Engine eval executes String.fromCharCode smoke subset" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(String.fromCharCode(65));
        \\print(String.fromCharCode(72, 101, 108, 108, 111));
        \\let calls = 0;
        \\let dynamic = { valueOf: function() { calls++; return 66; } };
        \\print(String.fromCharCode(dynamic), calls);
        \\let saved = String.fromCharCode;
        \\String.fromCharCode = function(x) { return "patched:" + x; };
        \\print(String.fromCharCode(67));
        \\String.fromCharCode = saved;
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("A\nHello\nB 1\npatched:67\n", stream.buffered());
}

test "Engine eval executes string method smoke subset" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [768]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const str = "Hello World";
        \\print(str.charAt(0));
        \\print(str.charAt(6));
        \\print(str.substring(0, 5));
        \\print(str.toUpperCase());
        \\print(str.toLowerCase());
        \\print(str.indexOf("World"));
        \\print(str.lastIndexOf("l"));
        \\print(str.charCodeAt(1));
        \\print(str.charCodeAt(99));
        \\print(String.prototype.length);
        \\print(str.includes("Hello"));
        \\print(str.startsWith("Hello"));
        \\print(str.endsWith("World"));
        \\print(str.trim());
        \\print("  abc  ".trim());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("H\nW\nHello\nHELLO WORLD\nhello world\n6\n9\n101\nNaN\n0\ntrue\ntrue\ntrue\nHello World\nabc\n", stream.buffered());
}

test "Engine eval executes Unicode string case conversion subset" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print("\u00D1".toLowerCase() === "\u00F1");
        \\print("\u00F1".toUpperCase() === "\u00D1");
        \\print("\u039F\u03A3".toLowerCase() === "\u03BF\u03C2");
        \\print("\u039F\u03A3\u0391".toLowerCase() === "\u03BF\u03C3\u03B1");
        \\print("\uD801\uDC00".toLowerCase() === "\uD801\uDC28");
        \\print("\uD801\uDC28".toUpperCase() === "\uD801\uDC00");
        \\var obj = { valueOf: function() {}, toString: void 0 };
        \\print(new String(obj).toLowerCase() === "undefined");
        \\print(new String(obj).toUpperCase() === "UNDEFINED");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\ntrue\ntrue\ntrue\ntrue\ntrue\ntrue\ntrue\n", stream.buffered());
}

test "Engine eval executes narrow new String method subset" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const str = new String("Hello World");
        \\print(str.charAt(0));
        \\print(str.charAt(6));
        \\print(str.substring(0, 5));
        \\print(str.toUpperCase());
        \\print(str.toLowerCase());
        \\print(str.indexOf("World"));
        \\print(str.lastIndexOf("l"));
        \\print(str.charCodeAt(1));
        \\print(str.includes("Hello"));
        \\print(str.startsWith("Hello"));
        \\print(str.endsWith("World"));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("H\nW\nHello\nHELLO WORLD\nhello world\n6\n9\n101\ntrue\ntrue\ntrue\n", stream.buffered());
}

test "Engine eval executes String constructor conversion smoke subset" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const s = new String("Hello");
        \\print(s.charAt(0));
        \\print(s.substring(0, 3));
        \\print(s.toUpperCase());
        \\print(typeof String([1, 2]));
        \\print(String([1, 2]));
        \\print(String(null));
        \\print(String(undefined));
        \\print(new String(null).toString());
        \\print(String.fromCharCode(72, 101, 108, 108, 111));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("H\nHel\nHELLO\nstring\n1,2\nnull\nundefined\nnull\nHello\n", stream.buffered());
}

test "Engine eval executes String wrapper coercion regression subset" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const boxed = new String(123);
        \\print(typeof boxed);
        \\print(boxed.toString());
        \\print(boxed.substring(1, 3));
        \\print(new String("abc").includes("b"));
        \\print(new String().toString());
        \\print(new String("1").valueOf());
        \\print(new String("1") & 1);
        \\print(1 | new String("1"));
        \\print(true ^ new String("1"));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("object\n123\n23\ntrue\n\n1\n1\n1\n0\n", stream.buffered());
}

test "String substring uses code units for primitive Unicode strings" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const s = "\u00e9\ud834\udf06x";
        \\const a = s.substring(1, 3);
        \\print(a.length, a.charCodeAt(0), a.charCodeAt(1));
        \\const b = new String(s).substring(3, 1);
        \\print(b.length, b.charCodeAt(0), b.charCodeAt(1));
        \\print("abc".substring(1, 2, { valueOf: function() { throw new Error("unused"); } }));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("2 55348 57094\n2 55348 57094\nb\n", stream.buffered());
}

test "String charAt and at use code units for primitive Unicode strings" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const s = "\u00e9\ud834\udf06x";
        \\let c = s.charAt(0);
        \\print(c.length, c.charCodeAt(0));
        \\c = s.charAt(1);
        \\print(c.length, c.charCodeAt(0));
        \\c = new String(s).charAt(2);
        \\print(c.length, c.charCodeAt(0));
        \\c = s.at(1);
        \\print(c.length, c.charCodeAt(0));
        \\c = new String(s).at(-1);
        \\print(c.length, c.charCodeAt(0));
        \\print(s.at(99) === undefined);
        \\print(s.charAt(99).length);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1 233\n1 55348\n1 57094\n1 55348\n1 120\ntrue\n0\n", stream.buffered());
}

test "String search methods use code unit indexes for primitive Unicode strings" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const s = "\u00e9\ud834\udf06x\ud834x";
        \\print(s.indexOf("x", 3));
        \\print(s.indexOf("\ud834", 1));
        \\print(s.indexOf("\udf06", 1));
        \\print(s.lastIndexOf("\ud834"));
        \\print(s.lastIndexOf("x", 4));
        \\print(s.includes("\udf06x", 2));
        \\print(s.startsWith("\ud834", 1));
        \\print(s.endsWith("\udf06x", 4));
        \\print(new String(s).indexOf("x", 3));
        \\print("abc".indexOf("b", 1, { valueOf: function() { throw new Error("unused"); } }));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3\n1\n2\n4\n3\ntrue\ntrue\ntrue\n3\n1\n", stream.buffered());
}

test "String split uses code unit slices for primitive Unicode strings" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const s = "\u00e9\ud834\udf06";
        \\let a = s.split("");
        \\print(a.length);
        \\for (let i = 0; i < a.length; i++) print(a[i].length, a[i].charCodeAt(0));
        \\a = new String(s).split("\ud834");
        \\print(a.length, a[0].length, a[1].length, a[1].charCodeAt(0));
        \\a = s.split("", 2);
        \\print(a.length, a[0].charCodeAt(0), a[1].charCodeAt(0));
        \\a = s.split();
        \\print(a.length, a[0].length, a[0].charCodeAt(1));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3\n1 233\n1 55348\n1 57094\n2 1 1 57094\n2 233 55348\n1 3 55348\n", stream.buffered());
}

test "Engine eval executes exponentiation regression subset" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(1 ** Infinity);
        \\print((-1) ** -Infinity);
        \\let base = 4;
        \\print(--base ** 2);
        \\print(++base ** 2);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("NaN\nNaN\n9\n16\n", stream.buffered());
}

test "Engine eval executes sparse array literal elision regression subset" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let a = [,];
        \\let b = [,,,,,];
        \\let c = [4,5,,,,];
        \\let d = [,,3,,,];
        \\print(a.length);
        \\print(b.length);
        \\print(c.length);
        \\print(c[4]);
        \\print(d.length);
        \\print(d[2]);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\n5\n5\nundefined\n5\n3\n", stream.buffered());
}

test "Engine eval catches nullish property access TypeError" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\try { undefined.toString(); } catch (e) { print(e instanceof TypeError); }
        \\try { undefined["toString"](); } catch (e) { print(e instanceof TypeError); }
        \\try { null.toString(); } catch (e) { print(e instanceof TypeError); }
        \\try { null["toString"](); } catch (e) { print(e instanceof TypeError); }
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\ntrue\ntrue\ntrue\n", stream.buffered());
}

test "Engine eval preserves bound function metadata and bind getter throws" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function f(a, b) {}
        \\const g = f.bind({ x: 1 }, 1);
        \\print(g.name);
        \\print(g.length);
        \\print(JSON.stringify(Reflect.ownKeys(g)));
        \\let threw = false;
        \\try {
        \\  Object.defineProperty(function() {}, "name", {
        \\    get: function() { throw new Test262Error(); }
        \\  }).bind();
        \\} catch (e) {
        \\  threw = e && e.name === "Test262Error";
        \\}
        \\print(threw);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("bound f\n1\n[\"name\",\"length\"]\ntrue\n", stream.buffered());
}

test "Engine eval executes BigInt asN coercion regression subset" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(BigInt.asIntN(4, "15"));
        \\print(BigInt.asUintN(4, true));
        \\try { BigInt.asIntN("4", 7); } catch (e) { print(e instanceof TypeError); }
        \\print(123456789012345678901234567890n);
        \\print(BigInt.asUintN(80, 1208925819614629174706175n));
        \\print(BigInt.asIntN(80, 1208925819614629174706175n));
        \\print(12345678901234567890123456789012345678901234567890n);
        \\print(BigInt.asUintN(256, 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffn));
        \\print(123456789012345678901234567890n / 97n);
        \\print(123456789012345678901234567890n % 97n);
        \\print(2n ** 20n);
        \\print(1n << 130n);
        \\print(-1n >> 100n);
        \\print(0xffffffffffffffffffffn & 0xffn);
        \\print(~0n);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("-1\n1\ntrue\n123456789012345678901234567890\n1208925819614629174706175\n-1\n12345678901234567890123456789012345678901234567890\n115792089237316195423570985008687907853269984665640564039457584007913129639935\n1272750402189130710322005854\n52\n1048576\n1361129467683753853853498429727072845824\n-1\n255\n-1\n", stream.buffered());
}

test "Engine eval executes typeof standard globals and new Object smoke subset" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(typeof Math);
        \\print(typeof JSON);
        \\print(typeof Promise);
        \\print(typeof Map);
        \\print(typeof Set);
        \\print(typeof ArrayBuffer);
        \\print(typeof DataView);
        \\print(typeof Symbol);
        \\print(typeof new Object());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("object\nobject\nfunction\nfunction\nfunction\nfunction\nfunction\nfunction\nobject\n", stream.buffered());
}

test "globalThis is a writable configurable own global property" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\let original = globalThis;
        \\let desc = Object.getOwnPropertyDescriptor(original, "globalThis");
        \\assert.sameValue(desc.value, original);
        \\assert.sameValue(desc.writable, true);
        \\assert.sameValue(desc.enumerable, false);
        \\assert.sameValue(desc.configurable, true);
        \\original.globalThis = "changed";
        \\assert.sameValue(original.globalThis, "changed");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Engine eval executes primitive constructor smoke subset" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\console.log(typeof Number("42"));
        \\console.log(Number("42"));
        \\console.log(typeof new Number("42"));
        \\console.log(new Number("42").valueOf());
        \\console.log(typeof Boolean(0));
        \\console.log(Boolean(0));
        \\console.log(Boolean(""));
        \\console.log(Boolean(0n));
        \\console.log(typeof new Boolean(1));
        \\console.log(new Boolean(1).valueOf());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("number\n42\nobject\n42\nboolean\nfalse\nfalse\nfalse\nobject\ntrue\n", stream.buffered());
}

test "Engine eval executes optional property access smoke subset" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const obj = { a: { b: 42 } };
        \\print(obj?.a?.b);
        \\print(obj?.x?.y);
        \\const nullObj = null;
        \\print(nullObj?.a);
        \\print(undefined?.a);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("42\nundefined\nundefined\nundefined\n", stream.buffered());
}

test "Engine eval executes basic construction smoke subset" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\class MyClass {
        \\    constructor(x) {
        \\    }
        \\}
        \\const obj = new MyClass(42);
        \\console.log(obj !== undefined);
        \\function Factory() {}
        \\Factory.prototype = 1;
        \\const device = new Factory();
        \\console.log(typeof Factory.prototype, Object.prototype.isPrototypeOf(device));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\nnumber true\n", stream.buffered());
}

test "Engine eval executes async object smoke subset" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\async function testAsync() {
        \\    return 42;
        \\}
        \\async function testAwait() {
        \\    const result = await Promise.resolve(100);
        \\    return result;
        \\}
        \\const p = testAsync();
        \\console.log(typeof p);
        \\const promise = new Promise((resolve, reject) => {
        \\    resolve(123);
        \\});
        \\console.log(typeof promise);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("object\nobject\n", stream.buffered());
}

test "Engine eval records unhandled Promise.reject through quick parser" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    const previous_tracking = js.context.track_unhandled_rejections;
    js.context.track_unhandled_rejections = true;
    defer js.context.track_unhandled_rejections = previous_tracking;

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const p = new Promise((resolve, reject) => {
        \\    resolve(1);
        \\});
        \\print(typeof p);
        \\print(Promise.resolve(1));
        \\print(Promise.all([1, 2]));
        \\print(Promise.race([Promise.resolve(3), 4]));
        \\print(Promise.reject(1));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("object\n[object Promise]\n[object Promise]\n[object Promise]\n[object Promise]\n", stream.buffered());
    try std.testing.expect(js.context.hasException());
    const thrown = js.context.takeException();
    defer thrown.free(js.runtime);
    try std.testing.expectEqual(@as(i32, 1), thrown.asInt32().?);
}

test "Promise.catch handles settled rejections without leaving unhandled state" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\Promise.reject(1).catch(e => print("caught", e));
        \\print("after");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("after\ncaught 1\n", stream.buffered());
    try std.testing.expect(!js.context.hasException());
    try std.testing.expect(!js.context.hasUnhandledRejection());
}

test "async default parameter rejection handled by immediate then is not unhandled" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    const previous_tracking = js.context.track_unhandled_rejections;
    js.context.track_unhandled_rejections = true;
    defer js.context.track_unhandled_rejections = previous_tracking;

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var callCount = 0;
        \\async function f(x = y, y) {
        \\  callCount = callCount + 1;
        \\}
        \\f().then(function() {
        \\  print("resolved");
        \\}, function(error) {
        \\  print(error.constructor === ReferenceError);
        \\  print(callCount);
        \\});
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\n0\n", stream.buffered());
    try std.testing.expect(!js.context.hasException());
    try std.testing.expect(!js.context.hasUnhandledRejection());
}

test "Unhandled Promise.reject survives later caught exceptions" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    const previous_tracking = js.context.track_unhandled_rejections;
    js.context.track_unhandled_rejections = true;
    defer js.context.track_unhandled_rejections = previous_tracking;

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\Promise.reject(7);
        \\try {
        \\  throw new Error("caught");
        \\} catch (e) {
        \\  print(e.message);
        \\}
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("caught\n", stream.buffered());
    try std.testing.expect(js.context.hasUnhandledRejection());
    const rejection = js.context.takeUnhandledRejection();
    defer rejection.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 7), rejection.asInt32());
    if (js.context.hasException()) {
        const thrown = js.context.takeException();
        thrown.free(js.runtime);
    }
}

test "Promise.catch passes through settled fulfillment" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\Promise.resolve(1).catch(e => print("caught", e));
        \\print("after");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("after\n", stream.buffered());
    try std.testing.expect(!js.context.hasException());
}

test "Promise.all invokes constructor resolve for each iterated value" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\var p1 = new Promise(function() {});
        \\var p2 = new Promise(function() {});
        \\var p3 = new Promise(function() {});
        \\var resolve = Promise.resolve;
        \\var callCount = 0;
        \\var current = p1;
        \\var next = p2;
        \\var afterNext = p3;
        \\Promise.resolve = function(nextValue) {
        \\    assert.sameValue(nextValue, current);
        \\    assert.sameValue(arguments.length, 1);
        \\    assert.sameValue(this, Promise);
        \\    current = next;
        \\    next = afterNext;
        \\    afterNext = null;
        \\    callCount += 1;
        \\    return resolve.apply(Promise, arguments);
        \\};
        \\Promise.all([p1, p2, p3]);
        \\assert.sameValue(callCount, 3);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Promise.all.call on subclass constructs subclass capability" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var executor = null;
        \\var callCount = 0;
        \\class SubPromise extends Promise {
        \\    constructor(a) {
        \\        super(a);
        \\        executor = a;
        \\        callCount += 1;
        \\    }
        \\}
        \\var instance = Promise.all.call(SubPromise, []);
        \\assert.sameValue(instance.constructor, SubPromise);
        \\assert.sameValue(instance instanceof SubPromise, true);
        \\assert.sameValue(callCount, 1);
        \\assert.sameValue(typeof executor, "function");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Promise.resolve returns same promise for native promise inputs" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var p = new Promise(function() {});
        \\assert.sameValue(Promise.resolve(p), p);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Promise.resolve on custom constructors exposes a real capability executor" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var executorFunction;
        \\function NotPromise(executor) {
        \\    executorFunction = executor;
        \\    executor(function() {}, function() {});
        \\}
        \\var value = Promise.resolve.call(NotPromise, 1);
        \\assert.sameValue(typeof executorFunction, "function");
        \\assert.sameValue(executorFunction.length, 2);
        \\assert.sameValue(Object.getPrototypeOf(executorFunction), Function.prototype);
        \\assert.sameValue(value instanceof NotPromise, true);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}
