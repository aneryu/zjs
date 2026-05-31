const std = @import("std");
const engine = @import("quickjs_zig_engine");

const core = engine.core;
const op = engine.bytecode.opcode.op;

const helpers = @import("exec_helpers.zig");
const oom_helpers = @import("oom_helpers.zig");
const makeFunction = helpers.makeFunction;
const runFunction = helpers.runFunction;
const countJob = helpers.countJob;
const countJobArgs = helpers.countJobArgs;
test "Engine eval executes test262 helpers through generic call paths" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval("assert.sameValue(1 + 1, 2, 'sum');");
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
    try std.testing.expectError(error.Test262Error, js.eval("assert.sameValue(1, 2);"));
    try std.testing.expectError(error.Test262Error, js.eval("throw new Test262Error('boom');"));
}

test "Engine eval strips TypeScript source kind before execution" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalWithOptions(
        \\type Label = string;
        \\interface Box { value: number }
        \\const value: number = 41;
        \\function add(input: number): number { return input + 1; }
        \\assert.sameValue(add(value), 42 as number);
    , .{ .source_kind = .typescript });
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine eval strips TypeScript method annotations" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalWithOptions(
        \\class C { m(x: number): number { return x; } }
        \\const object = { m(x: number): number { return x + 1; } };
        \\assert.sameValue(new C().m(41), 41);
        \\assert.sameValue(object.m(41), 42);
    , .{ .source_kind = .typescript });
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine eval preserves as and satisfies runtime property names in TypeScript files" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalWithOptions(
        \\const obj = { as: 1, satisfies: 2 };
        \\assert.sameValue(obj.as + obj.satisfies, 3);
    , .{ .source_kind = .typescript });
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine eval rejects TypeScript parameter properties" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    try std.testing.expectError(
        error.SyntaxError,
        js.evalWithOptions(
            "class Box { constructor(public value: number) {} }",
            .{ .source_kind = .typescript },
        ),
    );
}

test "Engine eval strips TypeScript automatically for ts filenames" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalWithOptions(
        \\const value: number = 42;
        \\assert.sameValue(value, 42);
    , .{ .filename = "sample.ts" });
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine defineScriptArgs OOM releases pending global array once" {
    var saw_oom = false;
    var saw_success = false;

    const samples = oom_helpers.defaultSampleSet(320);
    var fail_offset: usize = 0;
    while (fail_offset < samples.limit) : (fail_offset += 1) {
        if (!oom_helpers.shouldRunOffset(samples, fail_offset)) continue;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var js = try engine.Engine.init(failing.allocator());

        const warmup = try js.eval("Array.prototype;");
        warmup.free(js.runtime);
        try fillGlobalPropertyCapacity(&js);

        const args = [_][]const u8{ "one", "two" };
        failing.fail_index = failing.alloc_index + fail_offset;
        const result = js.defineScriptArgs(args[0..]);
        failing.fail_index = std.math.maxInt(usize);

        if (result) {
            saw_success = true;
        } else |err| switch (err) {
            error.OutOfMemory => saw_oom = true,
            else => |unexpected| {
                js.deinit();
                return unexpected;
            },
        }

        js.deinit();
        if (oom_helpers.shouldStopAfterCoverage(saw_oom, saw_success)) return;
    }

    try std.testing.expect(saw_oom);
    try std.testing.expect(saw_success);
}

fn fillGlobalPropertyCapacity(js: *engine.Engine) !void {
    const global = try engine.exec.qjs_vm.ensureContextGlobal(js.context);
    var index: usize = 0;
    while (global.properties.len < global.property_capacity) : (index += 1) {
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "__zjs_oom_fill_{d}", .{index});
        const key = try js.runtime.internAtom(name);
        defer js.runtime.atoms.free(key);
        try global.defineOwnProperty(js.runtime, key, core.Descriptor.data(core.Value.int32(@intCast(index)), true, true, true));
    }
}

