const std = @import("std");
const engine = @import("quickjs_zig_engine");

const core = engine.core;
const op = engine.bytecode.opcode.op;

const helpers = @import("exec_helpers.zig");
const oom_helpers = @import("oom_helpers.zig");
const makeFunction = helpers.makeFunction;
const runFunction = helpers.runFunction;
const objectFromValue = helpers.objectFromValue;
const expectActiveSetStrings = helpers.expectActiveSetStrings;

test "TypedArray array-like construction does not replay coercions after fast path bailout" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var calls = 0;
        \\var value = {
        \\  valueOf: function() {
        \\    calls++;
        \\    return 7;
        \\  }
        \\};
        \\var source = {};
        \\source.length = 2;
        \\source[0] = value;
        \\source.x = 1;
        \\source[1] = 8;
        \\var typed = new Int8Array(source);
        \\assert.sameValue(calls, 1);
        \\assert.sameValue(typed[0], 7);
        \\assert.sameValue(typed[1], 8);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "TypedArray defineProperty value conversion may detach buffer" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var ta = new Int8Array([17]);
        \\assert.sameValue(Reflect.defineProperty(ta, 0, {
        \\    value: {
        \\        valueOf: function() {
        \\            ta.buffer.transfer();
        \\            return 42;
        \\        }
        \\    }
        \\}), true);
        \\assert.sameValue(ta[0], undefined);
        \\
        \\var big = new BigInt64Array([17n]);
        \\assert.sameValue(Reflect.defineProperty(big, 0, {
        \\    value: {
        \\        valueOf: function() {
        \\            big.buffer.transfer();
        \\            return 42n;
        \\        }
        \\    }
        \\}), true);
        \\assert.sameValue(big[0], undefined);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Promise constructor resolve and reject functions inherit Function.prototype" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var resolveFunction;
        \\var rejectFunction;
        \\new Promise(function(resolve, reject) {
        \\    resolveFunction = resolve;
        \\    rejectFunction = reject;
        \\});
        \\assert.sameValue(Object.getPrototypeOf(resolveFunction), Function.prototype);
        \\assert.sameValue(Object.getPrototypeOf(rejectFunction), Function.prototype);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Promise resolving functions keep internal state off user properties" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var savedResolve;
        \\var savedReject;
        \\var promise = new Promise(function(resolve, reject) {
        \\    savedResolve = resolve;
        \\    savedReject = reject;
        \\});
        \\assert.sameValue("__zjs_promise_target" in savedResolve, false);
        \\assert.sameValue("__zjs_promise_reject" in savedResolve, false);
        \\assert.sameValue("__zjs_promise_state" in savedResolve, false);
        \\assert.sameValue(Object.getOwnPropertyDescriptor(savedResolve, "__zjs_promise_target"), undefined);
        \\savedResolve.__zjs_promise_target = null;
        \\savedResolve.__zjs_promise_reject = true;
        \\savedResolve.__zjs_promise_state = null;
        \\savedResolve(42);
        \\savedReject("ignored");
        \\promise.then(
        \\    function(value) { assert.sameValue(value, 42); },
        \\    function(reason) { throw new Test262Error("unexpected rejection: " + reason); }
        \\);
        \\var rejectOnly;
        \\var rejected = new Promise(function(resolve, reject) {
        \\    rejectOnly = reject;
        \\});
        \\rejectOnly.__zjs_promise_target = null;
        \\rejectOnly("bad");
        \\rejected.then(
        \\    function(value) { throw new Test262Error("unexpected fulfillment: " + value); },
        \\    function(reason) { assert.sameValue(reason, "bad"); }
        \\);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Promise.resolve rejects self-resolution from custom capability" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var resolve;
        \\var reject;
        \\var promise = new Promise(function(_resolve, _reject) {
        \\    resolve = _resolve;
        \\    reject = _reject;
        \\});
        \\function P(executor) {
        \\    executor(resolve, reject);
        \\    return promise;
        \\}
        \\Promise.resolve.call(P, promise).then(
        \\    function() { throw new Test262Error("should reject"); },
        \\    function(reason) { assert.sameValue(reason.constructor, TypeError); }
        \\);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Promise capability executor keeps internal slot off user properties" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function C(executor) {
        \\    assert.sameValue(typeof executor, "function");
        \\    assert.sameValue("__zjs_promise_capability_slot" in executor, false);
        \\    assert.sameValue(Object.getOwnPropertyDescriptor(executor, "__zjs_promise_capability_slot"), undefined);
        \\    assert.sameValue(executor.__zjs_promise_capability_slot, undefined);
        \\    executor.__zjs_promise_capability_slot = null;
        \\    executor(
        \\        function(value) { print("resolve", value); },
        \\        function(reason) { print("reject", reason); }
        \\    );
        \\    print("executor ok");
        \\}
        \\C.resolve = function(value) { return value; };
        \\Promise.resolve.call(C, 1);
        \\print("done");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("executor ok\nresolve 1\ndone\n", stream.buffered());
    try std.testing.expect(!js.context.hasException());
}

test "Promise combinator element callbacks inherit Function.prototype" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var resolveElementFunction;
        \\var rejectElementFunction;
        \\var resolveThenable = {
        \\    then: function(fulfill) {
        \\        resolveElementFunction = fulfill;
        \\    }
        \\};
        \\var rejectThenable = {
        \\    then: function(_, reject) {
        \\        rejectElementFunction = reject;
        \\    }
        \\};
        \\function NotPromise(executor) {
        \\    executor(function() {}, function() {});
        \\}
        \\NotPromise.resolve = function(v) { return v; };
        \\Promise.all.call(NotPromise, [resolveThenable]);
        \\Promise.allSettled.call(NotPromise, [rejectThenable]);
        \\assert.sameValue(Object.getPrototypeOf(resolveElementFunction), Function.prototype);
        \\assert.sameValue(Object.getPrototypeOf(rejectElementFunction), Function.prototype);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Promise combinator callbacks keep internal state off user properties" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var saved;
        \\var p0 = new Promise(function() {});
        \\p0.then = function(onFulfilled, onRejected) {
        \\    saved = onFulfilled;
        \\    return Promise.prototype.then.call(this, onFulfilled, onRejected);
        \\};
        \\var all = Promise.all([p0]);
        \\assert.sameValue("__zjs_promise_comb_mode" in saved, false);
        \\assert.sameValue("__zjs_promise_comb_state" in saved, false);
        \\assert.sameValue("__zjs_promise_comb_index" in saved, false);
        \\assert.sameValue("__zjs_promise_comb_called" in saved, false);
        \\assert.sameValue(Object.getOwnPropertyDescriptor(saved, "__zjs_promise_comb_mode"), undefined);
        \\assert.sameValue(saved.__zjs_promise_comb_mode, undefined);
        \\saved.__zjs_promise_comb_called = 1;
        \\saved.__zjs_promise_comb_state = null;
        \\saved.__zjs_promise_comb_index = 99;
        \\saved("ok");
        \\all.then(
        \\    function(values) { assert.sameValue(values[0], "ok"); },
        \\    function(reason) { throw new Test262Error("unexpected rejection: " + reason); }
        \\);
        \\
        \\var onFulfilled;
        \\var onRejected;
        \\var p1 = new Promise(function() {});
        \\p1.then = function(fulfill, reject) {
        \\    onFulfilled = fulfill;
        \\    onRejected = reject;
        \\    return Promise.prototype.then.call(this, fulfill, reject);
        \\};
        \\var settled = Promise.allSettled([p1]);
        \\assert.sameValue("__zjs_promise_comb_mode" in onFulfilled, false);
        \\assert.sameValue("__zjs_promise_comb_mode" in onRejected, false);
        \\onFulfilled.__zjs_promise_comb_called = 1;
        \\onRejected.__zjs_promise_comb_called = 1;
        \\onRejected("bad");
        \\onFulfilled("ignored");
        \\settled.then(
        \\    function(values) {
        \\        assert.sameValue(values[0].status, "fulfilled");
        \\        assert.sameValue(values[0].value, "ignored");
        \\        assert.sameValue(values[0].reason, undefined);
        \\    },
        \\    function(reason) { throw new Test262Error("unexpected rejection: " + reason); }
        \\);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "pending Promise.then reactions run after deferred settlement" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var resolve;
        \\var p = new Promise(function(r) { resolve = r; });
        \\var q = p.then(function(v) { print("first", v); return v + "!"; });
        \\p.then(function(v) { print("second", v); });
        \\q.then(function(v) { print("chain", v); });
        \\resolve("ok");
        \\print("after resolve");
        \\
        \\var reject;
        \\var bad = new Promise(function(resolve, r) { reject = r; });
        \\bad.then(null, function(reason) { print("caught", reason); return "handled"; })
        \\   .then(function(v) { print("recovered", v); });
        \\reject("boom");
        \\print("after reject");
        \\
        \\var passResolve;
        \\var pass = new Promise(function(r) { passResolve = r; });
        \\pass.then().then(function(v) { print("pass", v); });
        \\passResolve("through");
        \\print("after pass");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "after resolve\nafter reject\nafter pass\nfirst ok\nsecond ok\ncaught boom\nchain ok!\nrecovered handled\npass through\n",
        stream.buffered(),
    );
    try std.testing.expect(!js.context.hasException());
}

