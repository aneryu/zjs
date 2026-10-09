//! Exec integration tests: calls_generators_classes.
const std = @import("std");
const zjs = @import("zjs");
const engine = zjs;
const core = zjs.core;
const helpers = @import("../harness.zig");
const bytecode = zjs.bytecode;
const op = zjs.bytecode.opcode.op;
const property_ops = zjs.exec.property_ops;
const object_ops = zjs.exec.object_ops;
const array_ops = zjs.exec.array_ops;
const inline_calls = zjs.exec.inline_calls;
const common = @import("common.zig");
const createTailOpcodeFixture = common.createTailOpcodeFixture;

fn fixtureFlagsFromFunction(function: *const bytecode.FunctionBytecode) bytecode.FunctionBytecode.Flags {
    return .{
        .is_strict_mode = function.isStrictMode(),
        .runtime_strict_mode = function.runtimeStrictMode(),
        .has_prototype = function.hasPrototype(),
        .has_simple_parameter_list = function.hasSimpleParameterList(),
        .is_derived_class_constructor = function.isDerivedClassConstructor(),
        .need_home_object = function.needHomeObject(),
        .func_kind = function.functionKind(),
        .new_target_allowed = function.newTargetAllowed(),
        .super_call_allowed = function.superCallAllowed(),
        .super_allowed = function.superAllowed(),
        .arguments_allowed = function.argumentsAllowed(),
        .is_direct_or_indirect_eval = function.isDirectOrIndirectEval(),
    };
}

fn createOversizedLeafFixture(
    rt: *core.JSRuntime,
    source: *const bytecode.FunctionBytecode,
) !*bytecode.FunctionBytecode {
    const fixture = try bytecode.FunctionBytecode.createFixture(rt, .{
        .realm = source.realmContext(),
        .flags = fixtureFlagsFromFunction(source),
        .stack_size = core.VmStackArena.chunk_slots,
    });
    fixture.setExecutionFlags(source.executionFlags());
    return fixture;
}

test "cycle teardown preserves restored strong counts for weakly referenced keys" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    // Each key is both strongly retained by a result record and weakly retained
    // by the map. A cycle pass may visit the key before the map; the key must
    // keep its restored strong refcount until those result properties release
    // it, instead of being converted to an rc-zero weak husk prematurely.
    const result = try js.eval(
        \\var first = {};
        \\var second = {};
        \\var results = [];
        \\var originalSet = WeakMap.prototype.set;
        \\WeakMap.prototype.set = function(key, value) {
        \\    results.push({ receiver: this, key: key, value: value });
        \\    return originalSet.call(this, key, value);
        \\};
        \\var map = new WeakMap([[first, 42], [second, 43]]);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "Engine eval preserves regexp UTF-16 test host output semantics" {
    try helpers.expectPrints(
        \\let re = new RegExp("\u00e9+", "");
        \\print(re.test("\u00e9\u00e9"));
        \\print(re.test("\u0100\u00e9"));
        \\print(re.test("\u0100"));
        \\let oldTest = RegExp.prototype.test;
        \\RegExp.prototype.test = function(input) { return input.length + ":" + (this === re); };
        \\print(re.test("\u00e9\u00e9"));
        \\RegExp.prototype.test = oldTest;
        \\re.test = function(input) { return input.charCodeAt(0); };
        \\print(re.test("\u00e9\u00e9"));
        \\delete re.test;
        \\print(re.test("aa"));
        \\let execOverride = /a+b/;
        \\let seenExec = "";
        \\execOverride.exec = function(input) { seenExec = input + ":" + (this === execOverride); return null; };
        \\print(execOverride.test("aaab"));
        \\print(seenExec);
        \\let globalRe = /a+b/g;
        \\print(globalRe.test("aaab"), globalRe.lastIndex);
        \\print(globalRe.test("x"), globalRe.lastIndex);
        \\let stickyRe = /a/y;
        \\stickyRe.lastIndex = 1;
        \\print(stickyRe.test("ba"), stickyRe.lastIndex);
    , "true\ntrue\nfalse\n2:true\n233\nfalse\nfalse\naaab:true\ntrue 4\nfalse 0\ntrue 2\n");
}

test "Engine eval prepared RegExp call observes same-site property changes" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let re = /a+b/;
        \\function hit(input) { return re.test(input); }
        \\print(hit("aaab"));
        \\RegExp.prototype.test = function(input) { return "patched:" + input + ":" + (this === re); };
        \\print(hit("aaab"));
        \\re.test = function(input) { return "own:" + input; };
        \\print(hit("aaab"));
        \\delete re.test;
        \\print(hit("aaab"));
    , &stream);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("true\npatched:aaab:true\nown:aaab\npatched:aaab:true\n", stream.buffered());
}

test "Engine eval preserves dense array join host output semantics" {
    try helpers.expectPrints(
        \\let tab = [3, 1, 2];
        \\tab.sort();
        \\print(tab.join(","));
        \\let oldJoin = Array.prototype.join;
        \\Array.prototype.join = function(separator) { return "custom:" + separator + ":" + this.length; };
        \\print(tab.join("|"));
        \\Array.prototype.join = oldJoin;
        \\tab.join = function(separator) { return "own:" + separator; };
        \\print(tab.join(","));
        \\delete tab.join;
        \\tab[0] = { toString: function() { globalThis.seenJoinObject = "object"; return "obj"; } };
        \\print(tab.join(","));
        \\print(globalThis.seenJoinObject);
    , "1,2,3\ncustom:|:3\nown:,\nobj,2,3\nobject\n");
}

test "Engine eval preserves dense array pop host output semantics" {
    try helpers.expectPrints(
        \\let tab = [1, 2];
        \\print(tab.pop());
        \\print(tab.length);
        \\let oldPop = Array.prototype.pop;
        \\Array.prototype.pop = function() { return "custom:" + this.length; };
        \\print(tab.pop());
        \\Array.prototype.pop = oldPop;
        \\tab.pop = function() { return "own:" + this.length; };
        \\print(tab.pop());
        \\delete tab.pop;
        \\let accessorTab = [1];
        \\Object.defineProperty(accessorTab, "0", { get: function() { globalThis.seenPopGetter = "getter"; return 9; }, configurable: true });
        \\print(accessorTab.pop());
        \\print(accessorTab.length);
        \\print(globalThis.seenPopGetter);
    , "2\n1\ncustom:1\nown:1\n9\n0\ngetter\n");
}

test "Engine eval preserves ordinary array pop fast path semantics" {
    try helpers.expectPrintsFresh(
        \\let a = [1, 2, 3];
        \\let x = a.pop();
        \\print(x, a.length, a.join(","));
        \\let extra = [1, 2];
        \\print(extra.pop(0), extra.length, extra.join(","));
        \\let b = [1];
        \\b.length = 2;
        \\print(b.pop(), b.length);
        \\Object.prototype[1] = 7;
        \\let c = [1];
        \\c.length = 2;
        \\print(c.pop(), c.length);
        \\delete Object.prototype[1];
        \\let d = [1, 2];
        \\Object.defineProperty(d, "1", { value: 2, configurable: false });
        \\try {
        \\    print(d.pop());
        \\} catch (e) {
        \\    print(e.name, d.length, d[1]);
        \\}
    , "3 2 1,2\n2 1 1\nundefined 1\n7 1\nTypeError 2 2\n");
}

test "empty native array pop fast arm preserves observable length writes" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var frozen = Object.freeze([]);
        \\var frozenError;
        \\try { frozen.pop(); } catch (error) { frozenError = error; }
        \\assert.sameValue(frozenError.name, "TypeError");
        \\assert.sameValue(frozenError.message, "'length' is read-only");
        \\
        \\var log = [];
        \\var target = [];
        \\var proxy = new Proxy(target, {
        \\    get: function(target, key, receiver) {
        \\        if (key === "length") log.push("get");
        \\        return Reflect.get(target, key, receiver);
        \\    },
        \\    set: function(target, key, value, receiver) {
        \\        if (key === "length") log.push("set:" + value);
        \\        return Reflect.set(target, key, value, receiver);
        \\    }
        \\});
        \\assert.sameValue(Array.prototype.pop.call(proxy), undefined);
        \\assert.sameValue(log.join(","), "get,set:0");
        \\assert.sameValue(target.length, 0);
        \\
        \\var gets = 0;
        \\var sets = [];
        \\var ordinary = {
        \\    get length() { gets++; return 0; },
        \\    set length(value) { sets.push(value); }
        \\};
        \\assert.sameValue(Array.prototype.pop.call(ordinary), undefined);
        \\assert.sameValue(gets, 1);
        \\assert.sameValue(sets.join(","), "0");
        \\
        \\class SubArray extends Array {}
        \\var subclass = new SubArray();
        \\assert.sameValue(subclass.pop(), undefined);
        \\assert.sameValue(subclass.length, 0);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "array pop length write removes elements added by the last-element getter" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var array = [];
        \\array.length = 1;
        \\Object.defineProperty(array, "0", {
        \\    configurable: true,
        \\    get: function() {
        \\        array[5] = 9;
        \\        return 7;
        \\    }
        \\});
        \\assert.sameValue(array.pop(), 7);
        \\assert.sameValue(array.length, 0);
        \\assert.sameValue(0 in array, false);
        \\assert.sameValue(5 in array, false);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "array pop reports read-only length after deleting a configurable last element" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var array = [7];
        \\Object.defineProperty(array, "length", { writable: false });
        \\var thrown;
        \\try { array.pop(); } catch (error) { thrown = error; }
        \\assert.sameValue(thrown.name, "TypeError");
        \\assert.sameValue(thrown.message, "'length' is read-only");
        \\assert.sameValue(array.length, 1);
        \\assert.sameValue(0 in array, false);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "Engine eval preserves simple closure call host output semantics" {
    try helpers.expectPrints(
        \\function counter() { let n = 0; return function () { n++; return n; }; }
        \\let next = counter();
        \\print(next());
        \\print(next());
        \\let oldPrint = print;
        \\print = function(x) { globalThis.seenClosureCall = "[" + x + "]"; };
        \\print(next());
        \\oldPrint(globalThis.seenClosureCall);
        \\print = oldPrint;
    , "1\n2\n[3]\n");
}

test "Engine eval preserves one-shot array literal host output semantics" {
    try helpers.expectPrints(
        \\function lengthOnly() {
        \\  let tab = [1, 2];
        \\  print(tab.length);
        \\}
        \\print(lengthOnly() === undefined);
        \\function valueAndLength() {
        \\  let tab = [2];
        \\  print(tab[0]);
        \\  print(tab.length);
        \\}
        \\print(valueAndLength() === undefined);
        \\let oldPrint = print;
        \\print = function(x) { globalThis.seen = (globalThis.seen || "") + "[" + x + "]"; };
        \\let tab = [2];
        \\print(tab[0]);
        \\print(tab.length);
        \\oldPrint(globalThis.seen);
        \\print = oldPrint;
    , "2\ntrue\n2\n1\ntrue\n[2][1]\n");
}

test "Engine eval preserves one-shot array named property host output semantics" {
    try helpers.expectPrintsFresh(
        \\let tab = [1];
        \\tab.a = 9;
        \\print(tab.a);
        \\let oldPrint = print;
        \\print = function(x) { oldPrint("custom:" + x); };
        \\let tab2 = [1];
        \\tab2.a = 8;
        \\print(tab2.a);
        \\print = oldPrint;
        \\let seen = 0;
        \\Object.defineProperty(Array.prototype, "guarded", {
        \\  set: function(v) { seen = v + 1; },
        \\  get: function() { return seen; },
        \\  configurable: true
        \\});
        \\let tab3 = [1];
        \\tab3.guarded = 7;
        \\print(tab3.guarded);
        \\delete Array.prototype.guarded;
    , "9\ncustom:8\n8\n");
}

test "Engine eval preserves typed array constructor length host output semantics" {
    try helpers.expectPrints(
        \\function lengthOnly() {
        \\  let tab = new Int32Array(new ArrayBuffer(16));
        \\  print(tab.length);
        \\}
        \\print(lengthOnly() === undefined);
        \\let oldPrint = print;
        \\print = function(x) { globalThis.seen = "print:" + x; };
        \\let tab = new Int32Array(new ArrayBuffer(16));
        \\print(tab.length);
        \\oldPrint(globalThis.seen);
        \\print = oldPrint;
        \\let OldTA = Int32Array;
        \\Int32Array = function(buffer) { this.length = 99; };
        \\let fake = new Int32Array(new ArrayBuffer(16));
        \\print(fake.length);
        \\Int32Array = OldTA;
    , "4\ntrue\nprint:4\n99\n");
}

test "Engine eval preserves Int32Array indexed read fast path semantics" {
    try helpers.expectPrintsFresh(
        \\let a = new Int32Array(2);
        \\a[0] = 7;
        \\a[1] = -3;
        \\print(a[0], a[1], a[2]);
        \\Object.prototype[0] = 9;
        \\let b = new Int32Array(0);
        \\print(b[0]);
        \\delete Object.prototype[0];
        \\let c = new Int32Array(1);
        \\c.buffer.transfer();
        \\print(c[0]);
    , "7 -3 undefined\nundefined\nundefined\n");
}

test "strict plain calls preserve this arguments eval captures and backtraces" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function strictZero() {
        \\    "use strict";
        \\    assert.sameValue(this, undefined);
        \\    return arguments.length;
        \\}
        \\assert.sameValue(strictZero(), 0);
        \\function strictArgs(value) {
        \\    "use strict";
        \\    arguments[0] = 9;
        \\    return value;
        \\}
        \\assert.sameValue(strictArgs(1), 1);
        \\function strictArgumentsIdentity() { "use strict"; return arguments === arguments; }
        \\assert.sameValue(strictArgumentsIdentity(1), true);
        \\function strictOriginalArgs(value) {
        \\    "use strict";
        \\    value = 17;
        \\    return arguments[0];
        \\}
        \\assert.sameValue(strictOriginalArgs(1), 1);
        \\function strictEval() {
        \\    "use strict";
        \\    eval("var hidden = 1");
        \\    return typeof hidden;
        \\}
        \\assert.sameValue(strictEval(), "undefined");
        \\function makeStrictClosure() {
        \\    var captured = 4;
        \\    return function strictClosure() { "use strict"; return captured; };
        \\}
        \\assert.sameValue(makeStrictClosure()(), 4);
        \\function strictStack() { "use strict"; return new Error("x").stack; }
        \\assert.sameValue(strictStack().indexOf("    at strictStack"), 0);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "strict arguments preserve qjs intrinsic metadata and dense element semantics" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\const savedValues = Array.prototype.values;
        \\Array.prototype.values = function patchedValues() { throw new Error("observable lookup"); };
        \\try {
        \\    function capture(a, b, c) {
        \\        "use strict";
        \\        return { args: arguments, parameter: a };
        \\    }
        \\    const record = capture(1, 2, 3);
        \\    const args = record.args;
        \\    assert.sameValue(args[Symbol.iterator], savedValues);
        \\    assert.sameValue(JSON.stringify(args), '{"0":1,"1":2,"2":3}');
        \\    const keys = Reflect.ownKeys(args);
        \\    assert.sameValue(keys.length, 6);
        \\    assert.sameValue(keys[0], "0");
        \\    assert.sameValue(keys[1], "1");
        \\    assert.sameValue(keys[2], "2");
        \\    assert.sameValue(keys[3], "length");
        \\    assert.sameValue(keys[4], "callee");
        \\    assert.sameValue(keys[5], Symbol.iterator);
        \\    const lengthDesc = Object.getOwnPropertyDescriptor(args, "length");
        \\    assert.sameValue(lengthDesc.value, 3);
        \\    assert.sameValue(lengthDesc.writable, true);
        \\    assert.sameValue(lengthDesc.enumerable, false);
        \\    assert.sameValue(lengthDesc.configurable, true);
        \\    const iteratorDesc = Object.getOwnPropertyDescriptor(args, Symbol.iterator);
        \\    assert.sameValue(iteratorDesc.value, savedValues);
        \\    assert.sameValue(iteratorDesc.writable, true);
        \\    assert.sameValue(iteratorDesc.enumerable, false);
        \\    assert.sameValue(iteratorDesc.configurable, true);
        \\    const calleeDesc = Object.getOwnPropertyDescriptor(args, "callee");
        \\    assert.sameValue(calleeDesc.get, calleeDesc.set);
        \\    assert.sameValue(calleeDesc.enumerable, false);
        \\    assert.sameValue(calleeDesc.configurable, false);
        \\    let calleeThrew = false;
        \\    try { void args.callee; } catch (error) { calleeThrew = error instanceof TypeError; }
        \\    assert.sameValue(calleeThrew, true);
        \\    args.length = 1;
        \\    assert.sameValue(Array.prototype.join.call(args, "-"), "1");
        \\    args[0] = 9;
        \\    assert.sameValue(record.parameter, 1);
        \\    assert.sameValue(args[0], 9);
        \\    assert.sameValue(delete args[0], true);
        \\    assert.sameValue(0 in args, false);
        \\    Object.defineProperty(args, "1", { value: 7, writable: false, enumerable: false, configurable: false });
        \\    assert.sameValue(args[1], 7);
        \\    assert.sameValue(Object.keys(args).join(","), "2");
        \\    Object.freeze(args);
        \\    const frozen = Object.getOwnPropertyDescriptor(args, "2");
        \\    assert.sameValue(frozen.value, 3);
        \\    assert.sameValue(frozen.writable, false);
        \\    assert.sameValue(frozen.enumerable, true);
        \\    assert.sameValue(frozen.configurable, false);
        \\    assert.sameValue(Object.isFrozen(args), true);
        \\} finally {
        \\    Array.prototype.values = savedValues;
        \\}
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "mapped arguments use var-ref indexed storage and detach on descriptor changes" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function mapped(first, second) {
        \\    const args = arguments;
        \\    first = 5;
        \\    assert.sameValue(args[0], 5);
        \\    args[1] = 7;
        \\    assert.sameValue(second, 7);
        \\    const keys = Reflect.ownKeys(args);
        \\    assert.sameValue(keys[0], "0");
        \\    assert.sameValue(keys[1], "1");
        \\    assert.sameValue(keys[2], "length");
        \\    assert.sameValue(keys[3], "callee");
        \\    assert.sameValue(keys[4], Symbol.iterator);
        \\    const initial = Object.getOwnPropertyDescriptor(args, "0");
        \\    assert.sameValue(initial.value, 5);
        \\    assert.sameValue(initial.writable, true);
        \\    assert.sameValue(initial.enumerable, true);
        \\    assert.sameValue(initial.configurable, true);
        \\    assert.sameValue(delete args[0], true);
        \\    first = 8;
        \\    assert.sameValue(0 in args, false);
        \\    assert.sameValue(args[0], undefined);
        \\    Object.defineProperty(args, "1", { enumerable: false });
        \\    second = 9;
        \\    assert.sameValue(args[1], 9);
        \\    assert.sameValue(Object.getOwnPropertyDescriptor(args, "1").enumerable, false);
        \\    Object.defineProperty(args, "1", { writable: false });
        \\    second = 10;
        \\    assert.sameValue(args[1], 9);
        \\    return args;
        \\}
        \\const mappedArgs = mapped(1, 2);
        \\assert.sameValue(Object.keys(mappedArgs).length, 0);
        \\function mappedArgumentsIdentity() {
        \\    assert.sameValue(arguments, arguments);
        \\    arguments.callee = 1;
        \\    assert.sameValue(arguments.callee, 1);
        \\}
        \\mappedArgumentsIdentity({ callee: "argument" });
        \\function annexBArgumentsBinding() {
        \\    const outer = arguments;
        \\    {
        \\        assert.sameValue(arguments(), undefined);
        \\        function arguments() {}
        \\        assert.sameValue(arguments(), undefined);
        \\    }
        \\    assert.sameValue(arguments, outer);
        \\}
        \\annexBArgumentsBinding();
        \\function extra(first) {
        \\    const args = arguments;
        \\    args[1] = 6;
        \\    return args[1];
        \\}
        \\assert.sameValue(extra(1, 2), 6);
        \\function duplicate(value, value) {
        \\    const args = arguments;
        \\    value = 7;
        \\    assert.sameValue(args[0], 1);
        \\    assert.sameValue(args[1], 7);
        \\    args[0] = 8;
        \\    assert.sameValue(value, 7);
        \\    args[1] = 9;
        \\    assert.sameValue(value, 9);
        \\}
        \\duplicate(1, 2);
        \\function frozen(value) {
        \\    const args = arguments;
        \\    Object.freeze(args);
        \\    value = 4;
        \\    const desc = Object.getOwnPropertyDescriptor(args, "0");
        \\    assert.sameValue(args[0], 1);
        \\    assert.sameValue(desc.writable, false);
        \\    assert.sameValue(desc.configurable, false);
        \\    assert.sameValue(Object.isFrozen(args), true);
        \\}
        \\frozen(1);
    );
    try std.testing.expect(result.is(.undefined_value));
}

// qjs:41171 resolves length through ordinary [[Get]] before qjs:41182-41197
// selects ARRAY/ARGUMENTS/MAPPED_ARGUMENTS or the observable element fallback.
test "apply resolves arguments length and preserves observable fallback" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function signature() {
        \\    return arguments.length + ":" + arguments[0] + ":" + arguments[arguments.length - 1];
        \\}
        \\function mapped(first, second, third) {
        \\    return signature.apply(null, arguments);
        \\}
        \\assert.sameValue(mapped(1, 2, 3), "3:1:3");
        \\function unmapped(first, second, third) {
        \\    "use strict";
        \\    return Reflect.apply(signature, null, arguments);
        \\}
        \\assert.sameValue(unmapped(4, 5, 6), "3:4:6");
        \\function rewrittenLength(first, second, third) {
        \\    arguments.length = 1;
        \\    return signature.apply(null, arguments);
        \\}
        \\assert.sameValue(rewrittenLength(7, 8, 9), "1:7:7");
        \\let lengthGets = 0;
        \\function accessorLength(first, second, third) {
        \\    Object.defineProperty(arguments, "length", {
        \\        get: function() { lengthGets++; return 2; }
        \\    });
        \\    return signature.apply(null, arguments);
        \\}
        \\assert.sameValue(accessorLength(10, 11, 12), "2:10:11");
        \\assert.sameValue(lengthGets, 1);
        \\function detached(first, second) {
        \\    delete arguments[0];
        \\    return signature.apply(null, arguments);
        \\}
        \\Object.prototype[0] = 13;
        \\try {
        \\    assert.sameValue(detached(1, 14), "2:13:14");
        \\} finally {
        \\    delete Object.prototype[0];
        \\}
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "resident generators preserve mapped arguments parameter aliases" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function* mappedGenerator(first, second, third, missing) {
        \\    arguments[0] = 32;
        \\    arguments[1] = 54;
        \\    arguments[2] = 333;
        \\    yield first;
        \\    yield second;
        \\    yield third;
        \\    yield missing;
        \\}
        \\const iterator = mappedGenerator(23, 45, 33);
        \\assert.sameValue(iterator.next().value, 32);
        \\assert.sameValue(iterator.next().value, 54);
        \\assert.sameValue(iterator.next().value, 333);
        \\assert.sameValue(iterator.next().value, undefined);
        \\assert.sameValue(iterator.next().done, true);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "implicit arguments resolution preserves mapped aliases" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function annexRead(value) {
        \\  { function arguments() {} }
        \\  return arguments[0];
        \\}
        \\function annexAliasFromArguments(value) {
        \\  { function arguments() {} }
        \\  arguments[0] = 5;
        \\  return value;
        \\}
        \\function annexAliasFromParameter(value) {
        \\  { function arguments() {} }
        \\  value = 7;
        \\  return arguments[0];
        \\}
        \\function annexCaptured(first, second) {
        \\  { function arguments() {} }
        \\  const read = () => first;
        \\  arguments[0] = 5;
        \\  second = 7;
        \\  return read() + ":" + arguments[1];
        \\}
        \\function* annexGenerator(value) {
        \\  { function arguments() {} }
        \\  yield arguments[0];
        \\}
        \\print(annexRead(42));
        \\print(annexAliasFromArguments(42));
        \\print(annexAliasFromParameter(42));
        \\print(annexCaptured(1, 2));
        \\print(annexGenerator(9).next().value);
        \\try { print(annexRead(43)); } catch (error) { print("caught", error.name); }
        \\print("after");
    , &output);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("42\n5\n7\n5:7\n9\n43\nafter\n", output.buffered());
}

test "body function named arguments does not create a synthetic lexical collision" {
    try helpers.expectPrints(
        \\function bodyCollision() { return typeof arguments; function arguments() {} }
        \\print(bodyCollision());
    , "function\n");
}

test "resident mapped arguments share one open bare arg slot" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\function* mappedArgStorage(first) {
        \\  globalThis.__mappedArgArguments = arguments;
        \\  yield first;
        \\  first += 1;
        \\  yield first;
        \\}
        \\globalThis.__mappedArgGenerator = mappedArgStorage(41);
        \\__mappedArgGenerator.next();
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const generator_key = try js.runtime.internAtom("__mappedArgGenerator");
    const generator_value = try global.getProperty(generator_key);
    const generator = try property_ops.expectObject(generator_value);
    const state = generator.generatorExecutionState();
    const arg_slot = &state.storage.frame.args[0];

    const arguments_key = try js.runtime.internAtom("__mappedArgArguments");
    const arguments_value = try global.getProperty(arguments_key);
    const arguments = try property_ops.expectObject(arguments_value);
    const argument_refs = arguments.argumentsVarRefs();
    try std.testing.expectEqual(@as(usize, 1), argument_refs.len);
    const cell = argument_refs[0] orelse return error.TypeError;

    try std.testing.expectEqual(@as(?i32, 41), arg_slot.as(.int));
    try std.testing.expect(core.VarRef.fromValue(arg_slot.*) == null);
    try std.testing.expect(cell.is_open);
    try std.testing.expect(cell.pvalue == arg_slot);
    var identity_matches: usize = 0;
    for (state.storage.frame.open_var_refs) |maybe_ref| {
        if (maybe_ref == cell) identity_matches += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), identity_matches);

    _ = try js.eval(
        \\const step = __mappedArgGenerator.next();
        \\assert.sameValue(step.value, 42);
        \\assert.sameValue(step.done, false);
    );
    try std.testing.expect(arg_slot == &generator.generatorExecutionState().storage.frame.args[0]);
    try std.testing.expect(cell.pvalue == arg_slot);
    try std.testing.expectEqual(@as(?i32, 42), arg_slot.as(.int));
}

test "generic arg opcodes preserve mapped aliases in a bare resident slot" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\function* genericArgStorage(a, b, c, d, fifth) {
        \\  globalThis.__genericArgArguments = arguments;
        \\  arguments[4] = 50;
        \\  yield fifth;
        \\  fifth = 51;
        \\  yield arguments[4];
        \\  yield (fifth = 52);
        \\  return arguments[4];
        \\}
        \\globalThis.__genericArgGenerator = genericArgStorage(1, 2, 3, 4, 5);
        \\const first = __genericArgGenerator.next();
        \\assert.sameValue(first.value, 50);
        \\assert.sameValue(first.done, false);
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const generator_key = try js.runtime.internAtom("__genericArgGenerator");
    const generator_value = try global.getProperty(generator_key);
    const generator = try property_ops.expectObject(generator_value);
    const fifth_slot = &generator.generatorExecutionState().storage.frame.args[4];
    try std.testing.expectEqual(@as(?i32, 50), fifth_slot.as(.int));
    try std.testing.expect(core.VarRef.fromValue(fifth_slot.*) == null);

    const completion = try js.eval(
        \\let step = __genericArgGenerator.next();
        \\assert.sameValue(step.value, 51);
        \\assert.sameValue(step.done, false);
        \\step = __genericArgGenerator.next();
        \\assert.sameValue(step.value, 52);
        \\assert.sameValue(step.done, false);
        \\step = __genericArgGenerator.next();
        \\assert.sameValue(step.value, 52);
        \\assert.sameValue(step.done, true);
    );
    try std.testing.expect(completion.is(.undefined_value));
}