test "CallSite metadata is internal" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\Error.prepareStackTrace = function(err, sites) {
        \\    var site = sites[0];
        \\    assert.sameValue("__zjs_callsite" in site, false);
        \\    assert.sameValue("__zjs_callsite_line" in site, false);
        \\    assert.sameValue(typeof site.getFunction, "function");
        \\    assert.sameValue(typeof site.getThis, "undefined");
        \\    assert.sameValue(site.hasOwnProperty("getFunction"), false);
        \\    assert.sameValue(site.toString(), "[object CallSite]");
        \\    assert.sameValue(Object.prototype.toString.call(site), "[object CallSite]");
        \\    assert.sameValue(site[Symbol.toStringTag], "CallSite");
        \\    var name = site.getFunctionName();
        \\    var file = site.getFileName();
        \\    var line = site.getLineNumber();
        \\    var column = site.getColumnNumber();
        \\    site.__zjs_callsite_function = "fakeFn";
        \\    site.__zjs_callsite_file = "fake.js";
        \\    site.__zjs_callsite_line = 999;
        \\    site.__zjs_callsite_column = 777;
        \\    assert.sameValue(site.getFunctionName(), name);
        \\    assert.sameValue(site.getFileName(), file);
        \\    assert.sameValue(site.getLineNumber(), line);
        \\    assert.sameValue(site.getColumnNumber(), column);
        \\    assert.sameValue(site.toString().indexOf("fake"), -1);
        \\    return "ok";
        \\};
        \\function inner() {
        \\    return new Error("x").stack;
        \\}
        \\assert.sameValue(inner(), "ok");
        \\Error.prepareStackTrace = undefined;
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Error stack uses object method runtime names" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var object = {
        \\    return() {
        \\        return new Error("x").stack;
        \\    }
        \\};
        \\var stack = object.return();
        \\assert.sameValue(stack.indexOf("at return") >= 0, true);
        \\assert.sameValue(stack.indexOf("    at return"), 0);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Error stack preserves construction frames across delayed access" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function makeError() {
        \\    return new Error("x");
        \\}
        \\var err = makeError();
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(err, "stack"), false);
        \\function readStack(error) {
        \\    return error.stack;
        \\}
        \\var stack = readStack(err);
        \\assert.sameValue(typeof stack, "string");
        \\assert.sameValue(stack.indexOf("at makeError") >= 0, true);
        \\assert.sameValue(stack.indexOf("at readStack") < 0, true);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Error prepareStackTrace formats captured frames lazily" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var calls = 0;
        \\Error.prepareStackTrace = function() {
        \\    calls++;
        \\    return "early";
        \\};
        \\function makeError() {
        \\    return new Error("x");
        \\}
        \\var err = makeError();
        \\assert.sameValue(calls, 0);
        \\Error.prepareStackTrace = function(error, sites) {
        \\    calls++;
        \\    assert.sameValue(error, err);
        \\    assert.sameValue(sites[0].getFunctionName(), "makeError");
        \\    return "late:" + sites[0].getFunctionName();
        \\};
        \\assert.sameValue(err.stack, "late:makeError");
        \\assert.sameValue(calls, 1);
        \\assert.sameValue(err.stack, "late:makeError");
        \\assert.sameValue(calls, 1);
        \\Error.prepareStackTrace = undefined;
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Error stack setter accepts non-string own stack values" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var err = new Error("x");
        \\err.stack = 123;
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(err, "stack"), true);
        \\assert.sameValue(err.stack, 123);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Error stack copied accessor setter writes without recursion" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var err = new Error("x");
        \\Object.defineProperty(err, "stack", Object.getOwnPropertyDescriptor(Error.prototype, "stack"));
        \\err.stack = 123;
        \\var desc = Object.getOwnPropertyDescriptor(err, "stack");
        \\assert.sameValue(desc.value, 123);
        \\assert.sameValue(desc.writable, true);
        \\assert.sameValue(err.stack, 123);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Error stack copied accessor setter writes through proxy without recursion" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var proxy = new Proxy(new Error("x"), {});
        \\Object.defineProperty(proxy, "stack", Object.getOwnPropertyDescriptor(Error.prototype, "stack"));
        \\proxy.stack = 123;
        \\var desc = Object.getOwnPropertyDescriptor(proxy, "stack");
        \\assert.sameValue(desc.value, 123);
        \\assert.sameValue(desc.writable, true);
        \\assert.sameValue(proxy.stack, 123);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Error stack reentrant formatting is capped to captured frames" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var previousLimit = Error.stackTraceLimit;
        \\Error.stackTraceLimit = 1;
        \\var calls = 0;
        \\Error.prepareStackTrace = function(error, sites) {
        \\    calls++;
        \\    sites.length = 3;
        \\    sites[2] = sites[0];
        \\    return error.stack;
        \\};
        \\var stack = new Error("x").stack;
        \\Error.prepareStackTrace = undefined;
        \\Error.stackTraceLimit = previousLimit;
        \\var frames = String(stack).split("\n").filter(function(line) {
        \\    return line.indexOf("    at ") === 0;
        \\});
        \\assert.sameValue(calls, 1);
        \\assert.sameValue(frames.length, 1);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Array fill respects proxy prototypes" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var calls = [];
        \\var array = new Array(3);
        \\Object.setPrototypeOf(array, new Proxy(Array.prototype, {
        \\    set: function(target, key, value, receiver) {
        \\        calls.push(String(key) + ":" + value);
        \\        return Reflect.set(target, key, value, receiver);
        \\    }
        \\}));
        \\Array.prototype.fill.call(array, 7);
        \\assert.sameValue(calls.join(","), "0:7,1:7,2:7");
        \\assert.sameValue(array.join(","), "7,7,7");
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Error.prepareStackTrace exceptions produce null stack" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\Error.prepareStackTrace = function() {
        \\    throw new TypeError("prep");
        \\};
        \\assert.sameValue(new Error("x").stack, null);
        \\Error.prepareStackTrace = undefined;
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine runtime-strict file eval matches QuickJS CLI script surface" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileWithOutputModeRuntimeStrict(
        \\function strictThis() { return this === undefined; }
        \\function cliLocalFunction() {}
        \\print(this === undefined);
        \\print(strictThis());
        \\var desc = Object.getOwnPropertyDescriptor(globalThis, "cliLocalFunction");
        \\print(desc === undefined);
        \\print(cliLocalFunction.name);
        \\var roProto = {};
        \\Object.defineProperty(roProto, "locked", { value: 1, writable: false, configurable: true });
        \\var roObj = Object.create(roProto);
        \\try { roObj.locked = 2; print(false); } catch (e) { print(e instanceof TypeError); }
        \\try { missingQuickJsCliStrict = 1; print(false); } catch (e) { print(e instanceof ReferenceError); }
        \\var capture;
        \\eval("var evalCreated = 5; capture = function(){ return evalCreated; };");
        \\print(evalCreated);
        \\print(delete evalCreated);
        \\try { print(capture()); } catch (e) { print(e instanceof ReferenceError); }
    , &stream, .script, "runtime-strict-file.js", true);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\ntrue\ntrue\ncliLocalFunction\ntrue\ntrue\n5\ntrue\ntrue\n", stream.buffered());
}

