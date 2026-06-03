const std = @import("std");
const engine = @import("quickjs_zig_engine");

const core = engine.core;
const QjsLexer = engine.frontend.zjs_lexer.Lexer;
const zjs_parser = engine.frontend.zjs_parser;
const ParseState = zjs_parser.ParseState;

const helpers = @import("zjs_vm_helpers.zig");
const oom_helpers = @import("oom_helpers.zig");
const parseAndRun = helpers.parseAndRun;
const parseAndRunWithTopLevelChildren = helpers.parseAndRunWithTopLevelChildren;
const parseStmtAndRun = helpers.parseStmtAndRun;
const parseStmtAndRunWithTopLevelChildren = helpers.parseStmtAndRunWithTopLevelChildren;
const expectStringBytes = helpers.expectStringBytes;
const expectSingleCodeUnit = helpers.expectSingleCodeUnit;

test "class prototype installation OOM releases prototype objects once" {
    try expectPrototypeInstallOOMCleanup("(function(){ class C { #x; #m(){ return this.#x; } method(){ return this.#m(); } } return C; })()");
}

fn expectPrototypeInstallOOMCleanup(src: []const u8) !void {
    var saw_oom = false;
    var saw_success = false;

    const samples = oom_helpers.defaultSampleSet(480);
    var fail_offset: usize = 0;
    while (fail_offset < samples.limit) : (fail_offset += 1) {
        if (!oom_helpers.shouldRunOffset(samples, fail_offset)) continue;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const rt = try core.JSRuntime.create(failing.allocator());
        const ctx = try core.JSContext.create(rt);

        const warm_name = try rt.internAtom("warmup");
        var warm_function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, warm_name);
        rt.atoms.free(warm_name);
        var warm_lex = QjsLexer.init(std.testing.allocator, &rt.atoms, "0");
        var warm_state = try ParseState.init(&warm_lex, &warm_function);
        try zjs_parser.parseExpr(&warm_state);
        try engine.bytecode.pipeline.finalize.runWithFunctionDefRuntime(&warm_function, &warm_state.function_def, rt);

        const name = try rt.internAtom("prototype-oom");
        var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        rt.atoms.free(name);
        var lex = QjsLexer.init(std.testing.allocator, &rt.atoms, src);
        var state = try ParseState.init(&lex, &function);
        state.top_level_functions_as_children = true;
        try zjs_parser.parseExpr(&state);
        try engine.bytecode.pipeline.finalize.runWithFunctionDefRuntime(&function, &state.function_def, rt);

        var vm = engine.exec.Vm.init(ctx);
        const warm_result = try vm.run(&warm_function);
        warm_result.free(rt);

        failing.fail_index = failing.alloc_index + fail_offset;
        const result = vm.run(&function);
        failing.fail_index = std.math.maxInt(usize);

        if (result) |value| {
            saw_success = true;
            value.free(rt);
        } else |err| switch (err) {
            error.OutOfMemory => saw_oom = true,
            else => |unexpected| {
                cleanupPrototypeInstallOOMIteration(rt, ctx, &vm, &function, &state, &warm_function, &warm_state);
                return unexpected;
            },
        }

        cleanupPrototypeInstallOOMIteration(rt, ctx, &vm, &function, &state, &warm_function, &warm_state);
        if (oom_helpers.shouldStopAfterCoverage(saw_oom, saw_success)) return;
    }

    try std.testing.expect(saw_oom);
    try std.testing.expect(saw_success);
}

fn cleanupPrototypeInstallOOMIteration(
    rt: *core.JSRuntime,
    ctx: *core.JSContext,
    vm: *engine.exec.Vm,
    function: *engine.bytecode.Bytecode,
    state: *ParseState,
    warm_function: *engine.bytecode.Bytecode,
    warm_state: *ParseState,
) void {
    if (ctx.hasException()) {
        const exception = ctx.takeException();
        exception.free(rt);
    }
    vm.deinit();
    state.deinit(rt);
    function.deinit(rt);
    warm_state.deinit(rt);
    warm_function.deinit(rt);
    ctx.destroy();
    rt.destroy();
}

test "M3.1 F4: direct eval accessor captures caller locals" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var s1 = 5; var s2 = 1; var s3 = 9; var o; eval(\"o = { get foo(){ return s1; }, set foo(v){ return s2 = s3; } };\"); var a = o.foo; o.foo = 10; return a + s2; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 14), result.asInt32().?);
}