test "generator mapped arguments closures and direct eval share one alias across resumes" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function* aliasedGenerator(argument) {
        \\  globalThis.__aliasedArguments = arguments;
        \\  globalThis.__aliasedRead = function() { return argument; };
        \\  globalThis.__aliasedWrite = function(value) { argument = value; };
        \\  arguments[0] = 20;
        \\  yield __aliasedRead();
        \\  eval('argument = 30');
        \\  yield arguments[0];
        \\  argument = 40;
        \\  yield __aliasedRead();
        \\}
        \\globalThis.__aliasedGenerator = aliasedGenerator(10);
        \\let step = __aliasedGenerator.next();
        \\assert.sameValue(step.value, 20);
        \\assert.sameValue(__aliasedRead(), 20);
        \\__aliasedArguments[0] = 25;
        \\assert.sameValue(__aliasedRead(), 25);
        \\step = __aliasedGenerator.next();
        \\assert.sameValue(step.value, 30);
        \\assert.sameValue(__aliasedRead(), 30);
        \\__aliasedWrite(35);
        \\assert.sameValue(__aliasedArguments[0], 35);
        \\step = __aliasedGenerator.next();
        \\assert.sameValue(step.value, 40);
        \\assert.sameValue(__aliasedArguments[0], 40);
        \\step = __aliasedGenerator.next();
        \\assert.sameValue(step.done, true);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "async mapped arguments and closures retain one alias across await" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\async function mappedAsync(argument) {
        \\  const read = function() { return argument; };
        \\  arguments[0] = 55;
        \\  print('before', read());
        \\  const awaited = await Promise.resolve(argument);
        \\  print('after', arguments[0], read(), awaited);
        \\  return read();
        \\}
        \\mappedAsync(10).then(
        \\  function(value) { print('resolved', value); },
        \\  function(error) { print('rejected', error.name); }
        \\);
    , &stream);
    try js.runJobs();

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings(
        "before 55\nafter 55 55 55\nresolved 55\n",
        stream.buffered(),
    );
}

test "escaped generator arg aliases retain resident backing across cycle collection" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\var __argCycleHolder;
        \\function* argCycle(argument) {
        \\  const self = __argCycleHolder;
        \\  globalThis.__argCycleArguments = arguments;
        \\  globalThis.__argCycleRead = function() { return argument; };
        \\  globalThis.__argCycleWrite = function(value) { argument = value; };
        \\  yield 0;
        \\  return self;
        \\}
        \\__argCycleHolder = argCycle(41);
        \\__argCycleHolder.next();
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const arguments_key = try js.runtime.internAtom("__argCycleArguments");
    const arguments_value = try global.getProperty(arguments_key);
    const arguments = try property_ops.expectObject(arguments_value);
    const refs = arguments.argumentsVarRefs();
    try std.testing.expectEqual(@as(usize, 1), refs.len);
    const cell = refs[0] orelse return error.TypeError;
    try std.testing.expect(cell.is_open);
    try std.testing.expectEqual(@as(?i32, 41), cell.varRefValue().as(.int));

    _ = try js.eval("__argCycleHolder = null;");
    _ = try js.runtime.collectForTest();
    // QuickJS's attached JSVarRef owns the parked async-function state. The
    // escaped arguments object and closures therefore keep this generator
    // frame resident even after its direct global reference is gone.
    try std.testing.expect(cell.is_open);
    try std.testing.expect(cell.value.is(.object));
    try std.testing.expectEqual(core.class.ids.generator, (try property_ops.expectObject(cell.value)).class_id);
    try std.testing.expectEqual(@as(?i32, 41), cell.varRefValue().as(.int));

    const escaped = try js.eval(
        \\assert.sameValue(__argCycleRead(), 41);
        \\__argCycleArguments[0] = 52;
        \\assert.sameValue(__argCycleRead(), 52);
        \\__argCycleWrite(63);
        \\assert.sameValue(__argCycleArguments[0], 63);
    );
    try std.testing.expect(escaped.is(.undefined_value));
}

test "generator completion closes escaped arg aliases before releasing resident backing" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\function* completingArgAlias(argument) {
        \\  globalThis.__completedArgArguments = arguments;
        \\  globalThis.__completedArgRead = function() { return argument; };
        \\  yield 0;
        \\  return argument;
        \\}
        \\globalThis.__completedArgGenerator = completingArgAlias(41);
        \\__completedArgGenerator.next();
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const generator_key = try js.runtime.internAtom("__completedArgGenerator");
    const generator_value = try global.getProperty(generator_key);
    const generator = try property_ops.expectObject(generator_value);

    const arguments_key = try js.runtime.internAtom("__completedArgArguments");
    const arguments_value = try global.getProperty(arguments_key);
    const arguments = try property_ops.expectObject(arguments_value);
    const cell = arguments.argumentsVarRefs()[0] orelse return error.TypeError;
    try std.testing.expect(cell.is_open);

    _ = try js.eval(
        \\const step = __completedArgGenerator.next();
        \\assert.sameValue(step.value, 41);
        \\assert.sameValue(step.done, true);
    );
    try std.testing.expect(!cell.is_open);
    try std.testing.expect(generator.generatorExecutionState().storage.isEmpty());

    const escaped = try js.eval(
        \\__completedArgArguments[0] = 52;
        \\assert.sameValue(__completedArgRead(), 52);
    );
    try std.testing.expect(escaped.is(.undefined_value));
}

test "get_length preserves qjs own-property-before-exotic ordering and actions" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const own = { length: 3 };
        \\assert.sameValue(own.length, 3);
        \\const inherited = Object.create({ length: 4 });
        \\assert.sameValue(inherited.length, 4);
        \\const self = {};
        \\self.length = self;
        \\assert.sameValue(self.length, self);
        \\function strictLength(value) {
        \\    "use strict";
        \\    return arguments.length;
        \\}
        \\assert.sameValue(strictLength(1), 1);
        \\function mappedLength(value) {
        \\    return arguments.length;
        \\}
        \\assert.sameValue(mappedLength(1), 1);
        \\function mappedComputedDescriptor(value) {
        \\    const args = arguments;
        \\    const key = "0";
        \\    Object.defineProperty(args, key, { configurable: false });
        \\    args[key] = 2;
        \\    assert.sameValue(value, 2);
        \\    assert.sameValue(args[key], 2);
        \\    const desc = Object.getOwnPropertyDescriptor(args, key);
        \\    assert.sameValue(desc.value, 2);
        \\    assert.sameValue(desc.writable, true);
        \\    assert.sameValue(desc.enumerable, true);
        \\    assert.sameValue(desc.configurable, false);
        \\}
        \\mappedComputedDescriptor(1);
        \\const typed = new Uint8Array(2);
        \\assert.sameValue(typed.length, 2);
        \\assert.sameValue(typed.byteLength, 2);
        \\assert.sameValue(typed.byteOffset, 0);
        \\const typedPrototypeImpostor = Object.create(typed);
        \\let typedBrandRejected = false;
        \\try {
        \\    void typedPrototypeImpostor.length;
        \\} catch (error) {
        \\    typedBrandRejected = error instanceof TypeError;
        \\}
        \\assert.sameValue(typedBrandRejected, true);
        \\const customPrototypeTyped = new Uint8Array(2);
        \\Object.setPrototypeOf(customPrototypeTyped, { length: 15, byteLength: 16, byteOffset: 17 });
        \\assert.sameValue(customPrototypeTyped.length, 15);
        \\assert.sameValue(customPrototypeTyped.byteLength, 16);
        \\assert.sameValue(customPrototypeTyped.byteOffset, 17);
        \\assert.sameValue(Reflect.get(customPrototypeTyped, "length"), 15);
        \\const nullPrototypeTyped = new Uint8Array(2);
        \\Object.setPrototypeOf(nullPrototypeTyped, null);
        \\assert.sameValue(nullPrototypeTyped.length, undefined);
        \\assert.sameValue(nullPrototypeTyped.byteLength, undefined);
        \\assert.sameValue(nullPrototypeTyped.byteOffset, undefined);
        \\assert.sameValue(Reflect.get(nullPrototypeTyped, "length"), undefined);
        \\Object.defineProperty(typed, "length", { value: 9, configurable: true });
        \\assert.sameValue(typed.length, 9);
        \\let typedGetterCount = 0;
        \\Object.defineProperty(typed, "length", {
        \\    configurable: true,
        \\    get() {
        \\        typedGetterCount++;
        \\        return 12;
        \\    },
        \\});
        \\assert.sameValue(typed.length, 12);
        \\const lengthKey = "length";
        \\assert.sameValue(typed[lengthKey], 12);
        \\assert.sameValue(Reflect.get(typed, lengthKey), 12);
        \\assert.sameValue(typedGetterCount, 3);
        \\Object.defineProperty(typed, "byteLength", {
        \\    configurable: true,
        \\    get() { return 13; },
        \\});
        \\assert.sameValue(typed.byteLength, 13);
        \\assert.sameValue(Reflect.get(typed, "byteLength"), 13);
        \\Object.defineProperty(typed, "byteOffset", { configurable: true, value: 14 });
        \\assert.sameValue(typed.byteOffset, 14);
        \\assert.sameValue(Reflect.get(typed, "byteOffset"), 14);
        \\let getterCount = 0;
        \\let getterReceiver;
        \\const accessorPrototype = {
        \\    get length() {
        \\        getterCount++;
        \\        getterReceiver = this;
        \\        return 5;
        \\    },
        \\};
        \\const accessor = Object.create(accessorPrototype);
        \\assert.sameValue(accessor.length, 5);
        \\assert.sameValue(getterCount, 1);
        \\assert.sameValue(getterReceiver, accessor);
        \\const accessorAlias = { get length() { return this; } };
        \\assert.sameValue(accessorAlias.length, accessorAlias);
        \\const undefinedAccessor = {};
        \\Object.defineProperty(undefinedAccessor, "length", { get: undefined });
        \\assert.sameValue(undefinedAccessor.length, undefined);
        \\const thrownMarker = {};
        \\const throwingAccessor = { get length() { throw thrownMarker; } };
        \\try {
        \\    void throwingAccessor.length;
        \\    throw new Error("unreachable");
        \\} catch (thrown) {
        \\    assert.sameValue(thrown, thrownMarker);
        \\}
        \\let trapCount = 0;
        \\let trapReceiver;
        \\const proxy = new Proxy({}, {
        \\    get(target, key, receiver) {
        \\        trapCount++;
        \\        trapReceiver = receiver;
        \\        return key === "length" ? 6 : Reflect.get(target, key, receiver);
        \\    },
        \\});
        \\assert.sameValue(proxy.length, 6);
        \\assert.sameValue(trapCount, 1);
        \\assert.sameValue(trapReceiver, proxy);
        \\let targetGetterReceiver;
        \\const proxyTarget = {};
        \\Object.defineProperty(proxyTarget, "length", {
        \\    configurable: true,
        \\    get() {
        \\        targetGetterReceiver = this;
        \\        return 7;
        \\    },
        \\});
        \\const noTrapProxy = new Proxy(proxyTarget, {});
        \\assert.sameValue(noTrapProxy.length, 7);
        \\assert.sameValue(targetGetterReceiver, noTrapProxy);
        \\const frozenTarget = {};
        \\Object.defineProperty(frozenTarget, "length", { value: 1, writable: false, configurable: false });
        \\try {
        \\    void new Proxy(frozenTarget, { get() { return 2; } }).length;
        \\    throw new Error("unreachable");
        \\} catch (error) {
        \\    assert.sameValue(error instanceof TypeError, true);
        \\}
        \\const revocable = Proxy.revocable({}, {});
        \\revocable.revoke();
        \\try {
        \\    void revocable.proxy.length;
        \\    throw new Error("unreachable");
        \\} catch (error) {
        \\    assert.sameValue(error instanceof TypeError, true);
        \\}
        \\function mappedAccessor(value) {
        \\    const args = arguments;
        \\    Object.defineProperty(args, "length", {
        \\        configurable: true,
        \\        get() { return 11; },
        \\    });
        \\    return args.length;
        \\}
        \\assert.sameValue(mappedAccessor(1), 11);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "missing-argument plain calls preserve parameter and arguments ownership" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function sloppyMissing(first, second) {
        \\    assert.sameValue(arguments.length, 0);
        \\    assert.sameValue(arguments.hasOwnProperty("0"), false);
        \\    assert.sameValue(arguments.hasOwnProperty("1"), false);
        \\    first = 7;
        \\    second = 8;
        \\    assert.sameValue(arguments.hasOwnProperty("0"), false);
        \\    assert.sameValue(arguments.hasOwnProperty("1"), false);
        \\    return first + second;
        \\}
        \\assert.sameValue(sloppyMissing(), 15);
        \\function sloppyPartial(first, second) {
        \\    assert.sameValue(arguments.length, 1);
        \\    first = 7;
        \\    second = 8;
        \\    assert.sameValue(arguments[0], 7);
        \\    assert.sameValue(arguments.hasOwnProperty("1"), false);
        \\    return first + second;
        \\}
        \\assert.sameValue(sloppyPartial(1), 15);
        \\function strictPartial(first, second) {
        \\    "use strict";
        \\    first = 7;
        \\    second = 8;
        \\    assert.sameValue(arguments.length, 1);
        \\    assert.sameValue(arguments[0], 1);
        \\    assert.sameValue(arguments.hasOwnProperty("1"), false);
        \\    return first + second;
        \\}
        \\assert.sameValue(strictPartial(1), 15);
        \\function captureMissing(value) {
        \\    return function readCaptured() { return value; };
        \\}
        \\assert.sameValue(captureMissing()(), undefined);
        \\function evalMissing(value) {
        \\    return eval("value");
        \\}
        \\assert.sameValue(evalMissing(), undefined);
        \\const marker = {};
        \\function keepActual(first, second) { return first; }
        \\assert.sameValue(keepActual(marker), marker);
        \\function escapeMapped(first, second) { return arguments; }
        \\const mapped = escapeMapped(marker);
        \\assert.sameValue(mapped.length, 1);
        \\assert.sameValue(mapped[0], marker);
        \\assert.sameValue(mapped.hasOwnProperty("1"), false);
        \\function escapeStrict(first, second) {
        \\    "use strict";
        \\    first = 9;
        \\    return arguments;
        \\}
        \\const unmapped = escapeStrict(marker);
        \\assert.sameValue(unmapped.length, 1);
        \\assert.sameValue(unmapped[0], marker);
        \\assert.sameValue(unmapped.hasOwnProperty("1"), false);
        \\try {
        \\    (function throwMissing(first, second) { throw first; })(marker);
        \\} catch (thrown) {
        \\    assert.sameValue(thrown, marker);
        \\}
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "inline calls release lazily materialized arguments state" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    _ = try js.eval(
        \\function readArguments(value) {
        \\    return arguments.length + value;
        \\}
        \\assert.sameValue(readArguments(1), 2);
    );
    const exercise =
        \\(function exerciseArgumentsCalls() {
        \\    let total = 0;
        \\    for (let i = 0; i < 256; i++) total += readArguments(i);
        \\    assert.sameValue(total, 32896);
        \\})();
    ;
    _ = try js.eval(exercise);
    _ = try js.runtime.collectForTest();
    const baseline_objects = js.runtime.gc.liveCount();

    _ = try js.eval(exercise);
    _ = try js.runtime.collectForTest();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "inline empty leaf abrupt teardown releases pending operands" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    _ = try js.eval(
        \\function throwWithPendingOperand() {
        \\    return {} + null.missing;
        \\}
        \\function exerciseEmptyLeafThrow() {
        \\    for (let i = 0; i < 256; i++) {
        \\        try { throwWithPendingOperand(); } catch (error) {}
        \\    }
        \\}
        \\exerciseEmptyLeafThrow();
    );
    _ = try js.runtime.collectForTest();
    const baseline_objects = js.runtime.gc.liveCount();

    _ = try js.eval("exerciseEmptyLeafThrow()");
    _ = try js.runtime.collectForTest();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "exact-args leaf abrupt teardown releases borrowed args exactly once" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // The callee is a published exact-args leaf (params only, no locals or
    // cell creation); each call moves TWO refcounted argument objects into
    // the caller-region args window before throwing mid-body. Abrupt
    // completion must release each borrowed-window arg exactly once —
    // a double free corrupts rc, a missed free strands the objects, and
    // either breaks the liveCount balance below. Also covers the plain /
    // strict / method entry arms.
    _ = try js.eval(
        \\function leafThrow(a, b) {
        \\    return a.x + null.missing + b.x;
        \\}
        \\function strictLeafThrow(a, b) {
        \\    "use strict";
        \\    return a.x + null.missing + b.x;
        \\}
        \\const leafRecv = { m: function (a, b) { return a.x + null.missing + b.x; } };
        \\function exerciseExactArgsLeafThrow() {
        \\    for (let i = 0; i < 256; i++) {
        \\        try { leafThrow({ x: 1 }, { x: 2 }); } catch (error) {}
        \\        try { strictLeafThrow({ x: 3 }, { x: 4 }); } catch (error) {}
        \\        try { leafRecv.m({ x: 5 }, { x: 6 }); } catch (error) {}
        \\    }
        \\}
        \\exerciseExactArgsLeafThrow();
    );
    _ = try js.runtime.collectForTest();
    const baseline_objects = js.runtime.gc.liveCount();

    _ = try js.eval("exerciseExactArgsLeafThrow()");
    _ = try js.runtime.collectForTest();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "missing-argument abrupt teardown releases supplied args and pads exactly once" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Release-balance side of `argc < arg_count`: general teardown walks the
    // FULL `arg_count` window — the supplied refcounted prefix exactly once
    // (double free corrupts rc, missed free strands the object) and the
    // undefined pads as tag-test no-ops. Covers supplied-prefix (argc=1 < 2),
    // all-missing (argc=0 < 2), and the plain/strict/method entry arms.
    _ = try js.eval(
        \\function padThrow(a, b) { return a.x + null.missing + String(b); }
        \\function strictPadThrow(a, b) { "use strict"; return a.x + null.missing + String(b); }
        \\const padThrowRecv = { m: function (a, b) { return a.x + null.missing + String(b); } };
        \\function exercisePaddedLeafThrow() {
        \\    for (let i = 0; i < 256; i++) {
        \\        try { padThrow({ x: 1 }); } catch (error) {}
        \\        try { padThrow(); } catch (error) {}
        \\        try { strictPadThrow({ x: 2 }); } catch (error) {}
        \\        try { padThrowRecv.m({ x: 3 }); } catch (error) {}
        \\    }
        \\    return true;
        \\}
        \\exercisePaddedLeafThrow();
    );
    _ = try js.runtime.collectForTest();
    const baseline_objects = js.runtime.gc.liveCount();

    _ = try js.eval("exercisePaddedLeafThrow()");
    _ = try js.runtime.collectForTest();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "leaf returns with leftover operands route through general teardown" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // The parser elides trailing expression-statement drops and leaves
    // switch discriminants on the operand stack at `return` (qjs frees both
    // in the done: local_buf..sp loop). The exact-args leaf return arm must
    // detect the non-empty callee window and fall back to general teardown;
    // the narrow epilogue would strand these object leftovers (rc leak, and
    // a Debug assert abort). The zero-arg twin of this exposure (HEAD
    // ec058eed: `function k(){ ({}); }` trips the same assert) is fixed on
    // the publication side instead — the return-balance proof refuses those
    // bodies the leaf flag; see "zero-arg leaf leftover bodies ..." below.
    _ = try js.eval(
        \\function exactArgsLeftover(a) { ({ x: a }); }
        \\function switchLeftover(a) {
        \\    switch (a) { case 1: return { x: 9 }; }
        \\}
        \\function exerciseLeafLeftovers() {
        \\    for (let i = 0; i < 256; i++) {
        \\        exactArgsLeftover(i);
        \\        switchLeftover(1).x;
        \\    }
        \\}
        \\exerciseLeafLeftovers();
    );
    _ = try js.runtime.collectForTest();
    const baseline_objects = js.runtime.gc.liveCount();

    _ = try js.eval("exerciseLeafLeftovers()");
    _ = try js.runtime.collectForTest();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "missing-argument calls read undefined across every entry arm" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    const rt = js.runtime;
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);

    // Outcome side of the `argc < arg_count` call shape (qjs's `for(i = argc;
    // i < arg_count; i++) arg_buf[i] = JS_UNDEFINED`, quickjs.c):
    // missing params read undefined, writes to a padded slot stay frame-local
    // (fresh undefined on the next call), the supplied prefix stays bound, and
    // the sloppy/strict/arrow/method `this` arms keep their policies. A
    // dedicated warm padded-leaf family used to serve these calls and was
    // deleted (3273 Octane hits total); the callees below are still published
    // exact-args leaves, so this is also the regression pin that their
    // MISSING-arg siblings keep generic-path semantics.
    _ = try js.eval(
        \\globalThis.__padOne = function (value) { return value === undefined ? 1 : 0; };
        \\globalThis.__padTwo = function (first, second) {
        \\    return String(first) + "," + String(second);
        \\};
        \\globalThis.__padWrite = function (a, b) { b = 42; return b; };
        \\globalThis.__padFive = function (a, b, c, d, fifth) { return fifth; };
        \\globalThis.__padPutShort = function (a, b, c, d) { a = b; d = b; return a === d ? a : null; };
        \\globalThis.__padSetShort = function (a, b, c, d) { return (a = b) === (d = b); };
        \\globalThis.__padPutWide = function (a, b, c, d, fifth) { fifth = a; return fifth; };
        \\globalThis.__padSetWide = function (a, b, c, d, fifth) { return (fifth = a); };
        \\globalThis.__padStrict = function (a, b) {
        \\    "use strict";
        \\    return String(this) + ":" + String(a) + ":" + String(b);
        \\};
        \\globalThis.__padStrictLeaf = function (a, b) {
        \\    "use strict";
        \\    return String(a) + "^" + String(b);
        \\};
        \\globalThis.__padArrow = (p, q) => String(p) + "&" + String(q);
        \\const padRecv = { m: function (x, y) { return String(this === padRecv) + "|" + String(x) + "|" + String(y); } };
        \\globalThis.__padRecv = padRecv;
        \\function exercisePaddedLeafOutcomes() {
        \\    for (let i = 0; i < 256; i++) {
        \\        if (__padOne() !== 1) throw new Error("missing-one read");
        \\        if (__padTwo(i) !== i + ",undefined") throw new Error("missing-second read");
        \\        if (__padTwo() !== "undefined,undefined") throw new Error("missing-both read");
        \\        if (__padWrite(i) !== 42) throw new Error("pad write");
        \\        if (__padWrite(i) !== 42) throw new Error("pad write not frame-local");
        \\        if (__padFive(1, 2, 3, 4) !== undefined) throw new Error("wide missing read");
        \\        if (__padFive(1, 2, 3, 4, i) !== i) throw new Error("wide supplied read");
        \\        const marker = { i: i };
        \\        if (__padPutShort(null, marker, null, null) !== marker) throw new Error("short put arg");
        \\        if (__padSetShort(null, marker, null, null) !== true) throw new Error("short set arg");
        \\        if (__padPutWide(marker, null, null, null) !== marker) throw new Error("wide put arg");
        \\        if (__padSetWide(marker, null, null, null) !== marker) throw new Error("wide set arg");
        \\        if (__padStrict(i) !== "undefined:" + i + ":undefined") throw new Error("strict pad this");
        \\        if (__padStrictLeaf(i) !== i + "^undefined") throw new Error("strict pad leaf");
        \\        if (__padStrictLeaf() !== "undefined^undefined") throw new Error("strict pad leaf both");
        \\        if (__padArrow(i) !== i + "&undefined") throw new Error("arrow pad");
        \\        if (padRecv.m() !== "true|undefined|undefined") throw new Error("method pad receiver");
        \\        if (padRecv.m(i) !== "true|" + i + "|undefined") throw new Error("method pad supplied");
        \\    }
        \\    return true;
        \\}
        \\exercisePaddedLeafOutcomes();
    );

    // Publication pins: these callees really are published exact-args leaves,
    // so the outcomes above are the missing-arg shape of the leaf family and
    // not some unrelated generic callee. The sloppy plain callee and sloppy
    // arrow publish `.sloppy`; the non-`this`-reading strict callee publishes
    // `.raw_this`. The `this`-READING strict callee pins `.none`: `this`
    // compiles to `push_this; put_loc` (a local), so `var_count > 0` refuses
    // the whole leaf family by geometry.
    const one_name = try rt.internAtom("__padOne");
    const strict_name = try rt.internAtom("__padStrict");
    const strict_leaf_name = try rt.internAtom("__padStrictLeaf");
    const arrow_name = try rt.internAtom("__padArrow");
    const one_fn = try global.getProperty(one_name);
    const strict_fn = try global.getProperty(strict_name);
    const strict_leaf_fn = try global.getProperty(strict_leaf_name);
    const arrow_fn = try global.getProperty(arrow_name);
    const resolved_one = inline_calls.resolveInlineFunction(global, one_fn) orelse
        return error.InvalidFunctionBytecode;
    try std.testing.expect(resolved_one.fb.hasExtension());
    try std.testing.expect(resolved_one.fb.byte_code != null);
    try std.testing.expect(resolved_one.fb.byte_code_len > 0);
    try std.testing.expectEqual(resolved_one.fb.canonicalCallFacts(), resolved_one.call_facts);
    try std.testing.expect(resolved_one.fb.exactArgsLeafKind() == .sloppy);
    const bound_one = resolved_one.bind(core.JSValue.undefinedValue(), one_fn);
    try std.testing.expectEqual(resolved_one.call_facts, bound_one.call_facts);
    const resolved_strict = inline_calls.resolveInlineFunction(global, strict_fn) orelse
        return error.InvalidFunctionBytecode;
    try std.testing.expect(resolved_strict.fb.exactArgsLeafKind() == .none);
    const resolved_strict_leaf = inline_calls.resolveInlineFunction(global, strict_leaf_fn) orelse
        return error.InvalidFunctionBytecode;
    try std.testing.expect(resolved_strict_leaf.fb.exactArgsLeafKind() == .raw_this);
    const resolved_arrow = inline_calls.resolveInlineFunction(global, arrow_fn) orelse
        return error.InvalidFunctionBytecode;
    try std.testing.expect(resolved_arrow.fb.exactArgsLeafKind() == .sloppy);

    _ = try rt.collectForTest();
    const baseline_objects = rt.gc.liveCount();

    _ = try js.eval("exercisePaddedLeafOutcomes()");
    _ = try rt.collectForTest();

    try std.testing.expectEqual(baseline_objects, rt.gc.liveCount());
}