test "settled Promise.then reactions run as deferred jobs" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\Promise.resolve("ok")
        \\    .then(function(v) { print("then", v); return v + "!"; })
        \\    .then(function(v) { print("chain", v); });
        \\Promise.reject("bad")
        \\    .then(undefined, function(v) { print("caught", v); return "handled"; })
        \\    .then(function(v) { print("recovered", v); });
        \\print("sync");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "sync\nthen ok\ncaught bad\nchain ok!\nrecovered handled\n",
        stream.buffered(),
    );
    try std.testing.expect(!js.context.hasException());
}

test "Promise.finally callbacks keep internal state off user properties" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var savedFulfill;
        \\var savedReject;
        \\var cleanupCount = 0;
        \\var p = new Promise(function() {});
        \\p.then = function(onFulfilled, onRejected) {
        \\    savedFulfill = onFulfilled;
        \\    savedReject = onRejected;
        \\    return Promise.prototype.then.call(this, onFulfilled, onRejected);
        \\};
        \\p.finally(function() {
        \\    cleanupCount += 1;
        \\    print("cleanup", cleanupCount);
        \\    return "cleanup-result";
        \\});
        \\assert.sameValue("__zjs_promise_finally_mode" in savedFulfill, false);
        \\assert.sameValue("__zjs_promise_finally_callback" in savedFulfill, false);
        \\assert.sameValue("__zjs_promise_finally_constructor" in savedFulfill, false);
        \\assert.sameValue("__zjs_promise_finally_mode" in savedReject, false);
        \\assert.sameValue(Object.getOwnPropertyDescriptor(savedFulfill, "__zjs_promise_finally_mode"), undefined);
        \\assert.sameValue(savedFulfill.__zjs_promise_finally_mode, undefined);
        \\savedFulfill.__zjs_promise_finally_callback = function() {
        \\    print("tampered");
        \\    return "bad";
        \\};
        \\savedFulfill.__zjs_promise_finally_payload = "bad";
        \\savedFulfill("direct");
        \\print("after direct");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("cleanup 1\nafter direct\n", stream.buffered());
    try std.testing.expect(!js.context.hasException());
}

test "Promise.allSettled reject element callback is alreadyCalled guarded" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\let rejectCallCount = 0;
        \\let returnValue = {};
        \\let error = new Test262Error();
        \\function Constructor(executor) {
        \\    function reject(value) {
        \\        assert.sameValue(value, error);
        \\        rejectCallCount += 1;
        \\        return returnValue;
        \\    }
        \\    executor(() => { throw error; }, reject);
        \\}
        \\Constructor.resolve = function(v) { return v; };
        \\Constructor.reject = function(v) { return v; };
        \\let pOnRejected;
        \\let p = {
        \\    then(onResolved, onRejected) {
        \\        pOnRejected = onRejected;
        \\        onResolved();
        \\    }
        \\};
        \\Promise.allSettled.call(Constructor, [p]);
        \\assert.sameValue(rejectCallCount, 1);
        \\assert.sameValue(pOnRejected(), undefined);
        \\assert.sameValue(rejectCallCount, 1);
        \\pOnRejected();
        \\assert.sameValue(rejectCallCount, 1);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Promise.all accepts string iterables through the built-in Promise path" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\Promise.all("ab").then(v => {
        \\    print(v.length);
        \\    print(v[0]);
        \\    print(v[1]);
        \\});
        \\print("after");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("after\n2\na\nb\n", stream.buffered());
    try std.testing.expect(!js.context.hasException());
}

test "Promise.race accepts Set iterables through the built-in Promise path" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\Promise.race(new Set([1, 2])).then(v => print(v));
        \\print("after");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("after\n1\n", stream.buffered());
    try std.testing.expect(!js.context.hasException());
}

test "Promise.allSettled accepts Set iterables through the built-in Promise path" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\Promise.allSettled(new Set([1, 2])).then(v => {
        \\    print(v.length);
        \\    print(v[0].status);
        \\    print(v[0].value);
        \\    print(v[1].status);
        \\    print(v[1].value);
        \\});
        \\print("after");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("after\n2\nfulfilled\n1\nfulfilled\n2\n", stream.buffered());
    try std.testing.expect(!js.context.hasException());
}

test "Promise keyed combinators preserve enumerable own keys" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(Promise.allKeyed.length);
        \\print(Promise.allSettledKeyed.name);
        \\var resolveFirst;
        \\var sym = Symbol("s");
        \\var input = {
        \\    first: new Promise(resolve => { resolveFirst = resolve; }),
        \\    second: Promise.resolve("two"),
        \\};
        \\input[sym] = Promise.resolve("sym");
        \\Object.defineProperty(input, "hidden", {
        \\    enumerable: false,
        \\    value: Promise.resolve("hidden"),
        \\});
        \\Promise.allKeyed(input).then(result => {
        \\    print(Object.getPrototypeOf(result) === null);
        \\    print(Object.keys(result).join("|"));
        \\    print(result.first + "|" + result.second + "|" + result[sym]);
        \\    print(result.hidden);
        \\});
        \\Promise.allSettledKeyed({
        \\    ok: Promise.resolve(1),
        \\    bad: Promise.reject("x"),
        \\}).then(result => {
        \\    print(result.ok.status + ":" + result.ok.value);
        \\    print(result.bad.status + ":" + result.bad.reason);
        \\});
        \\resolveFirst("one");
        \\print("after");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "1\nallSettledKeyed\nafter\nfulfilled:1\nrejected:x\ntrue\nfirst|second\none|two|sym\nundefined\n",
        stream.buffered(),
    );
    try std.testing.expect(!js.context.hasException());
}

test "Promise keyed combinator OOM releases intermediate arrays once" {
    try expectPromiseKeyedCombinatorOOMCleanup(
        \\var applyFn = Reflect.apply;
        \\var allKeyedFn = Promise.allKeyed;
        \\Promise.resolve(0).then(function(v){ return v; });
        \\applyFn(allKeyedFn, Promise, [{ first: 1, second: 2 }]).then(function(){});
        \\Reflect.apply(Promise.allSettledKeyed, Promise, [{ ok: 1, bad: 2 }]).then(function(){});
        \\var keyedInput = { first: 1, second: 2 };
        \\var keyedArgs = [keyedInput];
    ,
        "applyFn(allKeyedFn, Promise, keyedArgs)",
    );
    try expectPromiseKeyedCombinatorOOMCleanup(
        \\var applyFn = Reflect.apply;
        \\var allSettledKeyedFn = Promise.allSettledKeyed;
        \\Promise.resolve(0).then(function(v){ return v; });
        \\Reflect.apply(Promise.allKeyed, Promise, [{ first: 1, second: 2 }]).then(function(){});
        \\applyFn(allSettledKeyedFn, Promise, [{ ok: 1, bad: 2 }]).then(function(){});
        \\var settledInput = { ok: 1, bad: 2 };
        \\var settledArgs = [settledInput];
    ,
        "applyFn(allSettledKeyedFn, Promise, settledArgs)",
    );
}