test "M3.1 F4: computed accessor unresolvable name throws ReferenceError" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ assert.throws(ReferenceError, function(){ ({ get [test262unresolvable]() {} }); }); return 1; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 1), result.asInt32().?);
}

test "M3.1 F4: object literal permits non-data duplicate __proto__ forms" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "Object.getOwnPropertyDescriptor({ __proto__: null, ['__proto__']: null, __proto__() {}, * __proto__() {}, async __proto__() {}, async * __proto__() {}, get __proto__() { return 33; }, set __proto__(_) { return 44; } }, '__proto__').get()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 33), result.asInt32().?);
}

test "M3.1 F4: object literal __proto__ function value remains retained" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var o = { __proto__: function NamedProto() {} }; return Object.getPrototypeOf(o).name === \"NamedProto\"; })()");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: Annex B escape and unescape observe ToPrimitive" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var trace = "";
        \\  var o = { [Symbol.toPrimitive]: function(hint) { trace += hint; return "\u0100"; } };
        \\  assert.sameValue(escape(o), "%u0100");
        \\  assert.sameValue(unescape({ toString: function(){ trace += "t"; return "%u0100"; } }), "\u0100");
        \\  assert.throws(TypeError, function(){ escape(Symbol("x")); });
        \\  return trace === "stringt";
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: ToPrimitive fallback probes well-known symbol once" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var log = [];
        \\  function doGet(target, propertyName, receiver) {
        \\    log.push(propertyName);
        \\  }
        \\  var handler = new Proxy({}, {
        \\    get: function(target, trapName, receiver) {
        \\      if (trapName !== "get") throw new Test262Error("unexpected trap " + String(trapName));
        \\      return doGet;
        \\    }
        \\  });
        \\  var proxy = new Proxy(Object.create(null), handler);
        \\  assert.throws(TypeError, function(){ proxy == 0; });
        \\  assert.compareArray(log, [Symbol.toPrimitive, "valueOf", "toString"]);
        \\  return 1;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 1), result.asInt32().?);
}

test "M3.1 F4: computed accessor abrupt completion preserves thrown constructor" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var thrower = function(){ throw new Test262Error(); }; assert.throws(Test262Error, function(){ ({ get [thrower()]() {} }); }); assert.throws(Test262Error, function(){ ({ set [thrower()](_) {} }); }); return 1; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 1), result.asInt32().?);
}

test "M3.1 F4: object get/set method names allow destructuring before rest" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var total = 0;
        \\  ({ get([a], ...b) { total += a + b[0]; } }).get([1], 2);
        \\  ({ get({a}, ...b) { total += a + b[0]; } }).get({a: 3}, 4);
        \\  ({ get({a: A}, ...b) { total += A + b[0]; } }).get({a: 5}, 6);
        \\  ({ set([a], ...b) { total += a + b[0]; } }).set([7], 8);
        \\  ({ set({a}, ...b) { total += a + b[0]; } }).set({a: 9}, 10);
        \\  ({ set({a: A}, ...b) { total += A + b[0]; } }).set({a: 11}, 12);
        \\  total += (([a], ...b) => a + b[0])([13], 14);
        \\  return total;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 105), result.asInt32().?);
}

test "M3.1 F4: object accessor syntax rejects rest parameters" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  assert.throws(SyntaxError, function(){ eval("({ get x(...a) { } })"); });
        \\  assert.throws(SyntaxError, function(){ eval("({ get x(a, ...b) { } })"); });
        \\  assert.throws(SyntaxError, function(){ eval("({ get x([a], ...b) { } })"); });
        \\  assert.throws(SyntaxError, function(){ eval("({ get x({a}, ...b) { } })"); });
        \\  assert.throws(SyntaxError, function(){ eval("({ set x(...a) { } })"); });
        \\  assert.throws(SyntaxError, function(){ eval("({ set x(a, ...b) { } })"); });
        \\  assert.throws(SyntaxError, function(){ eval("({ set x([a], ...b) { } })"); });
        \\  assert.throws(SyntaxError, function(){ eval("({ set x({a}, ...b) { } })"); });
        \\  return 1;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 1), result.asInt32().?);
}