test "Engine strict script top-level this remains the global object" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\"use strict";
        \\print(this === globalThis);
        \\function strictThis() { return this === undefined; }
        \\print(strictThis());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\ntrue\n", stream.buffered());
}

test "Engine direct eval publishes Annex B block functions" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\eval("{ function annexBEvalGlobalFn() { return 'global'; } }");
        \\assert.sameValue(annexBEvalGlobalFn(), "global");
        \\delete globalThis.annexBEvalGlobalFn;
        \\
        \\var init, changed, localAfter, functionAfter;
        \\(function() {
        \\  eval("init = annexBEvalLocalFn; annexBEvalLocalFn = 123; changed = annexBEvalLocalFn; { function annexBEvalLocalFn() { return 'local'; } } localAfter = annexBEvalLocalFn();");
        \\  functionAfter = annexBEvalLocalFn();
        \\}());
        \\assert.sameValue(init, undefined);
        \\assert.sameValue(changed, 123);
        \\assert.sameValue(localAfter, "local");
        \\assert.sameValue(functionAfter, "local");
        \\assert.throws(ReferenceError, function() { annexBEvalLocalFn; });
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine direct eval Annex B block function updates same-name parameter" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var init, after;
        \\(function(f) {
        \\  eval("init = f; { function f() {} } after = f;");
        \\}(123));
        \\print(init);
        \\print(typeof after);
        \\print(after());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("123\nfunction\nundefined\n", stream.buffered());
}