test "missing-argument calls on leaf-excluded shapes keep generic-path outcomes" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    const rt = js.runtime;
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);

    // Exclusion side: the shapes no leaf arm may ever capture stay off the O1
    // kind byte at publication, so a missing-arg call keeps its authoritative
    // semantics — `arguments` observes the real argc (not a padded window),
    // default parameter initializers run (`has_simple_parameter_list` gate),
    // rest parameters collect the real args, and a captured parameter reads
    // through its cell (`open_var_ref_count` gate).
    _ = try js.eval(
        \\globalThis.__exArguments = function (a, b) { return arguments.length; };
        \\globalThis.__exDefault = function (a, b = 9) { return String(a) + ":" + String(b); };
        \\globalThis.__exRest = function (a, ...rest) { return String(a) + "#" + rest.length; };
        \\globalThis.__exCapture = function (a, b) { return function () { return String(b); }; };
        \\function exercisePaddedExclusions() {
        \\    for (let i = 0; i < 256; i++) {
        \\        if (__exArguments(1) !== 1) throw new Error("arguments.length");
        \\        if (__exArguments() !== 0) throw new Error("arguments.length zero");
        \\        if (__exDefault(3) !== "3:9") throw new Error("default init");
        \\        if (__exRest(4) !== "4#0") throw new Error("rest collect");
        \\        if (__exCapture(5)() !== "undefined") throw new Error("captured missing arg");
        \\    }
        \\    return true;
        \\}
        \\exercisePaddedExclusions();
    );

    // Publication pins: every excluded shape must read `.none`, which proves
    // these calls can never enter any leaf constructor.
    const names = [_][]const u8{ "__exArguments", "__exDefault", "__exRest", "__exCapture" };
    for (names) |name| {
        const atom_name = try rt.internAtom(name);
        const fn_value = try global.getProperty(atom_name);
        const resolved = inline_calls.resolveInlineFunction(global, fn_value) orelse
            return error.InvalidFunctionBytecode;
        try std.testing.expect(resolved.fb.exactArgsLeafKind() == .none);
    }

    _ = try rt.collectForTest();
    const baseline_objects = rt.gc.liveCount();

    _ = try js.eval("exercisePaddedExclusions()");
    _ = try rt.collectForTest();

    try std.testing.expectEqual(baseline_objects, rt.gc.liveCount());
}

test "missing-argument leftover-carrying returns route through general teardown" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Missing-argument twin of the exact-args leftover coverage. Parser-elided
    // trailing drops and switch discriminants held across `return` must route
    // to general teardown, which releases the leftovers AND the padded args
    // window exactly once.
    _ = try js.eval(
        \\function padLeftover(a, b) { ({ x: a, y: b }); }
        \\function padSwitchLeftover(a, b) {
        \\    switch (a) { case 1: return { x: String(b) }; }
        \\}
        \\function exercisePaddedLeafLeftovers() {
        \\    for (let i = 0; i < 256; i++) {
        \\        padLeftover(i);
        \\        padLeftover();
        \\        if (padSwitchLeftover(1).x !== "undefined") throw new Error("switch pad");
        \\    }
        \\    return true;
        \\}
        \\exercisePaddedLeafLeftovers();
    );
    _ = try js.runtime.collectForTest();
    const baseline_objects = js.runtime.gc.liveCount();

    _ = try js.eval("exercisePaddedLeafLeftovers()");
    _ = try js.runtime.collectForTest();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "zero-arg leaf leftover bodies are refused publication and balance rc" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    const rt = js.runtime;
    const ctx = js.context;
    const global = try engine.exec.zjs_vm.contextGlobal(ctx);

    // Zero-arg bodies that leave operands live at return: the parser-elided
    // trailing expression-statement drop and the switch discriminant held
    // across `return`. HEAD ec058eed published these as zero-arg empty
    // leaves, and that family's return arm is the one leaf epilogue WITHOUT
    // an operand-window guard — the leftover was stranded (Debug assert in
    // deinitEmptyLeafInline; one leaked object per call in ReleaseFast).
    // The static return-balance proof now refuses them publication, so they
    // ride the generic simple-inline path whose teardown releases leftovers
    // exactly once — across the direct sloppy, method-receiver, strict and
    // arrow entry shapes.
    _ = try js.eval(
        \\globalThis.__zeroTrailingDrop = function () { ({ z: 1 }); };
        \\globalThis.__zeroSwitchLeftover = function () { switch ({ x: 7 }) { default: return 5; } };
        \\globalThis.__zeroBalancedBranchy = function () { if ("a" < "b") return 1; return 2; };
        \\const zeroRecv = {
        \\    drop: function () { ({ z: 2 }); },
        \\    strictDrop: function () { "use strict"; ({ z: 3 }); },
        \\};
        \\const zeroArrowDrop = () => { ({ z: 4 }); };
        \\function exerciseZeroArgLeftovers() {
        \\    for (let i = 0; i < 256; i++) {
        \\        if (__zeroTrailingDrop() !== undefined) throw new Error("drop result");
        \\        if (__zeroSwitchLeftover() !== 5) throw new Error("switch result");
        \\        if (zeroRecv.drop() !== undefined) throw new Error("method drop result");
        \\        if (zeroRecv.strictDrop() !== undefined) throw new Error("strict drop result");
        \\        if (zeroArrowDrop() !== undefined) throw new Error("arrow drop result");
        \\        if (__zeroBalancedBranchy() !== 1) throw new Error("branchy result");
        \\    }
        \\}
        \\exerciseZeroArgLeftovers();
    );

    // Publication pins: unbalanced bodies are refused BOTH zero-arg leaf
    // bits; the branchy-but-balanced body keeps its publication (the
    // BFS proof carries exact per-pc levels — it is not a conservative
    // straight-line scan that would refuse every branch).
    const drop_name = try rt.internAtom("__zeroTrailingDrop");
    const switch_name = try rt.internAtom("__zeroSwitchLeftover");
    const branchy_name = try rt.internAtom("__zeroBalancedBranchy");
    const drop_fn = try global.getProperty(drop_name);
    const switch_fn = try global.getProperty(switch_name);
    const branchy_fn = try global.getProperty(branchy_name);
    const resolved_drop = inline_calls.resolveInlineFunction(global, drop_fn) orelse
        return error.InvalidFunctionBytecode;
    try std.testing.expect(!resolved_drop.fb.simpleInlineEmptyLeaf());
    try std.testing.expect(!resolved_drop.fb.rawThisInlineEmptyLeaf());
    try std.testing.expect(!resolved_drop.fb.smallInlineEligible());
    const resolved_switch = inline_calls.resolveInlineFunction(global, switch_fn) orelse
        return error.InvalidFunctionBytecode;
    try std.testing.expect(!resolved_switch.fb.simpleInlineEmptyLeaf());
    try std.testing.expect(!resolved_switch.fb.rawThisInlineEmptyLeaf());
    try std.testing.expect(!resolved_switch.fb.smallInlineEligible());
    const resolved_branchy = inline_calls.resolveInlineFunction(global, branchy_fn) orelse
        return error.InvalidFunctionBytecode;
    try std.testing.expect(resolved_branchy.fb.simpleInlineEmptyLeaf());
    try std.testing.expect(resolved_branchy.fb.smallInlineEligible());

    _ = try rt.collectForTest();
    const baseline_objects = rt.gc.liveCount();

    _ = try js.eval("exerciseZeroArgLeftovers()");
    _ = try rt.collectForTest();

    try std.testing.expectEqual(baseline_objects, rt.gc.liveCount());
}

test "capture leaf abrupt teardown releases operands and keeps borrowed cells" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Each callee is a published capture leaf (zero args, no locals, only an
    // inherited capture cell) that throws mid-body with a live refcounted
    // operand already on its stack. Abrupt completion must route through
    // general teardown: the pending operand is released exactly once and the
    // BORROWED capture cells are never closed or double-released (the cells
    // belong to the still-live closure; a teardown release would corrupt
    // their rc and break the second eval round). Covers the ordinary sloppy
    // function and arrow frame policy plus the method receiver entry arm.
    _ = try js.eval(
        \\const capThrowState = (function () {
        \\    const held = { x: 1 };
        \\    return {
        \\        plain: function () { return held.x + null.missing; },
        \\        arrow: () => held.x + null.missing,
        \\    };
        \\})();
        \\const capRecv = {
        \\    m: (function () { const held = { x: 2 }; return function () { return held.x + null.missing; }; })(),
        \\};
        \\function exerciseCaptureLeafThrow() {
        \\    for (let i = 0; i < 256; i++) {
        \\        try { capThrowState.plain(); } catch (error) {}
        \\        try { capThrowState.arrow(); } catch (error) {}
        \\        try { capRecv.m(); } catch (error) {}
        \\    }
        \\}
        \\exerciseCaptureLeafThrow();
    );
    _ = try js.runtime.collectForTest();
    const baseline_objects = js.runtime.gc.liveCount();

    _ = try js.eval("exerciseCaptureLeafThrow()");
    _ = try js.runtime.collectForTest();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "capture leaf returns with leftover operands route through general teardown" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Zero-arg twin of the exact-args leftover coverage, reachable in the
    // capture family precisely because its bodies read free names: a
    // refcounted switch discriminant left on the operand stack at `return`,
    // and a parser-elided trailing expression-statement drop. The capture
    // leaf publishes the exact_args_leaf teardown bit, so its return arm
    // carries the operand-window guard and both shapes must fall back to
    // general teardown (the narrow epilogue would strand the leftovers and
    // Debug-assert).
    _ = try js.eval(
        \\const capSwitchLeftover = (function () {
        \\    const held = { x: 7 };
        \\    return function () { switch (held) { case held: return held.x; } };
        \\})();
        \\const capTrailingDrop = (function () {
        \\    const held = { y: 1 };
        \\    return function () { ({ z: held.y }); };
        \\})();
        \\function exerciseCaptureLeafLeftovers() {
        \\    for (let i = 0; i < 256; i++) {
        \\        capSwitchLeftover();
        \\        capTrailingDrop();
        \\    }
        \\}
        \\exerciseCaptureLeafLeftovers();
    );
    _ = try js.runtime.collectForTest();
    const baseline_objects = js.runtime.gc.liveCount();

    _ = try js.eval("exerciseCaptureLeafLeftovers()");
    _ = try js.runtime.collectForTest();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "capture leaf shares live cells with its closure across calls" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // The capture-leaf frame BORROWS the closure's cell array — the same
    // cells every other reference sees. Mutations through the leaf must be
    // visible to siblings and persist across calls (a snapshot or copied
    // window would reset the counter), and the lexical-this arrow must read
    // and write its `this` cell (the pivot shape) through the borrowed
    // array. `<repl>` filename keeps the script completion value.
    const result = try js.evalWithOptions(
        \\const counterPair = (function () {
        \\    let n = 0;
        \\    return { bump: () => ++n, read: function () { return n; } };
        \\})();
        \\counterPair.bump();
        \\counterPair.bump();
        \\const owner = {
        \\    value: 40,
        \\    makeReader() { return () => this.value; },
        \\    makeBumper() { return () => ++this.value; },
        \\};
        \\const read = owner.makeReader();
        \\const bump = owner.makeBumper();
        \\bump();
        \\bump();
        \\counterPair.bump() * 1000000 + counterPair.read() * 10000 + read() * 100 + owner.value;
    , .{ .filename = "<repl>" });
    // bump()=3, read()=3, arrow read()=42, owner.value=42.
    try std.testing.expectEqual(@as(?i32, 3034242), result.as(.int));
}

test "inline empty leaf warm constructor preserves miss fallback and ownership" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    const rt = js.runtime;
    const ctx = js.context;
    const global = try engine.exec.zjs_vm.contextGlobal(ctx);

    _ = try js.eval("globalThis.__warmEmptyLeaf = function () { return 1; };");
    const leaf_name = try rt.internAtom("__warmEmptyLeaf");
    const callable = try global.getProperty(leaf_name);
    const resolved = inline_calls.resolveInlineFunction(global, callable) orelse
        return error.InvalidFunctionBytecode;
    try std.testing.expect(resolved.fb.simpleInlineEmptyLeaf());

    const l0_execution_function = try bytecode.FunctionBytecode.createFixture(rt, .{ .byte_code = &.{op.return_undef} });
    defer l0_execution_function.destroyUnpublishedFixture(rt);
    var l0_frame = engine.exec.frame.Frame.init(l0_execution_function);
    defer l0_frame.deinit(rt.nativeAllocator(), rt);
    var l0_stack = engine.exec.stack.Stack.init(rt, rt.stackSize());
    defer l0_stack.deinit(rt);
    var catch_target: ?usize = null;
    var l0 = inline_calls.L0State{ .level = .{
        .frame = &l0_frame,
        .stack = &l0_stack,
        .catch_target = &catch_target,
    } };
    var machine = inline_calls.Machine.init(ctx, null, global, &l0);
    defer machine.deinit();
    const initial_call_depth = ctx.runtime.stack.call_depth;

    // A fresh Machine has neither Entry nor arena backing. The speculative
    // arm must miss without consuming the source or changing call depth.
    try l0_stack.pushOwned(callable);
    var region_start = l0_stack.topPtr() - 1;
    l0_stack.setTopPtr(region_start);
    const l0_resume_pc = l0_frame.function.byteCode().ptr + l0_frame.pc;
    try std.testing.expect(machine.tryPushEmptyLeafCallFast(.sloppy_global, ctx.runtime, global, &l0_stack, resolved.fb, resolved.call_facts, region_start, l0_resume_pc) == null);
    try std.testing.expectEqual(initial_call_depth, ctx.runtime.stack.call_depth);
    try std.testing.expect(!region_start[0].is(.undefined_value));

    const first = try machine.pushEmptyLeafCall(.sloppy_global, global, &l0_stack, resolved.fb, resolved.call_facts, region_start);
    try std.testing.expect(first.isEmptyLeaf());
    machine.popReturnedEmptyLeaf(ctx.runtime);
    try std.testing.expectEqual(initial_call_depth, ctx.runtime.stack.call_depth);
    const steady_bytes = rt.allocation_diagnostics.allocated_bytes;

    // Entry and arena chunks are now warm. A second exact call must publish
    // the same leaf shape without touching the allocator.
    try l0_stack.pushOwned(callable);
    region_start = l0_stack.topPtr() - 1;
    l0_stack.setTopPtr(region_start);
    const alloc_calls = rt.allocation_diagnostics.alloc_calls;
    const create_calls = rt.allocation_diagnostics.create_calls;
    const warm = machine.tryPushEmptyLeafCallFast(.sloppy_global, ctx.runtime, global, &l0_stack, resolved.fb, resolved.call_facts, region_start, l0_resume_pc) orelse
        return error.Unexpected;
    try std.testing.expect(warm.isEmptyLeaf());
    try std.testing.expectEqual(alloc_calls, rt.allocation_diagnostics.alloc_calls);
    try std.testing.expectEqual(create_calls, rt.allocation_diagnostics.create_calls);
    machine.popReturnedEmptyLeaf(ctx.runtime);
    try std.testing.expectEqual(steady_bytes, rt.allocation_diagnostics.allocated_bytes);

    // An oversized operand window cannot use the active arena chunk. The fast
    // miss is pure and the authoritative constructor owns/frees heap backing.
    const oversized = try createOversizedLeafFixture(rt, resolved.fb);
    var oversized_alive = true;
    defer if (oversized_alive) oversized.destroyUnpublishedFixture(rt);
    const oversized_bytes = rt.allocation_diagnostics.allocated_bytes;
    try l0_stack.pushOwned(callable);
    region_start = l0_stack.topPtr() - 1;
    l0_stack.setTopPtr(region_start);
    try std.testing.expect(machine.tryPushEmptyLeafCallFast(.sloppy_global, ctx.runtime, global, &l0_stack, oversized, oversized.callFacts(), region_start, l0_resume_pc) == null);
    try std.testing.expectEqual(initial_call_depth, ctx.runtime.stack.call_depth);
    const heap_entry = try machine.pushEmptyLeafCall(.sloppy_global, global, &l0_stack, oversized, oversized.callFacts(), region_start);
    try std.testing.expect(!heap_entry.isEmptyLeaf());
    var continuation = machine.popReturnedFrame();
    continuation.deinit();
    try std.testing.expectEqual(oversized_bytes, rt.allocation_diagnostics.allocated_bytes);

    // The same miss under a hard memory cap must restore depth/watermark and
    // release the source slot, leaving the warmed Machine reusable.
    try l0_stack.pushOwned(callable);
    region_start = l0_stack.topPtr() - 1;
    l0_stack.setTopPtr(region_start);
    // Injecting an allocation failure, not testing the collector: see
    // `suppressLimitCollectionForTest`.
    rt.suppressLimitCollectionForTest(true);
    defer rt.suppressLimitCollectionForTest(false);
    rt.setNativeBytesLimitForTest(rt.allocation_diagnostics.allocated_bytes);
    const failed = machine.pushEmptyLeafCall(.sloppy_global, global, &l0_stack, oversized, oversized.callFacts(), region_start);
    rt.setNativeBytesLimitForTest(null);
    try std.testing.expectError(error.OutOfMemory, failed);
    try std.testing.expectEqual(initial_call_depth, ctx.runtime.stack.call_depth);
    try std.testing.expect(region_start[0].is(.undefined_value));
    try std.testing.expectEqual(oversized_bytes, rt.allocation_diagnostics.allocated_bytes);
    oversized.destroyUnpublishedFixture(rt);
    oversized_alive = false;
    try std.testing.expectEqual(steady_bytes, rt.allocation_diagnostics.allocated_bytes);
}

test "forwarded leaf call semantics keep exclusions on the authoritative path" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // The O3 arm accepts only argc<=1 undefined-thisArg calls of published
    // sloppy zero-arg leaves, including sloppy arrows. Strict targets, a
    // null/object thisArg, and extra arguments keep the authoritative
    // forwarding semantics.
    // 256 rounds cross the cold->warm seam (first call misses into the
    // generic path, later calls ride the warm constructor).
    const result = try js.evalWithOptions(
        \\function fwdOne() { return 1; }
        \\function fwdStrict() { "use strict"; return this === undefined ? 10 : 0; }
        \\const fwdArrow = () => 100;
        \\function fwdSloppyThis() { return this === globalThis ? 1000 : 0; }
        \\let total = 0;
        \\for (let i = 0; i < 256; i++) {
        \\    total += fwdOne.call();
        \\    total += fwdOne.call(undefined);
        \\    total += fwdOne.call(null);
        \\    total += fwdOne.call(undefined, 9);
        \\    total += fwdStrict.call(undefined);
        \\    total += fwdArrow.call(undefined);
        \\    total += fwdSloppyThis.call(undefined);
        \\}
        \\total;
    , .{ .filename = "<repl>" });
    try std.testing.expectEqual(@as(?i32, 256 * (1 + 1 + 1 + 1 + 10 + 100 + 1000)), result.as(.int));
}

test "forwarded leaf abrupt completion balances and keeps the native frame" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // A throwing published leaf entered through Function.prototype.call:
    // abrupt completion must release the callee operands and the owned
    // native `call` frame exactly once (liveCount balance over two rounds),
    // and a backtrace captured while the forwarded frame is live must keep
    // the qjs order target -> call (native) -> caller on BOTH the cold and
    // warm entries.
    _ = try js.eval(
        \\function fwdThrower() { return (void 0).missing; }
        \\function exerciseForwardedThrow() {
        \\    for (let i = 0; i < 256; i++) {
        \\        let hit = false;
        \\        try {
        \\            fwdThrower.call(undefined);
        \\        } catch (error) {
        \\            hit = true;
        \\            const stack = String(error.stack);
        \\            const first = stack.indexOf("\n");
        \\            if (stack.indexOf("    at fwdThrower") !== 0)
        \\                throw new Error("target frame missing at round " + i);
        \\            if (stack.slice(first + 1).indexOf("    at call (native)") !== 0)
        \\                throw new Error("native frame missing at round " + i);
        \\        }
        \\        if (!hit) throw new Error("forwarded thrower did not throw");
        \\    }
        \\}
        \\exerciseForwardedThrow();
    );
    _ = try js.runtime.collectForTest();
    const baseline_objects = js.runtime.gc.liveCount();

    _ = try js.eval("exerciseForwardedThrow()");
    _ = try js.runtime.collectForTest();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "forwarded leaf returns with leftover operands route through general teardown" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Zero-arg leaf bodies that leave operands at `return` (parser-elided
    // trailing expression-statement drop; a refcounted switch discriminant
    // held across `return`) entered through Function.prototype.call: the
    // forwarded return arm carries an operand-window guard, so these must
    // fall back to general teardown, which releases the leftovers AND the
    // owned native frame exactly once. Only forwarded entries are exercised
    // — the shapes are never called directly here.
    _ = try js.eval(
        \\function fwdTrailingDrop() { ({ z: 1 }); }
        \\function fwdSwitchLeftover() { switch ({ x: 7 }) { default: return 5; } }
        \\function exerciseForwardedLeftovers() {
        \\    for (let i = 0; i < 256; i++) {
        \\        fwdTrailingDrop.call(undefined);
        \\        if (fwdSwitchLeftover.call(undefined) !== 5)
        \\            throw new Error("switch leftover result mismatch");
        \\    }
        \\}
        \\exerciseForwardedLeftovers();
    );
    _ = try js.runtime.collectForTest();
    const baseline_objects = js.runtime.gc.liveCount();

    _ = try js.eval("exerciseForwardedLeftovers()");
    _ = try js.runtime.collectForTest();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "method call empty leaf binds receiver as this and balances refcounts" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\Object.defineProperty(String.prototype, "__leafThis", {
        \\    value: function () { return this; },
        \\    configurable: true,
        \\});
        \\function exerciseMethodEmptyLeaf() {
        \\    const stable = { m() { return 1; }, self() { return this; } };
        \\    let total = 0;
        \\    for (let i = 0; i < 256; i++) {
        \\        total += stable.m();
        \\        if (stable.self() !== stable) throw new Error("stable this mismatch");
        \\        const fresh = { self() { return this; } };
        \\        if (fresh.self() !== fresh) throw new Error("fresh this mismatch");
        \\        const boxed = "abc".__leafThis();
        \\        if (typeof boxed !== "object" || String(boxed) !== "abc")
        \\            throw new Error("primitive receiver coercion mismatch");
        \\    }
        \\    assert.sameValue(total, 256);
        \\}
        \\exerciseMethodEmptyLeaf();
    );
    _ = try js.runtime.collectForTest();
    const baseline_objects = js.runtime.gc.liveCount();

    _ = try js.eval("exerciseMethodEmptyLeaf()");
    _ = try js.runtime.collectForTest();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "method call empty leaf abrupt teardown releases receiver" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    _ = try js.eval(
        \\function exerciseMethodEmptyLeafThrow() {
        \\    for (let i = 0; i < 256; i++) {
        \\        const recv = { boom() { return null.missing; } };
        \\        try { recv.boom(); } catch (error) {}
        \\    }
        \\}
        \\exerciseMethodEmptyLeafThrow();
    );
    _ = try js.runtime.collectForTest();
    const baseline_objects = js.runtime.gc.liveCount();

    _ = try js.eval("exerciseMethodEmptyLeafThrow()");
    _ = try js.runtime.collectForTest();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "method empty leaf warm constructor moves receiver ownership" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    const rt = js.runtime;
    const ctx = js.context;
    const global = try engine.exec.zjs_vm.contextGlobal(ctx);

    _ = try js.eval("globalThis.__warmMethodLeafRecv = { m() { return 1; } };");
    const holder_name = try rt.internAtom("__warmMethodLeafRecv");
    const receiver = try global.getProperty(holder_name);
    const receiver_object = object_ops.objectFromValue(receiver) orelse
        return error.Unexpected;
    const method_name = try rt.internAtom("m");
    const callable = try receiver_object.getProperty(method_name);
    const resolved = inline_calls.resolveInlineFunction(global, callable) orelse
        return error.InvalidFunctionBytecode;
    try std.testing.expect(resolved.fb.simpleInlineEmptyLeaf());

    const l0_execution_function = try bytecode.FunctionBytecode.createFixture(rt, .{ .byte_code = &.{op.return_undef} });
    defer l0_execution_function.destroyUnpublishedFixture(rt);
    var l0_frame = engine.exec.frame.Frame.init(l0_execution_function);
    defer l0_frame.deinit(rt.nativeAllocator(), rt);
    var l0_stack = engine.exec.stack.Stack.init(rt, rt.stackSize());
    defer l0_stack.deinit(rt);
    var catch_target: ?usize = null;
    var l0 = inline_calls.L0State{ .level = .{
        .frame = &l0_frame,
        .stack = &l0_stack,
        .catch_target = &catch_target,
    } };
    var machine = inline_calls.Machine.init(ctx, null, global, &l0);
    defer machine.deinit();
    const initial_call_depth = ctx.runtime.stack.call_depth;

    // Fresh Machine: the speculative arm must miss without consuming either
    // slot of the [receiver, callable] region or changing call depth.
    try l0_stack.pushOwned(receiver);
    try l0_stack.pushOwned(callable);
    var region_start = l0_stack.topPtr() - 2;
    l0_stack.setTopPtr(region_start);
    const l0_resume_pc = l0_frame.function.byteCode().ptr + l0_frame.pc;
    try std.testing.expect(machine.tryPushEmptyLeafCallFast(.receiver, ctx.runtime, global, &l0_stack, resolved.fb, resolved.call_facts, region_start, l0_resume_pc) == null);
    try std.testing.expectEqual(initial_call_depth, ctx.runtime.stack.call_depth);
    try std.testing.expect(!region_start[0].is(.undefined_value));
    try std.testing.expect(!region_start[1].is(.undefined_value));

    // Authoritative constructor: receiver moves into the frame's raw `this`
    // and the retired operand slot is cleared.
    const first = try machine.pushEmptyLeafCall(.receiver, global, &l0_stack, resolved.fb, resolved.call_facts, region_start);
    try std.testing.expect(first.isEmptyLeaf());
    try std.testing.expect(first.frame.this_value.same(receiver));
    try std.testing.expect(region_start[0].is(.undefined_value));
    machine.popReturnedEmptyLeaf(ctx.runtime);
    try std.testing.expectEqual(initial_call_depth, ctx.runtime.stack.call_depth);
    const steady_bytes = rt.allocation_diagnostics.allocated_bytes;

    // Warm hit: same leaf shape and allocation-free movement.
    try l0_stack.pushOwned(receiver);
    try l0_stack.pushOwned(callable);
    region_start = l0_stack.topPtr() - 2;
    l0_stack.setTopPtr(region_start);
    const alloc_calls = rt.allocation_diagnostics.alloc_calls;
    const create_calls = rt.allocation_diagnostics.create_calls;
    const warm = machine.tryPushEmptyLeafCallFast(.receiver, ctx.runtime, global, &l0_stack, resolved.fb, resolved.call_facts, region_start, l0_resume_pc) orelse
        return error.Unexpected;
    try std.testing.expect(warm.isEmptyLeaf());
    try std.testing.expect(warm.frame.this_value.same(receiver));
    try std.testing.expectEqual(alloc_calls, rt.allocation_diagnostics.alloc_calls);
    try std.testing.expectEqual(create_calls, rt.allocation_diagnostics.create_calls);
    machine.popReturnedEmptyLeaf(ctx.runtime);
    try std.testing.expectEqual(steady_bytes, rt.allocation_diagnostics.allocated_bytes);

    // Setup failure must restore depth/watermark and release BOTH region
    // slots — receiver and callable — leaving the warmed Machine reusable.
    const oversized = try createOversizedLeafFixture(rt, resolved.fb);
    var oversized_alive = true;
    defer if (oversized_alive) oversized.destroyUnpublishedFixture(rt);
    const oversized_bytes = rt.allocation_diagnostics.allocated_bytes;
    try l0_stack.pushOwned(receiver);
    try l0_stack.pushOwned(callable);
    region_start = l0_stack.topPtr() - 2;
    l0_stack.setTopPtr(region_start);
    // Injecting the failure, not testing the collector: see
    // `suppressLimitCollectionForTest`.
    rt.suppressLimitCollectionForTest(true);
    rt.setNativeBytesLimitForTest(rt.allocation_diagnostics.allocated_bytes);
    const failed = machine.pushEmptyLeafCall(.receiver, global, &l0_stack, oversized, oversized.callFacts(), region_start);
    rt.setNativeBytesLimitForTest(null);
    rt.suppressLimitCollectionForTest(false);
    try std.testing.expectError(error.OutOfMemory, failed);
    try std.testing.expectEqual(initial_call_depth, ctx.runtime.stack.call_depth);
    try std.testing.expect(region_start[0].is(.undefined_value));
    try std.testing.expect(region_start[1].is(.undefined_value));
    try std.testing.expectEqual(oversized_bytes, rt.allocation_diagnostics.allocated_bytes);
    oversized.destroyUnpublishedFixture(rt);
    oversized_alive = false;
    try std.testing.expectEqual(steady_bytes, rt.allocation_diagnostics.allocated_bytes);
}