fn expectPromiseKeyedCombinatorOOMCleanup(setup_src: []const u8, src: []const u8) !void {
    var saw_oom = false;
    var saw_success = false;

    if (!oom_helpers.fullSweep()) {
        const rt = try core.JSRuntime.create(std.testing.allocator);
        const ctx = try core.JSContext.create(rt);
        var warmup = try engine.frontend.parser.parse(rt, setup_src, .{ .return_completion = true });
        var compiled = try engine.frontend.parser.parse(rt, src, .{ .return_completion = true });
        var vm = engine.exec.Vm.init(ctx);

        const warmup_result = try vm.run(&warmup.function);
        const warmup_global = try engine.exec.zjs_vm.contextGlobal(ctx);
        try engine.exec.zjs_vm.drainPendingPromiseJobs(ctx, null, warmup_global);
        warmup_result.free(rt);

        const result = try vm.run(&compiled.function);
        const global = try engine.exec.zjs_vm.contextGlobal(ctx);
        try engine.exec.zjs_vm.drainPendingPromiseJobs(ctx, null, global);
        result.free(rt);

        cleanupPromiseKeyedCombinatorOOMIteration(rt, ctx, &vm, &compiled, &warmup);
        saw_success = true;
    }

    const samples = oom_helpers.defaultSampleSet(240);
    var fail_offset: usize = 0;
    while (fail_offset < samples.limit) : (fail_offset += 1) {
        if (!oom_helpers.shouldRunOffset(samples, fail_offset)) continue;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const rt = try core.JSRuntime.create(failing.allocator());
        const ctx = try core.JSContext.create(rt);

        var warmup = try engine.frontend.parser.parse(rt, setup_src, .{ .return_completion = true });
        var compiled = try engine.frontend.parser.parse(rt, src, .{ .return_completion = true });

        var vm = engine.exec.Vm.init(ctx);
        const warmup_result = try vm.run(&warmup.function);
        const warmup_global = try engine.exec.zjs_vm.contextGlobal(ctx);
        try engine.exec.zjs_vm.drainPendingPromiseJobs(ctx, null, warmup_global);
        warmup_result.free(rt);

        failing.fail_index = failing.alloc_index + fail_offset;
        const result = vm.run(&compiled.function);
        failing.fail_index = std.math.maxInt(usize);

        if (result) |value| {
            saw_success = true;
            const global = try engine.exec.zjs_vm.contextGlobal(ctx);
            try engine.exec.zjs_vm.drainPendingPromiseJobs(ctx, null, global);
            value.free(rt);
        } else |err| switch (err) {
            error.OutOfMemory => saw_oom = true,
            else => |unexpected| {
                cleanupPromiseKeyedCombinatorOOMIteration(rt, ctx, &vm, &compiled, &warmup);
                return unexpected;
            },
        }

        cleanupPromiseKeyedCombinatorOOMIteration(rt, ctx, &vm, &compiled, &warmup);
        if (oom_helpers.shouldStopAfterCoverage(saw_oom, saw_success)) return;
    }

    try std.testing.expect(saw_oom);
    try std.testing.expect(saw_success);
}

fn cleanupPromiseKeyedCombinatorOOMIteration(
    rt: *core.JSRuntime,
    ctx: *core.JSContext,
    vm: *engine.exec.Vm,
    compiled: *engine.frontend.parser.Result,
    warmup: *engine.frontend.parser.Result,
) void {
    if (ctx.hasException()) {
        const exception = ctx.takeException();
        exception.free(rt);
    }
    if (ctx.hasUnhandledRejection()) {
        const rejection = ctx.takeUnhandledRejection();
        rejection.free(rt);
    }
    vm.deinit();
    compiled.deinit();
    warmup.deinit();
    ctx.destroy();
    rt.destroy();
}

test "Promise.any accepts Set iterables through the built-in Promise path" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\Promise.any(new Set([1, 2])).then(v => print(v), e => print(e.name));
        \\print("after");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("after\n1\n", stream.buffered());
    try std.testing.expect(!js.context.hasException());
}

test "Engine eval executes named instanceof smoke subset" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function Foo() {}
        \\const foo = new Foo();
        \\print(foo instanceof Foo);
        \\print({} instanceof Object);
        \\print([] instanceof Array);
        \\print([] instanceof Object);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\ntrue\ntrue\ntrue\n", stream.buffered());
}

test "Engine eval executes Number parse smoke subset" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var quick_output_buffer: [256]u8 = undefined;
    var quick_stream = std.Io.Writer.fixed(&quick_output_buffer);
    const quick_result = try js.evalWithOutput(
        \\print(parseInt("0x10"));
        \\print(parseInt("0x10", 10));
        \\print(parseInt("11", "2"));
        \\print(parseInt("11", true));
        \\print(parseFloat("1.5x"));
        \\print(Number.parseInt("42"));
        \\print(Number.parseFloat("3.14"));
        \\print(Number.POSITIVE_INFINITY);
    , &quick_stream);
    defer quick_result.free(js.runtime);

    try std.testing.expect(quick_result.isUndefined());
    try std.testing.expectEqualStrings("16\n0\n3\nNaN\n1.5\n42\n3.14\nInfinity\n", quick_stream.buffered());

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(Number.parseInt("42"));
        \\print(Number.parseFloat("3.14"));
        \\print(Number.NaN);
        \\print(Number.POSITIVE_INFINITY);
        \\print(Number.NEGATIVE_INFINITY);
        \\print(typeof globalThis);
        \\print(globalThis.globalThis === globalThis);
        \\print(globalThis.Math === Math);
        \\print(parseInt("0x10"));
        \\print(parseInt("0x10", 16));
        \\print(parseInt("0x10", 10));
        \\print(parseInt("-0xF"));
        \\print(parseInt("+0xF"));
        \\print(parseInt("10", 1));
        \\print(parseInt("10", 37));
        \\print(parseInt("12px"));
        \\print(1 / parseInt("-0"));
        \\print(parseFloat("1.5x"));
        \\print(parseFloat("+.5x"));
        \\print(parseFloat("Infinityx"));
        \\print(parseFloat("-Infinityx"));
        \\print(parseFloat("x1"));
        \\print(1 / parseFloat("-0"));
        \\print(parseFloat("1_1"));
        \\print(parseFloat("1.0e-1_0"));
        \\print(parseFloat("0x1"));
        \\print(parseFloat("\u00A01.1"));
        \\print(parseFloat("\u20281.1"));
        \\print(parseFloat(new Number(-1.1)));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("42\n3.14\nNaN\nInfinity\n-Infinity\nobject\ntrue\ntrue\n16\n16\n0\n-15\n15\nNaN\nNaN\n12\n-Infinity\n1.5\n0.5\nInfinity\n-Infinity\nNaN\n-Infinity\n1\n0.1\n0\n1.1\n1.1\n-1.1\n", stream.buffered());
}

test "Engine eval executes object helper smoke subset" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const o = { a: 1, b: 2 };
        \\print(o.a, o.b);
        \\o.c = 3;
        \\print(o.c);
        \\print(Object.keys(o).join(","));
        \\print(Object.values(o).join(","));
        \\print(JSON.stringify(Object.entries(o)));
        \\var keyOrder = "";
        \\for (var k in o) keyOrder += k;
        \\print(keyOrder);
        \\var proto = { shadowed: 1 };
        \\var child = Object.create(proto, { own: { value: 2, enumerable: true }, shadowed: { value: 3, enumerable: false } });
        \\var childKeys = "";
        \\for (var childKey in child) childKeys += childKey;
        \\print(childKeys);
        \\Object.defineProperty(o, "a", { value: 11 });
        \\var preservedKeys = "";
        \\for (var preservedKey in o) preservedKeys += preservedKey;
        \\print(preservedKeys);
        \\const arr = [10, 20, 30];
        \\print(arr[0], arr[1], arr[2]);
        \\print(arr.length);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1 2\n3\na,b,c\n1,2,3\n[[\"a\",1],[\"b\",2],[\"c\",3]]\nabc\nown\nabc\n10 20 30\n3\n", stream.buffered());
}