test "Engine eval supports Annex B escape and unescape code-unit semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(escape('\u0100\u0101\u0102'), '%u0100%u0101%u0102');
        \\assert.sameValue(escape('\ufffd\ufffe\uffff'), '%uFFFD%uFFFE%uFFFF');
        \\assert.sameValue(escape('\ud834\udf06'), '%uD834%uDF06');
        \\assert.sameValue(escape('{|}~\x7f\x80'), '%7B%7C%7D%7E%7F%80');
        \\assert.sameValue(unescape('%0%FE00'), '%0\xfe00');
        \\assert.sameValue(escape(unescape('%u0100')), '%u0100');
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine eval supports Annex B Date setYear ordering" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var dt = new Date(0);
        \\var called = 0;
        \\var value = { valueOf: function() { called++; dt.setTime(NaN); return 1; } };
        \\var result = dt.setYear(value);
        \\assert.sameValue(called, 1);
        \\assert.notSameValue(result, NaN);
        \\assert.sameValue(result, dt.getTime());
        \\assert.sameValue(dt.getYear(), 1);
        \\assert.throws(TypeError, function() { dt.setYear(Symbol("x")); });
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine eval supports Annex B String HTML wrappers and trim aliases" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue("_".big(), "<big>_</big>");
        \\assert.sameValue(String.prototype.big.call(0x2A), "<big>42</big>");
        \\assert.sameValue("x".anchor('a"b'), '<a name="a&quot;b">x</a>');
        \\assert.sameValue(String.prototype.trimLeft, String.prototype.trimStart);
        \\assert.sameValue(String.prototype.trimLeft.name, "trimStart");
        \\assert.sameValue(Number.isNaN("x"), false);
        \\assert.sameValue(Number.isFinite(1), true);
        \\assert.sameValue(Number.isFinite("1"), false);
        \\assert.sameValue(isFinite("1"), true);
        \\assert.sameValue(isFinite(Infinity), false);
        \\assert.sameValue(Math.trunc(-1.9), -1);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine eval TypeError with evaluated arguments does not double free constants" {
    {
        var js = try engine.Engine.init(std.testing.allocator);
        defer js.deinit();
        try std.testing.expectError(error.TypeError, js.eval("const obj = {}; obj.missing(\"a\", \"a\");"));
    }
    {
        var js = try engine.Engine.init(std.testing.allocator);
        defer js.deinit();
        try std.testing.expectError(error.TypeError, js.eval("RegExp.test(\"a\", \"a\");"));
    }
}

test "vm call handler accepts allocator-backed argument lists" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const name = try rt.internAtom("wide-call");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    const print_key = try rt.internAtom("print");
    defer rt.atoms.free(print_key);
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try bytes.append(rt.memory.allocator, op.get_var);
    try bytes.appendSlice(rt.memory.allocator, std.mem.asBytes(&print_key));
    var arg: i32 = 1;
    while (arg <= 40) : (arg += 1) {
        try bytes.append(rt.memory.allocator, op.push_i32);
        try bytes.appendSlice(rt.memory.allocator, std.mem.asBytes(&arg));
    }
    try bytes.append(rt.memory.allocator, op.call);
    const argc: u16 = 40;
    try bytes.appendSlice(rt.memory.allocator, std.mem.asBytes(&argc));
    try function.setCode(bytes.items);

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    var vm_instance = engine.exec.Vm.initWithOutput(ctx, &stream);
    defer vm_instance.deinit();
    const result = try vm_instance.run(&function);
    defer result.free(rt);

    var expected = std.ArrayList(u8).empty;
    defer expected.deinit(std.testing.allocator);
    var expected_arg: i32 = 1;
    while (expected_arg <= 40) : (expected_arg += 1) {
        if (expected_arg != 1) try expected.append(std.testing.allocator, ' ');
        var int_buf: [16]u8 = undefined;
        const printed = try std.fmt.bufPrint(&int_buf, "{d}", .{expected_arg});
        try expected.appendSlice(std.testing.allocator, printed);
    }
    try expected.append(std.testing.allocator, '\n');

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(expected.items, stream.buffered());
}