test "strict empty leaf preserves undefined this across call forms" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Three plain-call forms of the strict leaf: a directly strict function,
    // a nested function inheriting strictness from its enclosing 'use strict'
    // body, and a strict method detached and called as a plain function. All
    // must observe `this === undefined` (no sloppy global substitution).
    _ = try js.eval(
        \\function strictLeafThis() {
        \\    "use strict";
        \\    return this;
        \\}
        \\function strictOuterFactory() {
        \\    "use strict";
        \\    function nestedStrictLeaf() { return this; }
        \\    return nestedStrictLeaf;
        \\}
        \\const nestedLeaf = strictOuterFactory();
        \\const holder = { m: function () { "use strict"; return this; } };
        \\const detachedLeaf = holder.m;
        \\function exerciseStrictLeafThis() {
        \\    for (let i = 0; i < 256; i++) {
        \\        if (strictLeafThis() !== undefined)
        \\            throw new Error("strict leaf this must be undefined");
        \\        if (nestedLeaf() !== undefined)
        \\            throw new Error("nested strict leaf this must be undefined");
        \\        if (detachedLeaf() !== undefined)
        \\            throw new Error("detached strict leaf this must be undefined");
        \\    }
        \\}
        \\exerciseStrictLeafThis();
    );
    _ = try js.runtime.collectForTest();
    const baseline_objects = js.runtime.gc.liveCount();

    _ = try js.eval("exerciseStrictLeafThis()");
    _ = try js.runtime.collectForTest();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "strict method empty leaf passes primitive receiver uncoerced" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\Object.defineProperty(String.prototype, "__strictLeafThis", {
        \\    value: function () { "use strict"; return this; },
        \\    configurable: true,
        \\});
        \\Object.defineProperty(Number.prototype, "__strictLeafThis", {
        \\    value: function () { "use strict"; return this; },
        \\    configurable: true,
        \\});
        \\function exerciseStrictMethodLeaf() {
        \\    const stable = { m() { "use strict"; return this; } };
        \\    for (let i = 0; i < 256; i++) {
        \\        if (stable.m() !== stable)
        \\            throw new Error("strict method object this mismatch");
        \\        const prim = "abc".__strictLeafThis();
        \\        if (typeof prim !== "string" || prim !== "abc")
        \\            throw new Error("strict primitive receiver must not box");
        \\        const num = (5).__strictLeafThis();
        \\        if (typeof num !== "number" || num !== 5)
        \\            throw new Error("strict number receiver must not box");
        \\    }
        \\}
        \\exerciseStrictMethodLeaf();
    );
    _ = try js.runtime.collectForTest();
    const baseline_objects = js.runtime.gc.liveCount();

    _ = try js.eval("exerciseStrictMethodLeaf()");
    _ = try js.runtime.collectForTest();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "strict empty leaf frame preserves undefined this and borrowed ownership" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    const rt = js.runtime;
    const ctx = js.context;
    const global = try engine.exec.zjs_vm.contextGlobal(ctx);

    _ = try js.eval("globalThis.__strictWarmLeaf = function () { \"use strict\"; return 1; };");
    const leaf_name = try rt.internAtom("__strictWarmLeaf");
    const callable = try global.getProperty(leaf_name);
    const resolved = inline_calls.resolveInlineFunction(global, callable) orelse
        return error.InvalidFunctionBytecode;
    // The raw-this leaf publishes its own eligibility byte (the packed sloppy
    // bit stays clear); the call adapter selects the undefined-`this` arm.
    try std.testing.expect(!resolved.fb.simpleInlineEmptyLeaf());
    try std.testing.expect(resolved.fb.rawThisInlineEmptyLeaf());
    try std.testing.expect(resolved.fb.isStrictMode());

    const l0_execution_function = try bytecode.FunctionBytecode.createFixture(rt, .{ .byte_code = &.{op.return_undef} });
    defer l0_execution_function.destroyUnpublishedFixture(rt);
    var l0_frame = engine.exec.frame.Frame.init(l0_execution_function);
    defer l0_frame.deinit(rt.nativeAllocator(), rt);
    var l0_stack = engine.exec.stack.Stack.init(rt, rt.stackSize());
    defer l0_stack.deinit(rt);
    var catch_target: ?usize = null;
    var l0 = inline_calls.L0State{ .level = .{
        .frame = &l0_frame,
        .stack = &l0_stack,
        .catch_target = &catch_target,
    } };
    var machine = inline_calls.Machine.init(ctx, null, global, &l0);
    defer machine.deinit();
    const initial_call_depth = ctx.runtime.stack.call_depth;

    // Authoritative constructor: `this` stays undefined, matching
    // setupSimpleInlineEntryImpl's strict plain arm.
    try l0_stack.pushOwned(callable);
    var region_start = l0_stack.topPtr() - 1;
    l0_stack.setTopPtr(region_start);
    const first = try machine.pushEmptyLeafCall(.raw_undefined, global, &l0_stack, resolved.fb, resolved.call_facts, region_start);
    try std.testing.expect(first.isEmptyLeaf());
    try std.testing.expect(first.frame.this_value.is(.undefined_value));
    machine.popReturnedEmptyLeaf(ctx.runtime);
    try std.testing.expectEqual(initial_call_depth, ctx.runtime.stack.call_depth);
    const steady_bytes = rt.allocation_diagnostics.allocated_bytes;

    // Warm arm publishes the same strict shape allocation-free.
    try l0_stack.pushOwned(callable);
    region_start = l0_stack.topPtr() - 1;
    l0_stack.setTopPtr(region_start);
    const l0_resume_pc = l0_frame.function.byteCode().ptr + l0_frame.pc;
    const alloc_calls = rt.allocation_diagnostics.alloc_calls;
    const create_calls = rt.allocation_diagnostics.create_calls;
    const warm = machine.tryPushEmptyLeafCallFast(.raw_undefined, ctx.runtime, global, &l0_stack, resolved.fb, resolved.call_facts, region_start, l0_resume_pc) orelse
        return error.Unexpected;
    try std.testing.expect(warm.isEmptyLeaf());
    try std.testing.expect(warm.frame.this_value.is(.undefined_value));
    try std.testing.expectEqual(alloc_calls, rt.allocation_diagnostics.alloc_calls);
    try std.testing.expectEqual(create_calls, rt.allocation_diagnostics.create_calls);
    machine.popReturnedEmptyLeaf(ctx.runtime);
    try std.testing.expectEqual(initial_call_depth, ctx.runtime.stack.call_depth);
    try std.testing.expectEqual(steady_bytes, rt.allocation_diagnostics.allocated_bytes);
}

test "inline call teardown releases every escaped storage shape" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try engine.exec.zjs_vm.contextGlobal(ctx);

    const l0_execution_function = try bytecode.FunctionBytecode.createFixture(rt, .{ .byte_code = &.{op.return_undef} });
    defer l0_execution_function.destroyUnpublishedFixture(rt);
    var l0_frame = engine.exec.frame.Frame.init(l0_execution_function);
    defer l0_frame.deinit(rt.nativeAllocator(), rt);
    var l0_stack = engine.exec.stack.Stack.init(rt, rt.stackSize());
    defer l0_stack.deinit(rt);
    var catch_target: ?usize = null;
    var l0 = inline_calls.L0State{ .level = .{
        .frame = &l0_frame,
        .stack = &l0_stack,
        .catch_target = &catch_target,
    } };
    var machine = inline_calls.Machine.init(ctx, null, global, &l0);
    defer machine.deinit();

    const execution_function = try bytecode.FunctionBytecode.createFixture(rt, .{ .byte_code = &.{op.return_undef} });
    defer execution_function.destroyUnpublishedFixture(rt);
    execution_function.setExecutionFlags(.{ .simple_inline_eligible = true });
    var unused_var_refs: [1]*core.VarRef = undefined;
    const target = inline_calls.InlineTarget{
        .var_refs = &unused_var_refs,
        .callable = core.JSValue.undefinedValue(),
        .fb = execution_function,
        .call_facts = execution_function.callFacts(),
        .this_value = core.JSValue.undefinedValue(),
    };

    // Warm the Machine's Entry chunk and the VM stack-arena chunk; neither is
    // per-call storage, so take the balance baseline only after this call.
    try l0_stack.pushOwned(core.JSValue.undefinedValue());
    l0_stack.setLen(0);
    _ = try machine.pushCall(global, &l0_stack, &target, l0_stack.topPtr(), 0, .plain);
    var continuation = machine.popFrame();
    continuation.deinit();
    const baseline_bytes = rt.allocation_diagnostics.allocated_bytes;

    try l0_stack.pushOwned(core.JSValue.undefinedValue());
    l0_stack.setLen(0);
    var entry = try machine.pushCall(global, &l0_stack, &target, l0_stack.topPtr(), 0, .plain);
    _ = try entry.frame.ensureCold(rt.nativeAllocator());
    continuation = machine.popFrame();
    continuation.deinit();
    try std.testing.expectEqual(baseline_bytes, rt.allocation_diagnostics.allocated_bytes);

    try l0_stack.pushOwned(core.JSValue.undefinedValue());
    l0_stack.setLen(0);
    entry = try machine.pushCall(global, &l0_stack, &target, l0_stack.topPtr(), 0, .plain);
    _ = try entry.frame.allocOwnedStorage(rt.nativeAllocator(), 1);
    continuation = machine.popFrame();
    continuation.deinit();
    try std.testing.expectEqual(baseline_bytes, rt.allocation_diagnostics.allocated_bytes);

    try l0_stack.pushOwned(core.JSValue.undefinedValue());
    l0_stack.setLen(0);
    entry = try machine.pushCall(global, &l0_stack, &target, l0_stack.topPtr(), 0, .plain);
    try entry.stack.reserveAdditional(entry.stack.capacity + 1);
    continuation = machine.popFrame();
    continuation.deinit();
    try std.testing.expectEqual(baseline_bytes, rt.allocation_diagnostics.allocated_bytes);

    // A window larger than one arena chunk uses the setup-time heap fallback.
    execution_function.stack_size = core.VmStackArena.chunk_slots;
    try l0_stack.pushOwned(core.JSValue.undefinedValue());
    l0_stack.setLen(0);
    _ = try machine.pushCall(global, &l0_stack, &target, l0_stack.topPtr(), 0, .plain);
    continuation = machine.popFrame();
    continuation.deinit();
    try std.testing.expectEqual(baseline_bytes, rt.allocation_diagnostics.allocated_bytes);
}

test "VM stack storage borrowed windows survive growth and teardown" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const rt = js.runtime;
    const Stack = engine.exec.stack.Stack;

    // An interior slice models the operand window of a Frame-owned heap slab.
    // Its owner frees the complete allocation after Stack teardown.
    const slab = try std.testing.allocator.alloc(core.JSValue, 4);
    defer std.testing.allocator.free(slab);
    for ([_]bool{ false, true }) |resident| {
        var stack = Stack.initFrameWindow(rt, rt.stack.frame_storage, slab[1..3]);
        if (resident) stack.setBackingOwnership(.resident_window);
        defer stack.deinit(rt);
        try stack.push(core.JSValue.int32(17));
        const original = stack.values;
        try stack.reserveAdditional(2);
        try std.testing.expect(stack.values != original);
        try std.testing.expect(stack.storage.ownership == .owned);
        try std.testing.expectEqual(@as(i32, 17), stack.liveValues()[0].as(.int).?);
        // Growth must not invalidate or clear the borrowed window.
        try std.testing.expectEqual(@as(i32, 17), slab[1].as(.int).?);
    }
    for ([_]bool{ false, true }) |resident| {
        var stack = Stack.initFrameWindow(rt, rt.stack.frame_storage, slab[1..3]);
        if (resident) stack.setBackingOwnership(.resident_window);
        try stack.push(core.JSValue.int32(23));
        stack.deinit(rt);
        try std.testing.expect(slab[1].is(.undefined_value));
        try std.testing.expectEqual(@as(usize, 0), stack.capacity);
    }
}

test "VM stack storage arena restores nested windows and preserves limits" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const rt = js.runtime;
    const Stack = engine.exec.stack.Stack;
    rt.setStackSize(2);
    const initial = rt.vm_stack.mark();
    defer rt.vm_stack.restore(initial);
    const window = rt.vm_stack.carve(rt, 2).?;
    var stack = Stack.initFrameWindow(rt, rt.stack.frame_storage, window);
    defer stack.deinit(rt);
    try stack.push(core.JSValue.int32(7));
    try stack.push(core.JSValue.int32(9));
    try std.testing.expectError(error.StackOverflow, stack.push(core.JSValue.int32(11)));
    try std.testing.expect(stack.storage.ownership == .frame_window);
    try std.testing.expectEqual(@as(usize, 2), stack.stackLimit());

    const nested = rt.vm_stack.mark();
    const other = rt.vm_stack.carve(rt, core.VmStackArena.chunk_slots).?;
    try std.testing.expectEqual(@as(i32, 7), stack.liveValues()[0].as(.int).?);
    rt.vm_stack.restore(nested);
    const reused = rt.vm_stack.carve(rt, core.VmStackArena.chunk_slots).?;
    try std.testing.expectEqual(other.ptr, reused.ptr);
    rt.vm_stack.restore(nested);
    // Oversized requests fall back at the frame layer, without changing watermarks.
    try std.testing.expect(rt.vm_stack.carve(rt, core.VmStackArena.chunk_slots + 1) == null);
    try std.testing.expectEqualDeep(nested, rt.vm_stack.mark());
}

test "inline operand Stack keeps limit and ownership state in one word" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(engine.exec.stack.Stack));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(inline_calls.Machine.ArgsSource));
    // Frame and Entry are layout-sensitive (see the Entry pin in
    // inline_calls.zig and the layout note in docs/compiler-contract.md), so pin
    // both sizes here rather than leaving them to a benchmark to notice.
    try std.testing.expectEqual(@as(usize, 136), @sizeOf(engine.exec.frame.Frame));
    try std.testing.expectEqual(@as(usize, 240), @sizeOf(inline_calls.Entry));
}

test "ordinary root bytecode call carves one operand window" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);

    // Slightly more than half a chunk makes a duplicate stack-size carve
    // cross the chunk boundary deterministically. Frame metadata is empty, so
    // one operand window fits in one chunk while two require exactly two.
    const stack_size = core.VmStackArena.chunk_slots / 2 + 1;
    const code = [_]u8{op.return_undef};
    const callable = try createTailOpcodeFixture(
        &js,
        "__singleOperandWindow",
        &code,
        @intCast(stack_size),
    );

    try std.testing.expectEqual(@as(usize, 0), js.runtime.vm_stack.chunk_count);
    _ = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        callable,
        &.{},
        null,
        null,
    );

    try std.testing.expectEqual(@as(usize, 1), js.runtime.vm_stack.chunk_count);
    try std.testing.expectEqual(
        core.VmStackArena.Mark{ .chunk = 0, .used = 0 },
        js.runtime.vm_stack.mark(),
    );
}

test "method calls preserve receiver arguments eval captures and abrupt ownership" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\const receiver = { value: 4 };
        \\receiver.sloppy = function sloppy(first, second) {
        \\    assert.sameValue(this, receiver);
        \\    assert.sameValue(arguments.length, 1);
        \\    first = 7;
        \\    second = 8;
        \\    assert.sameValue(arguments[0], 7);
        \\    assert.sameValue(arguments.hasOwnProperty("1"), false);
        \\    return this;
        \\};
        \\assert.sameValue(receiver.sloppy(1), receiver);
        \\receiver.strict = function strict(first, second) {
        \\    "use strict";
        \\    assert.sameValue(this, receiver);
        \\    first = 7;
        \\    second = 8;
        \\    assert.sameValue(arguments.length, 1);
        \\    assert.sameValue(arguments[0], 1);
        \\    assert.sameValue(arguments.hasOwnProperty("1"), false);
        \\    return this;
        \\};
        \\assert.sameValue(receiver.strict(1), receiver);
        \\receiver.capture = function capture(value) {
        \\    return () => this;
        \\};
        \\assert.sameValue(receiver.capture()(), receiver);
        \\receiver.evalThis = function evalThis(value) {
        \\    return eval("this");
        \\};
        \\assert.sameValue(receiver.evalThis(), receiver);
        \\receiver.escape = function escape(first, second) { return arguments; };
        \\const escaped = receiver.escape(receiver);
        \\assert.sameValue(escaped.length, 1);
        \\assert.sameValue(escaped[0], receiver);
        \\assert.sameValue(escaped.hasOwnProperty("1"), false);
        \\receiver.thrower = function thrower(first, second) { throw this; };
        \\try {
        \\    receiver.thrower(receiver);
        \\} catch (thrown) {
        \\    assert.sameValue(thrown, receiver);
        \\}
        \\let getterReceiver;
        \\const accessor = {
        \\    get method() {
        \\        getterReceiver = this;
        \\        return function selected() { return this; };
        \\    }
        \\};
        \\assert.sameValue(accessor.method(), accessor);
        \\assert.sameValue(getterReceiver, accessor);
        \\const proxy = new Proxy(receiver, {});
        \\assert.sameValue(proxy.capture()(), proxy);
        \\String.prototype.strictReceiver = function strictReceiver() {
        \\    "use strict";
        \\    return this;
        \\};
        \\assert.sameValue("x".strictReceiver(), "x");
        \\delete String.prototype.strictReceiver;
        \\Number.prototype.sloppyReceiver = function sloppyReceiver() {
        \\    return Object.getPrototypeOf(this) === Number.prototype && this.valueOf();
        \\};
        \\assert.sameValue((4).sloppyReceiver(), 4);
        \\delete Number.prototype.sloppyReceiver;
        \\Number.prototype.arrowReceiver = function arrowReceiver() {
        \\    return () => this;
        \\};
        \\const readArrowReceiver = (5).arrowReceiver();
        \\const arrowBox = readArrowReceiver();
        \\assert.sameValue(Object.getPrototypeOf(arrowBox), Number.prototype);
        \\assert.sameValue(arrowBox.valueOf(), 5);
        \\assert.sameValue(readArrowReceiver(), arrowBox);
        \\delete Number.prototype.arrowReceiver;
        \\Number.prototype.evalReceiver = function evalReceiver() {
        \\    return eval("this");
        \\};
        \\const evalBox = (6).evalReceiver();
        \\assert.sameValue(Object.getPrototypeOf(evalBox), Number.prototype);
        \\assert.sameValue(evalBox.valueOf(), 6);
        \\delete Number.prototype.evalReceiver;
        \\function sloppyViaCall() { return this; }
        \\const callBox = sloppyViaCall.call(7);
        \\assert.sameValue(Object.getPrototypeOf(callBox), Number.prototype);
        \\assert.sameValue(callBox.valueOf(), 7);
        \\assert.sameValue(sloppyViaCall.call(null), globalThis);
        \\assert.sameValue(sloppyViaCall.call(undefined), globalThis);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "primitive prototype lookup preserves raw receiver and exotic prototype semantics" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\const dataKey = "__zjs_primitive_data_probe__";
        \\const inheritedKey = "__zjs_primitive_inherited_probe__";
        \\const strictGetterKey = "__zjs_primitive_strict_getter_probe__";
        \\const sloppyGetterKey = "__zjs_primitive_sloppy_getter_probe__";
        \\const proxyKey = "__zjs_primitive_proxy_probe__";
        \\const staticDataKey = "__zjs_primitive_static_data_probe__";
        \\const staticGetterKey = "__zjs_primitive_static_getter_probe__";
        \\const staticProxyKey = "__zjs_primitive_static_proxy_probe__";
        \\const originalNumberParent = Object.getPrototypeOf(Number.prototype);
        \\const intrinsicBigInt = BigInt;
        \\const intrinsicSymbol = Symbol;
        \\const bigintPrototype = BigInt.prototype;
        \\const symbolPrototype = Symbol.prototype;
        \\const symbolValue = Symbol("s");
        \\try {
        \\    Number.prototype[dataKey] = 11;
        \\    Boolean.prototype[dataKey] = 12;
        \\    String.prototype[dataKey] = 13;
        \\    bigintPrototype[dataKey] = 14;
        \\    symbolPrototype[dataKey] = 15;
        \\    Object.prototype[inheritedKey] = 16;
        \\    Number.prototype[staticDataKey] = 19;
        \\    assert.sameValue((1)[dataKey], 11);
        \\    assert.sameValue(true[dataKey], 12);
        \\    assert.sameValue("x"[dataKey], 13);
        \\    assert.sameValue((1n)[dataKey], 14);
        \\    assert.sameValue(symbolValue[dataKey], 15);
        \\    assert.sameValue((2)[inheritedKey], 16);
        \\    assert.sameValue("x"[inheritedKey], 16);
        \\    assert.sameValue((2).__zjs_primitive_static_data_probe__, 19);
        \\    globalThis.BigInt = function ReplacementBigInt() {};
        \\    globalThis.Symbol = function ReplacementSymbol() {};
        \\    assert.sameValue((1n)[dataKey], 14);
        \\    assert.sameValue(symbolValue[dataKey], 15);
        \\    Object.defineProperty(Number.prototype, strictGetterKey, {
        \\        configurable: true,
        \\        get: function primitiveStrictGetter() {
        \\            "use strict";
        \\            return this;
        \\        },
        \\    });
        \\    Object.defineProperty(Number.prototype, sloppyGetterKey, {
        \\        configurable: true,
        \\        get: function primitiveSloppyGetter() {
        \\            return Object.getPrototypeOf(this) === Number.prototype && this.valueOf();
        \\        },
        \\    });
        \\    Object.defineProperty(Number.prototype, staticGetterKey, {
        \\        configurable: true,
        \\        get: function primitiveStaticGetter() {
        \\            "use strict";
        \\            return this;
        \\        },
        \\    });
        \\    assert.sameValue((3)[strictGetterKey], 3);
        \\    assert.sameValue((4)[sloppyGetterKey], 4);
        \\    assert.sameValue((5).__zjs_primitive_static_getter_probe__, 5);
        \\    const parent = Object.create(originalNumberParent);
        \\    parent[inheritedKey] = 17;
        \\    Object.setPrototypeOf(Number.prototype, parent);
        \\    assert.sameValue((5)[inheritedKey], 17);
        \\    let seenReceiver;
        \\    let trapCount = 0;
        \\    const proxy = new Proxy(parent, {
        \\        get(target, key, receiver) {
        \\            trapCount++;
        \\            if (key === proxyKey || key === staticProxyKey) {
        \\                seenReceiver = receiver;
        \\                return 18;
        \\            }
        \\            return Reflect.get(target, key, receiver);
        \\        },
        \\    });
        \\    Object.setPrototypeOf(Number.prototype, proxy);
        \\    assert.sameValue((6)[proxyKey], 18);
        \\    assert.sameValue(seenReceiver, 6);
        \\    assert.sameValue(trapCount, 1);
        \\    assert.sameValue((6).__zjs_primitive_static_proxy_probe__, 18);
        \\    assert.sameValue(seenReceiver, 6);
        \\    assert.sameValue(trapCount, 2);
        \\    assert.sameValue((7).__zjs_primitive_missing_probe__, undefined);
        \\    String.prototype[0] = "prototype";
        \\    assert.sameValue("a"[0], "a");
        \\    assert.sameValue("a".length, 1);
        \\} finally {
        \\    globalThis.BigInt = intrinsicBigInt;
        \\    globalThis.Symbol = intrinsicSymbol;
        \\    Object.setPrototypeOf(Number.prototype, originalNumberParent);
        \\    delete Number.prototype[dataKey];
        \\    delete Boolean.prototype[dataKey];
        \\    delete String.prototype[dataKey];
        \\    delete bigintPrototype[dataKey];
        \\    delete symbolPrototype[dataKey];
        \\    delete Object.prototype[inheritedKey];
        \\    delete Number.prototype[strictGetterKey];
        \\    delete Number.prototype[sloppyGetterKey];
        \\    delete Number.prototype[staticDataKey];
        \\    delete Number.prototype[staticGetterKey];
        \\    delete String.prototype[0];
        \\}
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "computed named reads preserve prototype accessors proxies and operand ownership" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\const dataKey = "__zjs_computed_data_probe__";
        \\const getterKey = "__zjs_computed_getter_probe__";
        \\const emptyGetterKey = "__zjs_computed_empty_getter_probe__";
        \\const throwingGetterKey = "__zjs_computed_throwing_getter_probe__";
        \\const proxyKey = "__zjs_computed_proxy_probe__";
        \\const selfKey = "__zjs_computed_self_probe__";
        \\const prototype = {};
        \\prototype[dataKey] = 11;
        \\const object = Object.create(prototype);
        \\assert.sameValue(object[dataKey], 11);
        \\let getterReceiver;
        \\let getterCount = 0;
        \\Object.defineProperty(prototype, getterKey, {
        \\    configurable: true,
        \\    get() {
        \\        getterReceiver = this;
        \\        getterCount++;
        \\        return 12;
        \\    },
        \\});
        \\assert.sameValue(object[getterKey], 12);
        \\assert.sameValue(getterReceiver, object);
        \\assert.sameValue(getterCount, 1);
        \\Object.defineProperty(prototype, emptyGetterKey, {
        \\    configurable: true,
        \\    get: undefined,
        \\});
        \\assert.sameValue(object[emptyGetterKey], undefined);
        \\Object.defineProperty(prototype, throwingGetterKey, {
        \\    configurable: true,
        \\    get() { throw new Error("computed getter sentinel"); },
        \\});
        \\let caughtMessage;
        \\try {
        \\    object[throwingGetterKey];
        \\} catch (error) {
        \\    caughtMessage = error.message;
        \\}
        \\assert.sameValue(caughtMessage, "computed getter sentinel");
        \\let proxyReceiver;
        \\let proxyCount = 0;
        \\const proxy = new Proxy(prototype, {
        \\    get(target, key, receiver) {
        \\        proxyReceiver = receiver;
        \\        proxyCount++;
        \\        if (key === proxyKey) return 13;
        \\        return Reflect.get(target, key, receiver);
        \\    },
        \\});
        \\const proxyObject = Object.create(proxy);
        \\assert.sameValue(proxyObject[proxyKey], 13);
        \\assert.sameValue(proxyReceiver, proxyObject);
        \\assert.sameValue(proxyCount, 1);
        \\object[selfKey] = object;
        \\assert.sameValue(object[selfKey], object);
        \\object[dataKey] = dataKey;
        \\assert.sameValue(object[dataKey], dataKey);
        \\assert.sameValue(Object.create(null)[dataKey], undefined);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "computed integer write misses preserve generic set semantics" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\const own = { 0: 1 };
        \\own[0] = 2;
        \\assert.sameValue(own[0], 2);
        \\const negativeKey = -1;
        \\own[negativeKey] = 3;
        \\assert.sameValue(own["-1"], 3);
        \\let setterReceiver;
        \\let setterValue;
        \\const prototype = {};
        \\Object.defineProperty(prototype, "0", {
        \\    set(value) {
        \\        setterReceiver = this;
        \\        setterValue = value;
        \\    },
        \\});
        \\const inherited = Object.create(prototype);
        \\inherited[0] = 4;
        \\assert.sameValue(setterReceiver, inherited);
        \\assert.sameValue(setterValue, 4);
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(inherited, "0"), false);
        \\let trapReceiver;
        \\const target = { 0: 5 };
        \\const proxy = new Proxy(target, {
        \\    set(object, key, value, receiver) {
        \\        trapReceiver = receiver;
        \\        object[key] = value + 1;
        \\        return true;
        \\    },
        \\});
        \\proxy[0] = 6;
        \\assert.sameValue(target[0], 7);
        \\assert.sameValue(trapReceiver, proxy);
        \\function mapped(value) {
        \\    arguments[0] = 8;
        \\    return [value, arguments[0]];
        \\}
        \\const mappedResult = mapped(1);
        \\assert.sameValue(mappedResult[0], 8);
        \\assert.sameValue(mappedResult[1], 8);
        \\let coerced = 0;
        \\const typed = new Int32Array(1);
        \\typed[0] = { valueOf() { coerced++; return 9; } };
        \\assert.sameValue(typed[0], 9);
        \\assert.sameValue(coerced, 1);
        \\const frozen = {};
        \\Object.defineProperty(frozen, "0", { value: 10, writable: false });
        \\frozen[0] = 11;
        \\assert.sameValue(frozen[0], 10);
        \\function strictWrite() {
        \\    "use strict";
        \\    frozen[0] = 12;
        \\}
        \\let rejected = false;
        \\try {
        \\    strictWrite();
        \\} catch (error) {
        \\    rejected = error instanceof TypeError;
        \\}
        \\assert.sameValue(rejected, true);
        \\assert.sameValue(frozen[0], 10);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "dense write leaf consumes reserved appends only inside the qjs capacity window" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const array = try core.Object.createArray(rt, null);
    try array.fastArrayEnsureCapacity(rt, 2);

    const stored = try core.Object.create(rt, core.class.ids.object, null);
    _ = stored.value();
    try std.testing.expectEqual(
        array_ops.DenseArrayOverwriteFastResult.handled,
        array_ops.putDenseArrayElementOverwriteOwnedFast(
            rt,
            array.value(),
            core.JSValue.int32(0),
            stored.value(),
        ),
    );
    try std.testing.expectEqual(@as(u32, 1), array.fastArrayCount());
    try std.testing.expectEqual(@as(u32, 1), array.arrayLength());
    try std.testing.expectEqual(stored.gcHeader(), array.fastArrayElementAt(0).refHeader().?);

    const growth_array = try core.Object.createArray(rt, null);
    const retained = try core.Object.create(rt, core.class.ids.object, null);
    try std.testing.expectEqual(
        array_ops.DenseArrayOverwriteFastResult.append_candidate,
        array_ops.putDenseArrayElementOverwriteOwnedFast(
            rt,
            growth_array.value(),
            core.JSValue.int32(0),
            retained.value(),
        ),
    );

    const shaped_array = try core.Object.createArray(rt, null);
    try shaped_array.fastArrayEnsureCapacity(rt, 1);
    const extra_atom = try rt.internAtom("extra");
    try shaped_array.defineOwnProperty(
        rt,
        extra_atom,
        core.Descriptor.data(core.JSValue.int32(1), .all),
    );
    const shaped_retained = try core.Object.create(rt, core.class.ids.object, null);
    try std.testing.expectEqual(
        array_ops.DenseArrayOverwriteFastResult.append_candidate,
        array_ops.putDenseArrayElementOverwriteOwnedFast(
            rt,
            shaped_array.value(),
            core.JSValue.int32(0),
            shaped_retained.value(),
        ),
    );
}

