const std = @import("std");
const engine = @import("quickjs_zig_engine");

const core = engine.core;
const QjsLexer = engine.frontend.qjs_lexer.Lexer;
const qjs_parser = engine.frontend.qjs_parser;
const ParseState = qjs_parser.ParseState;

const helpers = @import("qjs_vm_helpers.zig");
const parseAndRun = helpers.parseAndRun;
const parseAndRunWithTopLevelChildren = helpers.parseAndRunWithTopLevelChildren;
const parseStmtAndRun = helpers.parseStmtAndRun;
const parseStmtAndRunWithTopLevelChildren = helpers.parseStmtAndRunWithTopLevelChildren;
const expectStringBytes = helpers.expectStringBytes;
const expectSingleCodeUnit = helpers.expectSingleCodeUnit;
test "M3.1 F4: qjs_vm executes Object.setPrototypeOf" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var proto = {x: 42}; var object = {}; return Object.setPrototypeOf(object, proto) === object && object.x === 42; })()");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: object generator method super uses receiver prototype" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var proto = { method(){ return 42; } }; var object = { *g(){ yield super.method(); } }; Object.setPrototypeOf(object, proto); return object.g().next().value; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "M3.1 F4: generator call stores non-strict this binding before resume" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var global = (function(){ return this; })();
        \\  var seenDecl = null;
        \\  function* g() { seenDecl = this; }
        \\  g().next();
        \\  var seenMethod = null;
        \\  var method = { *method() { seenMethod = this; } }.method;
        \\  method().next();
        \\  return seenDecl === global && seenMethod === global;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: logical return chain keeps short-circuit value before trailing call" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  function zero(){ return 0; }
        \\  function one(){ return 1; }
        \\  function fallback(){ return 2; }
        \\  return zero()
        \\      || zero()
        \\      || one()
        \\      || fallback();
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 1), result.asInt32().?);
}

test "M3.1 F4: if condition keeps member postfix update value" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  this.x = 1;
        \\  var object = { prop: 1 };
        \\  var seen = 0;
        \\  if (this.x-- !== 1) seen += 10;
        \\  if (object.prop-- !== 1) seen += 20;
        \\  return seen + this.x + object.prop;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 0), result.asInt32().?);
}

test "M3.1 F4: destructuring default anonymous class receives binding name" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var seen = 0; var obj = { async *method([cls = class {}]) { seen = cls.name === \"cls\" ? 1 : 0; } }; obj.method([]).next().then(function(){}); return seen; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 1), result.asInt32().?);
}

test "M3.1 F4: generator argument can feed empty rest array binding pattern" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var iterations = 0; var iter = (function*(){ iterations += 1; })(); var callCount = 0; var obj = { async *method([...[]]) { callCount = iterations; } }; obj.method(iter).next().then(function(){}); return callCount; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 1), result.asInt32().?);
}

test "M3.1 F4: generator next value resumes computed object accessor key" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var obj; var setValue = 0; var iter = (function*(){ obj = { get [yield](){ return 11; }, set [yield](v){ setValue = v; } }; })(); iter.next(); iter.next(\"first\"); iter.next(\"second\"); obj.second = 13; return obj.first === 11 && setValue === 13; })()");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: generator resume preserves locals for computed object data key" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var value = 0; var iter = (function*(){ let object = { [yield 1]: 9 }; value = object[yield 2] + object[String(yield 3)]; })(); iter.next(); iter.next(); iter.next(); iter.next(); return value; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 18), result.asInt32().?);
}

test "M3.1 F4: comma cover default does not infer anonymous function name" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var observed = 0; var obj = { async *method([cover = (function(){}), xCover = (0, function(){})]) { observed = cover.name === \"cover\" && xCover.name !== \"xCover\" ? 1 : 0; } }; obj.method([]).next().then(function(){}); return observed; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 1), result.asInt32().?);
}

test "M3.1 F4: comma expression drops member assignment values" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var obj = {}; obj.x = 1, obj[\"y\"] = 2; return obj.x * 10 + obj.y; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 12), result.asInt32().?);
}

test "M3.1 F4: large numeric computed assignment stays indexed" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var array = []; array[123456] = \"ok\"; return array[123456]; })()");
    defer result.free(rt);
    try expectStringBytes(result, "ok");
}

test "M3.1 F4: async generator destructuring defaults throw at call time" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var callCount = 0; var obj = { async *method([x = (function(){ throw new Test262Error(); })()]) { callCount = 1; } }; try { obj.method([undefined]); } catch (e) { return callCount === 0 ? 1 : 0; } return 0; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 1), result.asInt32().?);
}