test "Engine API eval and job queue are wired" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval("1 2");
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());

    helpers.job_counter = 0;
    try js.job_queue.enqueueFunc(js.context, countJob, &.{});
    try js.job_queue.enqueueFunc(js.context, countJob, &.{});
    try js.runJobs();
    try std.testing.expectEqual(@as(usize, 2), helpers.job_counter);

    helpers.job_counter = 0;
    var i: usize = 0;
    while (i < 16) : (i += 1) try js.job_queue.enqueueFunc(js.context, countJob, &.{});
    try js.runJobs();
    try std.testing.expectEqual(@as(usize, 16), helpers.job_counter);

    helpers.job_counter = 0;
    try js.job_queue.enqueueFunc(js.context, countJobArgs, &.{ core.Value.int32(2), core.Value.int32(3) });
    try js.runJobs();
    try std.testing.expectEqual(@as(usize, 5), helpers.job_counter);

    helpers.job_counter = 0;
    try js.job_queue.enqueueFunc(js.context, countJobArgs, &.{
        core.Value.int32(1),
        core.Value.int32(2),
        core.Value.int32(3),
        core.Value.int32(4),
        core.Value.int32(5),
    });
    try js.runJobs();
    try std.testing.expectEqual(@as(usize, 15), helpers.job_counter);

    try std.testing.expectError(error.TooManyJobArgs, js.job_queue.enqueueFunc(js.context, countJobArgs, &.{
        core.Value.int32(1),
        core.Value.int32(2),
        core.Value.int32(3),
        core.Value.int32(4),
        core.Value.int32(5),
        core.Value.int32(6),
    }));
    try std.testing.expectEqual(@as(usize, 0), js.job_queue.jobs.len);
}

test "job queue enqueue propagates allocator failure" {
    var buffer: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    var account = core.memory.MemoryAccount.init(fixed.allocator());
    var queue = engine.exec.jobs.Queue.init(&account);
    defer queue.deinit();

    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    try std.testing.expectError(error.OutOfMemory, queue.enqueueFunc(js.context, countJob, &.{}));
    try std.testing.expectEqual(@as(usize, 0), queue.jobs.len);
}

test "job queue keeps symbol arguments rooted until release" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    var queue = engine.exec.jobs.Queue.init(&rt.memory);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-job-queue-symbol");
    try queue.enqueueFunc(ctx, countJob, &.{core.Value.symbol(symbol_atom)});

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);

    queue.deinit();
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "job queue symbol roots preserve weak map values" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    var queue = engine.exec.jobs.Queue.init(&rt.memory);

    const weak_map = try core.Object.create(rt, core.class.ids.weakmap, null);
    defer weak_map.value().free(rt);

    const value = try core.Object.create(rt, core.class.ids.object, null);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-job-queue-weak-key");
    try engine.builtins.collection.setWeakMapEntry(rt, weak_map, core.Value.symbol(symbol_atom), value.value());
    value.value().free(rt);

    try queue.enqueueFunc(ctx, countJob, &.{core.Value.symbol(symbol_atom)});
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    try std.testing.expectEqual(@as(usize, 1), weak_map.weakCollectionEntries().len);
    try std.testing.expectEqual(&value.header, weak_map.weakCollectionEntries()[0].value.refHeader().?);

    queue.deinit();
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
    try std.testing.expectEqual(@as(usize, 0), weak_map.weakCollectionEntries().len);
}

test "Engine eval executes simple variable assignment and print" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("let value = 5; value = value + 7; print(value);", &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("12\n", stream.buffered());
}

test "Engine eval assigns contextual await bindings in sloppy scripts" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [16]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var await = 0;
        \\await = 1;
        \\print(await);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\n", stream.buffered());
}

test "Engine eval creates non-configurable enumerable global var bindings" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(delete __globalVar);
        \\var __globalVar = "defined";
        \\print(__globalVar);
        \\print(delete __globalVar, delete this["__globalVar"]);
        \\var seen = false;
        \\for (var key in this) { if (key === "__globalVar") seen = true; }
        \\print(seen);
        \\var first = 1, second = first + 1, third;
        \\print(first, second, third);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false\ndefined\nfalse false\ntrue\n1 2 undefined\n", stream.buffered());
}

test "Engine eval executes object property assignment through quick parser" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("const obj = { x: 1 }; obj.x = obj.x + 2; print(obj.x);", &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3\n", stream.buffered());
}