test "Object.defineProperty returns retained target object" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const proto = Map.prototype;
        \\const returned = Object.defineProperty(proto, "sentinel", { value: 7, writable: true, configurable: true });
        \\print(returned === proto);
        \\print(Map.prototype.sentinel);
        \\const map = new Map();
        \\map.set("key", "value");
        \\print(map.get("key"));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\n7\nvalue\n", stream.buffered());
}

test "Engine eval executes Map groupBy and iterable construction" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\new Map();
        \\const grouped = Map.groupBy([1, 2, 3], function (i) {
        \\  return i % 2 === 0 ? "even" : "odd";
        \\});
        \\print(grouped.size);
        \\print(Array.from(grouped.keys()).join(","));
        \\print(grouped.get("odd").join(","));
        \\const constructed = new Map([["a", 1], ["b", 2]]);
        \\print(constructed.size);
        \\print(constructed.get("b"));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("2\nodd,even\n1,3\n2\n2\n", stream.buffered());
}

test "Map and Set iterator next lives on iterator prototypes" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var mapIterator = new Map([[1, 2]]).values();
        \\var mapProto = Object.getPrototypeOf(mapIterator);
        \\var mapProtoAgain = Object.getPrototypeOf(new Map().keys());
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(mapIterator, "next"), false);
        \\assert.sameValue(mapIterator.__proto__, mapProto);
        \\assert.sameValue(mapProtoAgain, mapProto);
        \\assert.sameValue(Object.getPrototypeOf(mapProto), Iterator.prototype);
        \\var mapTag = Object.getOwnPropertyDescriptor(mapIterator.__proto__, Symbol.toStringTag);
        \\assert.sameValue(mapTag.value, "Map Iterator");
        \\assert.sameValue(mapTag.writable, false);
        \\assert.sameValue(mapTag.enumerable, false);
        \\assert.sameValue(mapTag.configurable, true);
        \\assert.sameValue(typeof mapProto.next, "function");
        \\assert.sameValue(mapProto.next.length, 0);
        \\assert.sameValue(mapProto.next.name, "next");
        \\assert.sameValue(mapProto.next.call(mapIterator).value, 2);
        \\var setIterator = new Set([3]).values();
        \\var setProto = Object.getPrototypeOf(setIterator);
        \\var setProtoAgain = Object.getPrototypeOf(new Set().keys());
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(setIterator, "next"), false);
        \\assert.sameValue(setIterator.__proto__, setProto);
        \\assert.sameValue(setProtoAgain, setProto);
        \\assert.sameValue(Object.getPrototypeOf(setProto), Iterator.prototype);
        \\var setTag = Object.getOwnPropertyDescriptor(setIterator.__proto__, Symbol.toStringTag);
        \\assert.sameValue(setTag.value, "Set Iterator");
        \\assert.sameValue(setTag.writable, false);
        \\assert.sameValue(setTag.enumerable, false);
        \\assert.sameValue(setTag.configurable, true);
        \\assert.sameValue(typeof setProto.next, "function");
        \\assert.sameValue(setProto.next.length, 0);
        \\assert.sameValue(setProto.next.name, "next");
        \\assert.sameValue(setProto.next.call(setIterator).value, 3);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Engine eval executes typed array smoke subset" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const ab = new ArrayBuffer(16);
        \\console.log(ab.byteLength);
        \\console.log(ab.slice(0, 8));
        \\const int8 = new Int8Array(ab);
        \\console.log(int8.length);
        \\console.log(int8.byteLength);
        \\console.log(int8.byteOffset);
        \\const uint8 = new Uint8Array(ab);
        \\console.log(uint8.length);
        \\const int16 = new Int16Array(ab);
        \\console.log(int16.length);
        \\const uint16 = new Uint16Array(ab);
        \\console.log(uint16.length);
        \\const int32 = new Int32Array(ab);
        \\console.log(int32.length);
        \\int32[0] = 3;
        \\console.log(int32[0]);
        \\int32[99] = 5;
        \\console.log(int32[99]);
        \\const uint32 = new Uint32Array(ab);
        \\console.log(uint32.length);
        \\const float32 = new Float32Array(ab);
        \\console.log(float32.length);
        \\const float64 = new Float64Array(ab);
        \\console.log(float64.length);
        \\const dv = new DataView(ab);
        \\console.log(dv.buffer);
        \\console.log(dv.byteLength);
        \\console.log(dv.byteOffset);
        \\console.log(dv.getInt8(0));
        \\console.log(dv.getUint8(0));
        \\console.log(dv.getInt16(0));
        \\console.log(dv.getUint16(0));
        \\console.log(dv.getInt32(0));
        \\console.log(dv.getUint32(0));
        \\console.log(dv.getFloat32(0));
        \\console.log(dv.getFloat64(0));
        \\dv.setInt8(0, 1);
        \\dv.setUint8(0, 1);
        \\dv.setInt16(0, 1);
        \\dv.setUint16(0, 1);
        \\dv.setInt32(0, 1);
        \\dv.setUint32(0, 1);
        \\dv.setUint32(0, 4294967295);
        \\console.log(dv.getUint32(0));
        \\dv.setUint32(0, -1);
        \\console.log(dv.getUint32(0));
        \\dv.setFloat32(0, 1.0);
        \\dv.setFloat64(0, 1.0);
        \\const dv2 = new DataView(ab, 1, 2);
        \\console.log(dv2.byteOffset);
        \\console.log(dv2.byteLength);
        \\dv2.setInt16(0, 4660, true);
        \\console.log(dv2.getUint8(0));
        \\console.log(dv2.getUint8(1));
        \\console.log(dv2.getInt16(0, true));
        \\const dv4 = new DataView(ab);
        \\console.log(dv4.getUint8(1));
        \\console.log(dv4.getUint8(2));
        \\const sliced = ab.slice(1, 3);
        \\const sdv = new DataView(sliced);
        \\console.log(sliced.byteLength);
        \\console.log(sdv.getUint8(0));
        \\console.log(sdv.getUint8(1));
        \\const big = new DataView(new ArrayBuffer(8));
        \\big.setBigInt64(0, -1n);
        \\console.log(big.getBigInt64(0));
        \\big.setBigUint64(0, 18446744073709551615n);
        \\console.log(big.getBigUint64(0));
        \\const dv3 = new DataView(ab, undefined, undefined);
        \\console.log(dv3.byteOffset);
        \\console.log(dv3.byteLength);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("16\n[object ArrayBuffer]\n16\n16\n0\n16\n8\n8\n4\n3\nundefined\n4\n4\n2\n[object ArrayBuffer]\n16\n0\n3\n3\n768\n768\n50331648\n50331648\n3.76158192263132e-37\n3.13151306251402e-294\n4294967295\n4294967295\n1\n2\n52\n18\n4660\n52\n18\n2\n52\n18\n-1\n18446744073709551615\n0\n16\n", stream.buffered());
}

