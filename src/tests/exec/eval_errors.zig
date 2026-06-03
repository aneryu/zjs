const std = @import("std");
const engine = @import("quickjs_zig_engine");

const core = engine.core;
const op = engine.bytecode.opcode.op;

const helpers = @import("exec_helpers.zig");
const makeFunction = helpers.makeFunction;
const runFunction = helpers.runFunction;
test "Engine eval keeps switch lexical declarations scoped to case block" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\try {
        \\  switch (0) { default: const x = 1; }
        \\  print(x);
        \\} catch (e) {
        \\  print(e.name);
        \\}
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("ReferenceError\n", stream.buffered());
}

test "Engine eval lets switch case expressions close over case lexical bindings" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let x = 'outside';
        \\var probeExpr, probeSelector, probeStmt;
        \\switch (probeExpr = function() { return x; }, null) {
        \\  case probeSelector = function() { return x; }, null:
        \\    probeStmt = function() { return x; };
        \\    let x = 'inside';
        \\}
        \\print(probeExpr(), probeSelector(), probeStmt());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("outside inside inside\n", stream.buffered());
}

test "Engine for-in skips nullish values and non-enumerable keys" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\for (var k in undefined) { print(k); }
        \\for (var k in null) { print(k); }
        \\var object = {};
        \\Object.defineProperty(object, "hidden", { value: 1 });
        \\object.visible = 2;
        \\for (var key in object) { print(key); }
        \\function consumeKey(source) {
        \\  for (var key in source) { key; }
        \\}
        \\consumeKey({ nested: 3 });
        \\var joined = "";
        \\for (var index in [2, 1, 4, 3]) { joined += index; }
        \\print(joined);
        \\function Parent() {}
        \\Parent.prototype = { inherited: 4, visible: 5 };
        \\var child = new Parent();
        \\child.visible = 6;
        \\var protoKeys = "";
        \\for (var protoKey in child) { protoKeys += protoKey + child[protoKey]; }
        \\print(protoKeys.indexOf("visible6") >= 0, protoKeys.indexOf("inherited4") >= 0, protoKeys.indexOf("visible5") < 0);
        \\var deleting = Object.create(null);
        \\deleting.aa = 1;
        \\deleting.ba = 2;
        \\deleting.ca = 3;
        \\var deletedKeys = "";
        \\for (var deleteKey in deleting) { delete deleting.ba; deletedKeys += deleteKey + deleting[deleteKey]; }
        \\print(deletedKeys);
        \\var memberTarget = {};
        \\for (memberTarget.key in { attr: null }) { print(memberTarget.key); }
        \\var parenTarget;
        \\for ((parenTarget) in { wrapped: null }) { print(parenTarget); }
        \\for (let in { keyword: null }) { print(let); }
        \\for (var let in { declared: null }) { print(let); }
        \\var indexedValue;
        \\Object.defineProperty(Array.prototype, "1", { set: function(value) { indexedValue = value; }, configurable: true });
        \\for ([let][1] in { indexed: null }) {}
        \\delete Array.prototype[1];
        \\print(indexedValue);
        \\for (var [x, x] in { ab: null }) {}
        \\print(x);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("visible\n0123\ntrue true true\naa1ca3\nattr\nwrapped\nkeyword\ndeclared\nindexed\nb\n", stream.buffered());
}

test "Engine eval creates fresh for-let bindings for captured closures" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var first;
        \\var second = null;
        \\for (let x = 'first'; second === null; x = 'second') {
        \\  if (!first) first = function() { return x; };
        \\  else second = function() { return x; };
        \\}
        \\print(first(), second());
        \\var before, test, incr, body;
        \\var run = true;
        \\for (let y = 'outside', _ = before = function() { return y; };
        \\     run && (y = 'inside', test = function() { return y; });
        \\     incr = function() { return y; }) {
        \\  body = function() { return y; };
        \\  run = false;
        \\}
        \\print(before(), test(), body(), incr());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("first second\noutside inside inside inside\n", stream.buffered());
}