test "static named getter and proxy fast paths preserve receivers throws and invariants" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\const prototype = {};
        \\let getterReceiver;
        \\let getterCount = 0;
        \\Object.defineProperty(prototype, "__zjs_static_getter_probe__", {
        \\    get() {
        \\        getterReceiver = this;
        \\        getterCount++;
        \\        return 21;
        \\    },
        \\});
        \\const object = Object.create(prototype);
        \\assert.sameValue(object.__zjs_static_getter_probe__, 21);
        \\assert.sameValue(getterReceiver, object);
        \\assert.sameValue(getterCount, 1);
        \\Object.defineProperty(prototype, "__zjs_static_throw_probe__", {
        \\    get() { throw new Error("static getter sentinel"); },
        \\});
        \\let getterThrow;
        \\try {
        \\    object.__zjs_static_throw_probe__;
        \\} catch (error) {
        \\    getterThrow = error.message;
        \\}
        \\assert.sameValue(getterThrow, "static getter sentinel");
        \\let primitiveReceiver;
        \\Object.defineProperty(Number.prototype, "__zjs_static_primitive_probe__", {
        \\    configurable: true,
        \\    get: function staticPrimitiveGetter() {
        \\        "use strict";
        \\        primitiveReceiver = this;
        \\        return 22;
        \\    },
        \\});
        \\assert.sameValue((1).__zjs_static_primitive_probe__, 22);
        \\assert.sameValue(primitiveReceiver, 1);
        \\delete Number.prototype.__zjs_static_primitive_probe__;
        \\let forwardedReceiver;
        \\const forwardedTarget = {};
        \\Object.defineProperty(forwardedTarget, "__zjs_static_forward_probe__", {
        \\    get() {
        \\        forwardedReceiver = this;
        \\        return 23;
        \\    },
        \\});
        \\const forwardedProxy = new Proxy(forwardedTarget, {});
        \\assert.sameValue(forwardedProxy.__zjs_static_forward_probe__, 23);
        \\assert.sameValue(forwardedReceiver, forwardedProxy);
        \\let handlerGetterReceiver;
        \\const handler = {};
        \\Object.defineProperty(handler, "get", {
        \\    get() {
        \\        handlerGetterReceiver = this;
        \\        return function (target, key, receiver) {
        \\            assert.sameValue(receiver, trappedProxy);
        \\            return 24;
        \\        };
        \\    },
        \\});
        \\const trappedProxy = new Proxy({}, handler);
        \\assert.sameValue(trappedProxy.__zjs_static_trap_probe__, 24);
        \\assert.sameValue(handlerGetterReceiver, handler);
        \\const frozenTarget = {};
        \\Object.defineProperty(frozenTarget, "frozen", {
        \\    value: 25,
        \\    writable: false,
        \\    configurable: false,
        \\});
        \\assert.sameValue(new Proxy(frozenTarget, { get() { return 25; } }).frozen, 25);
        \\let frozenRejected = false;
        \\try {
        \\    new Proxy(frozenTarget, { get() { return 26; } }).frozen;
        \\} catch (error) {
        \\    frozenRejected = error instanceof TypeError;
        \\}
        \\assert.sameValue(frozenRejected, true);
        \\const mutationTarget = { marker: 1 };
        \\const mutationProxy = new Proxy(mutationTarget, {
        \\    get(target, key) {
        \\        Object.defineProperty(target, key, {
        \\            value: 1,
        \\            writable: false,
        \\            configurable: false,
        \\        });
        \\        return 2;
        \\    },
        \\});
        \\let mutationRejected = false;
        \\try {
        \\    mutationProxy.marker;
        \\} catch (error) {
        \\    mutationRejected = error instanceof TypeError;
        \\}
        \\assert.sameValue(mutationRejected, true);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "proxy bytecode get continuation does not require spare operand capacity" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function readX(object) { return object.x; }
        \\const proxy = new Proxy({ x: 1 }, {
        \\    get(target, key, receiver) {
        \\        return Reflect.get(target, key, receiver);
        \\    },
        \\});
        \\assert.sameValue(readX(proxy), 1);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "for-of bytecode next continuation preserves result and abrupt semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\let events = [];
        \\let step = 0;
        \\function tailStep() {
        \\    if (step++ === 0) {
        \\        return {
        \\            get done() { events.push("done:false"); return false; },
        \\            get value() { events.push("value"); return 7; },
        \\        };
        \\    }
        \\    return {
        \\        get done() { events.push("done:true"); return true; },
        \\        get value() { throw new Error("done value was read"); },
        \\    };
        \\}
        \\const tailIterator = {
        \\    [Symbol.iterator]() { return this; },
        \\    next() { "use strict"; return tailStep(); },
        \\};
        \\let sum = 0;
        \\for (const value of tailIterator) sum += value;
        \\assert.sameValue(sum, 7);
        \\assert.sameValue(events.join(","), "done:false,value,done:true");
        \\
        \\let nextCalls = 0;
        \\let closeCalls = 0;
        \\const throwingIterator = {
        \\    [Symbol.iterator]() { return this; },
        \\    next() {
        \\        if (nextCalls++ === 0) return { value: 3, done: false };
        \\        throw new Error("next sentinel");
        \\    },
        \\    return() { closeCalls++; return { done: true }; },
        \\};
        \\let caught = false;
        \\try {
        \\    for (const value of throwingIterator) assert.sameValue(value, 3);
        \\} catch (error) {
        \\    caught = error.message === "next sentinel";
        \\}
        \\assert.sameValue(caught, true);
        \\assert.sameValue(closeCalls, 0);
        \\
        \\let arrowStep = 0;
        \\const arrowIterator = {
        \\    [Symbol.iterator]() { return this; },
        \\    next: () => arrowStep++ === 0
        \\        ? { value: 11, done: false }
        \\        : { done: true },
        \\};
        \\let arrowSum = 0;
        \\for (const value of arrowIterator) arrowSum += value;
        \\assert.sameValue(arrowSum, 11);
        \\
        \\let inheritedStep = 0;
        \\const inheritedResult = Object.create({ value: 13 });
        \\inheritedResult.done = false;
        \\const inheritedIterator = {
        \\    [Symbol.iterator]() { return this; },
        \\    next() { return inheritedStep++ === 0 ? inheritedResult : { done: true }; },
        \\};
        \\let inheritedSum = 0;
        \\for (const value of inheritedIterator) inheritedSum += value;
        \\assert.sameValue(inheritedSum, 13);
        \\
        \\let proxyStep = 0;
        \\let proxyReads = [];
        \\const proxyResult = new Proxy({ value: 17, done: false }, {
        \\    get(target, key, receiver) {
        \\        proxyReads.push(key);
        \\        return Reflect.get(target, key, receiver);
        \\    },
        \\});
        \\const proxyIterator = {
        \\    [Symbol.iterator]() { return this; },
        \\    next() { return proxyStep++ === 0 ? proxyResult : { done: true }; },
        \\};
        \\let proxySum = 0;
        \\for (const value of proxyIterator) proxySum += value;
        \\assert.sameValue(proxySum, 17);
        \\assert.sameValue(proxyReads.join(","), "done,value");
        \\
        \\let paddedStep = 0;
        \\const paddedIterator = {
        \\    [Symbol.iterator]() { return this; },
        \\    next(unused) {
        \\        "use strict";
        \\        assert.sameValue(unused, undefined);
        \\        assert.sameValue(arguments.length, 0);
        \\        return paddedStep++ === 0 ? { value: 19, done: false } : { done: true };
        \\    },
        \\};
        \\let paddedSum = 0;
        \\for (const value of paddedIterator) paddedSum += value;
        \\assert.sameValue(paddedSum, 19);
        \\
        \\let cachedStep = 0;
        \\const cachedMethodIterator = {
        \\    [Symbol.iterator]() { return this; },
        \\    next() {
        \\        this.next = null;
        \\        return cachedStep++ === 0 ? { value: 23, done: false } : { done: true };
        \\    },
        \\};
        \\let cachedMethodSum = 0;
        \\for (const value of cachedMethodIterator) cachedMethodSum += value;
        \\assert.sameValue(cachedMethodSum, 23);
        \\assert.sameValue(cachedMethodIterator.next, null);
        \\
        \\const falloffIterator = {
        \\    [Symbol.iterator]() { return this; },
        \\    next() {},
        \\};
        \\let sawTypeError = false;
        \\try {
        \\    for (const value of falloffIterator) {}
        \\} catch (error) {
        \\    sawTypeError = error instanceof TypeError;
        \\}
        \\assert.sameValue(sawTypeError, true);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "IteratorNext bound proxy and native throws do not close the iterator" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\let closeCalls = 0;
        \\function throwingNext() { throw 1; }
        \\const nextMethods = [
        \\    throwingNext.bind(null),
        \\    new Proxy(throwingNext, { apply(target, receiver, args) { return Reflect.apply(target, receiver, args); } }),
        \\    Symbol.prototype.valueOf,
        \\];
        \\for (const next of nextMethods) {
        \\    const iterator = {
        \\        [Symbol.iterator]() { return this; },
        \\        next,
        \\        return() { closeCalls++; return { done: true }; },
        \\    };
        \\    try { for (const value of iterator) {} } catch (error) {}
        \\}
        \\assert.sameValue(closeCalls, 0);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "destructuring abrupt completion closes every live outer iterator" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function run(value, body) {
        \\    const events = [];
        \\    const iterator = {
        \\        [Symbol.iterator]() { return this; },
        \\        next() { events.push("next"); return { value, done: false }; },
        \\        return() { events.push("return"); return { done: true }; },
        \\    };
        \\    body(iterator, events);
        \\    return events.join(",");
        \\}
        \\assert.sameValue(run(undefined, function(iterator, events) {
        \\    try { let [value = missingDefaultBinding] = iterator; } catch (error) { events.push(error.name); }
        \\}), "next,return,ReferenceError");
        \\assert.sameValue(run(1, function(iterator, events) {
        \\    try { let [[value]] = iterator; } catch (error) { events.push(error.name); }
        \\}), "next,return,TypeError");
        \\assert.sameValue(run(null, function(iterator, events) {
        \\    try { let [{ value }] = iterator; } catch (error) { events.push(error.name); }
        \\}), "next,return,TypeError");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "array destructuring rest roots direct symbol values while creating its result" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const old_threshold = js.runtime.gcThreshold();
    js.runtime.setGCThreshold(0);
    defer js.runtime.setGCThreshold(old_threshold);

    const result = try js.eval(
        \\const symbol = Symbol("gc-destructuring-rest-symbol");
        \\const source = [symbol];
        \\const [...rest] = source;
        \\assert.sameValue(rest.length, 1);
        \\assert.sameValue(rest[0], symbol);
        \\assert.sameValue(rest[0].description, "gc-destructuring-rest-symbol");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "computed object-rest keys perform observable ToPropertyKey once" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\let conversions = 0;
        \\const key = {
        \\  [Symbol.toPrimitive](hint) {
        \\    conversions++;
        \\    assert.sameValue(hint, "string");
        \\    return "kept";
        \\  },
        \\};
        \\const source = { kept: 1, copied: 2 };
        \\const { [key]: value, ...rest } = source;
        \\assert.sameValue(conversions, 1);
        \\assert.sameValue(value, 1);
        \\assert.sameValue(rest.kept, undefined);
        \\assert.sameValue(rest.copied, 2);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "object destructuring does not turn its source into a with environment" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function(global) {
        \\  "use strict";
        \\  const { Object } = global;
        \\  global.__destructuringFollowup = Object.freeze([1]);
        \\})(globalThis);
        \\assert.sameValue(globalThis.__destructuringFollowup.length, 1);
        \\delete globalThis.__destructuringFollowup;
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "object destructuring ToObject uses the current realm primitive prototypes" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const { __proto__: numberPrototype } = 42;
        \\const { __proto__: stringPrototype } = "value";
        \\const { __proto__: booleanPrototype } = true;
        \\const { __proto__: symbolPrototype } = Symbol("value");
        \\const { __proto__: bigintPrototype } = 1n;
        \\assert.sameValue(numberPrototype, Number.prototype);
        \\assert.sameValue(stringPrototype, String.prototype);
        \\assert.sameValue(booleanPrototype, Boolean.prototype);
        \\assert.sameValue(symbolPrototype, Symbol.prototype);
        \\assert.sameValue(bigintPrototype, BigInt.prototype);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "for-in-of generic lvalues use QuickJS bottom-stack evaluation order" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\let events = [];
        \\let target = { length: 0 };
        \\function targetBase() { events.push("base"); return target; }
        \\function targetKey() { events.push("key"); return "value"; }
        \\function iterable() { events.push("iterable"); return [7]; }
        \\for ((targetBase()[targetKey()]) of iterable()) {}
        \\assert.sameValue(events.join(","), "iterable,base,key");
        \\assert.sameValue(target.value, 7);
        \\
        \\events = [];
        \\for ((targetBase()[targetKey()]) of []) {}
        \\assert.sameValue(events.length, 0);
        \\
        \\for (target.length of [3]) {}
        \\assert.sameValue(target.length, 3);
        \\for (target.name in { only: true }) {}
        \\assert.sameValue(target.name, "only");
        \\
        \\var outside = 0;
        \\var environment = { outside: 1 };
        \\with (environment) {
        \\    for (outside of [4]) {}
        \\}
        \\assert.sameValue(environment.outside, 4);
        \\assert.sameValue(outside, 0);
        \\
        \\class Base {}
        \\Object.defineProperty(Base.prototype, "slot", {
        \\    set(value) { this.superValue = value; },
        \\});
        \\class Derived extends Base {
        \\    #privateValue = 0;
        \\    assign() {
        \\        for (super.slot of [5]) {}
        \\        for (this.#privateValue of [6]) {}
        \\        return this.superValue + this.#privateValue;
        \\    }
        \\}
        \\assert.sameValue(new Derived().assign(), 11);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "computed proxy bytecode trap continuations preserve nested calls throws and invariants" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\const key = ["__zjs_computed_", "proxy_probe__"].join("");
        \\const symbolKey = Symbol("computed proxy probe");
        \\const symbolOwn = {};
        \\Object.defineProperty(symbolOwn, symbolKey, { value: 29 });
        \\assert.sameValue(symbolOwn[symbolKey], 29);
        \\const symbolPrototype = {};
        \\let symbolGetterReceiver;
        \\Object.defineProperty(symbolPrototype, symbolKey, {
        \\    get() { symbolGetterReceiver = this; return 30; },
        \\});
        \\const symbolChild = Object.create(symbolPrototype);
        \\assert.sameValue(symbolChild[symbolKey], 30);
        \\assert.sameValue(symbolGetterReceiver, symbolChild);
        \\const symbolProxy = new Proxy({}, {
        \\    get(target, propertyKey, receiver) {
        \\        assert.sameValue(propertyKey, symbolKey);
        \\        assert.sameValue(receiver, symbolProxy);
        \\        return 31;
        \\    },
        \\});
        \\assert.sameValue(symbolProxy[symbolKey], 31);
        \\assert.sameValue({}[symbolKey], undefined);
        \\let trapCount = 0;
        \\let seenTarget;
        \\let seenKey;
        \\let seenReceiver;
        \\const basicTarget = {};
        \\const basicProxy = new Proxy(basicTarget, {
        \\    get(target, propertyKey, receiver) {
        \\        trapCount++;
        \\        seenTarget = target;
        \\        seenKey = propertyKey;
        \\        seenReceiver = receiver;
        \\        return 31;
        \\    },
        \\});
        \\for (let i = 0; i < 3; i++) {
        \\    assert.sameValue(basicProxy[key], 31);
        \\}
        \\assert.sameValue(trapCount, 3);
        \\assert.sameValue(seenTarget, basicTarget);
        \\assert.sameValue(seenKey, key);
        \\assert.sameValue(seenReceiver, basicProxy);
        \\const falloffProxy = new Proxy({}, {
        \\    get() {},
        \\});
        \\for (let i = 0; i < 3; i++) {
        \\    assert.sameValue(falloffProxy[key], undefined);
        \\}
        \\let throwCount = 0;
        \\const throwingProxy = new Proxy({}, {
        \\    get() { throw new Error("computed proxy sentinel"); },
        \\});
        \\for (let i = 0; i < 3; i++) {
        \\    try {
        \\        throwingProxy[key];
        \\    } catch (error) {
        \\        assert.sameValue(error.message, "computed proxy sentinel");
        \\        throwCount++;
        \\    }
        \\}
        \\assert.sameValue(throwCount, 3);
        \\let innerCount = 0;
        \\let outerCount = 0;
        \\const innerProxy = new Proxy({}, {
        \\    get() {
        \\        innerCount++;
        \\        return 32;
        \\    },
        \\});
        \\const outerProxy = new Proxy({}, {
        \\    get() {
        \\        outerCount++;
        \\        return innerProxy[key];
        \\    },
        \\});
        \\for (let i = 0; i < 3; i++) {
        \\    assert.sameValue(outerProxy[key], 32);
        \\}
        \\assert.sameValue(innerCount, 3);
        \\assert.sameValue(outerCount, 3);
        \\const frozenTarget = {};
        \\Object.defineProperty(frozenTarget, key, {
        \\    value: 33,
        \\    writable: false,
        \\    configurable: false,
        \\});
        \\const correctFrozenProxy = new Proxy(frozenTarget, {
        \\    get() { return 33; },
        \\});
        \\for (let i = 0; i < 3; i++) {
        \\    assert.sameValue(correctFrozenProxy[key], 33);
        \\}
        \\const rejectedFrozenProxy = new Proxy(frozenTarget, {
        \\    get() { return 34; },
        \\});
        \\let frozenRejected = 0;
        \\for (let i = 0; i < 3; i++) {
        \\    try {
        \\        rejectedFrozenProxy[key];
        \\    } catch (error) {
        \\        if (error instanceof TypeError) frozenRejected++;
        \\    }
        \\}
        \\assert.sameValue(frozenRejected, 3);
        \\function tailWrongFrozenValue() { return 34; }
        \\const tailRejectedProxy = new Proxy(frozenTarget, {
        \\    get() { return tailWrongFrozenValue(); },
        \\});
        \\let tailRejected = 0;
        \\for (let i = 0; i < 3; i++) {
        \\    try {
        \\        tailRejectedProxy[key];
        \\    } catch (error) {
        \\        if (error instanceof TypeError) tailRejected++;
        \\    }
        \\}
        \\assert.sameValue(tailRejected, 3);
        \\const catchingProxy = new Proxy({}, {
        \\    get() {
        \\        try {
        \\            return rejectedFrozenProxy[key];
        \\        } catch (error) {
        \\            assert.sameValue(error instanceof TypeError, true);
        \\            return 35;
        \\        }
        \\    },
        \\});
        \\for (let i = 0; i < 3; i++) {
        \\    assert.sameValue(catchingProxy[key], 35);
        \\}
        \\const mutationTarget = { marker: 1 };
        \\const mutationProxy = new Proxy(mutationTarget, {
        \\    get(target, propertyKey) {
        \\        Object.defineProperty(target, propertyKey, {
        \\            value: 36,
        \\            writable: false,
        \\            configurable: false,
        \\        });
        \\        return 37;
        \\    },
        \\});
        \\let mutationRejected = 0;
        \\for (let i = 0; i < 3; i++) {
        \\    try {
        \\        mutationProxy[key];
        \\    } catch (error) {
        \\        if (error instanceof TypeError) mutationRejected++;
        \\    }
        \\}
        \\assert.sameValue(mutationRejected, 3);
        \\const targetAlias = {};
        \\const targetAliasProxy = new Proxy(targetAlias, {
        \\    get(target) { return target; },
        \\});
        \\const receiverAliasProxy = new Proxy({}, {
        \\    get(target, propertyKey, receiver) { return receiver; },
        \\});
        \\const keyAliasProxy = new Proxy({}, {
        \\    get(target, propertyKey) { return propertyKey; },
        \\});
        \\for (let i = 0; i < 3; i++) {
        \\    assert.sameValue(targetAliasProxy[key], targetAlias);
        \\    assert.sameValue(receiverAliasProxy[key], receiverAliasProxy);
        \\    assert.sameValue(keyAliasProxy[key], key);
        \\}
        \\const paddedProxy = new Proxy({}, {
        \\    get(target, propertyKey, receiver, missing) {
        \\        assert.sameValue(missing, undefined);
        \\        return 38;
        \\    },
        \\});
        \\const snapshotPaddedProxy = new Proxy({}, {
        \\    get: function (target, propertyKey, receiver, missing) {
        \\        "use strict";
        \\        assert.sameValue(arguments.length, 3);
        \\        assert.sameValue(arguments[0], target);
        \\        assert.sameValue(arguments[1], propertyKey);
        \\        assert.sameValue(arguments[2], receiver);
        \\        assert.sameValue(missing, undefined);
        \\        target = null;
        \\        assert.notSameValue(arguments[0], target);
        \\        return 39;
        \\    },
        \\});
        \\for (let i = 0; i < 3; i++) {
        \\    assert.sameValue(paddedProxy[key], 38);
        \\    assert.sameValue(snapshotPaddedProxy[key], 39);
        \\}
        \\let handlerLookupCount = 0;
        \\const accessorHandler = {};
        \\Object.defineProperty(accessorHandler, "get", {
        \\    get() {
        \\        handlerLookupCount++;
        \\        return function () { return 40; };
        \\    },
        \\});
        \\const accessorHandlerProxy = new Proxy({}, accessorHandler);
        \\for (let i = 0; i < 3; i++) {
        \\    assert.sameValue(accessorHandlerProxy[key], 40);
        \\}
        \\assert.sameValue(handlerLookupCount, 3);
        \\let descriptorCount = 0;
        \\const descriptorTarget = new Proxy({}, {
        \\    getOwnPropertyDescriptor(target, propertyKey) {
        \\        descriptorCount++;
        \\        return Reflect.getOwnPropertyDescriptor(target, propertyKey);
        \\    },
        \\});
        \\const descriptorProxy = new Proxy(descriptorTarget, {
        \\    get() { return 41; },
        \\});
        \\for (let i = 0; i < 3; i++) {
        \\    assert.sameValue(descriptorProxy[key], 41);
        \\}
        \\assert.sameValue(descriptorCount, 3);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "native tail calls preserve iterator and proxy continuation success and throws" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\let nextIndex = 0;
        \\const nativeResultIterator = {
        \\    results: [
        \\        { value: 43, done: false },
        \\        { done: true },
        \\    ],
        \\    [Symbol.iterator]() { return this; },
        \\    next() {
        \\        "use strict";
        \\        return Object(this.results[nextIndex++]);
        \\    },
        \\};
        \\let iteratorSum = 0;
        \\for (const value of nativeResultIterator) iteratorSum += value;
        \\assert.sameValue(iteratorSum, 43);
        \\assert.sameValue(nextIndex, 2);
        \\
        \\let closeCalls = 0;
        \\const nativeThrowIterator = {
        \\    [Symbol.iterator]() { return this; },
        \\    next() {
        \\        "use strict";
        \\        return Number(Symbol("iterator native tail throw"));
        \\    },
        \\    return() {
        \\        closeCalls++;
        \\        return { done: true };
        \\    },
        \\};
        \\let iteratorThrew = false;
        \\try {
        \\    for (const value of nativeThrowIterator) {}
        \\} catch (error) {
        \\    iteratorThrew = error instanceof TypeError;
        \\}
        \\assert.sameValue(iteratorThrew, true);
        \\assert.sameValue(closeCalls, 0);
        \\
        \\const key = ["native", "tail", "continuation"].join("-");
        \\const nativeResultProxy = new Proxy({}, {
        \\    get() {
        \\        "use strict";
        \\        return Number("47");
        \\    },
        \\});
        \\assert.sameValue(nativeResultProxy[key], 47);
        \\
        \\const nativeThrowProxy = new Proxy({}, {
        \\    get() {
        \\        "use strict";
        \\        return Number(Symbol("proxy native tail throw"));
        \\    },
        \\});
        \\let proxyThrew = false;
        \\try {
        \\    nativeThrowProxy[key];
        \\} catch (error) {
        \\    proxyThrew = error instanceof TypeError;
        \\}
        \\assert.sameValue(proxyThrew, true);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "return conditional followed by newline comma keeps the comma expression" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function choose(condition) {
        \\  return condition ? 1 : 2
        \\  , 42;
        \\}
        \\assert.sameValue(choose(true), 42);
        \\assert.sameValue(choose(false), 42);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "Phase 7: inlined arrow keeps lexical this and ignores any receiver" {

    // An arrow captures `this` lexically. Its unobservable frame slot follows
    // the ordinary strict/sloppy or receiver policy, while bytecode reads the
    // capture cell. `bound.call(other)`/`carrier.m()` must not change that
    // lexical `this`.

    try helpers.expectPrints(
        \\const lex = { tag: "LEX" };
        \\function make() { return () => this.tag; }
        \\const bound = make.call(lex);
        \\print(bound());
        \\print(bound.call());
        \\const carrier = { tag: "CARRIER", m: bound };
        \\print(carrier.m());
        \\const obj = { name: "outer", run() { const a = () => this.name; return a(); } };
        \\print(obj.run());
    , "LEX\nLEX\nLEX\nouter\n");
}

test "arrow direct eval reads captured this and new.target" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Direct eval must resolve the arrow's capture cells rather than the
    // ordinary strict/sloppy frame-this slot selected by inline setup.
    const result = try js.eval(
        \\function Replacement() {}
        \\function Factory() {
        \\    const expectedThis = this;
        \\    return () => [eval("this") === expectedThis, eval("new.target")];
        \\}
        \\const read = Reflect.construct(Factory, [], Replacement);
        \\const observed = read.call({ ignored: true });
        \\assert.sameValue(observed[0], true);
        \\assert.sameValue(observed[1], Replacement);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "direct eval inherits QuickJS entry capabilities and var environment" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\class Base { constructor(value) { this.value = value; } }
        \\class Derived extends Base { constructor() { eval("super(7)"); } }
        \\assert.sameValue(new Derived().value, 7);
        \\let staticArgumentsSyntaxError = false;
        \\try { class StaticEval { static { eval("arguments"); } } }
        \\catch (error) { staticArgumentsSyntaxError = error instanceof SyntaxError; }
        \\assert.sameValue(staticArgumentsSyntaxError, true);
        \\eval("eval('var nestedGlobal = 3')");
        \\assert.sameValue(nestedGlobal, 3);
        \\function localEval() {
        \\  eval("eval('var nestedLocal = 4')");
        \\  return nestedLocal;
        \\}
        \\assert.sameValue(localEval(), 4);
        \\assert.sameValue(typeof nestedLocal, "undefined");
    );
    try std.testing.expect(result.is(.undefined_value));

    // An ordinary nested function does not inherit a method's Super grammar
    // capability. QuickJS rejects the complete source during parsing; the
    // surrounding runtime try/catch cannot intercept that early error.
    try js.expectThrown("SyntaxError", js.eval(
        \\class Parent { method() {} }
        \\class Child extends Parent {
        \\  method() { function nested() { return super.method(); } }
        \\}
    ));
}