test "BigInt typed arrays wrap values to low 64 bits" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var values = [
        \\    18446744073709551618n,
        \\    9223372036854775810n,
        \\    2n,
        \\    0n,
        \\    -2n,
        \\    -9223372036854775810n,
        \\    -18446744073709551618n,
        \\];
        \\var signedExpected = [
        \\    2n,
        \\    -9223372036854775806n,
        \\    2n,
        \\    0n,
        \\    -2n,
        \\    9223372036854775806n,
        \\    -2n,
        \\];
        \\var unsignedExpected = [
        \\    2n,
        \\    9223372036854775810n,
        \\    2n,
        \\    0n,
        \\    18446744073709551614n,
        \\    9223372036854775806n,
        \\    18446744073709551614n,
        \\];
        \\var signed = new BigInt64Array(values);
        \\var signedSet = new BigInt64Array(values.length);
        \\signedSet.set(values);
        \\var unsigned = new BigUint64Array(values);
        \\var unsignedSet = new BigUint64Array(values.length);
        \\unsignedSet.set(values);
        \\for (var i = 0; i < values.length; i++) {
        \\    assert.sameValue(signed[i], signedExpected[i]);
        \\    assert.sameValue(signedSet[i], signedExpected[i]);
        \\    assert.sameValue(unsigned[i], unsignedExpected[i]);
        \\    assert.sameValue(unsignedSet[i], unsignedExpected[i]);
        \\}
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "TypedArray.prototype.toString is configurable Array.prototype.toString alias" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var proto = TypedArray.prototype;
        \\var original = Object.getOwnPropertyDescriptor(proto, "toString");
        \\assert.sameValue(original.value, Array.prototype.toString);
        \\assert.sameValue(original.writable, true);
        \\assert.sameValue(original.enumerable, false);
        \\assert.sameValue(original.configurable, true);
        \\assert.sameValue(delete proto.toString, true);
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(proto, "toString"), false);
        \\Object.defineProperty(proto, "toString", original);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "typed array constructor OOM releases owned backing buffer once" {
    var saw_oom = false;
    var saw_success = false;

    if (!oom_helpers.fullSweep()) {
        const rt = try core.JSRuntime.create(std.testing.allocator);
        defer rt.destroy();
        const value = try engine.exec.construct.constructTypedArrayValue(
            rt,
            null,
            .{ .size = 1, .kind = 2 },
            &.{core.JSValue.int32(4)},
            null,
        );
        value.free(rt);
        saw_success = true;
    }

    const samples = oom_helpers.defaultSampleSet(96);
    var fail_offset: usize = 0;
    while (fail_offset < samples.limit) : (fail_offset += 1) {
        if (!oom_helpers.shouldRunOffset(samples, fail_offset)) continue;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const rt = try core.JSRuntime.create(failing.allocator());

        failing.fail_index = failing.alloc_index + fail_offset;
        const result = engine.exec.construct.constructTypedArrayValue(
            rt,
            null,
            .{ .size = 1, .kind = 2 },
            &.{core.JSValue.int32(4)},
            null,
        );
        failing.fail_index = std.math.maxInt(usize);

        if (result) |value| {
            saw_success = true;
            value.free(rt);
        } else |err| switch (err) {
            error.OutOfMemory => saw_oom = true,
            else => |unexpected| {
                rt.destroy();
                return unexpected;
            },
        }

        rt.destroy();
        if (oom_helpers.shouldStopAfterCoverage(saw_oom, saw_success)) return;
    }

    try std.testing.expect(saw_oom);
    try std.testing.expect(saw_success);
}

test "typed array fused ArrayBuffer constructor OOM releases owned backing buffer once" {
    try expectVmEvalOOMCleanup("var ta = new Uint8Array(new ArrayBuffer(4)); ta.length;", 220);
}

test "Uint8Array.fromHex OOM releases owned backing buffer once" {
    try expectVmEvalOOMCleanup("var ta = Uint8Array.fromHex('00010203'); ta.length;", 260);
}

fn expectVmEvalOOMCleanup(source: []const u8, comptime fail_limit: usize) !void {
    var saw_oom = false;
    var saw_success = false;

    if (!oom_helpers.fullSweep()) {
        var js = try engine.harness.Engine.init(std.testing.allocator);
        defer js.deinit();
        const value = try js.eval(source);
        value.free(js.runtime);
        saw_success = true;
    }

    const samples = oom_helpers.defaultSampleSet(fail_limit);
    var fail_offset: usize = 0;
    while (fail_offset < samples.limit) : (fail_offset += 1) {
        if (!oom_helpers.shouldRunOffset(samples, fail_offset)) continue;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var js = try engine.harness.Engine.init(failing.allocator());

        const warmup = try js.eval(source);
        warmup.free(js.runtime);

        var parsed = try engine.frontend.parser.parse(js.runtime, source, .{ .return_completion = true });
        var vm = engine.exec.Vm.init(js.context);

        failing.fail_index = failing.alloc_index + fail_offset;
        const result = vm.run(&parsed.function);
        failing.fail_index = std.math.maxInt(usize);

        if (result) |value| {
            saw_success = true;
            value.free(js.runtime);
        } else |err| switch (err) {
            error.OutOfMemory => saw_oom = true,
            else => |unexpected| {
                vm.deinit();
                parsed.deinit();
                js.deinit();
                return unexpected;
            },
        }

        vm.deinit();
        parsed.deinit();
        js.deinit();
        if (oom_helpers.shouldStopAfterCoverage(saw_oom, saw_success)) return;
    }

    try std.testing.expect(saw_oom);
    try std.testing.expect(saw_success);
}

test "Engine eval executes Map Set smoke subset" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const map = new Map();
        \\map.set("key", "value");
        \\console.log(map.get("key"));
        \\console.log(map.has("key"));
        \\console.log(map.size);
        \\map.delete("key");
        \\map.clear();
        \\const set = new Set();
        \\set.add(1);
        \\console.log(set.has(1));
        \\console.log(set.size);
        \\set.delete(1);
        \\set.clear();
        \\const weakMap = new WeakMap();
        \\console.log(typeof weakMap);
        \\console.log(weakMap.set);
        \\console.log(weakMap.get);
        \\console.log(weakMap.has);
        \\console.log(weakMap.delete);
        \\const weakSet = new WeakSet();
        \\console.log(typeof weakSet);
        \\console.log(weakSet.add);
        \\console.log(weakSet.has);
        \\console.log(weakSet.delete);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("value\ntrue\n1\ntrue\n1\nobject\nfunction set() {\n    [native code]\n}\nfunction get() {\n    [native code]\n}\nfunction has() {\n    [native code]\n}\nfunction delete() {\n    [native code]\n}\nobject\nfunction add() {\n    [native code]\n}\nfunction has() {\n    [native code]\n}\nfunction delete() {\n    [native code]\n}\n", stream.buffered());
}

test "Engine eval executes collection smoke fixture subset through quick parser" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const map = new Map();
        \\map.set("key", "value");
        \\print(map.get("key"));
        \\print(map.has("key"));
        \\print(map.size);
        \\print(map.delete("key"));
        \\const set = new Set();
        \\set.add(1);
        \\print(set.has(1));
        \\print(set.size);
        \\print(set.delete(1));
        \\const weakMap = new WeakMap();
        \\const weakKey = {};
        \\weakMap.set(weakKey, "weak");
        \\print(weakMap.get(weakKey));
        \\print(weakMap.has(weakKey));
        \\print(weakMap.delete(weakKey));
        \\const weakSet = new WeakSet();
        \\const weakSetKey = {};
        \\weakSet.add(weakSetKey);
        \\print(weakSet.has(weakSetKey));
        \\print(weakSet.delete(weakSetKey));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("value\ntrue\n1\ntrue\ntrue\n1\ntrue\nweak\ntrue\ntrue\ntrue\ntrue\n", stream.buffered());
}