test "Engine eval executes parenthesized literal postfix through quick parser" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("const obj = { x: 1 }; print(({ y: obj.x + 2 }).y); print(([3, 4])[1]);", &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3\n4\n", stream.buffered());
}

test "Engine eval executes compound assignment and update statements through quick parser" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("let x = 10; x += 5; x -= 3; x *= 2; x /= 4; x %= 5; x++; x--; print(x);", &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\n", stream.buffered());
}

test "Engine eval executes console.log with many arguments" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("console.log(1,2,3,4,5,6,7,8,9,10);", &stream);
    defer result.free(js.runtime);
    const output = stream.buffered();
    try std.testing.expectEqualStrings("1 2 3 4 5 6 7 8 9 10\n", output);
}

test "Engine eval routes host output through global function calls" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(1);
        \\console.log("x");
        \\const out = print;
        \\out(2 + 3, typeof out);
        \\const logger = console.log;
        \\logger("ok");
        \\const c = console;
        \\c.log("alias");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\nx\n5 function\nok\nalias\n", stream.buffered());
}

test "Engine eval preserves one-shot array literal host output semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
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
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("2\ntrue\n2\n1\ntrue\n[2][1]\n", stream.buffered());
}

test "Engine eval preserves one-shot array named property host output semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
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
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("9\ncustom:8\n8\n", stream.buffered());
}

test "Engine eval preserves typed array constructor length host output semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
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
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("4\ntrue\nprint:4\n99\n", stream.buffered());
}

test "Engine eval executes simple template interpolation" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("const x = 10; const y = 20; print(`${x} + ${y} = ${x + y}`);", &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("10 + 20 = 30\n", stream.buffered());
}

test "Engine eval template interpolation calls object toString" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        "const x = { toString(){ return 'custom'; } }; print(`${x}`);",
        &stream,
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("custom\n", stream.buffered());
}

test "Engine eval executes simple arrays and map" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("const arr = [1, 2, 3]; print(arr); print(arr.length); print(arr[0]); print(arr.map(x => x * 2));", &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1,2,3\n3\n1\n2,4,6\n", stream.buffered());
}

test "Engine eval executes simple functions and arrows" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [160]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function add(a, b) { return a + b; }
        \\print(add(2, 3));
        \\const double = x => x * 2;
        \\print(double(21));
        \\function fact(n) { return n <= 1 ? 1 : n * fact(n - 1); }
        \\print(fact(6));
        \\const mul = (a, b) => { return a * b; };
        \\print(mul(3, 4));
        \\function varArguments() { return typeof arguments; var arguments = 1; }
        \\print(varArguments(42));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("5\n42\n720\n12\nobject\n", stream.buffered());
}

test "Engine eval Function.prototype.toString returns source or native text" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [768]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function f(x) { return x; }
        \\print(f.toString());
        \\function /* a */ g /* b */ ( /* c */ y /* d */ ) /* e */ { /* f */ return y; /* g */ }
        \\print(g.toString());
        \\const arrow = y => y + 1;
        \\print(arrow.toString());
        \\print(print.toString());
        \\try { Function.prototype.toString.call({}); } catch (e) { print(e.name); }
        \\try { String({ toString: Function.prototype.toString }); } catch (e) { print(e.name); }
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "function f(x) { return x; }\n" ++
            "function /* a */ g /* b */ ( /* c */ y /* d */ ) /* e */ { /* f */ return y; /* g */ }\n" ++
            "y => y + 1\n" ++
            "function print() {\n    [native code]\n}\n" ++
            "TypeError\n" ++
            "TypeError\n",
        stream.buffered(),
    );
}