test "M3.1 F4: async generator object method binds array parameters on next" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var callCount = 0; var obj = { async *method([x, y, z]) { callCount = x + y + z; } }; obj.method([1, 2, 3]).next().then(function(){ callCount = callCount + 10; }); return callCount; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 6), result.asInt32().?);
}

test "M3.1 F4: array parameter elision advances generator to yield" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var first = 0; var second = 0; function* g(){ first = 1; yield; second = 1; } var seen = 0; var obj = { async *method([,]) { seen = first * 10 + second; } }; obj.method(g()).next().then(function(){}); return seen; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 10), result.asInt32().?);
}

test "M3.1 F4: array parameter default initializes undefined values" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var seen = 0; var obj = { async *method([x = 23]) { seen = x; } }; obj.method([undefined]).next().then(function(){}); return seen; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 23), result.asInt32().?);
}

test "M3.1 F4: array parameter default skips present values" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var initCount = 0; function counter(){ initCount = initCount + 1; return 99; } var seen = 0; var obj = { async *method([w = counter(), x = counter()]) { seen = w + x + initCount; } }; obj.method([10, 20]).next().then(function(){}); return seen; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 30), result.asInt32().?);
}

test "M3.1 F4: array parameter rest identifier receives copied array" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var values = [1, 2, 3]; var seen = 0; var obj = { async *method([...x]) { seen = Array.isArray(x) && x !== values && x.length === 3 && x[0] === 1 && x[1] === 2 && x[2] === 3 ? 1 : 0; } }; obj.method(values).next().then(function(){}); return seen; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 1), result.asInt32().?);
}

test "M3.1 F4: array parameter rest identifier skips elisions" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var seen = 0; var obj = { async *method([, , ...x]) { seen = x.length === 3 && x[0] === 3 && x[1] === 4 && x[2] === 5 ? 1 : 0; } }; obj.method([1, 2, 3, 4, 5]).next().then(function(){}); return seen; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 1), result.asInt32().?);
}

test "M3.1 F4: array parameter rest identifier can be exhausted" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var seen = 0; var obj = { async *method([, , ...x]) { seen = Array.isArray(x) && x.length === 0 ? 1 : 0; } }; obj.method([1, 2]).next().then(function(){}); return seen; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 1), result.asInt32().?);
}

test "M3.1 F4: array destructuring parameter has outer default" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var seen = 0; var obj = { async *method([x, y, z] = [1, 2, 3]) { seen = x + y + z; } }; obj.method().next().then(function(){}); return seen; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 6), result.asInt32().?);
}

test "M3.1 F4: nested array destructuring element has default" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var seen = 0; var obj = { async *method([[x, y, z] = [4, 5, 6]]) { seen = x + y + z; } }; obj.method([]).next().then(function(){}); return seen; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 15), result.asInt32().?);
}

test "M3.1 F4: nested object destructuring element has default" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var seen = 0; var obj = { async *method([{x, y, z} = {x: 44, y: 55, z: 66}]) { seen = x + y + z; } }; obj.method([]).next().then(function(){}); return seen; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 165), result.asInt32().?);
}

test "M3.1 F4: array rest can feed object binding pattern" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var seen = 0; var obj = { async *method([...{length}]) { seen = length; } }; obj.method([1, 2, 3]).next().then(function(){}); return seen; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 3), result.asInt32().?);
}

test "M3.1 F4: top-level child function captures sibling declaration" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRunWithTopLevelChildren(rt, ctx, "function compareArray(){ return 41; } var assert = {}; assert.compareArray = function(){ return compareArray() + 1; }; assert.compareArray();");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "M3.1 F4: duplicate sloppy block functions keep per-block lexical captures" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var total = 0; for (let x of [1]) { const a = 10; function f(){ return a + x; } total += f(); } for (let y of [2]) { const a = 20; function f(){ return a + y; } total += f(); } return total; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 33), result.asInt32().?);
}

test "M3.1 F4: predeclaration scanners skip template regexp substitutions" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ function format(propertyKey, objectName = \"\") { switch (typeof propertyKey) { case \"string\": return `${objectName}['${propertyKey.replace(/'/g, \"\\\\'\")}']`; default: return `${objectName}[${propertyKey}]`; } } return format(\"ab\", \"o\"); })()");
    defer result.free(rt);
    try expectStringBytes(result, "o['ab']");
}