test "class field direct eval keeps QuickJS field initializer capabilities" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\class FieldBase { get value() { return 41; } }
        \\class FieldDerived extends FieldBase { field = eval("super.value + 1"); }
        \\assert.sameValue(new FieldDerived().field, 42);
        \\let argumentsSyntaxError = false;
        \\try { class ArgumentsField { field = eval("arguments"); } new ArgumentsField(); }
        \\catch (error) { argumentsSyntaxError = error instanceof SyntaxError; }
        \\assert.sameValue(argumentsSyntaxError, true);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "public instance fields initialize once in constructor order on every path" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const events = [];
        \\const counts = {};
        \\function mark(label, value) {
        \\  events.push(label);
        \\  counts[label] = (counts[label] || 0) + 1;
        \\  return value;
        \\}
        \\
        \\class DefaultBase {
        \\  first = mark("base-default:first", 1);
        \\  second = mark("base-default:second", this.first + 1);
        \\}
        \\class ExplicitBase {
        \\  first = mark("base:first", 1);
        \\  second = mark("base:second", this.first + 1);
        \\  constructor() { events.push("base:body"); }
        \\}
        \\
        \\class Parent {
        \\  constructor(label) {
        \\    this.seed = 10;
        \\    events.push(label + ":parent");
        \\  }
        \\}
        \\class DirectDerived extends Parent {
        \\  first = mark("direct:first", this.seed + 1);
        \\  second = mark("direct:second", this.first + 1);
        \\  constructor() {
        \\    events.push("direct:before");
        \\    super("direct");
        \\    events.push("direct:body");
        \\  }
        \\}
        \\class SpreadDerived extends Parent {
        \\  first = mark("spread:first", this.seed + 1);
        \\  second = mark("spread:second", this.first + 1);
        \\  constructor(...args) {
        \\    events.push("spread:before");
        \\    super(...args);
        \\    events.push("spread:body");
        \\  }
        \\}
        \\class DefaultDerived extends Parent {
        \\  first = mark("default:first", this.seed + 1);
        \\  second = mark("default:second", this.first + 1);
        \\}
        \\class NestedOuter {
        \\  first = mark("nested:outer:first", 20);
        \\  Inner = class {
        \\    first = mark("nested:inner:first", 30);
        \\    second = mark("nested:inner:second", this.first + 1);
        \\  };
        \\  second = mark("nested:outer:second", this.first + 1);
        \\}
        \\
        \\const defaultBase = new DefaultBase();
        \\const base = new ExplicitBase();
        \\const direct = new DirectDerived();
        \\const spread = new SpreadDerived("spread");
        \\const derived = new DefaultDerived("default");
        \\const nestedA = new NestedOuter();
        \\const nestedB = new NestedOuter();
        \\const nestedInnerA = new nestedA.Inner();
        \\const nestedInnerB = new nestedB.Inner();
        \\
        \\assert.sameValue(defaultBase.first, 1);
        \\assert.sameValue(defaultBase.second, 2);
        \\assert.sameValue(base.first, 1);
        \\assert.sameValue(base.second, 2);
        \\assert.sameValue(direct.first, 11);
        \\assert.sameValue(direct.second, 12);
        \\assert.sameValue(spread.first, 11);
        \\assert.sameValue(spread.second, 12);
        \\assert.sameValue(derived.first, 11);
        \\assert.sameValue(derived.second, 12);
        \\assert.sameValue(nestedA.first, 20);
        \\assert.sameValue(nestedA.second, 21);
        \\assert.sameValue(nestedB.first, 20);
        \\assert.sameValue(nestedB.second, 21);
        \\assert.sameValue(nestedA.Inner === nestedB.Inner, false);
        \\assert.sameValue(nestedInnerA.first, 30);
        \\assert.sameValue(nestedInnerA.second, 31);
        \\assert.sameValue(nestedInnerB.first, 30);
        \\assert.sameValue(nestedInnerB.second, 31);
        \\for (const label of [
        \\  "base-default:first", "base-default:second",
        \\  "base:first", "base:second",
        \\  "direct:first", "direct:second",
        \\  "spread:first", "spread:second",
        \\  "default:first", "default:second",
        \\]) {
        \\  assert.sameValue(counts[label], 1, label + " initialized exactly once");
        \\}
        \\for (const label of [
        \\  "nested:outer:first", "nested:outer:second",
        \\  "nested:inner:first", "nested:inner:second",
        \\]) {
        \\  assert.sameValue(counts[label], 2, label + " initialized once per instance");
        \\}
        \\assert.sameValue(
        \\  events.join(","),
        \\  "base-default:first,base-default:second," +
        \\    "base:first,base:second,base:body," +
        \\    "direct:before,direct:parent,direct:first,direct:second,direct:body," +
        \\    "spread:before,spread:parent,spread:first,spread:second,spread:body," +
        \\    "default:parent,default:first,default:second," +
        \\    "nested:outer:first,nested:outer:second,nested:outer:first,nested:outer:second," +
        \\    "nested:inner:first,nested:inner:second,nested:inner:first,nested:inner:second"
        \\);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "arrow super property call keeps the enclosing method receiver" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\let derivedInstance;
        \\class Base {
        \\    method() {
        \\        assert.sameValue(this, derivedInstance);
        \\        return 42;
        \\    }
        \\}
        \\class Derived extends Base {
        \\    makeArrow() { return () => super.method(); }
        \\}
        \\derivedInstance = new Derived();
        \\const callSuper = derivedInstance.makeArrow();
        \\assert.sameValue(callSuper(), 42);
        \\assert.sameValue(callSuper.call({ ignored: true }), 42);
        \\class ReplacementBase {
        \\    method() {
        \\        assert.sameValue(this, derivedInstance);
        \\        return 84;
        \\    }
        \\}
        \\Object.setPrototypeOf(Derived.prototype, ReplacementBase.prototype);
        \\assert.sameValue(callSuper(), 84);
        \\assert.sameValue(callSuper.call({ ignored: true }), 84);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "super property assignment respects strictness when inherited descriptors reject writes" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const superSetBase = {};
        \\Object.defineProperty(superSetBase, "lockedData", {
        \\    value: 1,
        \\    writable: false,
        \\    configurable: true,
        \\});
        \\Object.defineProperty(superSetBase, "getterOnly", {
        \\    get() { return 2; },
        \\    configurable: true,
        \\});
        \\class StrictSuperSet {
        \\    setData() { super.lockedData = 10; }
        \\    setAccessor() { super.getterOnly = 20; }
        \\}
        \\Object.setPrototypeOf(StrictSuperSet.prototype, superSetBase);
        \\const strictReceiver = new StrictSuperSet();
        \\assert.throws(TypeError, () => strictReceiver.setData());
        \\assert.throws(TypeError, () => strictReceiver.setAccessor());
        \\const sloppyReceiver = {
        \\    __proto__: superSetBase,
        \\    setData() { super.lockedData = 10; },
        \\    setAccessor() { super.getterOnly = 20; },
        \\};
        \\sloppyReceiver.setData();
        \\sloppyReceiver.setAccessor();
        \\assert.sameValue(superSetBase.lockedData, 1);
        \\assert.sameValue(superSetBase.getterOnly, 2);
        \\assert.sameValue(
        \\    Object.prototype.hasOwnProperty.call(sloppyReceiver, "lockedData"),
        \\    false
        \\);
        \\assert.sameValue(
        \\    Object.prototype.hasOwnProperty.call(sloppyReceiver, "getterOnly"),
        \\    false
        \\);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "bytecode constructability follows canonical function shape" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function Ordinary(length) { this.length = length; }
        \\const arrow = () => {};
        \\function* generator() {}
        \\async function asyncFunction() {}
        \\async function* asyncGenerator() {}
        \\const functions = [arrow, generator, asyncFunction, asyncGenerator];
        \\for (const fn of functions) {
        \\  assert.throws(TypeError, function () { Reflect.construct(Object, [], fn); });
        \\  const values = Array.of.call(fn, 1, 2);
        \\  assert.sameValue(Array.isArray(values), true);
        \\  assert.sameValue(values.length, 2);
        \\  assert.sameValue(values[0], 1);
        \\  assert.sameValue(values[1], 2);
        \\}
        \\const ordinary = Array.of.call(Ordinary, 1, 2);
        \\assert.sameValue(ordinary instanceof Ordinary, true);
        \\assert.sameValue(ordinary.length, 2);
        \\assert.sameValue(ordinary[0], 1);
        \\assert.sameValue(ordinary[1], 2);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "forwarded call releases ignored arrow thisArg" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // The strict arrow publishes the ordinary raw frame policy. Forwarded
    // Function.call still transfers and releases its explicit receiver even
    // though arrow bytecode ignores that slot.
    _ = try js.eval(
        \\globalThis.strictArrowForCall = (function () {
        \\    "use strict";
        \\    return () => 0;
        \\})();
        \\strictArrowForCall.call({ marker: 0 });
    );
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const arrow_name = try js.runtime.internAtom("strictArrowForCall");
    const arrow = try global.getProperty(arrow_name);
    const resolved = inline_calls.resolveInlineFunction(global, arrow) orelse
        return error.InvalidFunctionBytecode;
    try std.testing.expect(!resolved.fb.simpleInlineEmptyLeaf());
    try std.testing.expect(resolved.fb.rawThisInlineEmptyLeaf());

    _ = try js.runtime.collectForTest();
    const baseline_objects = js.runtime.gc.liveCount();

    _ = try js.eval(
        \\for (let i = 0; i < 256; i++) {
        \\    strictArrowForCall.call({ marker: i });
        \\}
    );
    _ = try js.runtime.collectForTest();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "function inherited data lookup preserves own and exotic semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function target() {}
        \\var intrinsicCall = Function.prototype.call;
        \\assert.sameValue(target.call, intrinsicCall);
        \\assert.sameValue(target.bind(null).call, intrinsicCall);
        \\
        \\var ownReads = 0;
        \\var ownCall = function ownCall() {};
        \\Object.defineProperty(target, "call", {
        \\    configurable: true,
        \\    get: function() { ownReads++; return ownCall; }
        \\});
        \\assert.sameValue(target.call, ownCall);
        \\assert.sameValue(ownReads, 1);
        \\delete target.call;
        \\
        \\var inheritedCall = function inheritedCall() {};
        \\var proto = { call: inheritedCall };
        \\Object.setPrototypeOf(target, proto);
        \\assert.sameValue(target.call, inheritedCall);
        \\
        \\var inheritedReads = 0;
        \\Object.defineProperty(proto, "call", {
        \\    configurable: true,
        \\    get: function() { inheritedReads++; return ownCall; }
        \\});
        \\assert.sameValue(target.call, ownCall);
        \\assert.sameValue(inheritedReads, 1);
        \\
        \\var proxyReads = 0;
        \\var proxyProto = new Proxy({ call: inheritedCall }, {
        \\    get: function(object, key, receiver) {
        \\        if (key === "call") proxyReads++;
        \\        return Reflect.get(object, key, receiver);
        \\    }
        \\});
        \\Object.setPrototypeOf(target, proxyProto);
        \\assert.sameValue(target.call, inheritedCall);
        \\assert.sameValue(proxyReads, 1);
        \\
        \\var grandparentCall = function grandparentCall() {};
        \\Object.setPrototypeOf(target, Object.create({ call: grandparentCall }));
        \\assert.sameValue(target.call, grandparentCall);
        \\
        \\function strictFunction() { "use strict"; }
        \\assert.throws(TypeError, function() { return strictFunction.caller; });
        \\assert.throws(TypeError, function() { return strictFunction.arguments; });
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "function caller and arguments restrictions follow immutable function shape" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function assertForbidden(fn) {
        \\  assert.throws(TypeError, function() { return fn.caller; });
        \\  assert.throws(TypeError, function() { return fn.arguments; });
        \\}
        \\function ordinarySloppy() {}
        \\assert.sameValue(ordinarySloppy.caller, undefined);
        \\assert.sameValue(ordinarySloppy.arguments, undefined);
        \\function strictFunction() { "use strict"; }
        \\assertForbidden(strictFunction);
        \\assertForbidden(() => {});
        \\assertForbidden(async () => {});
        \\assertForbidden(async function() {});
        \\assertForbidden(function*() {});
        \\assertForbidden(async function*() {});
        \\assertForbidden(({ method() {} }).method);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "Engine eval releases arrow destructuring iterator closures cleanly" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var doneCallCount = 0;
        \\var iter = {};
        \\iter[Symbol.iterator] = function() {
        \\  return {
        \\    next: function() { return { value: null, done: false }; },
        \\    return: function() { doneCallCount = doneCallCount + 1; return {}; }
        \\  };
        \\};
        \\var f = ([x]) => { print(doneCallCount); };
        \\f(iter);
    , &stream);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("1\n", stream.buffered());
}

test "Engine eval preserves one-shot object missing field host output semantics" {
    try helpers.expectPrints(
        \\let obj = { a: 1 };
        \\print(obj.b === undefined);
        \\let obj2 = { a: 1 };
        \\print(obj2.a === undefined);
        \\let oldPrint = print;
        \\print = function(x) { oldPrint("custom:" + x); };
        \\let obj3 = { a: 1 };
        \\print(obj3.b === undefined);
        \\print = oldPrint;
        \\{
        \\  let undefined = 1;
        \\  let obj4 = { a: 1 };
        \\  print(obj4.b === undefined);
        \\}
    , "true\nfalse\ncustom:true\nfalse\n");
}

test "Engine eval preserves local string substring host output semantics" {
    try helpers.expectPrints(
        \\let s = "abcdef";
        \\print(s.substring(4, 1));
        \\print(s.substring(2));
        \\print(s.substring());
        \\let oldSubstring = String.prototype.substring;
        \\String.prototype.substring = function(start, end) {
        \\  return "custom:" + this + ":" + start + ":" + end;
        \\};
        \\print(s.substring(4, 1));
        \\String.prototype.substring = oldSubstring;
    , "bcd\ncdef\nabcdef\ncustom:abcdef:4:1\n");
}

test "String prim_self leaf arms (lane K) agree with the legacy bodies on every miss shape" {
    // Hot shape (flat string, int32 index) runs the method_leaf arm; each
    // other shape must take the fallback and print exactly what the legacy
    // body prints: out-of-range, negative `at`, double-represented and
    // fractional indices, missing index, rope receivers (first read
    // linearizes, later reads hit the arm), String wrappers, surrogates.
    try helpers.expectPrints(
        \\const s = "abcdefgh";
        \\print(s.charCodeAt(2), s.charAt(2), s.at(2), s.codePointAt(2));
        \\print(s.charCodeAt(8), JSON.stringify(s.charAt(8)), s.at(8), s.codePointAt(8));
        \\print(s.at(-1), s.at(-8), s.at(-9), s.charCodeAt(-1), s.charAt(-1) === "");
        \\print(s.charCodeAt(3.0), s.charCodeAt(3.7), s.charCodeAt("4"), s.charCodeAt(), s.charAt(), s.at(), s.codePointAt());
        \\print(s.charCodeAt(NaN), s.charCodeAt(-0), s.charCodeAt(1e10), s.charCodeAt(true), s.charCodeAt(null));
        \\let rope = "";
        \\for (let i = 0; i < 40; i++) rope += "xy" + i;
        \\print(rope.charCodeAt(0), rope.charAt(1), rope.at(-1), rope.codePointAt(2), rope.charCodeAt(0));
        \\const wrapped = new String("wrap");
        \\print(wrapped.charCodeAt(1), wrapped.charAt(1), wrapped.at(-1), wrapped.codePointAt(0));
        \\const emoji = "a😀b";
        \\print(emoji.codePointAt(1), emoji.codePointAt(2), emoji.charCodeAt(1), emoji.charAt(1).length, emoji.at(-2).length);
        \\print("é".charAt(0) === "\u00e9", "\u4e2d".charAt(0) === "\u4e2d", "\u4e2d".at(0).length);
        \\print(String.prototype.charCodeAt.call(123, 0), String.prototype.charAt.call(true, 1));
        \\try { String.prototype.charCodeAt.call(Symbol(), 0); } catch (e) { print(e.name); }
        \\try { String.prototype.at.call(undefined, 0); } catch (e) { print(e.name); }
    ,
        \\99 c c 99
        \\NaN "" undefined undefined
        \\h a undefined NaN true
        \\100 100 101 97 a a 97
        \\97 97 NaN 98 97
        \\120 y 9 48 120
        \\114 r p 119
        \\128512 56832 55357 1 1
        \\true true 1
        \\49 r
        \\TypeError
        \\TypeError
        \\
    );
}

test "String index-read native records preserve primitive fast paths and observable coercion" {
    try helpers.expectPrints(
        \\let log = "";
        \\const receiver = { toString() { log += "s"; return "A😀Z"; } };
        \\const index = { valueOf() { log += "i"; return 1; } };
        \\print(String.prototype.charCodeAt.call(receiver, index));
        \\print(String.prototype.at.call(receiver, -1));
        \\print(String.prototype.codePointAt.call(receiver, index));
        \\print(log);
        \\for (const method of ["charCodeAt", "at", "codePointAt"]) {
        \\  try { String.prototype[method].call(null, 0); }
        \\  catch (error) { print(method, error.name); }
        \\  try { String.prototype[method].call("x", Symbol()); }
        \\  catch (error) { print(method + "-index", error.name); }
        \\}
        \\print(String.prototype.charCodeAt.call(42, 1));
    , "55357\nZ\n128512\nsissi\n" ++
        "charCodeAt TypeError\ncharCodeAt-index TypeError\n" ++
        "at TypeError\nat-index TypeError\n" ++
        "codePointAt TypeError\ncodePointAt-index TypeError\n50\n");
}

test "mod cold handler preserves fmod and ToNumeric fallbacks" {
    try helpers.expectPrints(
        \\const out = [];
        \\const show = value => Object.is(value, -0) ? "-0" : String(value);
        \\for (const pair of [[5.5, 2], [5, 2.5], [-4, 2], [4, -2],
        \\                       [1, 0], [Infinity, 2], [2, Infinity], [NaN, 2]]) {
        \\  out.push(show(pair[0] % pair[1]));
        \\}
        \\let log = "";
        \\const left = { valueOf() { log += "l"; return 8.5; } };
        \\const right = { valueOf() { log += "r"; return 3; } };
        \\out.push(show(left % right), log, String(12345678901234567890n % 97n));
        \\function* generator() { yield "pause"; return 9.5 % 2; }
        \\const iterator = generator();
        \\out.push(iterator.next().value, show(iterator.next().value));
        \\try { 1 % Symbol(); } catch (error) { out.push(error.name); }
        \\print(out.join("|"));
    , "1.5|0|-0|0|NaN|NaN|2|NaN|2.5|lr|3|pause|1.5|TypeError\n");
}

test "Engine eval preserves resolve-label peephole semantics" {
    try helpers.expectPrints(
        \\function probe(v, u) {
        \\  let x = 0;
        \\  let y;
        \\  y = (x = v);
        \\  const z = x && y && 9;
        \\  function fn() {}
        \\  function early() { return; print("dead"); }
        \\  early();
        \\  print([x, y, z, x === null, u === undefined,
        \\    typeof u === "undefined", typeof fn === "function",
        \\    typeof Math.abs === "function",
        \\    typeof new Proxy(fn, {}) === "function"].join(","));
        \\}
        \\probe(3, undefined);
    , "3,3,9,false,true,true,true,true,true\n");
}

test "resident is_null preserves qjs true and refcounted false legs" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const values = [null, undefined, false, true, 0, 1, 1.5, "", Symbol("s"), 1n, {}, [], function() {}];
        \\for (let i = 0; i < values.length; i++) {
        \\  assert.sameValue(values[i] === null, i === 0);
        \\}
        \\for (let i = 0; i < 1000; i++) {
        \\  assert.sameValue(({ index: i }) === null, false);
        \\}
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "Engine generator return keeps finally rethrow control marker" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var obj = { foo: "not modified" };
        \\function* g() {
        \\  try { obj.foo = yield; }
        \\  finally { return 1; }
        \\}
        \\var iter = g();
        \\iter.next();
        \\var resumed = iter.return(45);
        \\assert.sameValue(obj.foo, "not modified");
        \\assert.sameValue(resumed.value, 1);
        \\assert.sameValue(resumed.done, true);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "generator return runs nested finally before closing its for-of iterator" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const events = [];
        \\let step = 0;
        \\const iterator = {
        \\  [Symbol.iterator]() { return this; },
        \\  next() { return step++ === 0 ? { value: 1, done: false } : { done: true }; },
        \\  return() { events.push("return"); return { done: true }; },
        \\};
        \\function* values() {
        \\  for (const value of iterator) {
        \\    try {
        \\      yield value;
        \\    } finally {
        \\      events.push("cleanup");
        \\    }
        \\  }
        \\}
        \\const generator = values();
        \\const first = generator.next();
        \\assert.sameValue(first.value, 1);
        \\assert.sameValue(first.done, false);
        \\const returned = generator.return(9);
        \\assert.sameValue(events.join(","), "cleanup,return");
        \\assert.sameValue(returned.value, 9);
        \\assert.sameValue(returned.done, true);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "return cleanup restores outer catch targets before finally and IteratorClose throws" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\let finallyCount = 0;
        \\function catchReturnFinallyThrow() {
        \\  try {
        \\    throw "try";
        \\  } catch (error) {
        \\    return "catch";
        \\  } finally {
        \\    finallyCount++;
        \\    throw "finally";
        \\  }
        \\}
        \\let caught;
        \\try { catchReturnFinallyThrow(); } catch (error) { caught = error; }
        \\assert.sameValue(caught, "finally");
        \\assert.sameValue(finallyCount, 1);
        \\function nestedReturn() {
        \\  try {
        \\    return 42;
        \\  } finally {
        \\    try {
        \\      try { return 43; } finally { throw 9; }
        \\    } catch (error) {}
        \\  }
        \\}
        \\assert.sameValue(nestedReturn(), 42);
        \\let returnCalled = 0;
        \\let innerCatchEntered = 0;
        \\let innerFinallyEntered = 0;
        \\const iterable = {
        \\  [Symbol.iterator]() {
        \\    return {
        \\      next() { return { done: false }; },
        \\      return() { returnCalled++; throw 42; },
        \\    };
        \\  },
        \\};
        \\function closeOnReturn() {
        \\  for (const value of iterable) {
        \\    try { return; }
        \\    catch (error) { innerCatchEntered++; }
        \\    finally { innerFinallyEntered++; }
        \\  }
        \\}
        \\caught = undefined;
        \\try { closeOnReturn(); } catch (error) { caught = error; }
        \\assert.sameValue(caught, 42);
        \\assert.sameValue(returnCalled, 1);
        \\assert.sameValue(innerCatchEntered, 0);
        \\assert.sameValue(innerFinallyEntered, 1);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "generator return crosses catch markers before closing its for-of iterator" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const events = [];
        \\let step = 0;
        \\const iterator = {
        \\  [Symbol.iterator]() { return this; },
        \\  next() { return { value: ++step, done: false }; },
        \\  return() { events.push("return"); return { done: true }; },
        \\};
        \\function* oneCatch() {
        \\  for (const value of iterator) {
        \\    try { yield value; } catch (error) {}
        \\  }
        \\}
        \\const first = oneCatch();
        \\first.next();
        \\const firstReturn = first.return(9);
        \\assert.sameValue(firstReturn.value, 9);
        \\assert.sameValue(firstReturn.done, true);
        \\assert.sameValue(events.join(","), "return");
        \\events.length = 0;
        \\function* twoCatches() {
        \\  for (const value of iterator) {
        \\    try { try { yield value; } catch (error) {} } catch (error) {}
        \\  }
        \\}
        \\const second = twoCatches();
        \\second.next();
        \\const secondReturn = second.return(10);
        \\assert.sameValue(secondReturn.value, 10);
        \\assert.sameValue(secondReturn.done, true);
        \\assert.sameValue(events.join(","), "return");
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "generator return closes an inner for-of iterator before its enclosing finally" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const events = [];
        \\let step = 0;
        \\const iterator = {
        \\  [Symbol.iterator]() { return this; },
        \\  next() { return { value: ++step, done: false }; },
        \\  return() { events.push("return"); return { done: true }; },
        \\};
        \\function* values() {
        \\  try {
        \\    for (const value of iterator) yield value;
        \\  } finally {
        \\    events.push("finally");
        \\  }
        \\}
        \\const generator = values();
        \\generator.next();
        \\const returned = generator.return(9);
        \\assert.sameValue(events.join(","), "return,finally");
        \\assert.sameValue(returned.value, 9);
        \\assert.sameValue(returned.done, true);
        \\events.length = 0;
        \\const patternIterator = {
        \\  [Symbol.iterator]() { return this; },
        \\  next() { return { value: undefined, done: false }; },
        \\  return() { events.push("pattern-return"); return { done: true }; },
        \\};
        \\function* patternValue() {
        \\  try {
        \\    const [value = yield 1] = patternIterator;
        \\  } finally {
        \\    events.push("pattern-finally");
        \\  }
        \\}
        \\const patternGenerator = patternValue();
        \\patternGenerator.next();
        \\const patternReturned = patternGenerator.return(10);
        \\assert.sameValue(events.join(","), "pattern-return,pattern-finally");
        \\assert.sameValue(patternReturned.value, 10);
        \\assert.sameValue(patternReturned.done, true);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "destructuring rest parameter defaults use the parameter environment" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\let binding = "outer";
        \\function value(...[get = () => binding]) {
        \\  var binding = "body";
        \\  return get();
        \\}
        \\assert.sameValue(value(), "outer");
        \\function objectValue(...{ 0: get = () => binding }) {
        \\  var binding = "body";
        \\  return get();
        \\}
        \\assert.sameValue(objectValue(), "outer");
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "caught destructuring error preserves IteratorClose output" {
    try helpers.expectPrints(
        \\const iterator = {
        \\  [Symbol.iterator]() { return this; },
        \\  next() { return { value: undefined, done: false }; },
        \\  return() { print("CLOSED"); return { done: true }; },
        \\};
        \\try { let [value = missingName] = iterator; } catch (error) {}
        \\print("END");
    , "CLOSED\nEND\n");
}