test "WeakMap and WeakSet accept non-registered symbols as weak keys" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const key = Symbol("weak");
        \\const other = Symbol("weak");
        \\const map = new WeakMap([[key, 1]]);
        \\assert.sameValue(map.get(key), 1);
        \\assert.sameValue(map.has(other), false);
        \\assert.sameValue(map.set(other, 2), map);
        \\assert.sameValue(map.get(other), 2);
        \\assert.sameValue(map.delete(key), true);
        \\assert.sameValue(map.has(key), false);
        \\const set = new WeakSet([key]);
        \\assert.sameValue(set.has(key), true);
        \\assert.sameValue(set.add(other), set);
        \\assert.sameValue(set.has(other), true);
        \\assert.sameValue(set.delete(key), true);
        \\assert.sameValue(set.has(key), false);
        \\assert.throws(TypeError, function () { map.set(Symbol.for("registered"), 3); });
        \\assert.throws(TypeError, function () { set.add(Symbol.for("registered")); });
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "host WeakMap mutation closure rejects registered symbol keys" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const map_value = try engine.builtins.collection.construct(rt, 3);
    defer map_value.free(rt);
    const map_object = objectFromValue(map_value);

    const closure_value = try engine.exec.closure.create(rt, 39, 0, 0, 0);
    defer closure_value.free(rt);

    const registered_name = try std.fmt.allocPrint(rt.memory.allocator, "{s}registered", .{engine.builtins.symbol.registry_prefix});
    defer rt.memory.allocator.free(registered_name);
    const registered_atom = try rt.atoms.internSymbol(registered_name);
    defer rt.atoms.free(registered_atom);

    const map_name = try rt.internAtom("map");
    defer rt.atoms.free(map_name);
    const key_name = try rt.internAtom("obj3");
    defer rt.atoms.free(key_name);

    var globals = [_]engine.exec.globals.Slot{
        .{ .name = map_name, .value = map_value.dup() },
        .{ .name = key_name, .value = core.JSValue.symbol(registered_atom) },
    };
    defer globals[0].value.free(rt);

    if (engine.exec.closure.call(rt, closure_value, &.{}, globals[0..])) |value| {
        defer value.free(rt);
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(error.TypeError, err);
    }
    try std.testing.expectEqual(@as(usize, 0), map_object.weakCollectionEntries().len);
}

test "host WeakMap mutation closure links entries into existing weak index" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const map_value = try engine.builtins.collection.construct(rt, 3);
    defer map_value.free(rt);
    const map_object = objectFromValue(map_value);

    var keys: [8]*core.Object = undefined;
    var key_count: usize = 0;
    defer {
        for (keys[0..key_count]) |key| key.value().free(rt);
    }

    for (&keys, 0..) |*slot, index| {
        const key = try core.Object.create(rt, core.class.ids.object, null);
        slot.* = key;
        key_count += 1;
        const result = try engine.builtins.collection.methodCall(rt, map_value, 1, &.{ key.value(), core.JSValue.int32(@intCast(index)) });
        result.free(rt);
    }
    try std.testing.expectEqual(@as(usize, 8), map_object.weakCollectionEntries().len);
    try std.testing.expect(map_object.collectionBucketHeads().len != 0);

    const mutation_key = try core.Object.create(rt, core.class.ids.object, null);
    defer mutation_key.value().free(rt);

    const closure_value = try engine.exec.closure.create(rt, 39, 0, 0, 0);
    defer closure_value.free(rt);

    const map_name = try rt.internAtom("map");
    defer rt.atoms.free(map_name);
    const key_name = try rt.internAtom("obj3");
    defer rt.atoms.free(key_name);

    var globals = [_]engine.exec.globals.Slot{
        .{ .name = map_name, .value = map_value.dup() },
        .{ .name = key_name, .value = mutation_key.value().dup() },
    };
    defer globals[0].value.free(rt);
    defer globals[1].value.free(rt);

    try std.testing.expectError(error.Test262Error, engine.exec.closure.call(rt, closure_value, &.{}, globals[0..]));

    try std.testing.expectEqual(@as(usize, 9), map_object.weakCollectionEntries().len);
    const get_result = try engine.builtins.collection.methodCall(rt, map_value, 2, &.{mutation_key.value()});
    defer get_result.free(rt);
    try helpers.expectStringValueBytes(get_result, "mutated");
}

test "Set.prototype.symmetricDifference tracks receiver mutations without fixture skips" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const base_set_value = try engine.builtins.collection.construct(rt, 2);
    defer base_set_value.free(rt);
    const base_set = objectFromValue(base_set_value);

    inline for (.{ "a", "b", "c", "d", "e", "q" }) |name| {
        const value = (try core.string.String.createUtf8(rt, name)).value();
        defer value.free(rt);
        const out = try engine.builtins.collection.methodCall(rt, base_set_value, 6, &.{value});
        out.free(rt);
    }

    const setlike = try core.Object.create(rt, core.class.ids.object, null);
    const setlike_value = setlike.value();
    defer setlike_value.free(rt);

    const size_key = try rt.internAtom("size");
    defer rt.atoms.free(size_key);
    try setlike.defineOwnProperty(rt, size_key, core.Descriptor.data(core.JSValue.int32(4), true, true, true));

    const mode_key = try rt.internAtom("__setlike_mode");
    defer rt.atoms.free(mode_key);
    try setlike.defineOwnProperty(rt, mode_key, core.Descriptor.data(core.JSValue.int32(5), true, true, true));

    const noop = try engine.exec.closure.create(rt, 13, 0, 0, 0);
    defer noop.free(rt);

    const has_key = try rt.internAtom("has");
    defer rt.atoms.free(has_key);
    try setlike.defineOwnProperty(rt, has_key, core.Descriptor.data(noop, true, true, true));

    const keys_key = try rt.internAtom("keys");
    defer rt.atoms.free(keys_key);
    try setlike.defineOwnProperty(rt, keys_key, core.Descriptor.data(noop, true, true, true));

    const base_set_name = try rt.internAtom("baseSet");
    defer rt.atoms.free(base_set_name);
    var globals = [_]engine.exec.globals.Slot{
        .{ .name = base_set_name, .value = base_set_value.dup() },
    };
    defer globals[0].value.free(rt);

    const result_value = try engine.builtins.collection.methodCallWithGlobals(rt, base_set_value, 20, &.{setlike_value}, globals[0..]);
    defer result_value.free(rt);
    const result_set = objectFromValue(result_value);

    try expectActiveSetStrings(result_set, &.{ "a", "c", "d", "e", "q", "x" });
    try expectActiveSetStrings(base_set, &.{ "a", "d", "e", "q", "b" });
}

test "host map closure releases appended value when entry allocation fails" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const map_value = try engine.builtins.collection.construct(rt, 1);
    defer map_value.free(rt);
    const map_object = objectFromValue(map_value);

    inline for (.{ 10, 11, 12, 13, 14, 15, 16, 17 }) |key| {
        const result = try engine.builtins.collection.methodCall(rt, map_value, 1, &.{ core.JSValue.int32(key), core.JSValue.int32(key) });
        result.free(rt);
    }
    try std.testing.expectEqual(@as(usize, 8), map_object.collectionEntries().len);
    try std.testing.expectEqual(@as(usize, 8), map_object.collectionEntriesCapacity());

    const closure_value = try engine.exec.closure.create(rt, 38, 0, 0, 0);
    defer closure_value.free(rt);

    const map_name = try rt.internAtom("map");
    defer rt.atoms.free(map_name);
    var globals = [_]engine.exec.globals.Slot{
        .{ .name = map_name, .value = map_value.dup() },
    };
    defer globals[0].value.free(rt);

    const old_bytes = rt.memory.allocated_bytes;
    const old_allocations = rt.memory.allocation_count;
    rt.setMemoryLimit(old_bytes + @sizeOf(core.string.String) + "mutated".len);
    try std.testing.expectError(error.OutOfMemory, engine.exec.closure.call(rt, closure_value, &.{}, globals[0..]));
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(old_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(old_allocations, rt.memory.allocation_count);
    try std.testing.expectEqual(@as(usize, 8), map_object.collectionEntries().len);
    try std.testing.expectEqual(@as(usize, 8), map_object.collectionActiveCount());
}