test "Engine lexical destructuring initialization clears TDZ" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let {x, y: z = 3} = {x: 1};
        \\const [...rest] = [4, 5];
        \\print(x, z, rest.length, rest[0], rest[1]);
        \\let [{ a } = { a: 9 }] = [{ a: 7 }];
        \\print(a);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1 3 2 4 5\n7\n", stream.buffered());
}

test "Engine closure captures preserve lexical TDZ before initialization" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\(function() {
        \\  function read() { return x; }
        \\  try { read(); print('no read throw'); } catch (e) { print(e.name); }
        \\  let x = 1;
        \\  print(read());
        \\}());
        \\(function() {
        \\  function write() { y = 2; }
        \\  try { write(); print('no write throw'); } catch (e) { print(e.name); }
        \\  let y;
        \\  print(y);
        \\}());
        \\(function() {
        \\  function stable() { return 3; }
        \\  try { print(stable()); } catch (e) { print(e.name); }
        \\}());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("ReferenceError\n1\nReferenceError\nundefined\n3\n", stream.buffered());
}

test "Engine object prototype chain supports isPrototypeOf" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function F() {}
        \\var f = function() {};
        \\print(Function.prototype.isPrototypeOf(F));
        \\print(Function.prototype.isPrototypeOf(f));
        \\print(Object.prototype.isPrototypeOf(F));
        \\print(Function.prototype.isPrototypeOf({}));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\ntrue\ntrue\nfalse\n", stream.buffered());
}

test "Engine bound functions inherit Function and Object prototype methods" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function target() {}
        \\var bound = target.bind({});
        \\print(typeof bound.hasOwnProperty);
        \\print(bound.hasOwnProperty('caller'), bound.hasOwnProperty('arguments'));
        \\try { bound.caller; print('no caller throw'); } catch (e) { print(e.name); }
        \\try { bound.caller = {}; print('no caller set throw'); } catch (e) { print(e.name); }
        \\try { bound.arguments; print('no arguments throw'); } catch (e) { print(e.name); }
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("function\nfalse false\nTypeError\nTypeError\nTypeError\n", stream.buffered());
}

test "Function.prototype.toString accepts bound functions" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var bound = function f() {}.bind({});
        \\var source = "" + bound;
        \\assert.sameValue(source.indexOf("function"), 0);
        \\assert.sameValue(source.indexOf("[native code]") >= 0, true);
        \\assert.sameValue(Function.prototype.toString.call(bound), source);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Engine for-in lexical heads use fresh bindings and RHS TDZ" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var fns = {};
        \\var obj = Object.create(null);
        \\obj.a = 1;
        \\obj.b = 1;
        \\obj.c = 1;
        \\for (let x in obj) {
        \\  fns[x] = function() { return x; };
        \\}
        \\print(fns.a(), fns.b(), fns.c());
        \\let outer = 'outside';
        \\var probeExpr;
        \\for (let outer in { i: probeExpr = function() { return typeof outer; }}) {}
        \\try { probeExpr(); print('no throw'); } catch (e) { print(e.name); }
        \\var probeDecl, probeBody;
        \\for (let [outer, _ = probeDecl = function() { return outer; }]
        \\     in { j: probeExpr = function() { typeof outer; }}) {
        \\  probeBody = function() { return outer; };
        \\}
        \\try { probeExpr(); print('no throw'); } catch (e) { print(e.name); }
        \\print(probeDecl(), probeBody());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("a b c\nReferenceError\nReferenceError\nj j\n", stream.buffered());
}