test "generator parameter eval cells close before body resume" {
    try helpers.expectPrints(
        \\var x = 'outside';
        \\var first, second, body;
        \\function* g(
        \\  _ = (eval('var x = "inside";'), first = function() { return x; }),
        \\  __ = second = function() { return x; }
        \\) { body = function() { return x; }; }
        \\g().next();
        \\var y = 'outside';
        \\var restParam, restBody;
        \\function* h(...[_ = (eval('var y = "inside";'), restParam = function() { return y; })]) {
        \\  restBody = function() { return y; };
        \\}
        \\h().next();
        \\print(first(), second(), body(), restParam(), restBody());
    , "inside inside inside inside inside\n");
}

test "generator return executes an add_loc-terminated shared finally before completing" {

    // The pending completion and gosub return PC now live on the resident
    // operand stack. An add_loc-terminated finalizer must reach `ret`, resume
    // the compiled return leg and never execute the post-finalizer body.

    try helpers.expectPrints(
        \\function* g() {
        \\  var s = 0;
        \\  try { yield 1; } finally { s += 1; }
        \\  s += 100;
        \\  yield s;
        \\}
        \\var it = g();
        \\var first = it.next();
        \\var second = it.return(42);
        \\var third = it.next();
        \\print(first.value, first.done, second.value, second.done, third.value, third.done);
    , "1 false 42 true undefined true\n");
}

test "generator default argument stores release refcounted stack values" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\var f = function*(x = arguments[2], y = arguments[3], z) {};
        \\f(undefined, undefined, 'third', 'fourth').next();
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "spread super brands derived instances before class field initializers" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    // Regression: super(...args) compiles to op.apply is_new=1. The lexical
    // `<class_fields_init>` call must run after that path just as after direct
    // super(), so `this.#m()` sees the installed brand.
    const result = try js.evalWithOptions(
        \\(function () {
        \\  class A { constructor(a, b) { this.s = (a | 0) + (b | 0); } }
        \\  class B extends A {
        \\    #m() { return this.s + 7; }
        \\    v = this.#m();
        \\    constructor(...args) { super(...args); }
        \\  }
        \\  return new B(1, 2).v;
        \\})();
    ,
        .{ .filename = "<repl>" },
    );

    try std.testing.expectEqual(@as(?i32, 10), result.as(.int));
}