test "M3.1 F4: async generator destructuring body stays deferred after call-time init" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var callCount = 0; var obj = { async *method([x]) { callCount = x; } }; var iter = obj.method([7]); var before = callCount; iter.next().then(function(){}); return before === 0 && callCount === 7; })()");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "P0 variable destructuring RHS keeps outer global binding" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var g = [7]; function read(){ var [x] = g; return x; } return read(); })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 7), result.asInt32().?);
}

test "P0 duplicate var destructuring declarations reuse one binding" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var {a, b} = {a: 1, b: 2};
        \\  var firstObject = a === 1 && b === 2;
        \\  var {a, b} = {a: 3, b: 4};
        \\  var [x] = [5];
        \\  var firstArray = x === 5;
        \\  var [x] = [6];
        \\  return firstObject && firstArray && a === 3 && b === 4 && x === 6;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "G1/P0: closures after catch cannot capture popped block lexical" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  let x = 1;
        \\  let ranCatch = false;
        \\  try {
        \\    x = 2;
        \\    throw new Error();
        \\  } catch {
        \\    let x = 3;
        \\    let y = true;
        \\    ranCatch = true;
        \\  }
        \\  try {
        \\    (function(){ y; })();
        \\  } catch (e) {
        \\    return ranCatch && x === 2 && e instanceof ReferenceError;
        \\  }
        \\  return false;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "G1/P0: Error toString matches name and message" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  return Error("hello").toString() === "Error: hello" &&
        \\    new RangeError(1).toString() === "RangeError: 1" &&
        \\    URIError("message").toString() === "URIError: message";
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "G1/P0: catch markers do not cover for-in iterator on continue" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var key;
        \\  var source = new Array();
        \\  source[0] = "A";
        \\  var count = 0;
        \\  for (key in source) {
        \\    try {
        \\      count += 1;
        \\      continue;
        \\    } catch (e) {}
        \\  }
        \\  for (key in source) {
        \\    try {
        \\      throw "e";
        \\    } catch (e) {
        \\      count += 1;
        \\      continue;
        \\    }
        \\  }
        \\  return count;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 2), result.asInt32().?);
}

test "M3.1 F4: for-in boxes primitive receivers" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var key = "unset";
        \\  for (key in "9") continue;
        \\  if (key !== "0") return -1;
        \\
        \\  function strictArguments() {
        \\    "use strict";
        \\    var name = "unset";
        \\    for (name in arguments) continue;
        \\    return name;
        \\  }
        \\  if (strictArguments() !== "unset") return -2;
        \\
        \\  Number.prototype.zjsForInProbe = 1;
        \\  var seen = false;
        \\  for (var numberKey in 0) {
        \\    if (numberKey === "zjsForInProbe") seen = true;
        \\  }
        \\  delete Number.prototype.zjsForInProbe;
        \\  return seen ? 0 : -3;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 0), result.asInt32().?);
}

test "M3.1 F4: for-of supports parenthesized member targets and closes on lhs throw" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var target = { value: 0 };
        \\  for ((target.value) of [7]) break;
        \\  if (target.value !== 7) return -1;
        \\
        \\  var closed = 0;
        \\  var iterable = {
        \\    [Symbol.iterator]: function() {
        \\      return {
        \\        next: function() { return { value: 9, done: false }; },
        \\        return: function() { closed++; return {}; }
        \\      };
        \\    }
        \\  };
        \\  function throwlhs() { throw "lhs"; }
        \\  var caught = "";
        \\  try {
        \\    for ((throwlhs().x) of iterable) continue;
        \\  } catch (e) {
        \\    caught = e;
        \\  }
        \\  return caught === "lhs" ? closed : -2;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 1), result.asInt32().?);
}

test "M3.1 F4: for-of closes after return through finally" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var closed = 0;
        \\  var finalized = 0;
        \\  var iterable = {
        \\    [Symbol.iterator]: function() {
        \\      return {
        \\        next: function() { return { value: 1, done: false }; },
        \\        return: function() { closed++; throw 42; }
        \\      };
        \\    }
        \\  };
        \\  try {
        \\    (function(){
        \\      for (var x of iterable) {
        \\        try {
        \\          return 7;
        \\        } finally {
        \\          finalized++;
        \\        }
        \\      }
        \\    })();
        \\  } catch (e) {
        \\    return e === 42 && closed === 1 && finalized === 1 ? 1 : -1;
        \\  }
        \\  return -2;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 1), result.asInt32().?);
}