test "Engine eval runs finally before function return completion" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function keepTryReturn() {
        \\  var count = 0;
        \\  try { return 'try'; }
        \\  catch (e) { return 'catch'; }
        \\  finally { count += 1; print('normal', count); }
        \\}
        \\function keepCatchReturn() {
        \\  var count = 0;
        \\  try { throw 'try'; }
        \\  catch (e) { return 'catch'; }
        \\  finally { count += 1; print('catch-finally', count); }
        \\}
        \\function finallyOverrides() {
        \\  try { return 'try'; }
        \\  finally { return 'finally'; }
        \\}
        \\function finallyThrowsOverReturn() {
        \\  try { return 'try'; }
        \\  catch (e) { print('bad-catch'); }
        \\  finally { throw 'finally-throw'; }
        \\}
        \\try { var nested = function() { return 100; }; } finally {}
        \\print(keepTryReturn());
        \\print(keepCatchReturn());
        \\print(finallyOverrides());
        \\try { finallyThrowsOverReturn(); } catch (e) { print(e); }
        \\print(nested());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("normal 1\ntry\ncatch-finally 1\ncatch\nfinally\nfinally-throw\n100\n", stream.buffered());
}

test "Engine eval propagates nested finally abrupt completions outward" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function capturedReturn() {
        \\  try {
        \\    try { return 1; }
        \\    finally { print("inner captured"); }
        \\  } finally {
        \\    print("outer captured");
        \\  }
        \\}
        \\function finallyReturn() {
        \\  try {
        \\    try { print("body"); }
        \\    finally { print("inner override"); return 2; }
        \\  } finally {
        \\    print("outer override");
        \\  }
        \\}
        \\print(capturedReturn());
        \\print(finallyReturn());
        \\try {
        \\  for (var i = 0; i < 1; i++) {
        \\    print("loop break");
        \\    break;
        \\  }
        \\  print("after loop");
        \\} finally {
        \\  print("loop finally");
        \\}
        \\outerBreak: for (;;) {
        \\  try { break outerBreak; }
        \\  finally { print("label break finally"); }
        \\}
        \\outerContinue: for (var j = 0; j < 2; j++) {
        \\  try { continue outerContinue; }
        \\  finally { print("label continue finally", j); }
        \\}
        \\print("label done");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "inner captured\nouter captured\n1\nbody\ninner override\nouter override\n2\nloop break\nafter loop\nloop finally\nlabel break finally\nlabel continue finally 0\nlabel continue finally 1\nlabel done\n",
        stream.buffered(),
    );
}