test "computed class keys close over runtime private field identity" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\let probe;
        \\class Box {
        \\  #value;
        \\  [probe = (candidate => #value in candidate)] = 0;
        \\}
        \\const box = new Box();
        \\assert.sameValue(probe(box), true, "computed-key closure recognizes the private field");
        \\assert.sameValue(probe({}), false, "computed-key closure rejects an unrelated object");
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "nested same-name private fields isolate repeated class evaluations" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function makePair(outerInitial, innerInitial) {
        \\  let outerProbe;
        \\  class Outer {
        \\    #value = outerInitial;
        \\    [outerProbe = (candidate => #value in candidate)] = 0;
        \\    read() { return this.#value; }
        \\    makeInner() {
        \\      let innerProbe;
        \\      class Inner {
        \\        #value = innerInitial;
        \\        [innerProbe = (candidate => #value in candidate)] = 0;
        \\        read() { return this.#value; }
        \\      }
        \\      return { value: new Inner(), probe: innerProbe };
        \\    }
        \\  }
        \\  const outer = new Outer();
        \\  const inner = outer.makeInner();
        \\  return { outer, inner: inner.value, outerProbe, innerProbe: inner.probe };
        \\}
        \\const first = makePair(11, 101);
        \\const second = makePair(22, 202);
        \\assert.sameValue(first.outer.read(), 11);
        \\assert.sameValue(first.inner.read(), 101);
        \\assert.sameValue(second.outer.read(), 22);
        \\assert.sameValue(second.inner.read(), 202);
        \\assert.sameValue(first.outerProbe(first.outer), true);
        \\assert.sameValue(first.outerProbe(first.inner), false);
        \\assert.sameValue(first.outerProbe(second.outer), false);
        \\assert.sameValue(first.innerProbe(first.inner), true);
        \\assert.sameValue(first.innerProbe(first.outer), false);
        \\assert.sameValue(first.innerProbe(second.inner), false);
        \\assert.sameValue(second.outerProbe(second.outer), true);
        \\assert.sameValue(second.innerProbe(second.inner), true);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "private fields isolate class evaluations and preserve lexical call and eval semantics" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\globalThis.__execPrivateFieldRegression = (function () {
        \\  function makePrivateBox(instanceInitial, staticInitial) {
        \\    return class PrivateBox {
        \\      #instanceValue = instanceInitial;
        \\      #callable = function () { return this; };
        \\      static #staticValue = staticInitial;
        \\
        \\      read() { return this.#instanceValue; }
        \\      write(value) {
        \\        this.#instanceValue = value;
        \\        return this.#instanceValue;
        \\      }
        \\      static readInstance(value) { return value.#instanceValue; }
        \\      static hasInstance(value) { return #instanceValue in value; }
        \\
        \\      static readStatic() { return this.#staticValue; }
        \\      static writeStatic(value) {
        \\        this.#staticValue = value;
        \\        return this.#staticValue;
        \\      }
        \\      static hasStatic(value) { return #staticValue in value; }
        \\
        \\      readFromArrow() { return (() => this.#instanceValue)(); }
        \\      readFromInnerFunction() {
        \\        const receiver = this;
        \\        return function () { return receiver.#instanceValue; }();
        \\      }
        \\      callStoredFunction() { return this.#callable(); }
        \\      readFromDirectEval() { return eval("this.#instanceValue"); }
        \\      writeFromDirectEval(value) {
        \\        return eval("this.#instanceValue = value");
        \\      }
        \\    };
        \\  }
        \\
        \\  const First = makePrivateBox(11, 101);
        \\  const Second = makePrivateBox(22, 202);
        \\  return { First, Second, first: new First(), second: new Second() };
        \\})();
    );

    _ = try js.eval(
        \\(function ({ First, Second, first, second }) {
        \\  assert.sameValue(
        \\    First.hasInstance(first),
        \\    true,
        \\    "first factory evaluation recognizes its instance private field"
        \\  );
        \\  assert.sameValue(
        \\    First.hasInstance(second),
        \\    false,
        \\    "first factory evaluation does not recognize the second private identity"
        \\  );
        \\  assert.sameValue(
        \\    Second.hasInstance(first),
        \\    false,
        \\    "second factory evaluation does not recognize the first private identity"
        \\  );
        \\  assert.sameValue(
        \\    Second.hasInstance(second),
        \\    true,
        \\    "second factory evaluation recognizes its instance private field"
        \\  );
        \\  assert.throws(
        \\    TypeError,
        \\    function () { First.readInstance(second); },
        \\    "cross-factory instance private reads fail their brand check"
        \\  );
        \\})(__execPrivateFieldRegression);
    );

    _ = try js.eval(
        \\(function ({ First, Second, first }) {
        \\  assert.sameValue(first.read(), 11, "instance private field read");
        \\  assert.sameValue(first.write(12), 12, "instance private field write result");
        \\  assert.sameValue(first.read(), 12, "instance private field write persists");
        \\  assert.sameValue(First.hasStatic(First), true, "static private field #in on owner");
        \\  assert.sameValue(First.hasStatic(Second), false, "static private field #in rejects peer class");
        \\  assert.sameValue(Second.hasStatic(First), false, "peer static private identity is isolated");
        \\  assert.sameValue(Second.hasStatic(Second), true, "peer static private field #in on owner");
        \\  assert.sameValue(First.readStatic(), 101, "static private field read");
        \\  assert.sameValue(First.writeStatic(303), 303, "static private field write result");
        \\  assert.sameValue(First.readStatic(), 303, "static private field write persists");
        \\  assert.sameValue(Second.readStatic(), 202, "peer static private field remains independent");
        \\})(__execPrivateFieldRegression);
    );

    _ = try js.eval(
        \\(function ({ first }) {
        \\  assert.sameValue(first.readFromArrow(), 12, "nested arrow captures private environment");
        \\  assert.sameValue(
        \\    first.readFromInnerFunction(),
        \\    12,
        \\    "nested ordinary function captures private environment"
        \\  );
        \\})(__execPrivateFieldRegression);
    );

    _ = try js.eval(
        \\(function ({ first }) {
        \\  assert.sameValue(
        \\    first.callStoredFunction(),
        \\    first,
        \\    "calling a function stored in a private field preserves the instance receiver"
        \\  );
        \\})(__execPrivateFieldRegression);
    );

    _ = try js.eval(
        \\(function ({ first }) {
        \\  assert.sameValue(first.readFromDirectEval(), 12, "direct eval reads the enclosing private name");
        \\  assert.sameValue(
        \\    first.writeFromDirectEval(44),
        \\    44,
        \\    "direct eval writes the enclosing private name"
        \\  );
        \\  assert.sameValue(first.read(), 44, "direct eval private write persists");
        \\})(__execPrivateFieldRegression);
    );
}

test "private method brands use lexical initializers on every constructor path" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\class ExplicitBase {
        \\  #method() { return 1; }
        \\  constructor() {}
        \\  read() { return this.#method(); }
        \\  hasBrand() { return #method in this; }
        \\}
        \\class Parent {}
        \\class DirectDerived extends Parent {
        \\  #method() { return 2; }
        \\  constructor() { super(); }
        \\  read() { return this.#method(); }
        \\  hasBrand() { return #method in this; }
        \\}
        \\class SpreadDerived extends Parent {
        \\  #method() { return 3; }
        \\  constructor(...args) { super(...args); }
        \\  read() { return this.#method(); }
        \\  hasBrand() { return #method in this; }
        \\}
        \\class DefaultDerived extends Parent {
        \\  #method() { return 4; }
        \\  read() { return this.#method(); }
        \\  hasBrand() { return #method in this; }
        \\}
        \\globalThis.__privateMethodExplicitBase = new ExplicitBase();
        \\globalThis.__privateMethodDirectDerived = new DirectDerived();
        \\globalThis.__privateMethodSpreadDerived = new SpreadDerived();
        \\globalThis.__privateMethodDefaultDerived = new DefaultDerived();
        \\assert.sameValue(__privateMethodExplicitBase.read(), 1);
        \\assert.sameValue(__privateMethodExplicitBase.hasBrand(), true);
        \\assert.sameValue(__privateMethodDirectDerived.read(), 2);
        \\assert.sameValue(__privateMethodDirectDerived.hasBrand(), true);
        \\assert.sameValue(__privateMethodSpreadDerived.read(), 3);
        \\assert.sameValue(__privateMethodSpreadDerived.hasBrand(), true);
        \\assert.sameValue(__privateMethodDefaultDerived.read(), 4);
        \\assert.sameValue(__privateMethodDefaultDerived.hasBrand(), true);
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const instance_names = [_][]const u8{
        "__privateMethodExplicitBase",
        "__privateMethodDirectDerived",
        "__privateMethodSpreadDerived",
        "__privateMethodDefaultDerived",
    };
    for (instance_names) |name| {
        const atom = try js.runtime.internAtom(name);
        const value = try global.getProperty(atom);
        const instance = try core.Object.expect(value);
        try std.testing.expect(!instance.hasOwnProperty(core.atom.ids.Private_brand));
    }
}

test "private methods and accessors preserve brands captures and readonly semantics" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\globalThis.__execPrivateMethodAccessorRegression = (function () {
        \\  function makePrivateMembers(instanceInitial, staticInitial) {
        \\    return class PrivateMembers {
        \\      #value = instanceInitial;
        \\      static #staticValue = staticInitial;
        \\
        \\      #method(delta) { return this.#value + delta; }
        \\      get #getterOnly() { return this.#value; }
        \\      set #setterOnly(value) { this.#value = value; }
        \\      get #getset() { return this.#value; }
        \\      set #getset(value) { this.#value = value; }
        \\
        \\      static #staticMethod(delta) { return this.#staticValue + delta; }
        \\      static get #staticGetterOnly() { return this.#staticValue; }
        \\      static set #staticSetterOnly(value) { this.#staticValue = value; }
        \\      static get #staticGetset() { return this.#staticValue; }
        \\      static set #staticGetset(value) { this.#staticValue = value; }
        \\
        \\      callMethod(delta) { return this.#method(delta); }
        \\      readGetterOnly() { return this.#getterOnly; }
        \\      writeSetterOnly(value) { this.#setterOnly = value; }
        \\      readSetterOnly() { return this.#setterOnly; }
        \\      readGetset() { return this.#getset; }
        \\      writeGetset(value) { this.#getset = value; }
        \\      overwriteMethod(value) { this.#method = value; }
        \\      overwriteGetterOnly(value) { this.#getterOnly = value; }
        \\
        \\      static callInstanceMethod(value, delta) { return value.#method(delta); }
        \\      static readInstanceGetter(value) { return value.#getterOnly; }
        \\      static writeInstanceSetter(value, next) { value.#setterOnly = next; }
        \\      static hasInstanceMethod(value) { return #method in value; }
        \\      static hasInstanceGetter(value) { return #getterOnly in value; }
        \\
        \\      static callStaticMethod(delta) { return this.#staticMethod(delta); }
        \\      static readStaticGetterOnly() { return this.#staticGetterOnly; }
        \\      static writeStaticSetterOnly(value) { this.#staticSetterOnly = value; }
        \\      static readStaticSetterOnly() { return this.#staticSetterOnly; }
        \\      static readStaticGetset() { return this.#staticGetset; }
        \\      static writeStaticGetset(value) { this.#staticGetset = value; }
        \\      static overwriteStaticMethod(value) { this.#staticMethod = value; }
        \\      static overwriteStaticGetterOnly(value) { this.#staticGetterOnly = value; }
        \\      static hasStaticMethod(value) { return #staticMethod in value; }
        \\      static hasStaticGetter(value) { return #staticGetterOnly in value; }
        \\
        \\      makeMethodArrow() { return delta => this.#method(delta); }
        \\      makeGetterInnerFunction() {
        \\        const receiver = this;
        \\        return function () { return receiver.#getterOnly; };
        \\      }
        \\    };
        \\  }
        \\
        \\  const First = makePrivateMembers(10, 100);
        \\  const Second = makePrivateMembers(20, 200);
        \\  return { First, Second, first: new First(), second: new Second() };
        \\})();
    );

    _ = try js.eval(
        \\(function ({ First, Second, first, second }) {
        \\  assert.sameValue(First.hasInstanceMethod(first), true, "instance private method #in on owner");
        \\  assert.sameValue(
        \\    First.hasInstanceMethod(second),
        \\    false,
        \\    "same factory source creates a fresh instance method brand per evaluation"
        \\  );
        \\  assert.sameValue(
        \\    Second.hasInstanceMethod(first),
        \\    false,
        \\    "peer factory evaluation rejects the first instance method brand"
        \\  );
        \\  assert.sameValue(Second.hasInstanceMethod(second), true, "peer instance method #in on owner");
        \\  assert.sameValue(First.hasInstanceGetter(first), true, "instance private accessor #in on owner");
        \\  assert.sameValue(
        \\    First.hasInstanceGetter(second),
        \\    false,
        \\    "instance private accessor identity is isolated across factory evaluations"
        \\  );
        \\  assert.sameValue(First.hasStaticMethod(First), true, "static private method #in on owner");
        \\  assert.sameValue(
        \\    First.hasStaticMethod(Second),
        \\    false,
        \\    "static private method identity is isolated across factory evaluations"
        \\  );
        \\  assert.sameValue(Second.hasStaticMethod(First), false, "peer static method brand rejects owner");
        \\  assert.sameValue(Second.hasStaticMethod(Second), true, "peer static private method #in on owner");
        \\  assert.sameValue(First.hasStaticGetter(First), true, "static private accessor #in on owner");
        \\  assert.sameValue(
        \\    First.hasStaticGetter(Second),
        \\    false,
        \\    "static private accessor identity is isolated across factory evaluations"
        \\  );
        \\})(__execPrivateMethodAccessorRegression);
    );

    _ = try js.eval(
        \\(function ({ First, Second, first, second }) {
        \\  assert.sameValue(first.callMethod(1), 11, "instance private method call");
        \\  assert.sameValue(first.readGetterOnly(), 10, "getter-only private accessor read");
        \\  first.writeSetterOnly(12);
        \\  assert.sameValue(first.readGetterOnly(), 12, "setter-only private accessor write");
        \\  assert.throws(
        \\    TypeError,
        \\    function () { first.readSetterOnly(); },
        \\    "reading a setter-only private accessor throws"
        \\  );
        \\  first.writeGetset(14);
        \\  assert.sameValue(first.readGetset(), 14, "paired private accessor read after write");
        \\  assert.sameValue(second.callMethod(1), 21, "peer instance method retains independent state");
        \\  assert.sameValue(Second.readInstanceGetter(second), 20, "peer private getter remains independent");
        \\  First.writeInstanceSetter(first, 16);
        \\  assert.sameValue(first.readGetterOnly(), 16, "static wrapper can write its matching private setter");
        \\})(__execPrivateMethodAccessorRegression);
    );

    _ = try js.eval(
        \\(function ({ First, Second }) {
        \\  assert.sameValue(First.callStaticMethod(1), 101, "static private method call");
        \\  assert.sameValue(First.readStaticGetterOnly(), 100, "static getter-only private accessor read");
        \\  First.writeStaticSetterOnly(120);
        \\  assert.sameValue(
        \\    First.readStaticGetterOnly(),
        \\    120,
        \\    "static setter-only private accessor write"
        \\  );
        \\  assert.throws(
        \\    TypeError,
        \\    function () { First.readStaticSetterOnly(); },
        \\    "reading a static setter-only private accessor throws"
        \\  );
        \\  First.writeStaticGetset(140);
        \\  assert.sameValue(First.readStaticGetset(), 140, "paired static private accessor read after write");
        \\  assert.sameValue(Second.callStaticMethod(1), 201, "peer static method retains independent state");
        \\  assert.sameValue(Second.readStaticGetterOnly(), 200, "peer static getter remains independent");
        \\})(__execPrivateMethodAccessorRegression);
    );

    _ = try js.eval(
        \\(function ({ first, second }) {
        \\  const methodArrow = first.makeMethodArrow();
        \\  const getterInnerFunction = first.makeGetterInnerFunction();
        \\  assert.sameValue(methodArrow.call(second, 2), 18, "nested arrow captures receiver and private method");
        \\  assert.sameValue(
        \\    getterInnerFunction.call(second),
        \\    16,
        \\    "nested ordinary function captures the private accessor environment"
        \\  );
        \\})(__execPrivateMethodAccessorRegression);
    );

    _ = try js.eval(
        \\(function ({ First, Second, second }) {
        \\  assert.throws(
        \\    TypeError,
        \\    function () { First.callInstanceMethod(second, 1); },
        \\    "instance private method rejects a peer factory brand"
        \\  );
        \\  assert.throws(
        \\    TypeError,
        \\    function () { First.readInstanceGetter(second); },
        \\    "instance private accessor rejects a peer factory brand"
        \\  );
        \\  assert.throws(
        \\    TypeError,
        \\    function () { First.writeInstanceSetter(second, 1); },
        \\    "instance private setter rejects a peer factory brand"
        \\  );
        \\  assert.throws(
        \\    TypeError,
        \\    function () { First.callStaticMethod.call(Second, 1); },
        \\    "static private method rejects a peer class receiver"
        \\  );
        \\  assert.throws(
        \\    TypeError,
        \\    function () { First.readStaticGetterOnly.call(Second); },
        \\    "static private accessor rejects a peer class receiver"
        \\  );
        \\})(__execPrivateMethodAccessorRegression);
    );

    _ = try js.eval(
        \\(function ({ First, first }) {
        \\  assert.throws(
        \\    TypeError,
        \\    function () { first.overwriteMethod(0); },
        \\    "instance private methods are readonly"
        \\  );
        \\  assert.throws(
        \\    TypeError,
        \\    function () { first.overwriteGetterOnly(0); },
        \\    "getter-only instance private accessors reject writes"
        \\  );
        \\  assert.throws(
        \\    TypeError,
        \\    function () { First.overwriteStaticMethod(0); },
        \\    "static private methods are readonly"
        \\  );
        \\  assert.throws(
        \\    TypeError,
        \\    function () { First.overwriteStaticGetterOnly(0); },
        \\    "getter-only static private accessors reject writes"
        \\  );
        \\  assert.sameValue(first.callMethod(1), 17, "failed method overwrite leaves method intact");
        \\  assert.sameValue(first.readGetterOnly(), 16, "failed getter overwrite leaves accessor intact");
        \\  assert.sameValue(First.callStaticMethod(1), 141, "failed static method overwrite leaves method intact");
        \\  assert.sameValue(
        \\    First.readStaticGetterOnly(),
        \\    140,
        \\    "failed static getter overwrite leaves accessor intact"
        \\  );
        \\})(__execPrivateMethodAccessorRegression);
    );
}

test "started generator resumes preserve unmapped arguments from parked locals" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function* strictGenerator(value) {
        \\  "use strict";
        \\  const first = arguments;
        \\  value = 17;
        \\  yield;
        \\  const shorthand = { arguments };
        \\  assert.sameValue(shorthand.arguments, first);
        \\  assert.sameValue(shorthand.arguments[0], 1);
        \\  yield;
        \\  assert.sameValue(arguments, first);
        \\  assert.sameValue(arguments[0], 1);
        \\}
        \\const strictIterator = strictGenerator(1);
        \\strictIterator.next();
        \\strictIterator.next();
        \\strictIterator.next();
        \\function* defaultGenerator(value = 3) {
        \\  const first = eval("arguments");
        \\  value = 19;
        \\  yield;
        \\  assert.sameValue(eval("arguments"), first);
        \\  assert.sameValue(eval("arguments")[0], 2);
        \\}
        \\const defaultIterator = defaultGenerator(2);
        \\defaultIterator.next();
        \\defaultIterator.next();
        \\function* restGenerator(...values) {
        \\  const first = arguments;
        \\  values[0] = 23;
        \\  yield;
        \\  assert.sameValue(arguments, first);
        \\  assert.sameValue(arguments[0], 4);
        \\}
        \\const restIterator = restGenerator(4);
        \\restIterator.next();
        \\restIterator.next();
        \\function* lateArguments(first) {
        \\  yield;
        \\  assert.sameValue(arguments.length, 3);
        \\  assert.sameValue(arguments[0], 5);
        \\  assert.sameValue(arguments[2], 7);
        \\}
        \\const lateIterator = lateArguments(5, 6, 7);
        \\lateIterator.next();
        \\lateIterator.next();
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "array named proto field uses ordinary lookup; length and index stay exotic" {
    // qjs GET_FIELD_INLINE: Array exotic is index +
    // length. A named atom such as `push` must resolve on Array.prototype
    // without changing `length` or dense-element reads.
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\const a = [7];
        \\assert.sameValue(a.push, Array.prototype.push);
        \\assert.sameValue(a.noSuchNamed, undefined);
        \\assert.sameValue(a.length, 1);
        \\assert.sameValue(a[0], 7);
        \\const mid = Object.create(Array.prototype);
        \\const b = [];
        \\Object.setPrototypeOf(b, mid);
        \\assert.sameValue(b.pop, Array.prototype.pop);
        \\assert.sameValue(b.length, 0);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "iterator results use ordinary transitions without a sixth realm shape" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);

    try std.testing.expect(!@hasField(core.RealmContext, "iterator_result_shape"));

    _ = try engine.exec.iterator_ops.createIteratorResult(js.runtime, global, core.JSValue.int32(1), false);
    const alloc_calls = js.runtime.allocation_diagnostics.alloc_calls;
    const create_calls = js.runtime.allocation_diagnostics.create_calls;
    const result = try engine.exec.iterator_ops.createIteratorResult(js.runtime, global, core.JSValue.int32(2), true);

    // QuickJS's js_create_iterator_result performs the ordinary `value` then
    // `done` transitions. With no realm-pinned iterator layout, zjs likewise
    // creates the object and the transient one-property Shape. The exact
    // two-slot property payload now trails the Object, so there is no second
    // general `alloc` call for the value array.
    try std.testing.expectEqual(alloc_calls, js.runtime.allocation_diagnostics.alloc_calls);
    try std.testing.expectEqual(create_calls + 2, js.runtime.allocation_diagnostics.create_calls);
    const object = try core.Object.expect(result);
    try std.testing.expectEqual(@as(?i32, 2), object.asDataAt(0).?.as(.int));
    try std.testing.expect(object.asDataAt(1).?.as(.boolean).?);
}

test "bytecode closures reuse the final function-prototype shape" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.evalWithOptions(
        "(function () { function make() { return function () {}; } return [make(), make()]; })()",
        .{ .filename = "<repl>" },
    );
    const functions = try core.Object.expect(result);
    const first_value = try functions.getProperty(core.Atom.taggedInt(0));
    const second_value = try functions.getProperty(core.Atom.taggedInt(1));
    const first = try core.Object.expect(first_value);
    const second = try core.Object.expect(second_value);
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);

    try std.testing.expectEqual(first.getPrototype(), second.getPrototype());
    try std.testing.expectEqual(first.shape_ref, second.shape_ref);
    try std.testing.expectEqual(global, first.bytecodeFunctionRealmGlobalPtr().?);
    try std.testing.expectEqual(global, second.bytecodeFunctionRealmGlobalPtr().?);
    try std.testing.expect(!first.flags.is_borrowed_reference_holder);
    try std.testing.expect(!second.flags.is_borrowed_reference_holder);
}

test "escaped closure keeps its compile realm after facade destruction" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const compile_facade = try zjs.JSContext.create(rt, .{});
    var compile_facade_alive = true;
    defer if (compile_facade_alive) compile_facade.destroy();
    const compile_realm = compile_facade.core;
    const compile_global = try zjs.globalObjectPtr(compile_facade);
    var parsed = try engine.parser.compile(
        .{ .realm = compile_realm },
        "(function escaped() { return this; })",
        .{ .mode = .script, .filename = "escaped-realm.js", .return_completion = true },
    );
    var parsed_alive = true;
    defer if (parsed_alive) parsed.deinit();

    // The public facade releases its initial RealmRef before any bytecode is
    // executed. The canonical root and child FBs are now the only realm owners.
    compile_facade.destroy();
    compile_facade_alive = false;

    const caller = try zjs.JSContext.create(rt, .{});
    defer caller.destroy();
    const root_function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    var stack = engine.exec.stack.Stack.init(rt, caller.core.stackLimit());
    defer stack.deinit(rt);
    const escaped = try engine.exec.zjs_vm.runWithOutput(caller.core, &stack, root_function, null);
    var escaped_alive = true;

    // Drop the root FB and its cpool edge. The escaped closure's child FB must
    // still own the compile realm independently.
    parsed.deinit();
    parsed_alive = false;
    const result = try caller.callFunction(escaped, &.{}, .{});
    try std.testing.expectEqual(compile_global, try core.Object.expect(result));

    escaped_alive = false;
    _ = try rt.collectForTest();
    try std.testing.expect(rt.contexts.forGlobal(compile_global, .include_constructing) == null);
}

test "standard constructors publish realm class prototype slots" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const Expected = struct {
        name: []const u8,
        class_id: core.ClassId,
    };
    const expected = [_]Expected{
        .{ .name = "Object", .class_id = core.class.ids.object },
        .{ .name = "Function", .class_id = core.class.ids.bytecode_function },
        .{ .name = "Array", .class_id = core.class.ids.array },
        .{ .name = "Number", .class_id = core.class.ids.number },
        .{ .name = "Boolean", .class_id = core.class.ids.boolean },
        .{ .name = "RegExp", .class_id = core.class.ids.regexp },
        .{ .name = "Iterator", .class_id = core.class.ids.iterator },
        .{ .name = "Map", .class_id = core.class.ids.map },
        .{ .name = "Set", .class_id = core.class.ids.set },
        .{ .name = "WeakMap", .class_id = core.class.ids.weakmap },
        .{ .name = "WeakSet", .class_id = core.class.ids.weakset },
        .{ .name = "Promise", .class_id = core.class.ids.promise },
        .{ .name = "ArrayBuffer", .class_id = core.class.ids.array_buffer },
        .{ .name = "Uint8Array", .class_id = core.class.ids.uint8_array },
        .{ .name = "DataView", .class_id = core.class.ids.dataview },
    };

    for (expected) |item| {
        const key = try js.runtime.internAtom(item.name);
        const constructor = global.getOwnDataObjectBorrowed(key) orelse return error.TestUnexpectedResult;
        const prototype = constructor.getOwnDataObjectBorrowed(core.atom.ids.prototype) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(prototype, js.context.classPrototypeObject(item.class_id).?);
    }
}

test "FunctionRealm query separates owned carriers from caller-semantics classes" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    _ = try js.eval(
        \\(function () {
        \\    var other = $262.createRealm().global;
        \\    other.eval("globalThis.bytecodeCarrier = function () {};");
        \\    var data = Proxy.revocable(function () {}, {});
        \\    var revoked = Proxy.revocable(other.Math.max, {});
        \\    revoked.revoke();
        \\    globalThis.__functionRealmCarriers = [
        \\        other.Math.max,
        \\        other.bytecodeCarrier,
        \\        other.Math.max.bind(null),
        \\        new Proxy(other.Math.max, {}),
        \\        data.revoke,
        \\        revoked.proxy,
        \\        {}
        \\    ];
        \\})()
    );
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const carriers_atom = try js.runtime.internAtom("__functionRealmCarriers");
    const carriers = try global.getProperty(carriers_atom);
    const carrier_array = try core.Object.expect(carriers);
    var values: [7]core.JSValue = undefined;
    for (&values, 0..) |*slot, index| slot.* = try carrier_array.getProperty(core.Atom.taggedInt(@intCast(index)));

    const native = try core.Object.expect(values[0]);
    const remote_realm = native.nativeFunctionRealm() orelse return error.TestUnexpectedResult;
    try std.testing.expect(remote_realm != js.context);
    for (values[0..4]) |value| {
        try std.testing.expectEqual(remote_realm, try engine.exec.call_runtime.functionRealmContext(js.context, value));
    }
    try std.testing.expectEqual(js.context, try engine.exec.call_runtime.functionRealmContext(js.context, values[4]));
    try std.testing.expectEqual(js.context, try engine.exec.call_runtime.functionRealmContext(js.context, values[6]));

    try std.testing.expectError(error.TypeError, engine.exec.call_runtime.functionRealmContext(js.context, values[5]));
    try std.testing.expect(js.context.hasException());
    js.context.clearException();
}

test "async resume callbacks remain callable and nonconstructible to all consumers" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    try js.ensureTest262GlobalsInstalled();
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const key = try js.runtime.internAtom("internalResumeCallback");
    for ([_]bool{ false, true }) |rejected| {
        const continuation = try core.Object.create(js.runtime, core.class.ids.object, null);
        const callback = try engine.exec.promise_ops.asyncFunctionResumeCallback(js.runtime, global, continuation, rejected);
        try global.defineOwnProperty(js.runtime, key, core.Descriptor.data(callback, .all));
        _ = try js.eval(
            \\assert.sameValue(typeof internalResumeCallback, 'function');
            \\assert.sameValue(Object.prototype.toString.call(internalResumeCallback), '[object Function]');
            \\assert(Function.prototype.toString.call(internalResumeCallback).includes('[native code]'));
            \\assert.sameValue(JSON.stringify({ f: internalResumeCallback }), '{}');
            \\assert.sameValue(JSON.stringify([internalResumeCallback]), '[null]');
            \\assert.throws(TypeError, () => Reflect.construct(internalResumeCallback, []));
            \\assert.throws(TypeError, () => Reflect.construct(function () {}, [], internalResumeCallback));
        );
    }
}

test "fulfilled await queues a direct resume and retains suspended values" {
    const ActiveProbe = struct {
        canary: *core.Object,
        hits: usize = 0,
        saw_empty_queue: bool = false,
        reclaimed: bool = false,
        fn run(rt: *core.JSRuntime, user_context: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(user_context.?));
            self.hits += 1;
            self.saw_empty_queue = rt.job_queue.jobs.len == 0;
            helpers.gc.reclaimNow(rt);
            self.reclaimed = !rt.ownsObject(self.canary);
            return false;
        }
    };
    for (0..3) |kind| {
        var js = try helpers.TestEngine.init(std.testing.allocator);
        defer js.deinit();
        _ = try js.eval(
            \\globalThis.resumeCount = 0;
            \\globalThis.awaitProbe = async function (value) {
            \\    const result = await value;
            \\    resumeCount++;
            \\    return result;
            \\};
        );
        const global = try engine.exec.zjs_vm.contextGlobal(js.context);
        const function = try global.getProperty(try js.runtime.internAtom("awaitProbe"));
        var input = core.JSValue.undefinedValue();
        var output = core.JSValue.undefinedValue();
        var roots = core.runtime.rootValues(.{ &input, &output });
        roots.activate(js.runtime);
        defer roots.deactivate(js.runtime);
        input = switch (kind) {
            0 => core.JSValue.undefinedValue(),
            1 => try js.runtime.symbolValue(try js.runtime.atoms.newValueSymbol("await-root")),
            else => (try core.Object.create(js.runtime, core.class.ids.object, null)).value(),
        };
        const expected = input;
        output = try engine.exec.call_runtime.callValueOrBytecodeRoot(js.context, null, global, core.JSValue.undefinedValue(), function, &.{input}, null, null);
        input = core.JSValue.undefinedValue();
        const promise = try core.Object.expect(output);
        try std.testing.expect(promise.promiseResult() == null);
        try std.testing.expectEqual(@as(usize, 1), js.runtime.job_queue.jobs.len);
        const job = &js.runtime.job_queue.jobs[0];
        try std.testing.expectEqual(core.jobs.Kind.async_resume, std.meta.activeTag(job.payload));
        try std.testing.expect(job.payload.async_resume.value.sameValue(expected));
        const continuation = try core.Object.expect(job.payload.async_resume.continuation);

        // Collect with only the queued job and returned Promise retaining the
        // suspended execution/value. An unrooted canary proves reclamation ran.
        const canary = try core.Object.create(js.runtime, core.class.ids.object, null);
        _ = try js.runtime.collectForTest();
        try std.testing.expect(!js.runtime.ownsObject(canary));
        try std.testing.expect(js.runtime.ownsObject(continuation));
        // Force a second actual collection after takeFirst, before the body
        // installs its frame roots: ActiveJobRoot alone retains the payload.
        var active_probe = ActiveProbe{ .canary = try core.Object.create(js.runtime, core.class.ids.object, null) };
        js.runtime.setInterruptHandler(ActiveProbe.run, &active_probe);
        defer js.runtime.setInterruptHandler(null, null);
        js.context.interrupt_counter = 1;
        try std.testing.expectEqual(core.jobs.RunOneStatus.success, try engine.exec.promise_ops.drainOnePendingJob(js.context, null));
        try std.testing.expectEqual(@as(usize, 1), active_probe.hits);
        try std.testing.expect(active_probe.saw_empty_queue);
        try std.testing.expect(active_probe.reclaimed);
        try std.testing.expectEqual(@as(usize, 0), js.runtime.job_queue.jobs.len);
        try std.testing.expect(!promise.promiseIsRejected());
        try std.testing.expect(promise.promiseResult().?.sameValue(expected));
        try std.testing.expectEqual(@as(?i32, 1), (try global.getProperty(try js.runtime.internAtom("resumeCount"))).as(.int));
    }
}

test "fulfilled await checks state after the constructor getter settles its input" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    _ = try js.eval(
        \\let release;
        \\globalThis.getterReads = 0;
        \\const input = new Promise(resolve => { release = resolve; });
        \\Object.defineProperty(input, 'constructor', { get() {
        \\    getterReads++;
        \\    release(42);
        \\    return Promise;
        \\}});
        \\globalThis.awaitProbe = async function () { return await input; };
    );
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const function = try global.getProperty(try js.runtime.internAtom("awaitProbe"));
    var output = try engine.exec.call_runtime.callValueOrBytecodeRoot(js.context, null, global, core.JSValue.undefinedValue(), function, &.{}, null, null);
    var roots = core.runtime.rootValues(.{&output});
    roots.activate(js.runtime);
    defer roots.deactivate(js.runtime);
    try std.testing.expectEqual(@as(?i32, 1), (try global.getProperty(try js.runtime.internAtom("getterReads"))).as(.int));
    try std.testing.expectEqual(@as(usize, 1), js.runtime.job_queue.jobs.len);
    const job = &js.runtime.job_queue.jobs[0];
    try std.testing.expectEqual(core.jobs.Kind.async_resume, std.meta.activeTag(job.payload));
    try std.testing.expectEqual(@as(?i32, 42), job.payload.async_resume.value.as(.int));
    try js.runJobs();
    try std.testing.expectEqual(@as(?i32, 42), (try core.Object.expect(output)).promiseResult().?.as(.int));
}

test "fulfilled await roots its continuation through constructor getter GC" {
    const Probe = struct {
        calls: usize = 0,
        canary: *core.Object,
        reclaimed_canary: bool = false,
        fn run(rt: *core.JSRuntime, user_context: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(user_context.?));
            self.calls += 1;
            helpers.gc.reclaimNow(rt);
            // Snapshot before await's subsequent allocations can reuse the
            // freed address; a later ownsObject(pointer) cannot prove identity.
            self.reclaimed_canary = !rt.ownsObject(self.canary);
            return false;
        }
    };
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    defer while (js.runtime.job_queue.takeFirst()) |queued| {
        var job = queued;
        job.deinit();
    };
    _ = try js.eval(
        \\globalThis.awaitInput = Promise.resolve(Symbol('constructor-root'));
        \\Object.defineProperty(awaitInput, 'constructor', {get() { return Promise; }});
    );
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const key = try js.runtime.internAtom("awaitInput");
    var awaited = try global.getProperty(key);
    var continuation_value = core.JSValue.undefinedValue();
    var setup_roots = core.runtime.rootValues(.{ &awaited, &continuation_value });
    setup_roots.activate(js.runtime);
    var setup_active = true;
    defer if (setup_active) setup_roots.deactivate(js.runtime);
    // A synthetic continuation isolates the Await callee's roots from the
    // normal VM caller. Its queued continuation is inspected, never executed.
    const continuation = try core.Object.create(js.runtime, core.class.ids.object, null);
    continuation_value = continuation.value();
    const input = try core.Object.expect(awaited);
    const symbol = input.promiseResult().?.asSymbolAtom().?;
    try global.defineOwnProperty(js.runtime, key, core.Descriptor.data(core.JSValue.undefinedValue(), .all));
    const canary = try core.Object.create(js.runtime, core.class.ids.object, null);
    setup_roots.deactivate(js.runtime);
    setup_active = false;
    var probe = Probe{ .canary = canary };
    js.runtime.setInterruptHandler(Probe.run, &probe);
    defer js.runtime.setInterruptHandler(null, null);
    js.context.interrupt_counter = 1;
    try engine.exec.promise_ops.asyncFunctionAwait(js.context, null, global, continuation, awaited);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(probe.reclaimed_canary);
    try std.testing.expect(js.runtime.ownsObject(continuation));
    try std.testing.expect(js.runtime.ownsObject(input));
    try std.testing.expect(js.runtime.atoms.name(symbol) != null);
    try std.testing.expectEqual(@as(usize, 1), js.runtime.job_queue.jobs.len);
    var job = js.runtime.job_queue.takeFirst().?;
    job.deinit();
    _ = try js.runtime.collectForTest();
    try std.testing.expect(!js.runtime.ownsObject(continuation));
    try std.testing.expect(!js.runtime.ownsObject(input));
    try std.testing.expect(js.runtime.atoms.name(symbol) == null);
}

test "pending and rejected await retain both callbacks and execute rejection recovery" {
    for ([_]bool{ false, true }) |initially_settled| {
        for ([_]bool{ false, true }) |rejected| {
            if (initially_settled and !rejected) continue;
            var js = try helpers.TestEngine.init(std.testing.allocator);
            defer js.deinit();
            _ = try js.eval(
                \\globalThis.input = new Promise(() => {});
                \\globalThis.awaitProbe = async function () {
                \\    try { return await input; } catch (reason) { return reason + 1; }
                \\};
            );
            const global = try engine.exec.zjs_vm.contextGlobal(js.context);
            const input = try core.Object.expect(try global.getProperty(try js.runtime.internAtom("input")));
            if (initially_settled) try engine.exec.promise_ops.promiseSettleValue(js.context, input, core.JSValue.int32(41), rejected);
            const function = try global.getProperty(try js.runtime.internAtom("awaitProbe"));
            var output = try engine.exec.call_runtime.callValueOrBytecodeRoot(js.context, null, global, core.JSValue.undefinedValue(), function, &.{}, null, null);
            var roots = core.runtime.rootValues(.{&output});
            roots.activate(js.runtime);
            defer roots.deactivate(js.runtime);
            const record = if (initially_settled) blk: {
                try std.testing.expectEqual(@as(usize, 1), js.runtime.job_queue.jobs.len);
                try std.testing.expectEqual(core.jobs.Kind.promise_reaction, std.meta.activeTag(js.runtime.job_queue.jobs[0].payload));
                break :blk try core.Object.expect(js.runtime.job_queue.jobs[0].payload.promise_reaction.reaction);
            } else blk: {
                try std.testing.expectEqual(@as(usize, 0), js.runtime.job_queue.jobs.len);
                try std.testing.expectEqual(@as(usize, 1), input.promiseReactions().len);
                break :blk try core.Object.expect(input.promiseReactions()[0]);
            };
            try std.testing.expectEqual(core.class.ids.async_function_resolve, (try core.Object.expect(record.promiseReactionOnFulfilled().?)).class_id);
            try std.testing.expectEqual(core.class.ids.async_function_reject, (try core.Object.expect(record.promiseReactionOnRejected().?)).class_id);
            if (!initially_settled) try engine.exec.promise_ops.promiseSettleValue(js.context, input, core.JSValue.int32(41), rejected);
            try js.runJobs();
            const result = try core.Object.expect(output);
            try std.testing.expect(!result.promiseIsRejected());
            try std.testing.expectEqual(@as(?i32, if (rejected) 42 else 41), result.promiseResult().?.as(.int));
        }
    }
}

test "async direct settlement preserves adoption self resolution and once guards" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    _ = try js.eval(
        \\let reads = 0, calls = 0, phase = 'sync';
        \\const adopted = (async () => ({ get then() {
        \\    reads++;
        \\    return function (resolve, reject) {
        \\        calls++;
        \\        assert.sameValue(phase, 'jobs');
        \\        assert.sameValue(resolve.name, '');
        \\        assert.sameValue(resolve.length, 1);
        \\        resolve(42); reject(43); resolve(44); throw Error('late');
        \\    };
        \\} }))();
        \\assert.sameValue(reads, 1);
        \\assert.sameValue(calls, 0);
        \\phase = 'jobs';
        \\let self;
        \\self = (async () => { await 0; return self; })();
        \\const selfCheck = self.then(() => { throw Error('self fulfilled'); }, error => {
        \\    assert(error instanceof TypeError);
        \\});
        \\const sentinel = {};
        \\const rejected = (async () => { throw sentinel; })().catch(error => {
        \\    assert.sameValue(error, sentinel);
        \\});
        \\let nativeThenCalls = 0;
        \\const native = Promise.resolve(5);
        \\native.then = function (resolve) { nativeThenCalls++; resolve(6); };
        \\const returnedNative = (async () => native)();
        \\Promise.all([adopted, selfCheck, rejected, returnedNative]).then(values => {
        \\    assert.sameValue(values[0], 42);
        \\    assert.sameValue(values[3], 6);
        \\    assert.sameValue(reads, 1);
        \\    assert.sameValue(calls, 1);
        \\    assert.sameValue(nativeThenCalls, 1);
        \\    globalThis.directSettlementDone = true;
        \\});
    );
    try js.runJobs();
    _ = try js.eval("assert.sameValue(directSettlementDone, true);");
}

test "async resume callbacks preserve thenable metadata microtasks and realms" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    _ = try js.eval(
        \\function check(v, m) { if (!v) throw Error(m); }
        \\const events = [];
        \\const originalThen = Promise.prototype.then;
        \\let release;
        \\const pending = new Promise(resolve => { release = resolve; });
        \\Promise.prototype.then = function () { throw Error('await called patched then'); };
        \\const p = (async () => {
        \\    events.push('enter');
        \\    check(await pending === 42, 'pending result');
        \\    events.push('resume');
        \\    return 43;
        \\})();
        \\release(42);
        \\Promise.prototype.then = originalThen;
        \\Promise.resolve().then(() => events.push('queued'));
        \\let metadataChecks = 0;
        \\const thenable = {
        \\    then(resolve, reject) {
        \\        for (const f of [resolve, reject]) {
        \\            const length = Object.getOwnPropertyDescriptor(f, 'length');
        \\            const name = Object.getOwnPropertyDescriptor(f, 'name');
        \\            check(typeof f === 'function' && length.value === 1 && name.value === '', 'resolving metadata');
        \\            check(!length.writable && !length.enumerable && length.configurable, 'length descriptor');
        \\            check(!name.writable && !name.enumerable && name.configurable, 'name descriptor');
        \\            metadataChecks++;
        \\        }
        \\        resolve(7); reject(8); throw Error('after resolve');
        \\    }
        \\};
        \\const sentinel = {};
        \\const a = (async () => {
        \\    check(await thenable === 7, 'thenable result');
        \\    try { await Promise.reject(sentinel); throw Error('missing rejection'); }
        \\    catch (e) { check(e === sentinel, 'rejection identity'); }
        \\    try { await { get then() { throw sentinel; } }; throw Error('missing getter throw'); }
        \\    catch (e) { check(e === sentinel, 'then getter identity'); }
        \\    return 9;
        \\})();
        \\const foreign = $262.createRealm().global;
        \\foreign.eval('globalThis.saved = 11; globalThis.fn = async function () { await 0; return [globalThis, saved]; };');
        \\const b = foreign.fn();
        \\Promise.all([p, a, b]).then(values => {
        \\    check(values[0] === 43 && values[1] === 9, 'results');
        \\    check(values[2][0] === foreign && values[2][1] === 11, 'realm');
        \\    check(events.join(',') === 'enter,resume,queued', 'microtask order');
        \\    check(metadataChecks === 2, 'thenable route coverage');
        \\    globalThis.__asyncCallbackDone = true;
        \\});
    );
    try js.runJobs();
    _ = try js.eval("assert.sameValue(globalThis.__asyncCallbackDone, true);");
}

test "generator async and wrapper noncarriers derive cross-realm state across GC" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    _ = try js.eval(
        \\globalThis.__w1b3eOther = $262.createRealm().global;
        \\__w1b3eOther.eval("globalThis.w1b3eSync = function* () { yield globalThis; return globalThis; }; globalThis.w1b3eThrow = function* () { try { yield 0; } catch (error) { yield globalThis; } }; globalThis.w1b3eFast = function* () { yield globalThis; }; globalThis.w1b3eAsyncGenerator = async function* () { yield globalThis; }; globalThis.w1b3eAsyncFunction = async function () { await 0; return globalThis; }; globalThis.w1b3eTarget = function () { return globalThis; };");
        \\globalThis.__w1b3eSync = __w1b3eOther.w1b3eSync();
        \\globalThis.__w1b3eThrow = __w1b3eOther.w1b3eThrow();
        \\globalThis.__w1b3eFast = __w1b3eOther.w1b3eFast();
        \\globalThis.__w1b3eAsyncGenerator = __w1b3eOther.w1b3eAsyncGenerator();
        \\globalThis.__w1b3eAsyncFunctionPromise = __w1b3eOther.w1b3eAsyncFunction();
        \\globalThis.__w1b3eBound = __w1b3eOther.w1b3eTarget.bind(null);
        \\globalThis.__w1b3eProxy = new Proxy(__w1b3eOther.w1b3eTarget, {});
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const names = [_][]const u8{
        "__w1b3eOther",
        "__w1b3eSync",
        "__w1b3eThrow",
        "__w1b3eFast",
        "__w1b3eAsyncGenerator",
        "__w1b3eBound",
        "__w1b3eProxy",
    };
    var values: [names.len]core.JSValue = @splat(core.JSValue.undefinedValue());
    for (names, &values) |name, *value| {
        const key = try js.runtime.internAtom(name);
        value.* = try global.getProperty(key);
    }

    const other_global = try core.Object.expect(values[0]);
    for (values[1..]) |value| {
        const object = try core.Object.expect(value);
        try std.testing.expect(!object.isBorrowedReferenceHolder());
        try std.testing.expect(object.borrowedReferenceHolderIndex() == null);
        try std.testing.expect(object.functionRealmGlobalPtr() == null);
        try std.testing.expectEqual(other_global, object_ops.objectRealmGlobal(object).?);
    }
    for (values[1..5]) |value| {
        const generator = try core.Object.expect(value);
        try std.testing.expectEqual(other_global, generator.generatorFunctionRealmGlobalPtr().?);
    }

    _ = try js.runtime.collectForTest();

    for (values[1..]) |value| {
        const object = try core.Object.expect(value);
        try std.testing.expect(!object.isBorrowedReferenceHolder());
        try std.testing.expectEqual(other_global, object_ops.objectRealmGlobal(object).?);
    }

    _ = try js.eval(
        \\var __w1b3eLocalGeneratorPrototype = Object.getPrototypeOf(function* () {}.prototype);
        \\var __w1b3eLocalNext = __w1b3eLocalGeneratorPrototype.next;
        \\var __w1b3eStep = __w1b3eLocalNext.call(__w1b3eSync);
        \\assert.sameValue(__w1b3eStep.value, __w1b3eOther);
        \\assert.sameValue(Object.getPrototypeOf(__w1b3eStep), __w1b3eOther.Object.prototype);
        \\__w1b3eStep = __w1b3eLocalGeneratorPrototype.return.call(__w1b3eSync, __w1b3eOther);
        \\assert.sameValue(__w1b3eStep.value, __w1b3eOther);
        \\assert.sameValue(Object.getPrototypeOf(__w1b3eStep), __w1b3eOther.Object.prototype);
        \\var __w1b3eCompleted = __w1b3eLocalNext.call(__w1b3eSync);
        \\assert.sameValue(Object.getPrototypeOf(__w1b3eCompleted), Object.prototype);
        \\__w1b3eLocalNext.call(__w1b3eThrow);
        \\__w1b3eStep = __w1b3eLocalGeneratorPrototype.throw.call(__w1b3eThrow, 1);
        \\assert.sameValue(__w1b3eStep.value, __w1b3eOther);
        \\assert.sameValue(Object.getPrototypeOf(__w1b3eStep), __w1b3eOther.Object.prototype);
        \\__w1b3eFast.next = __w1b3eLocalNext;
        \\assert.sameValue([...__w1b3eFast][0], __w1b3eOther);
        \\assert.sameValue(__w1b3eBound(), __w1b3eOther);
        \\assert.sameValue(__w1b3eProxy(), __w1b3eOther);
        \\assert.sameValue(Object.getPrototypeOf(__w1b3eAsyncFunctionPromise), __w1b3eOther.Promise.prototype);
        \\globalThis.__w1b3eAsyncFunctionValue = undefined;
        \\__w1b3eAsyncFunctionPromise.then(function (value) { __w1b3eAsyncFunctionValue = value; });
        \\var __w1b3eLocalAsyncGeneratorPrototype = Object.getPrototypeOf(async function* () {}.prototype);
        \\globalThis.__w1b3eAsyncGeneratorPromise = __w1b3eLocalAsyncGeneratorPrototype.next.call(__w1b3eAsyncGenerator);
        \\assert.sameValue(Object.getPrototypeOf(__w1b3eAsyncGeneratorPromise), __w1b3eOther.Promise.prototype);
        \\globalThis.__w1b3eAsyncGeneratorStep = undefined;
        \\__w1b3eAsyncGeneratorPromise.then(function (step) { __w1b3eAsyncGeneratorStep = step; });
    );

    try js.runJobs();
    const verify_async = try js.eval(
        \\assert.sameValue(__w1b3eAsyncFunctionValue, __w1b3eOther);
        \\assert.sameValue(__w1b3eAsyncGeneratorStep.value, __w1b3eOther);
        \\assert.sameValue(Object.getPrototypeOf(__w1b3eAsyncGeneratorStep), __w1b3eOther.Object.prototype);
    );
    try std.testing.expect(verify_async.is(.undefined_value));
}