test "host map closure rolls back appended entry when size update fails" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const map_value = try engine.builtins.collection.construct(rt, 1);
    defer map_value.free(rt);
    const map_object = objectFromValue(map_value);

    const first_set = try engine.builtins.collection.methodCall(rt, map_value, 1, &.{ core.JSValue.int32(1), core.JSValue.int32(11) });
    first_set.free(rt);

    try fillOwnPropertyStorageForFailure(rt, map_object);
    try std.testing.expect(map_object.deleteProperty(rt, core.atom.predefinedId("size", .string).?));

    const closure_value = try engine.exec.closure.create(rt, 39, 0, 0, 0);
    defer closure_value.free(rt);

    const map_name = try rt.internAtom("map");
    defer rt.atoms.free(map_name);
    var globals = [_]engine.exec.globals.Slot{
        .{ .name = map_name, .value = map_value.dup() },
    };
    defer globals[0].value.free(rt);

    const old_len = map_object.collectionEntries().len;
    const old_active = map_object.collectionActiveCount();
    const old_bytes = rt.memory.allocated_bytes;

    rt.setMemoryLimit(old_bytes + @sizeOf(core.string.String) + "mutated".len);
    try std.testing.expectError(error.OutOfMemory, engine.exec.closure.call(rt, closure_value, &.{}, globals[0..]));
    rt.setMemoryLimit(null);

    const entries_slot = map_object.collectionEntriesSlot();
    const observed_len = entries_slot.*.len;
    const observed_active = map_object.collectionActiveCount();
    if (entries_slot.*.len > old_len) {
        entries_slot.*[old_len].destroy(rt);
        entries_slot.*[old_len] = .{ .key = core.JSValue.undefinedValue(), .value = core.JSValue.undefinedValue(), .active = false };
        entries_slot.* = entries_slot.*.ptr[0..old_len];
        map_object.collectionActiveCountSlot().* = old_active;
        map_object.clearCollectionIndex(rt);
    }

    try std.testing.expectEqual(old_len, observed_len);
    try std.testing.expectEqual(old_active, observed_active);
    try std.testing.expectEqual(old_bytes, rt.memory.allocated_bytes);
}

test "fused Map prefix-int range rolls back inserted entry when size update fails" {
    var saw_oom = false;
    var saw_success = false;

    if (!oom_helpers.fullSweep()) {
        const rt = try core.JSRuntime.create(std.testing.allocator);
        defer rt.destroy();
        const map_value = try engine.builtins.collection.construct(rt, 1);
        defer map_value.free(rt);
        const map_object = objectFromValue(map_value);
        try map_object.ensureCollectionEntryCapacity(rt, 1);
        try fillOwnPropertyStorageForFailure(rt, map_object);
        try std.testing.expect(map_object.deleteProperty(rt, core.atom.predefinedId("size", .string).?));
        try engine.builtins.collection.mapSetLatin1PrefixInt32Range(rt, map_object, "p", 0, 1);
        saw_success = true;
    }

    const samples = oom_helpers.defaultSampleSet(160);
    var fail_offset: usize = 0;
    while (fail_offset < samples.limit) : (fail_offset += 1) {
        if (!oom_helpers.shouldRunOffset(samples, fail_offset)) continue;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const rt = try core.JSRuntime.create(failing.allocator());
        defer rt.destroy();

        const map_value = try engine.builtins.collection.construct(rt, 1);
        defer map_value.free(rt);
        const map_object = objectFromValue(map_value);
        try map_object.ensureCollectionEntryCapacity(rt, 1);
        try fillOwnPropertyStorageForFailure(rt, map_object);
        try std.testing.expect(map_object.deleteProperty(rt, core.atom.predefinedId("size", .string).?));

        const old_len = map_object.collectionEntries().len;
        const old_active = map_object.collectionActiveCount();
        const old_bytes = rt.memory.allocated_bytes;

        failing.fail_index = failing.alloc_index + fail_offset;
        const result = engine.builtins.collection.mapSetLatin1PrefixInt32Range(rt, map_object, "p", 0, 1);
        failing.fail_index = std.math.maxInt(usize);

        if (result) {
            saw_success = true;
        } else |err| switch (err) {
            error.OutOfMemory => {
                saw_oom = true;
                try std.testing.expectEqual(old_len, map_object.collectionEntries().len);
                try std.testing.expectEqual(old_active, map_object.collectionActiveCount());
                try std.testing.expectEqual(old_bytes, rt.memory.allocated_bytes);
            },
            else => |unexpected| return unexpected,
        }

        if (oom_helpers.shouldStopAfterCoverage(saw_oom, saw_success)) return;
    }

    try std.testing.expect(saw_oom);
    try std.testing.expect(saw_success);
}

test "Set.prototype.union uses GetSetRecord order for set-like classes" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var observedOrder = [];
        \\function observableIterator() {
        \\  var values = ["a", "b", "c"];
        \\  var index = 0;
        \\  return {
        \\    get next() {
        \\      observedOrder.push("getting next");
        \\      return function() {
        \\        observedOrder.push("calling next");
        \\        return {
        \\          get done() {
        \\            observedOrder.push("getting done");
        \\            return index >= values.length;
        \\          },
        \\          get value() {
        \\            observedOrder.push("getting value");
        \\            return values[index++];
        \\          }
        \\        };
        \\      };
        \\    }
        \\  };
        \\}
        \\class MySetLike {
        \\  get size() {
        \\    observedOrder.push("getting size");
        \\    return {
        \\      valueOf: function() {
        \\        observedOrder.push("ToNumber(size)");
        \\        return 2;
        \\      }
        \\    };
        \\  }
        \\  get has() {
        \\    observedOrder.push("getting has");
        \\    return function() {
        \\      throw new Test262Error("union should not invoke has");
        \\    };
        \\  }
        \\  get keys() {
        \\    observedOrder.push("getting keys");
        \\    return function() {
        \\      observedOrder.push("calling keys");
        \\      return observableIterator();
        \\    };
        \\  }
        \\}
        \\var expectedOrder = [
        \\  "getting size",
        \\  "ToNumber(size)",
        \\  "getting has",
        \\  "getting keys",
        \\  "calling keys",
        \\  "getting next",
        \\  "calling next",
        \\  "getting done",
        \\  "getting value",
        \\  "calling next",
        \\  "getting done",
        \\  "getting value",
        \\  "calling next",
        \\  "getting done",
        \\  "getting value",
        \\  "calling next",
        \\  "getting done"
        \\];
        \\var combined = new Set(["a", "d"]).union(new MySetLike());
        \\assert.compareArray([...combined], ["a", "d", "b", "c"]);
        \\assert.compareArray(observedOrder, expectedOrder);
        \\var coercionCalls = 0;
        \\assert.throws(TypeError, function() {
        \\  new Set([1, 2]).union({
        \\    size: { valueOf: function() { coercionCalls++; return NaN; } },
        \\    has: function() {},
        \\    keys: function() { return observableIterator(); }
        \\  });
        \\});
        \\assert.sameValue(coercionCalls, 1);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Set.prototype.intersection consumes set-like keys as a direct iterator" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var log = [];
        \\var keysIterator = {};
        \\Object.defineProperty(keysIterator, Symbol.iterator, {
        \\  get: function() {
        \\    log.push("get @@iterator");
        \\    return function() { return keysIterator; };
        \\  }
        \\});
        \\Object.defineProperty(keysIterator, "next", {
        \\  get: function() {
        \\    log.push("get next");
        \\    return function() {
        \\      log.push("call next");
        \\      return { done: true };
        \\    };
        \\  }
        \\});
        \\var setLike = {
        \\  size: 0,
        \\  has: function() {
        \\    throw new Test262Error("intersection should not call has when other is smaller");
        \\  },
        \\  keys: function() {
        \\    log.push("call keys");
        \\    return keysIterator;
        \\  }
        \\};
        \\var result = new Set([1]).intersection(setLike);
        \\assert.compareArray([...result], []);
        \\assert.compareArray(log, ["call keys", "get next", "call next"]);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Set union methods copy receiver after reading set-like keys next" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function setLikeThatReplaces(set) {
        \\  return {
        \\    size: 0,
        \\    has: function() {
        \\      throw new Test262Error("set-like has should not be called");
        \\    },
        \\    keys: function() {
        \\      return {
        \\        get next() {
        \\          set.clear();
        \\          set.add(4);
        \\          return function() {
        \\            return { done: true };
        \\          };
        \\        }
        \\      };
        \\    }
        \\  };
        \\}
        \\var unionBase = new Set([1, 2, 3]);
        \\assert.compareArray([...unionBase.union(setLikeThatReplaces(unionBase))], [4]);
        \\var symmetricBase = new Set([1, 2, 3]);
        \\assert.compareArray([...symmetricBase.symmetricDifference(setLikeThatReplaces(symmetricBase))], [4]);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Set.prototype.difference has branch ignores entries appended by receiver mutation" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var seen = [];
        \\var set = new Set([1, 2, 3, 4]);
        \\var setLike = {
        \\  size: 100,
        \\  has: function(value) {
        \\    seen.push(value);
        \\    if (seen.length === 1) {
        \\      set.clear();
        \\      set.add(11);
        \\      set.add(22);
        \\    }
        \\    return true;
        \\  },
        \\  keys: function() {
        \\    throw new Test262Error("difference should not call keys when other is larger");
        \\  }
        \\};
        \\assert.compareArray([...set.difference(setLike)], []);
        \\assert.compareArray([...set], [11, 22]);
        \\assert.compareArray(seen, [1, 2, 3, 4]);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Engine eval executes URI smoke subset" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var quick_output_buffer: [256]u8 = undefined;
    var quick_stream = std.Io.Writer.fixed(&quick_output_buffer);
    const quick_result = try js.evalWithOutput(
        \\console.log(encodeURI("a b?x=1&y=2#z"));
        \\console.log(encodeURIComponent("a b?x=1&y=2#z"));
        \\console.log(decodeURI("a%20b?x=1&y=2#z"));
        \\console.log(decodeURI("%3F"));
        \\console.log(decodeURIComponent("a%20b%3Fx%3D1%26y%3D2%23z"));
    , &quick_stream);
    defer quick_result.free(js.runtime);

    try std.testing.expect(quick_result.isUndefined());
    try std.testing.expectEqualStrings("a%20b?x=1&y=2#z\na%20b%3Fx%3D1%26y%3D2%23z\na b?x=1&y=2#z\n%3F\na b?x=1&y=2#z\n", quick_stream.buffered());

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\console.log(encodeURI("a b?x=1&y=2#z"));
        \\console.log(encodeURIComponent("a b?x=1&y=2#z"));
        \\console.log(decodeURI("a%20b?x=1&y=2#z"));
        \\console.log(decodeURI("%3F"));
        \\console.log(decodeURIComponent("a%20b%3Fx%3D1%26y%3D2%23z"));
        \\try {
        \\  decodeURIComponent("%E0%A4%A");
        \\} catch (e) {
        \\  console.log(e.name + ": " + e.message);
        \\}
        \\try {
        \\  decodeURI("%GG");
        \\} catch (e) {
        \\  console.log(e.name + ": " + e.message);
        \\}
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("a%20b?x=1&y=2#z\na%20b%3Fx%3D1%26y%3D2%23z\na b?x=1&y=2#z\n%3F\na b?x=1&y=2#z\nURIError: expecting hex digit\nURIError: expecting hex digit\n", stream.buffered());
}