test "Engine eval rejects break and continue outside loops" {
    // Each case runs in a fresh Engine so failed evals do not leak
    // global lexical bindings (e.g. an eval whose `const X` declaration
    // succeeds before its body throws would otherwise force the next
    // `const X` eval into a redeclaration SyntaxError instead of the
    // expected runtime error). Sharing one Engine across this whole list
    // would be an explicit divergence from QuickJS `JS_Eval` semantics
    // which preserve global lexical bindings across eval calls.
    try expectEvalError(error.SyntaxError, "break;");
    try expectEvalError(error.SyntaxError, "{ break; }");
    try expectEvalError(error.SyntaxError, "continue;");
    try expectEvalError(error.SyntaxError, "'use strict'; try {} catch (eval) {}");
    try expectEvalError(error.SyntaxError, "'use strict'; try {} catch (arguments) {}");
    try expectEvalError(error.SyntaxError, "with ({}) function f() {}");
    try expectEvalError(error.SyntaxError, "with ({}) class C {}");
    try expectEvalError(error.SyntaxError, "with ({}) let x;");
    try expectEvalError(error.SyntaxError, "with ({}) const x = 1;");
    try expectEvalError(error.SyntaxError, "var x = ({ i\\u0066 }) => {};");
    try expectEvalError(error.SyntaxError, "var x = ({ st\\u0061tic }) => {};");
    try expectEvalError(error.TypeError, "var f = ({}) => {}; f(null);");
    try expectEvalError(error.TypeError, "var f = ({} = undefined) => {}; f();");
    try expectEvalError(error.Test262Error, "function thrower() { throw new Test262Error(); } var f = ({ [thrower()]: x }) => {}; f({});");
    try expectEvalError(error.SyntaxError, "'use strict'; (function eval() {});");
    try expectEvalError(error.SyntaxError, "'use strict'; (function arguments() {});");
    try expectEvalError(error.SyntaxError, "'use strict'; (function (x, x) {});");
    try expectEvalError(error.SyntaxError, "(function (x, x) { 'use strict'; });");
    try expectEvalError(error.SyntaxError, "(function () { super(); });");
    try expectEvalError(error.SyntaxError, "(function () { super.x; });");
    try expectEvalError(error.SyntaxError, "(function eval() { 'use strict'; });");
    try expectEvalError(error.SyntaxError, "(function (eval) { 'use strict'; });");
    try expectEvalError(error.SyntaxError, "(function (...rest) { 'use strict'; });");
    try expectEvalError(error.ReferenceError, "(function (a = a) { return a; })();");
    try expectEvalError(error.SyntaxError, "(function (x = 0, x) {});");
    try expectEvalError(error.SyntaxError, "(function () { 'use strict'; { let f; var f; } });");
    try expectEvalError(error.SyntaxError, "(function () { 'use strict'; { const f = 1; var f; } });");
    try expectEvalError(error.TypeError, "const immutable = 0; immutable = 1;");
    try expectEvalError(error.TypeError, "const immutable = 0; immutable += 1;");
    try expectEvalError(error.TypeError, "const immutable = 0; ++immutable;");
    try expectEvalError(error.TypeError, "const immutable = 0; eval('immutable = 1');");
    try expectEvalError(error.TypeError, "const immutable = 0; eval('immutable += 1');");
    try expectEvalError(error.TypeError, "const immutable = 0; function writeEval() { return eval('immutable = 1'); } writeEval();");
    try expectEvalError(error.TypeError, "const captured = 0; function writeCaptured() { captured = 1; } writeCaptured();");
    try expectEvalError(error.TypeError, "const captured = 0; function writeCaptured() { for ([captured] of [[1]]) {} } writeCaptured();");
    try expectEvalError(error.TypeError, "for (const i = 0; i < 1; i++) {}");
    try expectEvalError(error.TypeError, "'use strict'; var ref = function BindingIdentifier() { BindingIdentifier = 1; }; ref();");

    var indirect_js = try engine.harness.Engine.init(std.testing.allocator);
    defer indirect_js.deinit();
    var indirect_buffer: [64]u8 = undefined;
    var indirect_stream = std.Io.Writer.fixed(&indirect_buffer);
    const indirect_result = try indirect_js.evalWithOutput(
        \\const outer = 0;
        \\(0, eval)("try { outer = 1; print('no'); } catch(e) { print(e.name); } print(outer);");
        \\const hidden = 2;
        \\(0, eval)("function f(){ try { return hidden; } catch(e) { return e.name; } } globalThis.f = f;");
        \\print(f());
        \\function optionalEvalProbe() { const hidden = "local"; return eval?.("hidden"); }
        \\print(optionalEvalProbe());
    , &indirect_stream);
    defer indirect_result.free(indirect_js.runtime);
    try std.testing.expect(indirect_result.isUndefined());
    try std.testing.expectEqualStrings("TypeError\n0\n2\n2\n", indirect_stream.buffered());

    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();
    var output_buffer: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const default_result = try js.evalWithOutput(
        \\var ref = function BindingIdentifier() { BindingIdentifier = 1; return BindingIdentifier === ref; };
        \\print(ref());
        \\print((function (a, b = 39,) { return b; })(1, undefined));
        \\print((function (a, b = 39) { return b; })(1, 7));
        \\print((function (a, b = 39,) {}).length);
    , &stream);
    defer default_result.free(js.runtime);
    try std.testing.expect(default_result.isUndefined());
    try std.testing.expectEqualStrings("true\n39\n7\n1\n", stream.buffered());
}

fn expectEvalError(expected: anyerror, source: []const u8) !void {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();
    try std.testing.expectError(expected, js.eval(source));
}