test "M3.1 F4: nested for-in and for-of close in inner-first order on return" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var closed = 0;
        \\  var iterable = {
        \\    [Symbol.iterator]: function() {
        \\      return {
        \\        next: function() { return { value: 1, done: false }; },
        \\        return: function() { closed++; return {}; }
        \\      };
        \\    }
        \\  };
        \\  var value = (function(){
        \\    for (var x in [0]) {
        \\      for (var y of iterable) {
        \\        try {} finally {
        \\          return 13;
        \\        }
        \\      }
        \\    }
        \\  })();
        \\  return value === 13 ? closed : -1;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 1), result.asInt32().?);
}

test "G1/P0: inner loop break keeps enclosing try catch marker" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var arr = [1];
        \\  var i = 1;
        \\  var observed = 0;
        \\  try {
        \\    for (eval("i in arr"); 1;) {
        \\      observed += 1;
        \\      break;
        \\    }
        \\  } catch (e) {
        \\    return -1;
        \\  }
        \\  return observed;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 1), result.asInt32().?);
}

test "G1/P0: for lexical head rejects body var redeclaration" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    try std.testing.expectError(error.UnexpectedToken, parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  for (let x; false;) {
        \\    var x;
        \\  }
        \\})()
    ));
    try std.testing.expectError(error.UnexpectedToken, parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  for (const x = 0; false;) {
        \\    var x;
        \\  }
        \\})()
    ));
}

test "G1/P0: for lexical destructuring head initializes current scope" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var total = 0;
        \\  for (let [x, y] = [2, 3]; total < 1;) {
        \\    total = x + y;
        \\  }
        \\  for (const {z: q} = {z: 4}; total < 6;) {
        \\    total += q;
        \\  }
        \\  return total;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 9), result.asInt32().?);

    try std.testing.expectError(error.UnexpectedToken, parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  for (let [x, x] = [1, 2]; false;) {}
        \\})()
    ));
}

test "G1/P0: for head treats sloppy let and async of arrow as expressions" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var let;
        \\  let = 1;
        \\  for (let; ; ) break;
        \\  if (let !== 1) return -1;
        \\  for (let = 3; ; ) break;
        \\  if (let !== 3) return -2;
        \\  let = 4;
        \\  for ([let][0]; ; ) break;
        \\  if (let !== 4) return -3;
        \\  var i = 0;
        \\  var counter = 0;
        \\  for (async of => {}; i < 10; ++i) {
        \\    ++counter;
        \\  }
        \\  return counter;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 10), result.asInt32().?);
}

test "M3.1 F4: for head rejects arrow expression bodies containing in" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var rejected = false;
        \\  try {
        \\    Function("for (x => 0 in 1;;) break;");
        \\  } catch (e) {
        \\    rejected = e instanceof SyntaxError;
        \\  }
        \\  Function("var f = x => 0 in {}; return f;");
        \\  return rejected;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: for declaration initializers reject in after comma" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var cases = [
        \\    "for (var x = 3 in {}; ; ) break;",
        \\    "for (var x, y = 3 in {}; ; ) break;",
        \\    "for (var x = 5, y = 3 in {}; ; ) break;",
        \\    "for (const x = 3 in {}; ; ) break;",
        \\    "for (const x = 5, y = 3 in {}; ; ) break;",
        \\    "for (let x = 3 in {}; ; ) break;",
        \\    "for (let x, y = 3 in {}; ; ) break;",
        \\    "for (let x = 2, y = 3 in {}; ; ) break;"
        \\  ];
        \\  for (var i = 0; i < cases.length; i++) {
        \\    var threw = false;
        \\    try { Function(cases[i]); } catch (e) { threw = e instanceof SyntaxError; }
        \\    if (!threw) return i;
        \\  }
        \\  Function("for (var x, y = 3; ; ) break;");
        \\  Function("for (let x, y = 3; ; ) break;");
        \\  return -1;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, -1), result.asInt32().?);
}

test "G1/P0: generator return closes destructuring iterators" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var iter = (function*(){ yield 1; yield 2; })();
        \\  var first = iter.next();
        \\  var close = iter.return(9);
        \\  var afterReturn = iter.next();
        \\  var dstr = (function*(){ yield 1; yield 2; })();
        \\  for (let [,] = dstr; ; ) {
        \\    break;
        \\  }
        \\  return first.value === 1 &&
        \\    typeof iter.return === "function" &&
        \\    close.value === 9 &&
        \\    close.done === true &&
        \\    afterReturn.done === true &&
        \\    dstr.next().done === true;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expect(result.asBool() == true);
}