test "Engine eval Function.prototype.toString emits syntactic native names" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var native = " {\n    [native code]\n}";
        \\var invalid = Object.getOwnPropertyDescriptor(RegExp, "$&").get.toString();
        \\assert.sameValue(invalid, "function get()" + native);
        \\assert.sameValue(invalid.indexOf("get $&"), -1);
        \\var valid = Object.getOwnPropertyDescriptor(RegExp, "input").get.toString();
        \\assert.sameValue(valid, "function get input()" + native);
        \\var computed = Object.getOwnPropertyDescriptor(Array, Symbol.species).get.toString();
        \\assert.sameValue(computed, "function get [Symbol.species]()" + native);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Engine eval Function.prototype.toString returns method and class source" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [1280]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const method = { /* before */ f /* a */ ( /* b */ ) /* c */ { /* d */ } /* after */ }.f;
        \\print(method.toString());
        \\const asyncComputed = { async /* a */ [ /* b */ "g" /* c */ ] /* d */ ( /* e */ ) /* f */ { /* g */ } }.g;
        \\print(asyncComputed.toString());
        \\const asyncGeneratorComputed = { async /* a */ * /* b */ [ /* c */ "h" /* d */ ] /* e */ ( /* f */ ) /* g */ { /* h */ } }.h;
        \\print(asyncGeneratorComputed.toString());
        \\function B() {}
        \\const C = class /* a */ A /* b */ extends /* c */ B /* d */ { /* e */ constructor /* f */ ( /* g */ ) /* h */ { /* i */ } /* j */ };
        \\print(C.toString());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "f /* a */ ( /* b */ ) /* c */ { /* d */ }\n" ++
            "async /* a */ [ /* b */ \"g\" /* c */ ] /* d */ ( /* e */ ) /* f */ { /* g */ }\n" ++
            "async /* a */ * /* b */ [ /* c */ \"h\" /* d */ ] /* e */ ( /* f */ ) /* g */ { /* h */ }\n" ++
            "class /* a */ A /* b */ extends /* c */ B /* d */ { /* e */ constructor /* f */ ( /* g */ ) /* h */ { /* i */ } /* j */ }\n",
        stream.buffered(),
    );
}

test "Engine eval releases arrow destructuring iterator closures cleanly" {
    var js = try engine.Engine.init(std.testing.allocator);
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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\n", stream.buffered());
}

test "Engine eval executes JSON smoke subset" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const obj = { a: 1, b: 2 };
        \\const str = JSON.stringify(obj);
        \\console.log(str);
        \\const parsed = JSON.parse(str);
        \\console.log(parsed.a);
        \\console.log(parsed.b);
        \\console.log(JSON.stringify({ a: undefined, b: null, c: 1 }));
        \\console.log(JSON.stringify([undefined, null, 1]));
        \\console.log(JSON.stringify(undefined));
        \\console.log(JSON.stringify(NaN));
        \\console.log(JSON.stringify(Infinity));
        \\console.log(JSON.stringify(-Infinity));
        \\const nonAsciiJson = JSON.stringify("é");
        \\console.log(nonAsciiJson.length);
        \\console.log(nonAsciiJson.charCodeAt(1));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("{\"a\":1,\"b\":2}\n1\n2\n{\"b\":null,\"c\":1}\n[null,null,1]\nundefined\nnull\nnull\nnull\n3\n233\n", stream.buffered());
}

test "Engine eval executes Math smoke subset" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(Math.abs(-5));
        \\print(Math.floor(3.7));
        \\print(Math.sqrt(2));
        \\print(Math.pow(4, 0.5));
        \\print(Math.min(1, 2, 3));
        \\const randomValue = Math.random();
        \\print(typeof randomValue);
        \\print(randomValue >= 0);
        \\print(randomValue < 1);
        \\print(1 / -0);
        \\print(Object.is(-0, -0));
        \\print(Object.is(0, -0));
        \\print(Math.acos(1));
        \\print(Math.asin(0));
        \\print(Math.atan(0));
        \\print(Math.atan2(0, -1));
        \\print(typeof Math.acosh);
        \\print(Math.acosh(0));
        \\print(Math.atanh(2));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("5\n3\n1.4142135623730951\n2\n1\nnumber\ntrue\ntrue\n-Infinity\ntrue\nfalse\n0\n0\n0\n3.141592653589793\nfunction\nNaN\nNaN\n", stream.buffered());
}

test "Engine eval preserves one-shot object missing field host output semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
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
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\nfalse\ncustom:true\nfalse\n", stream.buffered());
}