test "Engine eval copies object rest binding properties" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var o = { a: 1, b: 2, x: 3 };
        \\Object.defineProperty(o, "hidden", { value: 4, enumerable: false });
        \\var f = ({ a, ...rest }) => {
        \\  print(rest.a);
        \\  print(rest.b);
        \\  print(rest.x);
        \\  print(rest.hidden);
        \\};
        \\f(o);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("undefined\n2\n3\nundefined\n", stream.buffered());
}

test "Engine eval gives anonymous function expressions empty names" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print((function() {}).name);
        \\print((function named() {}).name);
        \\var fn = function() {};
        \\var desc = Object.getOwnPropertyDescriptor(fn, "prototype");
        \\print(desc.writable, desc.enumerable, desc.configurable);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("\nnamed\ntrue false false\n", stream.buffered());
}

test "Engine eval infers anonymous function names for with identifier assignment" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var scope = { dynamic: null };
        \\with (scope) {
        \\  dynamic = function() {};
        \\}
        \\print(scope.dynamic.name);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("dynamic\n", stream.buffered());
}

test "Engine eval does not infer anonymous names for non-direct initializers" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var logicalFn = true && function() {};
        \\var conditionalFn = true ? function() {} : null;
        \\var logicalClass = true && class {};
        \\var arrayFn = [function() {}][0];
        \\var directFn = function() {};
        \\var directClass = class {};
        \\print(logicalFn.name);
        \\print(conditionalFn.name);
        \\print(logicalClass.name);
        \\print(arrayFn.name);
        \\print(directFn.name);
        \\print(directClass.name);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("\n\n\n\ndirectFn\ndirectClass\n", stream.buffered());
}

test "Engine eval does not leak function expression name into body inference" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\(function namedLambda(param1) {
        \\  param1 = function() {};
        \\  var local = function() {};
        \\  print(param1.name);
        \\  print(local.name);
        \\})();
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("param1\nlocal\n", stream.buffered());
}

test "Engine eval keeps return expression parser state inside nested functions" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\Function("function f() { delete escape; } f();");
        \\var f = (function () {
        \\  return eval("var x; (function() { return delete x; })");
        \\})();
        \\print(f());
        \\print(f());
        \\print(eval("(function() { var x; return delete x; })")());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        \\true
        \\true
        \\false
        \\
    , stream.buffered());
}

test "Engine eval runs finally before nested try rethrow reaches outer catch" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [96]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var c = 0;
        \\try {
        \\  try { missingName; }
        \\  finally { c = 1; print("finally", c); }
        \\} catch (e) {
        \\  print("caught", c, e instanceof ReferenceError);
        \\}
        \\var count = 0;
        \\try {
        \\  try { throw "try"; } catch (e) { throw "catch"; } finally { count += 1; }
        \\} catch (e) {
        \\  print(e, count);
        \\}
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("finally 1\ncaught 1 true\ncatch 1\n", stream.buffered());
}

test "Engine eval unwinds stale pending throws before restoring outer catch" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\try {
        \\  try {
        \\    throw "inner";
        \\  } finally {
        \\    throw "override";
        \\  }
        \\} catch (e) {
        \\  print(e);
        \\}
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("override\n", stream.buffered());
}

test "Engine eval runs finally before unlabelled continue" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var count = 0;
        \\var fin = 0;
        \\do {
        \\  try {
        \\    count += 1;
        \\    continue;
        \\  } finally {
        \\    fin += 1;
        \\  }
        \\} while (count < 2);
        \\print(count, fin);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("2 2\n", stream.buffered());
}

test "Engine eval drops pending throw before finally continue in for-in" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var obj = { a: 1, b: 2, c: 3 };
        \\var count = 0;
        \\var fin = 0;
        \\for (var key in obj) {
        \\  try {
        \\    count += 1;
        \\    throw "pending";
        \\  } finally {
        \\    fin = 1;
        \\    continue;
        \\  }
        \\}
        \\print(count, fin);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3 1\n", stream.buffered());
}