test "M3.1 F4: predeclaration scanners rescan regexp literals in nested arrow bodies" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(
        rt,
        ctx,
        "(function(){ function outer(){ const isNewline = (c) => /[\\u000A\\u000D\\u2028\\u2029]/.test(c); const isWhitespace = (c) => /[\\u0009\\u000B\\u000C\\u0020\\u00A0\\uFEFF]/.test(c); return typeof isNewline + '|' + typeof isWhitespace; } return outer(); })()",
    );
    defer result.free(rt);
    try expectStringBytes(result, "function|function");
}

test "M3.1 F4: try scanner skips regexp literals" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(
        rt,
        ctx,
        "(function(){ try { var m = /@([^@:]*):([0-9]+)$/.exec('@x:12'); } catch (e) { return 'catch'; } return m[1] + ':' + m[2]; })()",
    );
    defer result.free(rt);
    try expectStringBytes(result, "x:12");
}

test "M3.1 F4: Object primitive wrappers use constructor prototypes" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var hidden = [
        \\    "__zjs_String_proto",
        \\    "__zjs_Number_proto",
        \\    "__zjs_Boolean_proto",
        \\    "__zjs_Symbol_proto",
        \\    "__zjs_BigInt_proto"
        \\  ];
        \\  for (var i = 0; i < hidden.length; i++) {
        \\    if (hidden[i] in Object) return false;
        \\    if (Object.getOwnPropertyDescriptor(Object, hidden[i]) !== undefined) return false;
        \\    Object[hidden[i]] = { bad: true };
        \\  }
        \\  var sym = Symbol("x");
        \\  var ok =
        \\    Object.getPrototypeOf(Object("x")) === String.prototype &&
        \\    Object("x").valueOf() === "x" &&
        \\    Object.getPrototypeOf(Object(3)) === Number.prototype &&
        \\    Object(3).valueOf() === 3 &&
        \\    Object.getPrototypeOf(Object(false)) === Boolean.prototype &&
        \\    Object(false).valueOf() === false &&
        \\    Object.getPrototypeOf(Object(sym)) === Symbol.prototype &&
        \\    Object(sym).valueOf() === sym &&
        \\    Object.getPrototypeOf(Object(1n)) === BigInt.prototype &&
        \\    Object(1n).valueOf() === 1n;
        \\  for (var j = 0; j < hidden.length; j++) delete Object[hidden[j]];
        \\  return ok;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: primitive wrapper internals do not consume public __primitive properties" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var sym = Symbol("p");
        \\  var n = Object(3);
        \\  var b = Object(false);
        \\  var bi = Object(1n);
        \\  var s = Object(sym);
        \\  if (Object.prototype.hasOwnProperty.call(n, "__primitive")) return "wrapper-own";
        \\  if (Object.getOwnPropertyDescriptor(Number.prototype, "__primitive") !== undefined) return "number-proto";
        \\  if (Object.getOwnPropertyDescriptor(Boolean.prototype, "__primitive") !== undefined) return "boolean-proto";
        \\  if (Number.prototype.valueOf() !== 0) return "number-proto-value";
        \\  if (Boolean.prototype.valueOf() !== false) return "boolean-proto-value";
        \\  n.__primitive = 9;
        \\  b.__primitive = true;
        \\  bi.__primitive = 2n;
        \\  s.__primitive = Symbol("other");
        \\  var plain = { __primitive: "user" };
        \\  var copied = Object.assign({}, plain);
        \\  return n.valueOf() + "|" +
        \\    b.valueOf() + "|" +
        \\    (bi.valueOf() === 1n) + "|" +
        \\    (s.valueOf() === sym) + "|" +
        \\    Object.keys(n).join(",") + "|" +
        \\    Object.keys(plain).join(",") + "|" +
        \\    copied.__primitive;
        \\})()
    );
    defer result.free(rt);
    try expectStringBytes(result, "3|false|true|true|__primitive|__primitive|user");
}

test "M3.1 F4: Object.assign copies string wrapper indices" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var out = Object.assign({}, 'ab'); return out[0] + out[1]; })()");
    defer result.free(rt);
    try expectStringBytes(result, "ab");
}

test "M3.1 F4: Object.assign updates sealed data properties" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var o = Object.seal({a: 1}); Object.assign(o, {a: 2}); return Object.isSealed(o) && o.a === 2; })()");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}