test "URI globals use observable string coercion and reject malformed UTF-8" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var object = {
        \\  valueOf: function() { return "^"; },
        \\  toString: function() { return " "; }
        \\};
        \\assert.sameValue(encodeURI(object), "%20");
        \\assert.sameValue(encodeURIComponent(object), "%20");
        \\assert.sameValue(decodeURI({ toString: function() { return "%5E"; } }), "^");
        \\assert.sameValue(decodeURIComponent({ toString: function() { return "%5E"; } }), "^");
        \\var originalFromCharCode = String.fromCharCode;
        \\String.fromCharCode = function() { return "patched"; };
        \\assert.sameValue(decodeURI("%F0%A0%80%80") === String.fromCharCode(0xD840, 0xDC00), false);
        \\String.fromCharCode = originalFromCharCode;
        \\var threw = false;
        \\try { decodeURIComponent("%ED%A0%80"); } catch (e) { threw = e instanceof URIError; }
        \\assert.sameValue(threw, true);
        \\assert.sameValue(encodeURI(), "undefined");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Engine eval builds frozen tagged template objects with raw arrays" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var captured;
        \\(function(strings, value) {
        \\  captured = strings;
        \\  assert.sameValue(value, 1);
        \\})`head${1}tail`;
        \\assert.sameValue(captured[0], "head");
        \\assert.sameValue(captured[1], "tail");
        \\assert.sameValue(captured.raw[0], "head");
        \\assert.sameValue(captured.raw[1], "tail");
        \\assert.sameValue(Object.isExtensible(captured), false);
        \\assert.sameValue(Object.isExtensible(captured.raw), false);
        \\assert.sameValue(Object.getOwnPropertyDescriptor(captured, "raw").enumerable, false);
        \\assert.sameValue(Object.getOwnPropertyDescriptor(captured, "0").writable, false);
        \\assert.sameValue(Object.getOwnPropertyDescriptor(captured, "length").writable, false);
        \\assert.sameValue(Object.getOwnPropertyDescriptor(captured.raw, "length").writable, false);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Engine eval applies tagged template before new invocation" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function Constructor(value) {
        \\  print(value);
        \\}
        \\var tag = function(strings) {
        \\  print(strings[0]);
        \\  return Constructor;
        \\};
        \\var first = new tag`first`;
        \\assert.sameValue(first instanceof Constructor, true);
        \\var second = new tag`second`("arg");
        \\assert.sameValue(second instanceof Constructor, true);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("first\nundefined\nsecond\narg\n", stream.buffered());
}

test "Engine eval permits invalid escapes only in tagged template cooked values" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function(strings) {
        \\  assert.sameValue(strings[0], undefined);
        \\  assert.sameValue(strings.raw[0], "\\xg");
        \\})`\xg`;
        \\(function(strings, value) {
        \\  assert.sameValue(strings[0], undefined);
        \\  assert.sameValue(strings.raw[0], "\\u{10FFFFF}");
        \\  assert.sameValue(strings[1], "right");
        \\  assert.sameValue(value, "inner");
        \\})`\u{10FFFFF}${"inner"}right`;
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Engine eval closures inherit direct eval function declarations" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let objs = [];
        \\function tag(templateObject) {
        \\  objs.push(templateObject);
        \\}
        \\for (let a = 0; a < 2; a++) {
        \\  eval("(function(){ for (let b = 0; b < 2; b++) { tag`${a}${b}`; } })();");
        \\}
        \\print(objs.length);
        \\print(objs[0] === objs[1]);
        \\print(objs[1] === objs[2]);
        \\print(objs[2] === objs[3]);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("4\ntrue\nfalse\ntrue\n", stream.buffered());
}

test "invalid opcode reports invalid bytecode without context exception" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    var function = try makeFunction(rt, &.{250});
    defer function.deinit(rt);
    try std.testing.expectError(error.InvalidBytecode, runFunction(rt, ctx, &function));
    try std.testing.expect(!ctx.hasException());
}

test "module top-level await works in object computed property names" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalModule(
        \\let o = { [await 9]: 9 };
        \\assert.sameValue(o[await 9], 9);
        \\assert.sameValue(o[String(await 9)], 9);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "module top-level await works in class computed fields inside try" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalModule(
        \\try {
        \\  let C = class {
        \\    [await 9] = 9;
        \\    static [await 9] = 9;
        \\  };
        \\  let c = new C();
        \\  assert.sameValue(c[await 9], 9);
        \\  assert.sameValue(C[await 9], 9);
        \\  assert.sameValue(c[String(await 9)], 9);
        \\  assert.sameValue(C[String(await 9)], 9);
        \\} catch (e) {
        \\  throw e;
        \\}
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

fn fillOwnPropertyStorageForFailure(rt: *core.JSRuntime, object: *core.Object) !void {
    var index: usize = 0;
    while (object.properties.len < object.property_capacity or object.shape_ref.prop_count < object.shape_ref.props.len) : (index += 1) {
        if (index > 512) return error.TestUnexpectedResult;
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "fill_{d}", .{index});
        const atom_id = try rt.internAtom(name);
        errdefer rt.atoms.free(atom_id);
        try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(core.JSValue.int32(@intCast(index)), true, true, true));
        rt.atoms.free(atom_id);
    }
}