test "Engine runJobs preserves pending JS exceptions for callers" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();
    js.context.preserve_uncaught_exception = true;

    const setup = try js.eval("var __zjs_timer_throw = function() { throw new Error('timer boom'); };");
    defer setup.free(js.runtime);
    const global = try engine.exec.qjs_vm.ensureContextGlobal(js.context);
    const callback_key = try js.runtime.internAtom("__zjs_timer_throw");
    defer js.runtime.atoms.free(callback_key);
    const callback = global.getProperty(callback_key);
    defer callback.free(js.runtime);

    try js.context.ensureOsTimerCapacity(1);
    const timer_index = js.context.os_timers.len;
    js.context.os_timers = js.context.os_timers.ptr[0 .. timer_index + 1];
    js.context.os_timers[timer_index] = try core.OsTimer.init(js.context, 1, callback, 0, 0, false);

    try js.runJobs();
    try std.testing.expect(js.context.hasException());

    var exception = js.takeExceptionInfo();
    defer exception.deinit();
}

test "host module graph syntax diagnostics do not write to program output" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    const modules = [_]HostFixtureModule{
        .{
            .specifier = "./bad.js",
            .path = "/fixture/bad.js",
            .source = "export const = ;",
            .kind = .esm,
        },
    };
    const host = HostFixture{ .modules = &modules };
    const hooks = hostHooks(&host);

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    try std.testing.expectError(
        error.SyntaxError,
        js.evalFileModuleGraphWithHostHooks(
            "import './bad.js';",
            &stream,
            "/fixture/main.mjs",
            hooks,
            std.testing.allocator,
        ),
    );
    try std.testing.expectEqualStrings("", stream.buffered());
}

test "host commonjs wrapper passes directory dirname" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    const modules = [_]HostFixtureModule{
        .{
            .specifier = "./lib/dep.cjs",
            .path = "/fixture/lib/dep.cjs",
            .source =
            \\module.exports = {
            \\  filename: __filename,
            \\  dirname: __dirname,
            \\};
            ,
            .kind = .commonjs,
        },
    };
    const host = HostFixture{ .modules = &modules };
    const hooks = hostHooks(&host);

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithHostHooks(
        \\import info from './lib/dep.cjs';
        \\assert.sameValue(info.filename, '/fixture/lib/dep.cjs');
        \\assert.sameValue(info.dirname, '/fixture/lib');
    ,
        &stream,
        "/fixture/main.mjs",
        hooks,
        std.testing.allocator,
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("", stream.buffered());
}

const HostFixtureModule = struct {
    specifier: []const u8,
    path: []const u8,
    source: []const u8,
    kind: engine.Engine.HostHooks.ModuleKind,
};

const HostFixture = struct {
    modules: []const HostFixtureModule,

    fn findBySpecifierOrPath(self: HostFixture, specifier: []const u8) ?HostFixtureModule {
        for (self.modules) |module| {
            if (std.mem.eql(u8, module.specifier, specifier) or std.mem.eql(u8, module.path, specifier)) return module;
        }
        return null;
    }

    fn findByPath(self: HostFixture, path: []const u8) ?HostFixtureModule {
        for (self.modules) |module| {
            if (std.mem.eql(u8, module.path, path)) return module;
        }
        return null;
    }
};

fn hostHooks(host: *const HostFixture) engine.Engine.HostHooks {
    return .{
        .ptr = @constCast(host),
        .resolveModule = resolveFixtureModule,
        .loadModule = loadFixtureModule,
    };
}

fn resolveFixtureModule(
    ptr: *anyopaque,
    specifier: []const u8,
    referrer: ?[]const u8,
    allocator: std.mem.Allocator,
) anyerror!engine.Engine.HostHooks.ResolvedModule {
    _ = referrer;
    const host: *const HostFixture = @ptrCast(@alignCast(ptr));
    const module = host.findBySpecifierOrPath(specifier) orelse return error.ModuleNotFound;
    return .{
        .specifier = try allocator.dupe(u8, specifier),
        .path = try allocator.dupe(u8, module.path),
        .kind = module.kind,
    };
}

fn loadFixtureModule(
    ptr: *anyopaque,
    resolved: engine.Engine.HostHooks.ResolvedModule,
    allocator: std.mem.Allocator,
) anyerror!engine.Engine.HostHooks.LoadedModule {
    const host: *const HostFixture = @ptrCast(@alignCast(ptr));
    const module = host.findByPath(resolved.path) orelse return error.ModuleNotFound;
    return .{
        .source = module.source,
        .path = try allocator.dupe(u8, module.path),
        .kind = module.kind,
        .owned = false,
    };
}