test "P5: Array concat rejects spread result above max safe length before scanning" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var huge = { length: Number.MAX_SAFE_INTEGER };
        \\  huge[Symbol.isConcatSpreadable] = true;
        \\  var objectThrows = false;
        \\  try {
        \\    [1].concat(huge);
        \\  } catch (e) {
        \\    objectThrows = e.constructor === TypeError;
        \\  }
        \\  var proxy = new Proxy([], {
        \\    get: function(_target, key) {
        \\      if (key === "length") return Number.MAX_SAFE_INTEGER;
        \\    }
        \\  });
        \\  var proxyThrows = false;
        \\  try {
        \\    [].concat(1, proxy);
        \\  } catch (e) {
        \\    proxyThrows = e.constructor === TypeError;
        \\  }
        \\  return objectThrows && proxyThrows;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expect(result.asBool() == true);
}

test "P5: typed array resize exposes Array method and iterator bounds distinctly" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var rab = new ArrayBuffer(4, { maxByteLength: 8 });
        \\  var fixed = new Uint8Array(rab, 0, 4);
        \\  fixed[0] = 11;
        \\  fixed[1] = 22;
        \\  var direct = new Uint8Array(new ArrayBuffer(2));
        \\  direct[1] = 9;
        \\  var iterated = 0;
        \\  for (let value of direct) {
        \\    iterated = iterated * 10 + value;
        \\  }
        \\  var fromKeys = Array.from(Array.prototype.keys.call(direct));
        \\  var iteratorOk = fromKeys.length === 2 && fromKeys[0] === 0 && fromKeys[1] === 1;
        \\  var keys = Array.prototype.keys.call(fixed);
        \\  if (keys.next().value !== 0) return false;
        \\  rab.resize(2);
        \\  var methodOk = Array.prototype.at.call(fixed, 0) === undefined;
        \\  var iteratorThrows = false;
        \\  try {
        \\    keys.next();
        \\  } catch (e) {
        \\    iteratorThrows = e.constructor === TypeError;
        \\  }
        \\  var fillBuffer = new ArrayBuffer(4, { maxByteLength: 8 });
        \\  var fillTarget = new Uint8Array(fillBuffer, 0, 4);
        \\  var resizeValue = { valueOf: function(){ fillBuffer.resize(2); return 5; } };
        \\  Array.prototype.fill.call(fillTarget, resizeValue, 1, 2);
        \\  var fillView = new Uint8Array(fillBuffer);
        \\  var fillOk = fillView.length === 2 && fillView[0] === 0 && fillView[1] === 0;
        \\  var bigBuffer = new ArrayBuffer(32, { maxByteLength: 64 });
        \\  var bigValue = BigInt({ valueOf: function(){ bigBuffer.resize(16); return 3; } });
        \\  var bigOk = bigValue === BigInt(3) && bigBuffer.byteLength === 16;
        \\  var copyBuffer = new ArrayBuffer(4, { maxByteLength: 8 });
        \\  var copy = new Uint8Array(copyBuffer);
        \\  copy[0] = 1; copy[1] = 2; copy[2] = 3; copy[3] = 4;
        \\  Array.prototype.copyWithin.call(copy, 0, 2);
        \\  var copyOk = copy.length === 4 && copy[0] === 3 && copy[1] === 4 && copy[2] === 3 && copy[3] === 4;
        \\  var concatTa = new Uint8Array(1);
        \\  Object.defineProperty(concatTa, "length", { value: 4 });
        \\  concatTa[Symbol.isConcatSpreadable] = true;
        \\  var concat = [].concat(concatTa);
        \\  var concatOk = concat.length === 4 && concat[0] === 0 && concat[1] === undefined;
        \\  return iterated === 9 && iteratorOk && methodOk && iteratorThrows && fillOk && bigOk && copyOk && concatOk;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expect(result.asBool() == true);
}

test "P5: Object prototype methods keep dispatch after name deletion and observe ToPropertyKey order" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var hasOwn = Object.prototype.hasOwnProperty;
        \\  delete hasOwn.name;
        \\  var afterDelete = hasOwn.call({ a: 1 }, "a") === true;
        \\  var sym = Symbol("k");
        \\  var count = 0;
        \\  var key = {};
        \\  key[Symbol.toPrimitive] = function(hint) {
        \\    count += hint === "string" ? 1 : 100;
        \\    return sym;
        \\  };
        \\  var obj = {};
        \\  obj[sym] = 1;
        \\  var symbolKey = obj.hasOwnProperty(key) === true && count === 1;
        \\  var order = "none";
        \\  var throwingKey = {
        \\    get toString() {
        \\      order = "key";
        \\      throw new Error("key");
        \\    }
        \\  };
        \\  try {
        \\    hasOwn.call(null, throwingKey);
        \\  } catch (e) {}
        \\  return afterDelete && symbolKey && order === "key";
        \\})()
    );
    defer result.free(rt);
    try std.testing.expect(result.asBool() == true);
}
