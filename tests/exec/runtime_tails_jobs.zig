//! Exec integration tests: runtime_tails_jobs.
const runtime_owner = @import("zjs").core.runtime;
const std = @import("std");
const zjs = @import("zjs");
const engine = zjs;
const core = zjs.core;
const helpers = @import("../harness.zig");
const bytecode = zjs.bytecode;
const op = zjs.bytecode.opcode.op;
const property_ops = zjs.exec.property_ops;
const common = @import("common.zig");
const makeFixture = common.makeFixture;
const globalFunctionBytecode = common.globalFunctionBytecode;
const finalOpcodeCount = common.finalOpcodeCount;

const countJob = helpers.countJob;
const countJobArgs = helpers.countJobArgs;

const JobQueueRootProvider = struct {
    queue: *engine.core.jobs.Queue,

    fn trace(context: *anyopaque, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.queue.traceRoots(visitor);
    }

    fn provider(self: *@This()) core.runtime.RootProvider {
        return .{ .context = self, .trace = trace };
    }
};

test "Engine eval exit leaves closed var-ref cycles for explicit collection" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const old_threshold = js.runtime.gcThreshold();
    js.runtime.setGCThreshold(std.math.maxInt(usize));
    defer js.runtime.setGCThreshold(old_threshold);

    _ = try js.eval(";");
    _ = try js.runtime.collectForTest();
    const baseline_live_objects = js.runtime.gc.liveCount();
    const baseline_objects = js.runtime.gc.liveCountKind(.object);
    const baseline_var_refs = js.runtime.gc.liveCountKind(.var_ref);
    const baseline_function_bytecode = js.runtime.gc.liveCountKind(.function_bytecode);
    const baseline_major_gc_count = js.runtime.gcStats().major_gc_count;

    _ = try js.eval(
        \\{
        \\    let self = function() { return self; };
        \\}
    );

    try std.testing.expectEqual(baseline_major_gc_count, js.runtime.gcStats().major_gc_count);
    try std.testing.expect(js.runtime.gc.liveCount() > baseline_live_objects);
    try std.testing.expect((try js.runtime.collectForTest()).freed_objects > 0);
    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCountKind(.object));
    try std.testing.expectEqual(baseline_var_refs, js.runtime.gc.liveCountKind(.var_ref));
    try std.testing.expectEqual(baseline_function_bytecode, js.runtime.gc.liveCountKind(.function_bytecode));
    // Function-bytecode destruction drops its atom ids after marking. A
    // follow-up major may therefore reclaim cached string bodies, but it must
    // not resurrect or retain any part of the closed var-ref cycle.
    _ = try js.runtime.collectForTest();
    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCountKind(.object));
    try std.testing.expectEqual(baseline_var_refs, js.runtime.gc.liveCountKind(.var_ref));
    try std.testing.expectEqual(baseline_function_bytecode, js.runtime.gc.liveCountKind(.function_bytecode));
}

fn expectEvalCycleReclaimed(js: *helpers.TestEngine, warmup_source: []const u8, cycle_source: []const u8) !void {
    const old_threshold = js.runtime.gcThreshold();
    js.runtime.setGCThreshold(std.math.maxInt(usize));
    defer js.runtime.setGCThreshold(old_threshold);

    _ = try js.eval(warmup_source);
    try js.runJobs();
    _ = try js.runtime.collectForTest();
    const baseline_live_objects = js.runtime.gc.liveCount();

    _ = try js.eval(cycle_source);
    try js.runJobs();

    try std.testing.expect(js.runtime.gc.liveCount() > baseline_live_objects);
    try std.testing.expect((try js.runtime.collectForTest()).freed_objects > 0);
    try std.testing.expectEqual(baseline_live_objects, js.runtime.gc.liveCount());
    try std.testing.expectEqual(@as(usize, 0), (try js.runtime.collectForTest()).freed_objects);
}

test "Promise result cycle is released by runtime cycle removal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    // Pins PromisePayload.result, object.zig:8661-8665.
    try expectEvalCycleReclaimed(
        &js,
        "(() => { let resolve; new Promise(r => { resolve = r; }); resolve({}); })()",
        "(() => { let resolve; const promise = new Promise(r => { resolve = r; }); const result = { promise }; resolve(result); })()",
    );
}

test "Promise reaction cycle is released by runtime cycle removal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    // Pins PromisePayload reaction fields/list, object.zig:8661-8665.
    try expectEvalCycleReclaimed(
        &js,
        "(() => { new Promise(() => {}).then(() => {}); })()",
        "(() => { const promise = new Promise(() => {}); promise.then(() => promise); })()",
    );
}

test "proxy revoke FunctionRare cycle is released by runtime cycle removal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    // Pins FunctionRarePayload.proxy_revoke_target, object.zig:8561-8573.
    try expectEvalCycleReclaimed(
        &js,
        "(() => { Proxy.revocable({}, {}); })()",
        "(() => { const target = {}; const pair = Proxy.revocable(target, {}); target.revoke = pair.revoke; })()",
    );
}

test "Promise finally FunctionRare cycle is released by runtime cycle removal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    // Pins FunctionRarePayload.promise_finally_callback, object.zig:8561-8573.
    try expectEvalCycleReclaimed(
        &js,
        "(() => { new Promise(() => {}).finally(() => {}); })()",
        "(() => { const promise = new Promise(() => {}); promise.finally(() => promise); })()",
    );
}

test "DisposableStack resource self-cycle is released by runtime cycle removal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    // Pins DisposableStackPayload resource value/method edges, object.zig:8596-8603.
    try expectEvalCycleReclaimed(
        &js,
        "(() => { const stack = new DisposableStack(); stack.adopt({}, () => {}); })()",
        "(() => { const stack = new DisposableStack(); stack.adopt(stack, () => {}); })()",
    );
}

test "module import-meta and eval-exception cycles are released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    var ctx_alive = true;
    defer if (ctx_alive) ctx.destroy();

    const module_name = try rt.internAtom("gc-module-payload-cycle.mjs");
    const back_key = try rt.internAtom("module");
    var pending = core.module.PendingDefinition.init(rt, rt.atoms);
    defer pending.deinit();
    const prepared = try ctx.modules.prepareFreshTarget(module_name, &pending);
    const record = prepared.record();
    const import_meta = try core.Object.create(rt, core.class.ids.object, null);
    const eval_exception = try core.Object.create(rt, core.class.ids.object, null);
    const record_value = core.JSValue.module(&record.header);
    try import_meta.defineOwnProperty(rt, back_key, core.Descriptor.data(record_value, .all));
    try eval_exception.defineOwnProperty(rt, back_key, core.Descriptor.data(record_value, .all));

    // Pins ModuleRecord import_meta/eval_exception edges, module.zig:572-573.
    record.import_meta = import_meta.value();
    record.setEvalException(rt, eval_exception.value());

    ctx.destroy();
    ctx_alive = false;
    const expected = rt.gc.liveCount();
    try std.testing.expect(expected != 0);
    try std.testing.expectEqual(expected, (try rt.collectForTest()).freed_objects);
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.shape));
}

test "disposable stack extras leftover runtime metadata preserves dispose aliases and disposed" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(DisposableStack.prototype[Symbol.toStringTag], "DisposableStack");
        \\assert.sameValue(AsyncDisposableStack.prototype[Symbol.toStringTag], "AsyncDisposableStack");
        \\assert.sameValue(DisposableStack.prototype[Symbol.dispose], DisposableStack.prototype.dispose);
        \\assert.sameValue(DisposableStack.prototype[Symbol.dispose].name, "dispose");
        \\assert.sameValue(AsyncDisposableStack.prototype[Symbol.asyncDispose], AsyncDisposableStack.prototype.disposeAsync);
        \\assert.sameValue(AsyncDisposableStack.prototype[Symbol.asyncDispose].name, "disposeAsync");
        \\var disposedDesc = Object.getOwnPropertyDescriptor(DisposableStack.prototype, "disposed");
        \\assert.sameValue(disposedDesc.get.name, "get disposed");
        \\assert.sameValue(disposedDesc.get.call(new DisposableStack()), false);
        \\assert.throws(TypeError, function() { disposedDesc.get.call({}); });
        \\var asyncDisposedDesc = Object.getOwnPropertyDescriptor(AsyncDisposableStack.prototype, "disposed");
        \\assert.sameValue(asyncDisposedDesc.get.name, "get disposed");
        \\assert.sameValue(asyncDisposedDesc.get.call(new AsyncDisposableStack()), false);
        \\assert.throws(TypeError, function() { asyncDisposedDesc.get.call({}); });
        \\var stack = new DisposableStack();
        \\var called = 0;
        \\stack.adopt({}, function() { called++; });
        \\var moved = stack.move();
        \\assert.sameValue(stack.disposed, true);
        \\moved.dispose();
        \\assert.sameValue(called, 1);
        \\assert.sameValue(moved.disposed, true);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "buffer constructor extras leftover runtime tables preserve ArrayBuffer SharedArrayBuffer and DataView" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(ArrayBuffer[Symbol.species], ArrayBuffer);
        \\assert.sameValue(SharedArrayBuffer[Symbol.species], SharedArrayBuffer);
        \\assert.sameValue(ArrayBuffer.prototype[Symbol.toStringTag], "ArrayBuffer");
        \\assert.sameValue(SharedArrayBuffer.prototype[Symbol.toStringTag], "SharedArrayBuffer");
        \\assert.sameValue(DataView.prototype[Symbol.toStringTag], "DataView");
        \\assert.sameValue(Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, "byteLength").get.name, "get byteLength");
        \\assert.sameValue(Object.getOwnPropertyDescriptor(SharedArrayBuffer.prototype, "growable").get.name, "get growable");
        \\assert.sameValue(Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, "growable"), undefined);
        \\assert.sameValue(Object.getOwnPropertyDescriptor(SharedArrayBuffer.prototype, "resizable"), undefined);
        \\var ab = new ArrayBuffer(8, { maxByteLength: 16 });
        \\assert.sameValue(ab.byteLength, 8);
        \\assert.sameValue(ab.maxByteLength, 16);
        \\assert.sameValue(ab.resizable, true);
        \\assert.sameValue(ab.detached, false);
        \\assert.sameValue("immutable" in ab, false);
        \\ab.resize(12);
        \\assert.sameValue(ab.byteLength, 12);
        \\assert.sameValue(ab.slice(0, 4).byteLength, 4);
        \\var sab = new SharedArrayBuffer(8, { maxByteLength: 16 });
        \\assert.sameValue(sab.byteLength, 8);
        \\assert.sameValue(sab.maxByteLength, 16);
        \\assert.sameValue(sab.growable, true);
        \\sab.grow(12);
        \\assert.sameValue(sab.byteLength, 12);
        \\var dv = new DataView(new ArrayBuffer(4), 1, 2);
        \\assert.sameValue(dv.byteLength, 2);
        \\assert.sameValue(dv.byteOffset, 1);
        \\assert.sameValue(dv.buffer.byteLength, 4);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "iterator step leftover post-next decode preserves for-of and helper results" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var events = [];
        \\var step = 0;
        \\var custom = {
        \\  [Symbol.iterator]() { return this; },
        \\  next() {
        \\    if (step++ === 0) {
        \\      return {
        \\        get done() { events.push("n-done-false"); return false; },
        \\        get value() { events.push("n-value"); return 7; },
        \\      };
        \\    }
        \\    return {
        \\      get done() { events.push("n-done-true"); return true; },
        \\      get value() { throw new Error("done value was read"); },
        \\    };
        \\  },
        \\};
        \\var sum = 0;
        \\for (var value of custom) sum += value;
        \\assert.sameValue(sum, 7);
        \\assert.sameValue(events.join(","), "n-done-false,n-value,n-done-true");
        \\var helperEvents = [];
        \\var helperStep = 0;
        \\var source = {
        \\  [Symbol.iterator]() { return this; },
        \\  next() {
        \\    if (helperStep++ === 0) {
        \\      return {
        \\        get done() { helperEvents.push("h-done-false"); return false; },
        \\        get value() { helperEvents.push("h-value"); return 3; },
        \\      };
        \\    }
        \\    return { done: true };
        \\  },
        \\};
        \\var mapped = Iterator.from(source).map(function(x) { return x + 1; });
        \\assert.sameValue(mapped.next().value, 4);
        \\assert.sameValue(mapped.next().done, true);
        \\assert.sameValue(helperEvents.join(","), "h-done-false,h-value");
        \\var bad = { [Symbol.iterator]() { return this; }, next() { return 1; } };
        \\assert.throws(TypeError, function() { for (var x of bad) {} });
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "class field initializer leftover runtime static preserves instance static private and computed fields" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var key = "comp";
        \\class C {
        \\  inst;
        \\  instInit = 1;
        \\  #priv;
        \\  #privInit = 2;
        \\  static st;
        \\  static stInit = 3;
        \\  static #spriv;
        \\  static #sprivInit = 4;
        \\  static [key];
        \\  static [key + "Init"] = 5;
        \\  readPriv() { return this.#priv; }
        \\  readPrivInit() { return this.#privInit; }
        \\  static readSpriv() { return C.#spriv; }
        \\  static readSprivInit() { return C.#sprivInit; }
        \\}
        \\var o = new C();
        \\assert.sameValue(o.inst, undefined);
        \\assert.sameValue(o.instInit, 1);
        \\assert.sameValue(o.readPriv(), undefined);
        \\assert.sameValue(o.readPrivInit(), 2);
        \\assert.sameValue(C.st, undefined);
        \\assert.sameValue(C.stInit, 3);
        \\assert.sameValue(C.readSpriv(), undefined);
        \\assert.sameValue(C.readSprivInit(), 4);
        \\assert.sameValue(C.comp, undefined);
        \\assert.sameValue(C.compInit, 5);
        \\class D {
        \\  nameField = class { static { this.seen = this.name; } };
        \\  static staticName = class { static { this.seen = this.name; } };
        \\}
        \\assert.sameValue((new D()).nameField.seen, "nameField");
        \\assert.sameValue(D.staticName.seen, "staticName");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "leftover instance-computed public field initializer through shared emit" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var key = "comp";
        \\class C {
        \\  [key];
        \\  [key + "Init"] = 7;
        \\  named = 1;
        \\  static [key + "S"] = 8;
        \\}
        \\var o = new C();
        \\assert.sameValue(o.comp, undefined);
        \\assert.sameValue(o.compInit, 7);
        \\assert.sameValue(o.named, 1);
        \\assert.sameValue(C.compS, 8);
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(o, "comp"), true);
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(o, "compInit"), true);
        \\class D {
        \\  [key + "Name"] = class { static { this.seen = this.name; } };
        \\}
        \\assert.sameValue((new D()).compName.seen, "compName");
        \\class E {
        \\  ["x"] = 1;
        \\  ["y"];
        \\}
        \\var e = new E();
        \\assert.sameValue(e.x, 1);
        \\assert.sameValue(e.y, undefined);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "leftover do while parse through one runtime flag" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var n = 0;
        \\while (n < 3) n += 1;
        \\assert.sameValue(n, 3);
        \\var d = 0;
        \\do { d += 1; } while (d < 3);
        \\assert.sameValue(d, 3);
        \\var once = 0;
        \\do { once += 1; } while (false);
        \\assert.sameValue(once, 1);
        \\var broken = 0;
        \\outer: while (true) {
        \\  while (true) {
        \\    broken += 1;
        \\    break outer;
        \\  }
        \\}
        \\assert.sameValue(broken, 1);
        \\var continued = 0;
        \\var i = 0;
        \\loop: do {
        \\  i += 1;
        \\  if (i === 1) continue loop;
        \\  continued += 1;
        \\} while (i < 3);
        \\assert.sameValue(i, 3);
        \\assert.sameValue(continued, 2);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "leftover error stack at-line format through one runtime kind" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function makeError() {
        \\    return new Error("x");
        \\}
        \\var captured = makeError().stack;
        \\assert.sameValue(typeof captured, "string");
        \\assert.sameValue(captured.indexOf("    at makeError") >= 0, true);
        \\assert.sameValue(captured.indexOf(" (") >= 0, true);
        \\function evalThrower() {
        \\    try { eval("]"); } catch (e) { return e; }
        \\    return null;
        \\}
        \\var liveParse = evalThrower().stack;
        \\assert.sameValue(typeof liveParse, "string");
        \\assert.sameValue(liveParse.indexOf("    at ") >= 0, true);
        \\assert.sameValue(liveParse.indexOf("at evalThrower") >= 0, true);
        \\function mark() {
        \\    Error.captureStackTrace(target);
        \\}
        \\var target = {};
        \\function outer() { mark(); }
        \\outer();
        \\assert.sameValue(typeof target.stack, "string");
        \\assert.sameValue(target.stack.indexOf("    at mark") >= 0, true);
        \\assert.sameValue(target.stack.indexOf("at outer") >= 0, true);
        \\function skipMe() {
        \\    Error.captureStackTrace(skipped, skipMe);
        \\}
        \\var skipped = {};
        \\function skipCaller() { skipMe(); }
        \\skipCaller();
        \\assert.sameValue(skipped.stack.indexOf("at skipMe") < 0, true);
        \\assert.sameValue(skipped.stack.indexOf("at skipCaller") >= 0, true);
        \\var previousLimit = Error.stackTraceLimit;
        \\Error.stackTraceLimit = 0;
        \\var empty = {};
        \\Error.captureStackTrace(empty);
        \\assert.sameValue(empty.stack, "");
        \\Error.stackTraceLimit = Infinity;
        \\var unlimited = {};
        \\Error.captureStackTrace(unlimited);
        \\assert.sameValue(unlimited.stack.indexOf("    at ") >= 0, true);
        \\Error.stackTraceLimit = -Infinity;
        \\var negative = {};
        \\Error.captureStackTrace(negative);
        \\assert.sameValue(negative.stack, "");
        \\Error.stackTraceLimit = previousLimit;
        \\var previousPrepare = Error.prepareStackTrace;
        \\Error.prepareStackTrace = function(error, sites) {
        \\    return error.stack;
        \\};
        \\var reentered = new Error("y").stack;
        \\Error.prepareStackTrace = previousPrepare;
        \\assert.sameValue(typeof reentered, "string");
        \\assert.sameValue(reentered.indexOf("    at ") >= 0, true);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "leftover array-from array-like through one runtime destination" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.compareArray(Array.from([1, 2, 3]), [1, 2, 3]);
        \\assert.compareArray(Array.from([1, 2, 3], function(x) { return x + 1; }), [2, 3, 4]);
        \\assert.compareArray(Array.from([7, 8], function(x, i) { return x + i; }), [7, 9]);
        \\var ta = Uint8Array.from({ length: 2, 0: 4, 1: 5 });
        \\assert.sameValue(ta.length, 2);
        \\assert.sameValue(ta[0], 4);
        \\assert.sameValue(ta[1], 5);
        \\var mapped = Uint8Array.from([1, 2], function(x) { return x * 2; });
        \\assert.sameValue(mapped[0], 2);
        \\assert.sameValue(mapped[1], 4);
        \\var C = function() {};
        \\var custom = Array.from.call(C, ["a", "b"]);
        \\assert.sameValue(custom instanceof C, true);
        \\assert.sameValue(custom[0], "a");
        \\assert.sameValue(custom[1], "b");
        \\assert.sameValue(custom.length, 2);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "leftover proxy set trap through one runtime kind" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\"use strict";
        \\var set = [];
        \\var p = new Proxy({}, { set: function (o, k, v) { set.push(k); o[k] = v; return true; }});
        \\p.foo = 1;
        \\assert.sameValue(set + "", "foo");
        \\assert.sameValue(p.foo, 1);
        \\assert.sameValue(Reflect.set(p, "bar", 2), true);
        \\assert.sameValue(p.bar, 2);
        \\var rejected = new Proxy({}, { set: function() { return false; } });
        \\var threw = false;
        \\try { rejected.x = 3; } catch (e) { threw = e instanceof TypeError; }
        \\assert.sameValue(threw, true);
        \\assert.sameValue(Reflect.set(rejected, "y", 3), false);
        \\var passthrough = new Proxy({ a: 0 }, {});
        \\passthrough.a = 4;
        \\assert.sameValue(passthrough.a, 4);
        \\var stackProxy = new Proxy(new Error("x"), {});
        \\Object.defineProperty(stackProxy, "stack", Object.getOwnPropertyDescriptor(Error.prototype, "stack"));
        \\stackProxy.stack = "updated";
        \\assert.sameValue(stackProxy.stack, "updated");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "leftover proxy extensible trap through one runtime kind" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\"use strict";
        \\var seen = [];
        \\var p = new Proxy({}, {
        \\  isExtensible: function (t) { seen.push("is"); return Object.isExtensible(t); }
        \\});
        \\assert.sameValue(Object.isExtensible(p), true);
        \\assert.sameValue(seen + "", "is");
        \\var preventTarget = {};
        \\var preventProxy = new Proxy(preventTarget, {
        \\  preventExtensions: function (t) { seen.push("prevent"); Object.preventExtensions(t); return true; }
        \\});
        \\Object.preventExtensions(preventProxy);
        \\assert.sameValue(Object.isExtensible(preventTarget), false);
        \\assert.sameValue(Object.isExtensible(preventProxy), false);
        \\assert.sameValue(seen + "", "is,prevent");
        \\var inner = new Proxy({}, {
        \\  isExtensible: function (t) { seen.push("inner"); return Object.isExtensible(t); }
        \\});
        \\var outer = new Proxy(inner, {});
        \\assert.sameValue(Object.isExtensible(outer), true);
        \\assert.sameValue(seen + "", "is,prevent,inner");
        \\Object.preventExtensions(outer);
        \\assert.sameValue(Object.isExtensible(outer), false);
        \\var rejected = new Proxy({}, { preventExtensions: function () { return false; } });
        \\assert.sameValue(Reflect.preventExtensions(rejected), false);
        \\var threw = false;
        \\try { Object.preventExtensions(rejected); } catch (e) { threw = e instanceof TypeError; }
        \\assert.sameValue(threw, true);
        \\var sealed = Object.preventExtensions({});
        \\var mismatch = new Proxy(sealed, { isExtensible: function () { return true; } });
        \\var threw2 = false;
        \\try { Object.isExtensible(mismatch); } catch (e) { threw2 = e instanceof TypeError; }
        \\assert.sameValue(threw2, true);
        \\var mismatchPrevent = new Proxy({}, { preventExtensions: function () { return true; } });
        \\var threw3 = false;
        \\try { Object.preventExtensions(mismatchPrevent); } catch (e) { threw3 = e instanceof TypeError; }
        \\assert.sameValue(threw3, true);
        \\var plain = {};
        \\assert.sameValue(Object.isExtensible(plain), true);
        \\Object.preventExtensions(plain);
        \\assert.sameValue(Object.isExtensible(plain), false);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "leftover proxy has trap through one outlined walk" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var seen = [];
        \\var target = { foo: 1 };
        \\var p = new Proxy(target, {
        \\  has: function (t, k) { seen.push(k); return Reflect.has(t, k); }
        \\});
        \\assert.sameValue("foo" in p, true);
        \\assert.sameValue("bar" in p, false);
        \\assert.sameValue(Reflect.has(p, "foo"), true);
        \\var withHit = false;
        \\with (p) { withHit = typeof foo === "number"; }
        \\assert.sameValue(withHit, true);
        \\assert.sameValue(seen.indexOf("foo") >= 0, true);
        \\assert.sameValue(seen.indexOf("bar") >= 0, true);
        \\assert.sameValue(seen.length >= 4, true);
        \\var passthrough = new Proxy({ a: 2 }, {});
        \\assert.sameValue("a" in passthrough, true);
        \\var withPass = 0;
        \\with (passthrough) { withPass = a; }
        \\assert.sameValue(withPass, 2);
        \\var sealed = Object.preventExtensions({ hidden: 1 });
        \\Object.defineProperty(sealed, "hidden", { configurable: false });
        \\var mismatch = new Proxy(sealed, { has: function () { return false; } });
        \\var threw = false;
        \\try { "hidden" in mismatch; } catch (e) { threw = e instanceof TypeError; }
        \\assert.sameValue(threw, true);
        \\var plain = { x: 3 };
        \\assert.sameValue("x" in plain, true);
        \\assert.sameValue("y" in plain, false);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "leftover proxy getPrototypeOf through one outlined walk" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var proto = { marker: 1 };
        \\var target = Object.create(proto);
        \\var seen = [];
        \\var p = new Proxy(target, {
        \\  getPrototypeOf: function (t) { seen.push("trap"); return Object.getPrototypeOf(t); }
        \\});
        \\assert.sameValue(Object.getPrototypeOf(p), proto);
        \\assert.sameValue(Reflect.getPrototypeOf(p), proto);
        \\assert.sameValue(p.__proto__, proto);
        \\assert.sameValue(seen + "", "trap,trap,trap");
        \\var inner = new Proxy(Object.create(proto), {
        \\  getPrototypeOf: function (t) { seen.push("inner"); return Object.getPrototypeOf(t); }
        \\});
        \\var outer = new Proxy(inner, {});
        \\assert.sameValue(Object.getPrototypeOf(outer), proto);
        \\assert.sameValue(seen + "", "trap,trap,trap,inner");
        \\var mismatch = new Proxy(Object.preventExtensions(Object.create(proto)), {
        \\  getPrototypeOf: function () { return {}; }
        \\});
        \\var threw = false;
        \\try { Object.getPrototypeOf(mismatch); } catch (e) { threw = e instanceof TypeError; }
        \\assert.sameValue(threw, true);
        \\var bad = new Proxy({}, { getPrototypeOf: function () { return 1; } });
        \\var threw2 = false;
        \\try { Object.getPrototypeOf(bad); } catch (e) { threw2 = e instanceof TypeError; }
        \\assert.sameValue(threw2, true);
        \\var plain = {};
        \\assert.sameValue(Object.getPrototypeOf(plain), Object.prototype);
        \\assert.sameValue(Object.getPrototypeOf(Object.prototype), null);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "leftover Object.isExtensible builtin through outlined extensible op" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(Object.isExtensible(1), false);
        \\assert.sameValue(Object.isExtensible(undefined), false);
        \\assert.sameValue(Reflect.isExtensible({}), true);
        \\var seen = [];
        \\var p = new Proxy({}, {
        \\  isExtensible: function (t) { seen.push("is"); return Object.isExtensible(t); }
        \\});
        \\assert.sameValue(Object.isExtensible(p), true);
        \\assert.sameValue(Reflect.isExtensible(p), true);
        \\assert.sameValue(seen + "", "is,is");
        \\var inner = new Proxy({}, {
        \\  isExtensible: function (t) { seen.push("inner"); return Object.isExtensible(t); }
        \\});
        \\assert.sameValue(Object.isExtensible(new Proxy(inner, {})), true);
        \\assert.sameValue(seen + "", "is,is,inner");
        \\var sealed = Object.preventExtensions({});
        \\var mismatch = new Proxy(sealed, { isExtensible: function () { return true; } });
        \\var threw = false;
        \\try { Object.isExtensible(mismatch); } catch (e) { threw = e instanceof TypeError; }
        \\assert.sameValue(threw, true);
        \\var plain = {};
        \\assert.sameValue(Object.isExtensible(plain), true);
        \\Object.preventExtensions(plain);
        \\assert.sameValue(Object.isExtensible(plain), false);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "leftover Object.getOwnPropertyNames through outlined enumerable own properties" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var o = Object.defineProperty({ a: 1, b: 2 }, "hidden", { value: 9, enumerable: false });
        \\var s = Symbol("s");
        \\o[s] = 3;
        \\assert.sameValue(Object.getOwnPropertyNames(o) + "", "a,b,hidden");
        \\assert.sameValue(Object.keys(o) + "", "a,b");
        \\assert.sameValue(Object.values(o) + "", "1,2");
        \\assert.sameValue(Object.entries(o) + "", "a,1,b,2");
        \\assert.sameValue(Object.getOwnPropertySymbols(o).length, 1);
        \\assert.sameValue(Object.getOwnPropertySymbols(o)[0], s);
        \\assert.sameValue(Object.getOwnPropertyNames("ab") + "", "0,1,length");
        \\var threw_names = false;
        \\try { Object.getOwnPropertyNames(null); } catch (e) { threw_names = e instanceof TypeError; }
        \\assert.sameValue(threw_names, true);
        \\var threw_keys = false;
        \\try { Object.keys(undefined); } catch (e) { threw_keys = e instanceof TypeError; }
        \\assert.sameValue(threw_keys, true);
        \\var seen = [];
        \\var p = new Proxy({ x: 1, y: 2 }, {
        \\  ownKeys: function (t) { seen.push("keys"); return Object.getOwnPropertyNames(t); }
        \\});
        \\assert.sameValue(Object.getOwnPropertyNames(p) + "", "x,y");
        \\assert.sameValue(Object.keys(p) + "", "x,y");
        \\assert.sameValue(seen + "", "keys,keys");
        \\assert.sameValue(Array.from([1, 2, 3]) + "", "1,2,3");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "leftover Array.shift index-move through outlined arrayMoveIndex" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var a = [1, , 3, 4];
        \\assert.sameValue(a.shift(), 1);
        \\assert.sameValue(a + "", ",3,4");
        \\assert.sameValue(a.hasOwnProperty("0"), false);
        \\assert.sameValue(0 in a, false);
        \\assert.sameValue(a[1], 3);
        \\var u = [1, , 3];
        \\assert.sameValue(u.unshift(0), 4);
        \\assert.sameValue(u + "", "0,1,,3");
        \\assert.sameValue(u.hasOwnProperty("2"), false);
        \\var sealed = Object.seal([1, 2, 3]);
        \\var threw_unshift = false;
        \\try { sealed.unshift(0); } catch (e) { threw_unshift = e instanceof TypeError; }
        \\assert.sameValue(threw_unshift, true);
        \\var shrink = [1, 2, , 4, 5];
        \\assert.sameValue(shrink.splice(1, 1) + "", "2");
        \\assert.sameValue(shrink + "", "1,,4,5");
        \\assert.sameValue(shrink.hasOwnProperty("1"), false);
        \\var grow = [1, 2, 3];
        \\assert.sameValue(grow.splice(1, 0, 8, 9) + "", "");
        \\assert.sameValue(grow + "", "1,8,9,2,3");
        \\var c = [1, , 3, 4];
        \\assert.sameValue(c.copyWithin(0, 1, 3) + "", ",3,3,4");
        \\assert.sameValue(c.hasOwnProperty("0"), false);
        \\var overlap = [1, 2, 3, 4];
        \\assert.sameValue(overlap.copyWithin(1, 0, 3) + "", "1,1,2,3");
        \\assert.sameValue(Array.from([1, 2, 3]) + "", "1,2,3");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "leftover Array.slice present-index through outlined arrayCopyPresentIndex" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var a = [1, , 3, 4];
        \\var sliced = a.slice(0, 3);
        \\assert.sameValue(sliced + "", "1,,3");
        \\assert.sameValue(sliced.hasOwnProperty("1"), false);
        \\assert.sameValue(1 in sliced, false);
        \\assert.sameValue(sliced[2], 3);
        \\assert.sameValue([1, 2, 3].slice(1) + "", "2,3");
        \\var shrink = [1, , 3, 4, 5];
        \\var removed = shrink.splice(0, 3);
        \\assert.sameValue(removed + "", "1,,3");
        \\assert.sameValue(removed.hasOwnProperty("1"), false);
        \\assert.sameValue(shrink + "", "4,5");
        \\var grow = [1, 2, 3];
        \\assert.sameValue(grow.splice(1, 0, 8, 9) + "", "");
        \\assert.sameValue(grow + "", "1,8,9,2,3");
        \\var c = [1, , 3].concat([, 5]);
        \\assert.sameValue(c + "", "1,,3,,5");
        \\assert.sameValue(c.hasOwnProperty("1"), false);
        \\assert.sameValue(c.hasOwnProperty("3"), false);
        \\var o = { 0: 9, length: 1 };
        \\assert.sameValue([1].concat(o) + "", "1,[object Object]");
        \\assert.sameValue(Array.from([1, 2, 3]) + "", "1,2,3");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "leftover integer binary through live bitwise and number arms" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(2 + 3, 5);
        \\assert.sameValue(8 - 3, 5);
        \\assert.sameValue(4 * 5, 20);
        \\assert.sameValue(10 / 2, 5);
        \\assert.sameValue(10 % 3, 1);
        \\assert.sameValue(2 ** 3, 8);
        \\assert.sameValue(1.5 + 2.25, 3.75);
        \\assert.sameValue(5 & 3, 1);
        \\assert.sameValue(5 | 2, 7);
        \\assert.sameValue(5 ^ 1, 4);
        \\assert.sameValue(8 << 1, 16);
        \\assert.sameValue(8 >> 1, 4);
        \\assert.sameValue(8 >>> 1, 4);
        \\assert.sameValue("2" * 3, 6);
        \\assert.sameValue("5" & 3, 1);
        \\assert.sameValue(1n + 2n, 3n);
        \\assert.sameValue("a" + "b", "ab");
        \\assert.sameValue(1 + "2", "12");
        \\assert.sameValue(Array.from([1, 2, 3]) + "", "1,2,3");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "leftover Array.map generic get through one runtime tail" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue([1, 2, 3].map(function(v) { return v + 1; }) + "", "2,3,4");
        \\var seen = [];
        \\assert.sameValue([1, , 3].map(function(v, i) { seen.push(i); return v; }) + "", "1,,3");
        \\assert.sameValue(seen + "", "0,2");
        \\var fe = [];
        \\[1, , 3].forEach(function(v, i) { fe.push(i); });
        \\assert.sameValue(fe + "", "0,2");
        \\assert.sameValue([1, , 3].findIndex(function(v) { return v === undefined; }), 1);
        \\assert.sameValue([1, , 3].findLastIndex(function(v) { return v === undefined; }), 1);
        \\assert.sameValue([1, 2, 3].findLast(function(v) { return v > 1; }), 3);
        \\assert.sameValue([1, 2, 3].every(function(v) { return v > 0; }), true);
        \\assert.sameValue([1, , 3].some(function(v) { return v === undefined; }), false);
        \\var o = { 0: 7, 2: 9, length: 3 };
        \\assert.sameValue(Array.prototype.map.call(o, function(v) { return v + 1; }) + "", "8,,10");
        \\assert.sameValue(Array.from([1, 2, 3]) + "", "1,2,3");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "leftover Array.toReversed get-define through outlined arrayCopyIndex" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var rev = [1, , 3].toReversed();
        \\assert.sameValue(rev + "", "3,,1");
        \\assert.sameValue(rev.hasOwnProperty("1"), true);
        \\assert.sameValue(rev[1], undefined);
        \\var with_h = [1, , 3].with(1, 8);
        \\assert.sameValue(with_h + "", "1,8,3");
        \\assert.sameValue([1, , 3].with(0, 9) + "", "9,,3");
        \\var spliced = [1, , 3, 4].toSpliced(1, 1, 8, 9);
        \\assert.sameValue(spliced + "", "1,8,9,3,4");
        \\var kept = [1, , 3, 4].toSpliced(1, 2);
        \\assert.sameValue(kept + "", "1,4");
        \\assert.sameValue(kept.hasOwnProperty("1"), true);
        \\assert.sameValue([3, 1, 2].toSorted() + "", "1,2,3");
        \\var o = { 0: 7, 2: 9, length: 3 };
        \\assert.sameValue(Array.prototype.toReversed.call(o) + "", "9,,7");
        \\assert.sameValue(Array.from([1, 2, 3]) + "", "1,2,3");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "leftover Array.sort generic set through one runtime tail" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var dense = [3, 1, 2];
        \\assert.sameValue(dense.sort() + "", "1,2,3");
        \\var already = [1, 2, 3];
        \\assert.sameValue(already.sort() + "", "1,2,3");
        \\var undefs = [undefined, 2, undefined, 1];
        \\assert.sameValue(undefs.sort() + "", "1,2,,");
        \\var holey = [3, , 1];
        \\assert.sameValue(holey.sort() + "", "1,3,");
        \\assert.sameValue(holey.hasOwnProperty("2"), false);
        \\var o = { 0: 3, 1: 1, 2: 2, length: 3 };
        \\assert.sameValue(Array.prototype.sort.call(o)[0], 1);
        \\assert.sameValue(o[1], 2);
        \\assert.sameValue(o[2], 3);
        \\var proxy_sets = 0;
        \\var p = new Proxy({ 0: 2, 1: 1, length: 2 }, {
        \\    set: function(t, k, v, r) { proxy_sets += 1; t[k] = v; return true; }
        \\});
        \\Array.prototype.sort.call(p);
        \\assert.sameValue(p[0], 1);
        \\assert.sameValue(p[1], 2);
        \\assert.sameValue(proxy_sets >= 2, true);
        \\assert.sameValue(Array.from([1, 2, 3]) + "", "1,2,3");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "leftover Array.fill generic set through one runtime tail" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var dense = [1, 2, 3, 4];
        \\assert.sameValue(dense.fill(9, 1, 3) + "", "1,9,9,4");
        \\var holey = new Array(5);
        \\assert.sameValue(holey.fill(7, 2, 4) + "", ",,7,7,");
        \\assert.sameValue(holey.hasOwnProperty("0"), false);
        \\assert.sameValue(holey[2], 7);
        \\var o = { 0: 1, 1: 2, length: 3 };
        \\assert.sameValue(Array.prototype.fill.call(o, 8, 0, 2)[0], 8);
        \\assert.sameValue(o[1], 8);
        \\assert.sameValue(o[2], undefined);
        \\var ta = new Uint8Array([1, 2, 3, 4]);
        \\ta.fill(9, 1, 3);
        \\assert.sameValue(ta[0], 1);
        \\assert.sameValue(ta[1], 9);
        \\assert.sameValue(ta[2], 9);
        \\assert.sameValue(ta[3], 4);
        \\assert.sameValue(Array.from([1, 2, 3]) + "", "1,2,3");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "leftover Array.indexOf direction through one runtime walk" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue([1, 2, 3, 2].indexOf(2), 1);
        \\assert.sameValue([1, 2, 3, 2].lastIndexOf(2), 3);
        \\assert.sameValue([1, 2, 3].indexOf(9), -1);
        \\assert.sameValue([1, 2, 3].lastIndexOf(9), -1);
        \\assert.sameValue([1, 2, 3].indexOf(2, 2), -1);
        \\assert.sameValue([1, 2, 3, 2].lastIndexOf(2, 2), 1);
        \\assert.sameValue([1, , 3].indexOf(undefined), -1);
        \\assert.sameValue([1, , 3].includes(undefined), true);
        \\assert.sameValue([1, , 3].lastIndexOf(undefined), -1);
        \\assert.sameValue([1, , 3].lastIndexOf(3, 1), -1);
        \\assert.sameValue([1, , 3].lastIndexOf(1, 1), 0);
        \\assert.sameValue([NaN].includes(NaN), true);
        \\assert.sameValue([NaN].indexOf(NaN), -1);
        \\assert.sameValue([NaN].lastIndexOf(NaN), -1);
        \\var o = { 0: 7, 2: 9, length: 3 };
        \\assert.sameValue(Array.prototype.indexOf.call(o, 9), 2);
        \\assert.sameValue(Array.prototype.lastIndexOf.call(o, 7), 0);
        \\assert.sameValue(Array.prototype.includes.call(o, undefined), true);
        \\assert.sameValue(Array.from([1, 2, 3]) + "", "1,2,3");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "leftover Array.reduce direction through one runtime walk" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue([1, 2, 3].reduce(function(a, v) { return a + v; }, 0), 6);
        \\assert.sameValue([1, 2, 3].reduceRight(function(a, v) { return a + v; }, 0), 6);
        \\assert.sameValue([1, 2, 3].reduce(function(a, v) { return a + v; }), 6);
        \\assert.sameValue([1, 2, 3].reduceRight(function(a, v) { return a - v; }), 0);
        \\var seen = [];
        \\assert.sameValue([1, , 3].reduce(function(a, v, i) { seen.push(i); return a + v; }, 0), 4);
        \\assert.sameValue(seen + "", "0,2");
        \\var seen_r = [];
        \\assert.sameValue([1, , 3].reduceRight(function(a, v, i) { seen_r.push(i); return a + v; }, 0), 4);
        \\assert.sameValue(seen_r + "", "2,0");
        \\assert.sameValue([, ,].reduce(function(a, v) { return v; }, 7), 7);
        \\var threw = false;
        \\try { [, ,].reduce(function(a, v) { return v; }); } catch (e) { threw = e instanceof TypeError; }
        \\assert.sameValue(threw, true);
        \\var threw_r = false;
        \\try { [, ,].reduceRight(function(a, v) { return v; }); } catch (e) { threw_r = e instanceof TypeError; }
        \\assert.sameValue(threw_r, true);
        \\assert.sameValue(Array.from([1, 2, 3]) + "", "1,2,3");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "leftover iterator wrap next return through one runtime kind" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var sealed = Object.preventExtensions({
        \\  next: function() { return { done: false, value: 3 }; },
        \\  return: function() { return { done: true, value: 9 }; },
        \\});
        \\var wrapped = Iterator.from(sealed);
        \\assert.sameValue(wrapped === sealed, false);
        \\assert.sameValue(wrapped.next().value, 3);
        \\assert.sameValue(wrapped.return().done, true);
        \\assert.sameValue(wrapped.return().value, 9);
        \\var no_return = Object.preventExtensions({
        \\  next: function() { return { done: true }; },
        \\});
        \\var wrapped2 = Iterator.from(no_return);
        \\assert.sameValue(wrapped2.return().done, true);
        \\assert.sameValue(wrapped2.return().value, undefined);
        \\var bad = Iterator.from({ next: 1 });
        \\var threw = false;
        \\try { bad.next(); } catch (e) { threw = e instanceof TypeError; }
        \\assert.sameValue(threw, true);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "stamped native data-method leftover runtime stamp preserves async generator and iterator helpers" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\async function* g() { yield 1; return 2; }
        \\var AsyncGeneratorPrototype = Object.getPrototypeOf(g.prototype);
        \\assert.sameValue(AsyncGeneratorPrototype[Symbol.toStringTag], "AsyncGenerator");
        \\assert.sameValue(AsyncGeneratorPrototype.next.length, 1);
        \\assert.sameValue(AsyncGeneratorPrototype.return.length, 1);
        \\assert.sameValue(AsyncGeneratorPrototype.throw.length, 1);
        \\assert.sameValue(AsyncGeneratorPrototype.next.name, "next");
        \\assert.sameValue(AsyncGeneratorPrototype.return.name, "return");
        \\assert.sameValue(AsyncGeneratorPrototype.throw.name, "throw");
        \\var helper = Iterator.from([1, 2]).map(function(x) { return x + 1; });
        \\var proto = Object.getPrototypeOf(helper);
        \\assert.sameValue(Object.prototype.toString.call(helper), "[object Iterator Helper]");
        \\assert.sameValue(helper.next, proto.next);
        \\assert.sameValue(helper.return, proto.return);
        \\assert.sameValue(proto.next.name, "next");
        \\assert.sameValue(proto.return.name, "return");
        \\assert.sameValue(proto.next.length, 0);
        \\assert.sameValue(helper.next().value, 2);
        \\assert.sameValue(helper.next().value, 3);
        \\assert.sameValue(helper.return().done, true);
        \\var concat = Iterator.concat([7]);
        \\assert.sameValue(Object.prototype.toString.call(concat), "[object Iterator Helper]");
        \\assert.sameValue(concat.next().value, 7);
        \\assert.sameValue(concat.return().done, true);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "fast prototype method leftover runtime domain preserves regexp and collection lookups" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var re = /a/;
        \\assert.sameValue(re.test, RegExp.prototype.test);
        \\assert.sameValue(re.exec, RegExp.prototype.exec);
        \\assert.sameValue(re.test("a"), true);
        \\assert.sameValue(re.exec("a")[0], "a");
        \\assert.sameValue(re.toString, RegExp.prototype.toString);
        \\re.test = 1;
        \\assert.sameValue(re.test, 1);
        \\delete re.test;
        \\assert.sameValue(re.test, RegExp.prototype.test);
        \\var savedTest = RegExp.prototype.test;
        \\RegExp.prototype.test = function(input) { return "patched:" + input; };
        \\assert.sameValue(re.test("a"), "patched:a");
        \\RegExp.prototype.test = savedTest;
        \\assert.sameValue(re.test("a"), true);
        \\var map = new Map([[1, 2]]);
        \\assert.sameValue(map.get, Map.prototype.get);
        \\assert.sameValue(map.set, Map.prototype.set);
        \\assert.sameValue(map.get(1), 2);
        \\map.get = 3;
        \\assert.sameValue(map.get, 3);
        \\delete map.get;
        \\assert.sameValue(map.get, Map.prototype.get);
        \\var savedGet = Map.prototype.get;
        \\Map.prototype.get = function(key) { return "mapped:" + key; };
        \\assert.sameValue(map.get(1), "mapped:1");
        \\Map.prototype.get = savedGet;
        \\assert.sameValue(map.get(1), 2);
        \\var set = new Set([1]);
        \\assert.sameValue(set.has, Set.prototype.has);
        \\assert.sameValue(set.add, Set.prototype.add);
        \\assert.sameValue(set.has(1), true);
        \\var wm = new WeakMap();
        \\var key = {};
        \\wm.set(key, 4);
        \\assert.sameValue(wm.get, WeakMap.prototype.get);
        \\assert.sameValue(wm.get(key), 4);
        \\var ws = new WeakSet();
        \\ws.add(key);
        \\assert.sameValue(ws.has, WeakSet.prototype.has);
        \\assert.sameValue(ws.has(key), true);
        \\assert.sameValue(set.get, undefined);
        \\assert.sameValue(({}).test, undefined);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "data view extras leftover optional species preserves accessors and omits species" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(Object.getOwnPropertyDescriptor(DataView, Symbol.species), undefined);
        \\assert.sameValue(ArrayBuffer[Symbol.species], ArrayBuffer);
        \\assert.sameValue(SharedArrayBuffer[Symbol.species], SharedArrayBuffer);
        \\assert.sameValue(DataView.prototype[Symbol.toStringTag], "DataView");
        \\assert.sameValue(Object.getOwnPropertyDescriptor(DataView.prototype, "buffer").get.name, "get buffer");
        \\assert.sameValue(Object.getOwnPropertyDescriptor(DataView.prototype, "byteLength").get.name, "get byteLength");
        \\assert.sameValue(Object.getOwnPropertyDescriptor(DataView.prototype, "byteOffset").get.name, "get byteOffset");
        \\assert.sameValue(Object.getOwnPropertyDescriptor(DataView.prototype, "resizable"), undefined);
        \\assert.sameValue(Object.getOwnPropertyDescriptor(DataView.prototype, "growable"), undefined);
        \\var dv = new DataView(new ArrayBuffer(4), 1, 2);
        \\assert.sameValue(dv.byteLength, 2);
        \\assert.sameValue(dv.byteOffset, 1);
        \\assert.sameValue(dv.buffer.byteLength, 4);
        \\dv.setUint8(0, 0xab);
        \\assert.sameValue(dv.getUint8(0), 0xab);
        \\assert.sameValue(dv.getInt8(1), 0);
        \\assert.throws(TypeError, function() {
        \\    Object.getOwnPropertyDescriptor(DataView.prototype, "byteLength").get.call({});
        \\});
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "defineNativeDataMethod leftover optional native id preserves iterator methods" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue([1].values().next().value, 1);
        \\assert.sameValue("ab"[Symbol.iterator]().next().value, "a");
        \\function* g() { yield 7; }
        \\var it = g();
        \\assert.sameValue(it.next().value, 7);
        \\assert.sameValue(it.return().done, true);
        \\var sealed = Object.preventExtensions({
        \\  next: function() { return { value: 9, done: false }; },
        \\  return: function() { return { value: 8, done: true }; },
        \\});
        \\var wrap = Iterator.from(sealed);
        \\assert.sameValue(wrap.next().value, 9);
        \\assert.sameValue(wrap.return().done, true);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "createStringValue leftover noinline preserves empty flags and ascii strings" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(/abc/.flags, "");
        \\assert.sameValue(/abc/.source, "abc");
        \\assert.sameValue("".bold(), "<b></b>");
        \\assert.sameValue("é".big(), "<big>é</big>");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "Engine eval TypeError with evaluated arguments does not double free constants" {
    {
        var js = try helpers.TestEngine.init(std.testing.allocator);
        defer js.deinit();
        try js.expectThrown("TypeError", js.eval("const obj = {}; obj.missing(\"a\", \"a\");"));
    }
    {
        var js = try helpers.TestEngine.init(std.testing.allocator);
        defer js.deinit();
        try js.expectThrown("TypeError", js.eval("RegExp.test(\"a\", \"a\");"));
    }
}

test "vm call handler accepts allocator-backed argument lists" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    try @import("zjs_host").output.install(ctx, try engine.exec.zjs_vm.contextGlobal(ctx));

    const print_key = try rt.internAtom("print");
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try bytes.append(rt.nativeAllocator(), op.get_var);
    var print_ref: [2]u8 = undefined;
    std.mem.writeInt(u16, &print_ref, 0, .little);
    try bytes.appendSlice(rt.nativeAllocator(), &print_ref);
    var arg: i32 = 1;
    while (arg <= 40) : (arg += 1) {
        try bytes.append(rt.nativeAllocator(), op.push_i32);
        try bytes.appendSlice(rt.nativeAllocator(), std.mem.asBytes(&arg));
    }
    try bytes.append(rt.nativeAllocator(), op.call);
    const argc: u16 = 40;
    try bytes.appendSlice(rt.nativeAllocator(), std.mem.asBytes(&argc));
    try bytes.append(rt.nativeAllocator(), op.@"return");
    const function = try makeFixture(rt, ctx, .{
        .name = "wide-call",
        .code = bytes.items,
        .globals = &.{print_key},
    });
    defer function.release(rt);

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    var vm_instance = engine.exec.Vm.initWithOutput(ctx, &stream);
    defer vm_instance.deinit();
    const result = try vm_instance.run(function.fb);

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

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings(expected.items, stream.buffered());
}

test "Engine API eval and job queue are wired" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    try js.expectThrown("SyntaxError", js.eval("1 2"));
    if (js.context.hasException()) js.context.clearException();

    const result = try js.eval("1; 2");
    try std.testing.expect(result.is(.undefined_value));

    helpers.test_engine.job_counter = 0;
    try js.runtime.job_queue.enqueueFunc(js.context, countJob, &.{});
    try js.runtime.job_queue.enqueueFunc(js.context, countJob, &.{});
    try js.runJobs();
    try std.testing.expectEqual(@as(usize, 2), helpers.test_engine.job_counter);

    helpers.test_engine.job_counter = 0;
    var i: usize = 0;
    while (i < 16) : (i += 1) try js.runtime.job_queue.enqueueFunc(js.context, countJob, &.{});
    try js.runJobs();
    try std.testing.expectEqual(@as(usize, 16), helpers.test_engine.job_counter);

    helpers.test_engine.job_counter = 0;
    try js.runtime.job_queue.enqueueFunc(js.context, countJobArgs, &.{ core.JSValue.int32(2), core.JSValue.int32(3) });
    try js.runJobs();
    try std.testing.expectEqual(@as(usize, 5), helpers.test_engine.job_counter);

    helpers.test_engine.job_counter = 0;
    try js.runtime.job_queue.enqueueFunc(js.context, countJobArgs, &.{
        core.JSValue.int32(1),
        core.JSValue.int32(2),
        core.JSValue.int32(3),
        core.JSValue.int32(4),
        core.JSValue.int32(5),
    });
    try js.runJobs();
    try std.testing.expectEqual(@as(usize, 15), helpers.test_engine.job_counter);

    try std.testing.expectError(error.TooManyJobArgs, js.runtime.job_queue.enqueueFunc(js.context, countJobArgs, &.{
        core.JSValue.int32(1),
        core.JSValue.int32(2),
        core.JSValue.int32(3),
        core.JSValue.int32(4),
        core.JSValue.int32(5),
        core.JSValue.int32(6),
    }));
    try std.testing.expectEqual(@as(usize, 0), js.runtime.job_queue.jobs.len);
}

test "job queue enqueue propagates allocator failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const account = try runtime_owner.createAllocationTestRuntime(failing.allocator());
    failing.fail_index = failing.alloc_index;
    defer account.destroy();
    var queue = engine.core.jobs.Queue.init(account);
    defer queue.deinit();

    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    try std.testing.expectError(error.OutOfMemory, queue.enqueueFunc(js.context, countJob, &.{}));
    try std.testing.expectEqual(@as(usize, 0), queue.jobs.len);
}

test "prepared Promise reactions reserve storage without claiming FIFO order" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const promise = try core.Object.create(js.runtime, core.class.ids.promise, null);
    const reaction = try engine.exec.promise_ops.promiseReactionRecord(
        js.runtime,
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
    );
    try engine.exec.promise_ops.appendPromiseReaction(js.runtime, promise, reaction);

    var prepared = try engine.exec.promise_ops.preparePromiseReactionJobs(
        js.context,
        promise,
        core.JSValue.int32(42),
        false,
    );
    defer prepared.deinit(js.runtime);
    try std.testing.expectEqual(@as(usize, 1), js.runtime.job_queue.reserved_entries);

    // This enqueue occurs while the reaction transaction is prepared, so it
    // must occupy the earlier physical FIFO position without stealing the
    // reaction's guaranteed slot.
    try js.runtime.job_queue.enqueuePromise(js.context, core.JSValue.int32(99));
    prepared.commit(js.context, promise);
    try std.testing.expectEqual(@as(usize, 0), js.runtime.job_queue.reserved_entries);
    try std.testing.expectEqual(@as(usize, 2), js.runtime.job_queue.jobs.len);

    var first = js.runtime.job_queue.takeFirst().?;
    defer first.deinit();
    switch (first.payload) {
        .promise => |payload| try std.testing.expectEqual(@as(?i32, 99), payload.value.as(.int)),
        else => return error.TypeError,
    }

    var second = js.runtime.job_queue.takeFirst().?;
    defer second.deinit();
    switch (second.payload) {
        .promise_reaction => |payload| try std.testing.expectEqual(@as(?i32, 42), payload.value.as(.int)),
        else => return error.TypeError,
    }
}

test "waitAsync completions enter one typed cross-realm FIFO after facade release" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    _ = try engine.exec.zjs_vm.contextGlobal(js.context);

    const realm_b = try core.JSContext.create(js.runtime, .{});
    var realm_b_owner = true;
    defer if (realm_b_owner) realm_b.destroy();
    _ = try engine.exec.zjs_vm.contextGlobal(realm_b);

    const promise_a = try core.Object.create(js.runtime, core.class.ids.promise, null);
    const promise_b = try core.Object.create(js.runtime, core.class.ids.promise, null);

    const waiter_a = try js.runtime.nativeAllocator().create(engine.exec.atomics_ops.AtomicsWaiter);
    waiter_a.* = .{
        .key = .{ .offset_or_ptr = @intFromPtr(promise_a) },
        .completion = .notified,
        .promise = promise_a.value(),
        .realm = core.RealmRef.retain(js.context),
    };
    engine.exec.atomics_ops.atomicsLinkAsyncWaiter(waiter_a);
    const waiter_b = try js.runtime.nativeAllocator().create(engine.exec.atomics_ops.AtomicsWaiter);
    waiter_b.* = .{
        .key = .{ .offset_or_ptr = @intFromPtr(promise_b) },
        .completion = .notified,
        .promise = promise_b.value(),
        .realm = core.RealmRef.retain(realm_b),
    };
    engine.exec.atomics_ops.atomicsLinkAsyncWaiter(waiter_b);
    var waiters_linked = true;
    defer if (waiters_linked) {
        engine.exec.atomics_ops.cleanupAtomicsWaitersForContext(js.context);
        engine.exec.atomics_ops.cleanupAtomicsWaitersForContext(realm_b);
    };

    // The host realm selects the Runtime, not which RealmRef-owned completion
    // is eligible to move into its FIFO.
    try engine.exec.atomics_ops.processExpiredAtomicsWaiters(js.context);
    waiters_linked = false;
    try std.testing.expectEqual(@as(usize, 2), js.runtime.job_queue.jobs.len);
    try std.testing.expect(js.runtime.job_queue.jobs[0].realm.borrow() == js.context);
    try std.testing.expect(js.runtime.job_queue.jobs[1].realm.borrow() == realm_b);

    realm_b.destroy();
    realm_b_owner = false;
    try std.testing.expect(js.runtime.job_queue.jobs[1].realm.borrow() == realm_b);

    try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(js.context, null)) == .success);
    try std.testing.expect(promise_a.promiseResult() != null);
    try std.testing.expect(promise_b.promiseResult() == null);
    try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(js.context, null)) == .success);
    try std.testing.expect(promise_b.promiseResult() != null);

    // Fulfilling a promise nothing subscribed to queues no further job.
    try std.testing.expectEqual(@as(usize, 0), js.runtime.job_queue.jobs.len);
}

test "public property key coercion accepts a Symbol.toPrimitive key" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const target = try ctx.createObject();
    const property_key = try ctx.eval(
        "({ [Symbol.toPrimitive]() { return 'missing'; } })",
        .{},
    );
    // The shadow observer's half of this test -- that the target and the key
    // stay exactly reachable across the coercion -- went with the observer.
    // What remains is the half that never depended on it: the coercion runs,
    // and a missing key resolves to undefined rather than trapping.
    const result = try ctx.getPropertyKey(target, property_key, .{});
    try std.testing.expect(result.is(.undefined_value));
}

test "waitAsync completion OOM stays at FIFO head for same-runtime retry" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    _ = try engine.exec.zjs_vm.contextGlobal(js.context);
    const promise = try core.Object.create(js.runtime, core.class.ids.promise, null);

    const waiter = try js.runtime.nativeAllocator().create(engine.exec.atomics_ops.AtomicsWaiter);
    waiter.* = .{
        .key = .{ .offset_or_ptr = @intFromPtr(promise) },
        .completion = .notified,
        .promise = promise.value(),
        .realm = core.RealmRef.retain(js.context),
    };
    engine.exec.atomics_ops.atomicsLinkAsyncWaiter(waiter);
    var waiter_linked = true;
    defer if (waiter_linked) engine.exec.atomics_ops.cleanupAtomicsWaitersForContext(js.context);

    try engine.exec.atomics_ops.processExpiredAtomicsWaiters(js.context);
    waiter_linked = false;
    helpers.test_engine.job_counter = 0;
    try js.runtime.job_queue.enqueueFunc(js.context, countJob, &.{});

    // TGC S4-b: sweep first -- the limit-triggered retry collection can now
    // reclaim storage cells, so the baseline must already be the live size.
    _ = js.runtime.collectFull() catch {};
    js.runtime.setNativeBytesLimitForTest(js.runtime.allocation_diagnostics.allocated_bytes);
    defer js.runtime.setNativeBytesLimitForTest(null);
    try std.testing.expectError(
        error.OutOfMemory,
        engine.exec.promise_ops.drainOnePendingJob(js.context, null),
    );
    try std.testing.expect(promise.promiseResult() == null);
    try std.testing.expectEqual(@as(usize, 2), js.runtime.job_queue.jobs.len);
    try std.testing.expect(std.meta.activeTag(js.runtime.job_queue.jobs[0].payload) == .atomics_waiter);
    try std.testing.expect(std.meta.activeTag(js.runtime.job_queue.jobs[1].payload) == .generic);

    js.runtime.setNativeBytesLimitForTest(null);
    try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(js.context, null)) == .success);
    try std.testing.expect(promise.promiseResult() != null);
    try std.testing.expectEqual(@as(usize, 1), js.runtime.job_queue.jobs.len);
    try std.testing.expect(std.meta.activeTag(js.runtime.job_queue.jobs[0].payload) == .generic);
    try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(js.context, null)) == .success);
    try std.testing.expectEqual(@as(usize, 1), helpers.test_engine.job_counter);
}

test "dynamic import job OOM retains its FIFO position for retry" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    _ = try engine.exec.zjs_vm.contextGlobal(js.context);

    const ImportProbe = struct {
        var attempts: usize = 0;

        fn run(
            _: *core.JSContext,
            _: ?*std.Io.Writer,
            _: *const engine.core.jobs.DynamicImportPayload,
        ) core.errors.RuntimeError!core.JSValue {
            attempts += 1;
            if (attempts == 1) return error.OutOfMemory;
            return core.JSValue.undefinedValue();
        }
    };
    ImportProbe.attempts = 0;
    helpers.test_engine.job_counter = 0;
    try js.runtime.job_queue.enqueueDynamicImport(
        js.context,
        ImportProbe.run,
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
    );
    try js.runtime.job_queue.enqueueFunc(js.context, countJob, &.{});

    try std.testing.expectError(
        error.OutOfMemory,
        engine.exec.promise_ops.drainOnePendingJob(js.context, null),
    );
    try std.testing.expectEqual(@as(usize, 2), js.runtime.job_queue.jobs.len);
    try std.testing.expect(std.meta.activeTag(js.runtime.job_queue.jobs[0].payload) == .dynamic_import);
    try std.testing.expect(std.meta.activeTag(js.runtime.job_queue.jobs[1].payload) == .generic);

    try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(js.context, null)) == .success);
    try std.testing.expectEqual(@as(usize, 2), ImportProbe.attempts);
    try std.testing.expectEqual(@as(usize, 1), js.runtime.job_queue.jobs.len);
    try std.testing.expect(std.meta.activeTag(js.runtime.job_queue.jobs[0].payload) == .generic);
    try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(js.context, null)) == .success);
    try std.testing.expectEqual(@as(usize, 1), helpers.test_engine.job_counter);
}

test "dynamic import job keeps its enqueue Realm after creator facade release" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    _ = try engine.exec.zjs_vm.contextGlobal(js.context);
    const entry_realm = try core.JSContext.create(js.runtime, .{});
    var entry_realm_owner = true;
    defer if (entry_realm_owner) entry_realm.destroy();
    const entry_global = try engine.exec.zjs_vm.contextGlobal(entry_realm);

    const ImportProbe = struct {
        var seen_realm: ?*core.JSContext = null;
        var seen_global: ?*core.Object = null;

        fn run(
            ctx: *core.JSContext,
            _: ?*std.Io.Writer,
            _: *const engine.core.jobs.DynamicImportPayload,
        ) core.errors.RuntimeError!core.JSValue {
            seen_realm = ctx;
            seen_global = ctx.global;
            return core.JSValue.undefinedValue();
        }
    };
    ImportProbe.seen_realm = null;
    ImportProbe.seen_global = null;
    try js.runtime.job_queue.enqueueDynamicImport(
        entry_realm,
        ImportProbe.run,
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
    );

    entry_realm.destroy();
    entry_realm_owner = false;
    try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(js.context, null)) == .success);
    try std.testing.expect(ImportProbe.seen_realm == entry_realm);
    try std.testing.expect(ImportProbe.seen_global == entry_global);
}

test "dynamic import loader mutates only the enqueue Realm registry after public owner release" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    _ = try engine.exec.zjs_vm.contextGlobal(js.context);

    const entry_realm = try core.JSContext.create(js.runtime, .{});
    var entry_realm_owner = true;
    defer if (entry_realm_owner) entry_realm.destroy();
    const entry_global = try engine.exec.zjs_vm.contextGlobal(entry_realm);

    const LoaderProbe = struct {
        expected: *core.JSContext,
        facade: *core.JSContext,
        saw_expected_realm: bool = false,
        active_registry_has_record: bool = false,
        facade_registry_has_record: bool = false,

        fn load(
            userdata: ?*anyopaque,
            ctx: *core.JSContext,
            _: ?*std.Io.Writer,
            _: *core.Object,
            _: []const u8,
            _: []const u8,
        ) core.context.DynamicImportError!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(userdata orelse return error.ModuleNotFound));
            const name = ctx.runtime.internAtom("w1e-enqueue-realm-record") catch return error.OutOfMemory;
            var pending = core.module.PendingDefinition.init(ctx.runtime, ctx.runtime.atoms);
            defer pending.deinit();
            _ = ctx.modules.prepareFreshTarget(name, &pending) catch return error.OutOfMemory;
            self.saw_expected_realm = ctx == self.expected;
            self.active_registry_has_record = ctx.modules.find(name) != null;
            self.facade_registry_has_record = self.facade.modules.find(name) != null;
            return core.JSValue.undefinedValue();
        }
    };

    var probe = LoaderProbe{
        .expected = entry_realm,
        .facade = js.context,
    };
    var loader_scope = js.runtime.installDynamicImportLoader(.{
        .callback = LoaderProbe.load,
        .userdata = &probe,
    });
    defer loader_scope.deinit();

    const specifier = try engine.exec.value_ops.createStringValue(js.runtime, "./record.mjs");
    _ = try engine.exec.module_graph.enqueueDynamicImportJob(
        entry_realm,
        entry_global,
        null,
        "/w1e/enqueue/main.mjs",
        specifier,
    );
    // The queued capability owns everything it needs; do not let the test's
    // returned Promise stand in for the Job's enqueue-Realm owner.

    entry_realm.destroy();
    entry_realm_owner = false;
    try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(js.context, null)) == .success);
    try std.testing.expect(probe.saw_expected_realm);
    try std.testing.expect(probe.active_registry_has_record);
    try std.testing.expect(!probe.facade_registry_has_record);
}

test "thenable job reservation OOM leaves resolving function retryable" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    try std.testing.expectEqual(@as(usize, 0), js.runtime.job_queue.capacity);

    const promise = try core.Object.create(js.runtime, core.class.ids.promise, null);
    const resolving = try engine.exec.promise_ops.createPromiseResolvingPair(js.runtime, global, promise.value());
    const resolve_object = try property_ops.expectObject(resolving.resolve);
    const state_value = resolve_object.functionPromiseResolvingState() orelse return error.TypeError;
    const state = try property_ops.expectObject(state_value);

    const thenable = try core.Object.create(js.runtime, core.class.ids.object, null);
    const promise_key = try js.runtime.internAtom("Promise");
    const callable = try global.getProperty(promise_key);
    const then_key = try js.runtime.internAtom("then");
    try thenable.defineOwnProperty(
        js.runtime,
        then_key,
        core.Descriptor.data(callable, .all),
    );

    js.runtime.setNativeBytesLimitForTest(js.runtime.allocation_diagnostics.allocated_bytes);
    defer js.runtime.setNativeBytesLimitForTest(null);
    try std.testing.expectError(error.OutOfMemory, engine.exec.promise_ops.promiseResolvingFunctionCall(
        js.context,
        null,
        global,
        resolve_object,
        &.{thenable.value()},
        null,
        null,
    ));

    try std.testing.expectEqual(@as(usize, 0), js.runtime.job_queue.jobs.len);
    try std.testing.expect(!state.promiseAlreadyResolved());
    try std.testing.expect(promise.promiseResult() == null);

    js.runtime.setNativeBytesLimitForTest(null);
    _ = try engine.exec.promise_ops.promiseResolvingFunctionCall(
        js.context,
        null,
        global,
        resolve_object,
        &.{thenable.value()},
        null,
        null,
    );

    try std.testing.expect(state.promiseAlreadyResolved());
    try std.testing.expect(promise.promiseResult() == null);
    try std.testing.expectEqual(@as(usize, 1), js.runtime.job_queue.jobs.len);
    try std.testing.expect(std.meta.activeTag(js.runtime.job_queue.jobs[0].payload) == .promise_thenable);
}

test "published Promise resolution survives resolver collection through typed FIFO owner" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    defer js.runtime.setNativeBytesLimitForTest(null);

    const promise = try core.Object.create(js.runtime, core.class.ids.promise, null);
    const reaction = try engine.exec.promise_ops.promiseReactionRecord(
        js.runtime,
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
    );
    try engine.exec.promise_ops.appendPromiseReaction(js.runtime, promise, reaction);

    const resolving = try engine.exec.promise_ops.createPromiseResolvingPair(js.runtime, global, promise.value());
    var resolving_alive = true;
    defer if (resolving_alive) {};
    const resolve_object = try property_ops.expectObject(resolving.resolve);

    // Reserve the durable continuation node, then force reaction-batch
    // preparation to fail after the resolving once-guard has committed.
    try js.runtime.job_queue.ensureCapacity(1);
    // TGC S4-b: sweep first -- the limit-triggered retry collection can now
    // reclaim storage cells, so the baseline must already be the live size.
    _ = js.runtime.collectFull() catch {};
    js.runtime.setNativeBytesLimitForTest(js.runtime.allocation_diagnostics.allocated_bytes);
    _ = try engine.exec.promise_ops.promiseResolvingFunctionCall(
        js.context,
        null,
        global,
        resolve_object,
        &.{core.JSValue.int32(41)},
        null,
        null,
    );
    try std.testing.expect(promise.promiseResult() == null);
    try std.testing.expectEqual(@as(usize, 1), js.runtime.job_queue.jobs.len);
    try std.testing.expect(std.meta.activeTag(js.runtime.job_queue.jobs[0].payload) == .promise_settlement);

    // Neither resolver is needed after publication: the Runtime FIFO owns the
    // target, completion and Realm until the same-runtime retry succeeds.
    resolving_alive = false;
    _ = try js.runtime.collectForTest();

    js.runtime.setNativeBytesLimitForTest(null);
    try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(js.context, null)) == .success);
    try std.testing.expectEqual(@as(?i32, 41), promise.promiseResult().?.as(.int));
    try std.testing.expect(!promise.promiseIsRejected());
    try std.testing.expectEqual(@as(usize, 1), js.runtime.job_queue.jobs.len);
    try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(js.context, null)) == .success);
}

test "Promise reaction retains callable Proxy classification after revocation" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    _ = try js.eval(
        \\var __revokedPromiseReaction = "pending";
        \\var __wakePromiseReaction;
        \\var __parentPromiseReaction = new Promise(function (resolve) { __wakePromiseReaction = resolve; });
        \\var __revocablePromiseHandler = Proxy.revocable(function (value) { return value + 1; }, {});
        \\var __childPromiseReaction = __parentPromiseReaction.then(__revocablePromiseHandler.proxy);
        \\__revocablePromiseHandler.revoke();
        \\__wakePromiseReaction(1);
        \\__childPromiseReaction.then(
        \\  function () { __revokedPromiseReaction = "fulfilled"; },
        \\  function (error) { __revokedPromiseReaction = error.name; }
        \\);
    );
    try js.runJobs();

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const result_key = try js.runtime.internAtom("__revokedPromiseReaction");
    const result = try global.getProperty(result_key);
    try helpers.expectStringValueBytes(result, "TypeError");
}

test "job queue keeps symbol arguments rooted until release" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    var queue = engine.core.jobs.Queue.init(rt);
    defer queue.deinit();
    var queue_roots = JobQueueRootProvider{ .queue = &queue };
    const provider = queue_roots.provider();
    try rt.registerRootProvider(provider);
    defer rt.unregisterRootProvider(provider);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-job-queue-symbol");
    const symbol_value = try rt.symbolValue(symbol_atom);
    try queue.enqueueFunc(ctx, countJob, &.{symbol_value});

    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);

    queue.deinit();
    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "job queue symbol roots preserve weak map values" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    var queue = engine.core.jobs.Queue.init(rt);
    defer queue.deinit();
    var queue_roots = JobQueueRootProvider{ .queue = &queue };
    const provider = queue_roots.provider();
    try rt.registerRootProvider(provider);
    defer rt.unregisterRootProvider(provider);

    const weak_map = try core.Object.create(rt, core.class.ids.weakmap, null);
    // The map is held only by this Zig local. The tracing collector treats
    // the host-explicit cycle removal below as a whole-heap mark-sweep with
    // declared roots, so name the TABLE; the entry value must stay alive
    // through ephemeron semantics alone (symbol key live via the queued
    // atom ref), which is exactly what this test exists to observe.
    var weak_map_slot: ?*core.Object = weak_map;
    var live_roots = core.runtime.rootObjects(.{&weak_map_slot});
    live_roots.activate(rt);
    defer live_roots.deactivate(rt);

    const value = try core.Object.create(rt, core.class.ids.object, null);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-job-queue-weak-key");
    const weak_key = try rt.symbolValue(symbol_atom);
    try engine.exec.collection_ops.setWeakMapEntry(rt, weak_map, weak_key, value.value());

    const queued_key = weak_key;
    try queue.enqueueFunc(ctx, countJob, &.{queued_key});
    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    try std.testing.expectEqual(@as(usize, 1), weak_map.weakCollectionEntries().len);
    try std.testing.expectEqual(value.gcHeader(), weak_map.weakCollectionEntries()[0].value.refHeader().?);

    queue.deinit();
    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
    try std.testing.expectEqual(@as(usize, 0), weak_map.weakCollectionEntries().len);
}

test "ordinary script entry points do not run full-heap cycle collection on exit" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const old_threshold = js.runtime.gcThreshold();
    js.runtime.setGCThreshold(std.math.maxInt(usize));
    defer js.runtime.setGCThreshold(old_threshold);

    const baseline_major_gc_count = js.runtime.gcStats().major_gc_count;

    // The direct-eval closure escapes the ordinary root through the global,
    // then remains callable after that root Frame has closed its open VarRefs.
    // This also pins the escaping/global/direct-eval ownership paths covered in
    // more detail by "Engine direct eval shares top-level lexical cells across
    // nested closures" and "escaped closure keeps its compile realm after
    // facade destruction".
    _ = try js.eval(
        \\globalThis.__evalExitClosure = (function () {
        \\  let value = 40;
        \\  return eval("() => ++value");
        \\})();
    );
    try std.testing.expectEqual(baseline_major_gc_count, js.runtime.gcStats().major_gc_count);

    _ = try js.eval(
        \\assert.sameValue(globalThis.__evalExitClosure(), 41);
        \\delete globalThis.__evalExitClosure;
    );
    try std.testing.expectEqual(baseline_major_gc_count, js.runtime.gcStats().major_gc_count);

    var context = zjs.borrowContext(js.context);
    const host_eval_script = try context.evalScriptSource(
        "globalThis.__hostEvalExitProbe = 7; __hostEvalExitProbe",
        .{ .filename = "no-exit-cycle-host-eval-script.js" },
    );
    try std.testing.expectEqual(@as(?i32, 7), host_eval_script.as(.int));
    try std.testing.expectEqual(baseline_major_gc_count, js.runtime.gcStats().major_gc_count);

    _ = try js.eval(
        \\(0, eval)("globalThis.__indirectEvalExitProbe = 9");
        \\assert.sameValue(globalThis.__indirectEvalExitProbe, 9);
        \\delete globalThis.__indirectEvalExitProbe;
        \\delete globalThis.__hostEvalExitProbe;
    );
    try std.testing.expectEqual(baseline_major_gc_count, js.runtime.gcStats().major_gc_count);

    // The public canonical-FB execution arm has no eval_entry/call wrapper.
    // Exercise it independently so its former exit collection cannot regress.
    var compiled = try engine.parser.compile(
        .{ .realm = js.context },
        "1 + 2",
        .{ .mode = .script, .filename = "no-exit-cycle-run-with-output.js", .return_completion = true },
    );
    defer compiled.deinit();
    const function = compiled.functionBytecode() orelse return error.TestExpectedEqual;
    var stack = engine.exec.stack.Stack.init(js.runtime, js.context.stackLimit());
    defer stack.deinit(js.runtime);
    const canonical = try engine.exec.zjs_vm.runWithOutput(js.context, &stack, function, null);
    try std.testing.expectEqual(@as(?i32, 3), canonical.as(.int));
    try std.testing.expectEqual(baseline_major_gc_count, js.runtime.gcStats().major_gc_count);
}

test "IC-R1: delete then get_field is undefined after a prior hit" {
    try helpers.expectPrints(
        \\function read(o) { return o.x; }
        \\var o = { x: 1 };
        \\var a = read(o);
        \\var d = delete o.x;
        \\var b = read(o);
        \\o.x = 2;
        \\var c = read(o);
        \\print([a, d, typeof b, b, c].join("/"));
    , "1/true/undefined//2\n");
}

test "IC-P1: OrdinarySet forwards to a Proxy proto [[Set]] trap" {
    try helpers.expectPrints(
        \\var called = false;
        \\var recv;
        \\var p = new Proxy({}, { set: function (t, k, v, r) { called = true; recv = r; return true; } });
        \\var o = Object.create(p);
        \\o.x = 1;
        \\print([called, o === recv, Object.prototype.hasOwnProperty.call(o, "x")].join("/"));
    , "true/true/false\n");
}

test "String.prototype.match invokes a custom matcher before coercing the receiver" {
    try helpers.expectPrints(
        \\var log = [];
        \\var receiver = { toString: function () { log.push("toString"); return "abc"; } };
        \\var matcher = {};
        \\matcher[Symbol.match] = function (value) { log.push(value === receiver ? "same" : "different"); return 7; };
        \\print(String.prototype.match.call(receiver, matcher));
        \\print(log.join(","));
    , "7\nsame\n");
}

test "RegExp Symbol.split preserves captures returned by custom exec" {
    try helpers.expectPrints(
        \\var log = [];
        \\var capture = { toString: function () { log.push("coerced"); return "capture"; } };
        \\function Splitter() { this.lastIndex = 0; }
        \\Splitter.prototype.exec = function () {
        \\  if (this.lastIndex === 1) { this.lastIndex = 2; return { 0: "x", 1: capture, length: 2 }; }
        \\  return null;
        \\};
        \\var regexp = /x/;
        \\regexp.constructor = {};
        \\regexp.constructor[Symbol.species] = Splitter;
        \\var parts = regexp[Symbol.split]("axb");
        \\print(parts[1] === capture);
        \\print(log.join(","));
    , "true\n\n");
}

test "RegExp Symbol.split propagates invalid species exec TypeError" {
    try helpers.expectPrints(
        \\var regexp = /,/;
        \\function Splitter() { return { exec: 1, lastIndex: 0 }; }
        \\regexp.constructor = { [Symbol.species]: Splitter };
        \\try { "a,b".split(regexp); } catch (error) { print(error.name); }
    , "TypeError\n");
}

test "RegExp Symbol.split appends sticky flag without narrowing wide species flags" {
    try helpers.expectPrints(
        \\var seen;
        \\function Splitter(pattern, flags) { seen = flags; return /,/y; }
        \\var regexp = /,/;
        \\Object.defineProperty(regexp, "flags", { get: function () { return "\u0100"; } });
        \\regexp.constructor = { [Symbol.species]: Splitter };
        \\var parts = "a,b".split(regexp);
        \\print(seen === "\u0100y");
        \\print(parts.join("|"));
    , "true\na|b\n");
}

test "RegExp Symbol.split unobservable loop matches the sticky spec loop" {
    try helpers.expectPrints(
        \\function show(parts) { return JSON.stringify(parts.map(function (p) { return p === undefined ? "U" : p; })); }
        \\print(show("a1b22c333".split(/(\d)(x)?/)));
        \\print(show("a1b22c333".split(/(\d)(x)?/, 4)));
        \\print(show("abc".split(/(?:)/)));
        \\print(show("a,b,".split(/,*/)));
        \\print(show("\ud83d\ude00x\ud83d".split(/(?:)/u)));
        \\print(show("\ud83d\ude00x".split(/(?:)/)));
        \\print(show("\ud83d\ude00\ud83d\ude00".split(/\ude00/u)));
        \\print(show("\ud83d\ude00\ud83d\ude00".split(/\ude00/)));
        \\print(show("ab\nab".split(/^a/)));
        \\print(show("ab\nab".split(/^a/m)));
        \\print(show("xaxbx".split(/(?<=a)x/)));
        \\print(show("a,b".split(/$/)));
        \\print(show("A-b-C".split(/-/i, 2)));
        \\print(show("k1=v1;k2=v2;x".split(/(\w)(\d)=/)));
        \\print(RegExp.lastMatch + " " + RegExp.$1 + " " + RegExp.$2 + " " + RegExp.leftContext);
        \\var held = /-/y;
        \\var re = /-/;
        \\re.constructor = { [Symbol.species]: function () { return held; } };
        \\held.lastIndex = 9;
        \\print(show("a-b-c".split(re)) + " " + held.lastIndex);
        \\held.lastIndex = 9;
        \\print(show("a-b-c".split(re, 2)) + " " + held.lastIndex);
        \\held.lastIndex = 9;
        \\print(show("a-b-".split(re)) + " " + held.lastIndex);
    ,
        \\["a","1","U","b","2","U","","2","U","c","3","U","","3","U","","3","U",""]
        \\["a","1","U","b"]
        \\["a","b","c"]
        \\["a","b",""]
        \\["😀","x","\ud83d"]
        \\["\ud83d","\ude00","x"]
        \\["😀😀"]
        \\["\ud83d","\ud83d",""]
        \\["","b\nab"]
        \\["","b\n","b"]
        \\["xa","bx"]
        \\["a,b"]
        \\["A","b"]
        \\["","k","1","v1;","k","2","v2;x"]
        \\k2= k 2 k1=v1;
        \\["a","b","c"] 0
        \\["a","b"] 4
        \\["a","b",""] 4
        \\
    );
}

test "RegExp Symbol.split keeps observable exec protocols on the generic loop" {
    try helpers.expectPrints(
        \\var log = [];
        \\var exec = RegExp.prototype.exec;
        \\RegExp.prototype.exec = function (s) { log.push(this.lastIndex); return exec.call(this, s); };
        \\print("a,b".split(/,/).join("|") + " " + log.join(","));
        \\RegExp.prototype.exec = exec;
        \\log = [];
        \\class Sub extends RegExp { exec(s) { log.push(this.lastIndex); return super.exec(s); } }
        \\print("x1y".split(new Sub("\\d")).join("|") + " " + log.join(","));
        \\log = [];
        \\var re = /-/;
        \\re.constructor = { [Symbol.species]: function (s, f) {
        \\  return new Proxy(new RegExp(s, f), {
        \\    set: function (o, k, v) { log.push(String(k) + "=" + v); o[k] = v; return true; },
        \\    get: function (o, k) { var v = o[k]; return typeof v === "function" ? v.bind(o) : v; },
        \\  });
        \\} };
        \\print("a-b".split(re).join("|") + " " + log.join(","));
        \\re.constructor = { [Symbol.species]: function (s, f) {
        \\  var r = new RegExp(s, f);
        \\  Object.defineProperty(r, "lastIndex", { writable: false });
        \\  return r;
        \\} };
        \\try { "a-b".split(re); } catch (error) { print(error.name); }
    , "a|b 0,1,2\nx|y 0,1,2\na|b lastIndex=0,lastIndex=1,lastIndex=2\nTypeError\n");
}

test "flagless RegExp flags accessor reuses the runtime empty string" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const pattern = try core.string.String.createAscii(rt, "a");
    const empty = try rt.emptyString();
    const regexp = try engine.exec.regexp_ops.constructWithPrototype(rt, pattern.value(), empty.value(), null);

    const allocations = rt.allocation_diagnostics.allocation_count;
    const flags = try engine.exec.regexp_ops.accessor(rt, regexp, "flags");
    try std.testing.expect(flags.asStringBody().? == empty);
    try std.testing.expectEqual(allocations, rt.allocation_diagnostics.allocation_count);
}

test "RegExp exec result template preserves metadata groups and indices" {
    try helpers.expectPrints(
        \\var plain = /a/.exec("ba");
        \\print([plain.length, plain[0], plain.index, plain.input, plain.groups === undefined].join("|"));
        \\var named = /(?<word>a)/d.exec("ba");
        \\print([named.length, named[0], named[1], named.index, named.input, named.groups.word,
        \\       named.indices[0][0], named.indices[0][1], named.indices.groups.word[0], named.indices.groups.word[1]].join("|"));
    , "1|a|1|ba|true\n2|a|a|1|ba|a|1|2|1|2\n");
}

test "RegExp compiler stack overflow is a catchable SyntaxError" {
    try helpers.expectPrints(
        \\try { new RegExp("(?:".repeat(40000)); print("no throw"); } catch(e) { print(e.name + ":" + e.message); }
        \\try { new RegExp("[".repeat(4000)+"a"+"]".repeat(4000),"v"); print("v-no throw"); } catch(e) { print("v:" + e.name + ":" + e.message); }
        \\try { new RegExp("[".repeat(200)+"a"+"]".repeat(200),"v"); print("v-shallow-ok"); } catch(e) { print("v-shallow:" + e.name); }
        \\try { new RegExp("(?:".repeat(1000)+")".repeat(1000)); print("shallow-ok"); } catch(e) { print("shallow:" + e.name); }
    , "SyntaxError:stack overflow\n" ++
        "v:SyntaxError:stack overflow\n" ++
        "v-shallow-ok\n" ++
        "shallow-ok\n");
}

test "RegExp accepts literal astral group names in non-unicode mode" {
    try helpers.expectPrints(
        \\var nm = String.fromCharCode(0xD801,0xDC00);
        \\["", "u", "v"].forEach(function(fl){
        \\  try { var r = new RegExp("(?<"+nm+">x)", fl); print("flags["+fl+"] accepted; groups:", JSON.stringify(Object.keys(r.exec("x").groups))); }
        \\  catch(e){ print("flags["+fl+"]:", e.message); }
        \\});
    , "flags[] accepted; groups: [\"𐐀\"]\n" ++
        "flags[u] accepted; groups: [\"𐐀\"]\n" ++
        "flags[v] accepted; groups: [\"𐐀\"]\n");
}

test "RegExp literals reuse parse-time bytecode and the intrinsic realm shape" {
    try helpers.expectPrints(
        \\var IntrinsicRegExp = RegExp;
        \\var intrinsicPrototype = RegExp.prototype;
        \\function make() { return /(?<letter>a)/dgi; }
        \\var first = make();
        \\var second = make();
        \\first.lastIndex = 3;
        \\print([first !== second, first.lastIndex, second.lastIndex, first.source, first.flags].join("|"));
        \\print([first.exec("---A").groups.letter, first.lastIndex].join("|"));
        \\var constructorCalls = 0;
        \\function ReplacementRegExp() { constructorCalls++; }
        \\ReplacementRegExp.prototype = { replacement: true };
        \\globalThis.RegExp = ReplacementRegExp;
        \\var afterReplacement = /b/gy;
        \\print([Object.getPrototypeOf(afterReplacement) === intrinsicPrototype,
        \\       afterReplacement.constructor === IntrinsicRegExp, constructorCalls,
        \\       afterReplacement.source, afterReplacement.flags,
        \\       afterReplacement.test("b"), afterReplacement.lastIndex].join("|"));
    , "true|3|0|(?<letter>a)|dgi\n" ++
        "A|4\n" ++
        "true|true|0|b|gy|true|1\n");
}

test "RegExp legacy statics preserve the realm snapshot across constructor replacement" {
    try helpers.expectPrints(
        \\var IntrinsicRegExp = RegExp;
        \\var noCapture = /x/;
        \\var captured = /(a)/;
        \\/(a)(b)?/.exec("zabq");
        \\print([IntrinsicRegExp.input, IntrinsicRegExp.lastMatch, IntrinsicRegExp.lastParen,
        \\       IntrinsicRegExp.leftContext, IntrinsicRegExp.rightContext,
        \\       IntrinsicRegExp.$1, IntrinsicRegExp.$2, IntrinsicRegExp.$3].join("|"));
        \\globalThis.RegExp = function Replacement() {};
        \\noCapture.exec("xx");
        \\print([IntrinsicRegExp.input, IntrinsicRegExp.lastMatch, IntrinsicRegExp.lastParen,
        \\       IntrinsicRegExp.leftContext, IntrinsicRegExp.rightContext,
        \\       IntrinsicRegExp.$1].join("|"));
        \\captured.exec("zaq");
        \\IntrinsicRegExp.input = "override";
        \\print([IntrinsicRegExp.input, IntrinsicRegExp.lastMatch, IntrinsicRegExp.leftContext,
        \\       IntrinsicRegExp.rightContext, IntrinsicRegExp.$1].join("|"));
    , "zabq|ab|b|z|q|a|b|\n" ++
        "xx|x|||x|\n" ++
        "override|a|z|q|a\n");
}

test "regexp split and global match arrays use the realm Array prototype" {
    try helpers.expectPrints(
        \\print(Object.getPrototypeOf("a".split(/x/)) === Array.prototype);
        \\print(Object.getPrototypeOf("a".split(/x/, 0)) === Array.prototype);
        \\print(Object.getPrototypeOf("a".match(/a/g)) === Array.prototype);
    , "true\ntrue\ntrue\n");
}

test "RegExp Symbol.split uses the realm intrinsic default species" {
    try helpers.expectPrints(
        \\var IntrinsicRegExp = RegExp;
        \\var split = IntrinsicRegExp.prototype[Symbol.split];
        \\var rx = /,/;
        \\Object.defineProperty(rx, "constructor", { value: undefined, configurable: true });
        \\var fakeCalls = 0;
        \\globalThis.RegExp = function FakeRegExp() { fakeCalls++; return { lastIndex: 0, exec: function () { return null; } }; };
        \\var parts = split.call(rx, "a,b");
        \\print(fakeCalls + ":" + parts.join("|"));
    , "0:a|b\n");
}

test "Engine eval preserves global lexical write fast path semantics" {
    try helpers.expectPrints(
        \\let g = 0;
        \\g = 1;
        \\function setGlobal() { g = g + 2; }
        \\setGlobal();
        \\print(g);
        \\const c = 1;
        \\try { c = 2; } catch (e) { print(e.name, c); }
        \\let shadow = "global";
        \\function localShadow() { let shadow = "local"; shadow = "changed"; return shadow; }
        \\print(localShadow(), shadow);
        \\let withTarget = { g: 10 };
        \\with (withTarget) { g = 11; }
        \\print(g, withTarget.g);
    , "3\nTypeError 1\nchanged global\n3 11\n");
}

test "Engine nested functions retain ancestor with environments during finalization" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var outer = 1;
        \\var environment = { outer: "initial" };
        \\with (environment) {
        \\  (function () { outer = "updated"; })();
        \\}
        \\assert.sameValue(outer, 1);
        \\assert.sameValue(environment.outer, "updated");
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "Engine eval preserves selected with references during updates" {
    try helpers.expectPrints(
        \\function updateDeletedProperty() {
        \\  var x = 0;
        \\  var scope = { get x() { delete this.x; return 2; } };
        \\  with (scope) { x *= 3; }
        \\  print(scope.x, x);
        \\}
        \\updateDeletedProperty();
        \\var probes = 0, outer = { x: 7 }, inner, flag = true;
        \\with (outer) {
        \\  with (inner = {
        \\    x: 4,
        \\    get [Symbol.unscopables]() {
        \\      probes++;
        \\      return { x: flag = !flag };
        \\    }
        \\  }) { x++; }
        \\}
        \\print(probes, outer.x, inner.x, flag);
    , "6 0\n1 7 5 false\n");
}

test "with compound assignment rechecks proxy binding before get and set" {
    try helpers.expectPrints(
        \\var log = [];
        \\var target = { p: 0 };
        \\var proxy = new Proxy(target, {
        \\  has: function(t, key) { log.push("has:" + String(key)); return Reflect.has(t, key); },
        \\  get: function(t, key, receiver) { log.push("get:" + String(key)); return Reflect.get(t, key, receiver); },
        \\  set: function(t, key, value, receiver) { log.push("set:" + String(key)); return Reflect.set(t, key, value, receiver); },
        \\  getOwnPropertyDescriptor: function(t, key) { log.push("getOwnPropertyDescriptor:" + String(key)); return Reflect.getOwnPropertyDescriptor(t, key); },
        \\  defineProperty: function(t, key, desc) { log.push("defineProperty:" + String(key)); return Reflect.defineProperty(t, key, desc); }
        \\});
        \\with (proxy) { p += 1; }
        \\print(log.join("|"));
    , "has:p|get:Symbol(Symbol.unscopables)|has:p|get:p|has:p|set:p|getOwnPropertyDescriptor:p|defineProperty:p\n");
}

test "Engine destructuring snapshots with binding references before property reads" {
    try helpers.expectPrints(
        \\var log = [];
        \\var sourceKey = { toString: function() { log.push('sourceKey'); return 'p'; } };
        \\var source = { get p() { log.push('get source'); return undefined; } };
        \\var env = new Proxy({}, { has: function(_, key) { log.push('binding::' + key); return false; } });
        \\var defaultValue = 0;
        \\var varTarget;
        \\with (env) { var { [sourceKey]: varTarget = defaultValue } = source; }
        \\print(varTarget, log.join('|'));
        \\log = [];
        \\var target = { selected: 'old' };
        \\var selected = 'local';
        \\var selectedSource = { get p() { log.push('get selected'); return 9; } };
        \\var selectedEnv = new Proxy(target, {
        \\  has: function(_, key) { log.push('has:' + key); return key === 'selected'; }
        \\});
        \\with (selectedEnv) { var { p: selected } = selectedSource; }
        \\print(selected, target.selected, log.join('|'));
        \\(function() {
        \\  var [x, readX] = [1, function() { return x; }];
        \\  print(x, readX());
        \\})();
        \\(function() {
        \\  var [readY, { p: y }] = [function() { return y; }, { p: 13 }];
        \\  print(y, readY());
        \\})();
    , "0 binding::source|binding::sourceKey|sourceKey|binding::varTarget|get source|binding::defaultValue\n" ++
        "local 9 has:selectedSource|has:selected|get selected|has:selected\n" ++
        "1 1\n13 13\n");
}

test "Engine with destructuring assignment reaches const fallback at runtime" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function fallback() {
        \\  const x = 0;
        \\  with ({}) ({ x } = { x: 1 });
        \\}
        \\let caught = false;
        \\try { fallback(); } catch (error) { caught = error instanceof TypeError; }
        \\assert.sameValue(caught, true);
        \\function dynamicBinding() {
        \\  const x = 0;
        \\  const scope = { x: 2 };
        \\  with (scope) ({ x } = { x: 3 });
        \\  return [x, scope.x];
        \\}
        \\const values = dynamicBinding();
        \\assert.sameValue(values[0], 0);
        \\assert.sameValue(values[1], 3);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "Engine eval assignments capture the target before dynamic var insertion" {
    try helpers.expectPrints(
        \\function simpleAssignment() {
        \\  var x = 0;
        \\  var inner = (function() {
        \\    x = (eval("var x;"), 1);
        \\    return x;
        \\  })();
        \\  print(inner, x);
        \\}
        \\function compoundAssignment() {
        \\  var x = 3;
        \\  var inner = (function() {
        \\    x *= (eval("var x = 2;"), 4);
        \\    return x;
        \\  })();
        \\  print(inner, x);
        \\}
        \\function initializerAssignment() {
        \\  var x = 0;
        \\  var inner = (function() {
        \\    var value = (x = (eval("var x;"), 1));
        \\    return [x, value];
        \\  })();
        \\  print(inner[0], inner[1], x);
        \\}
        \\function templateAssignment() {
        \\  var x = 3;
        \\  var inner = (function() {
        \\    x += `${eval("var x = 2;")}`;
        \\    return x;
        \\  })();
        \\  print(inner, x);
        \\}
        \\simpleAssignment();
        \\compoundAssignment();
        \\initializerAssignment();
        \\templateAssignment();
    , "undefined 1\n2 12\nundefined 1 1\n2 3undefined\n");
}

test "Engine arrow eval assignments capture the target before dynamic var insertion" {
    try helpers.expectPrints(
        \\function outer() {
        \\  var x = 0;
        \\  var simple = () => { x = (eval("var x;"), 1); return x; };
        \\  print(simple(), x);
        \\  x = 3;
        \\  var compound = () => { x *= (eval("var x = 2;"), 4); return x; };
        \\  print(compound(), x);
        \\  x = 0;
        \\  var initializer = () => {
        \\    var value = (x = (eval("var x;"), 1));
        \\    return [x, value];
        \\  };
        \\  var initialized = initializer();
        \\  print(initialized[0], initialized[1], x);
        \\  x = 3;
        \\  var template = () => { x += `${eval("var x = 2;")}`; return x; };
        \\  print(template(), x);
        \\}
        \\outer();
        \\const parameterEval = (
        \\  p = eval("var arguments = 'parameter'"),
        \\  readParameterArguments = () => arguments
        \\) => {
        \\  var arguments = "body";
        \\  return [arguments, readParameterArguments()];
        \\};
        \\const parameterEvalResult = parameterEval();
        \\assert.sameValue(parameterEvalResult[0], "body");
        \\assert.sameValue(parameterEvalResult[1], "parameter");
    , "undefined 1\n2 12\nundefined 1 1\n2 3undefined\n");
}

test "Engine direct eval captures the caller arguments binding" {

    // The direct eval assignment observes the function's mapped Arguments
    // binding. Parameter initializers use the parameter-environment binding
    // when the body declares its own `arguments` variable, and otherwise
    // share the function binding with the body.
    try helpers.expectPrints(
        \\function direct(value) { return eval("arguments[0]"); }
        \\function throughArrow(value) { return (() => eval("arguments[0]"))(); }
        \\function replace(value) {
        \\  var old = arguments;
        \\  var read = eval("arguments[0]");
        \\  eval("arguments = ['replaced']");
        \\  return [read, arguments[0], old === arguments];
        \\}
        \\function parameterShadow(arguments) {
        \\  eval("arguments = 'updated'");
        \\  return arguments;
        \\}
        \\function parameterClosure(h = () => arguments) {
        \\  var arguments = 0;
        \\  return arguments === h();
        \\}
        \\function parameterClosureNoInit(h = () => arguments) {
        \\  var arguments;
        \\  var before = [void 0 === arguments, h() === arguments];
        \\  arguments = 0;
        \\  return [before[0], before[1], arguments === h()];
        \\}
        \\var closed1, closed2, closedBody;
        \\function parameterEvalClosed(
        \\  _ = (eval("var scoped = 'inside'"), closed1 = function() { return scoped; }),
        \\  __ = closed2 = function() { return scoped; }
        \\) { closedBody = function() { return scoped; }; }
        \\var open1, open2;
        \\function parameterEvalOpen(
        \\  _ = open1 = function() { return opened; },
        \\  __ = (eval("var opened = 'inside'"), open2 = function() { return opened; })
        \\) {}
        \\var replaced = replace(41);
        \\parameterEvalClosed();
        \\parameterEvalOpen();
        \\print(direct(41), throughArrow(42));
        \\print(replaced[0], replaced[1], replaced[2], parameterShadow('old'));
        \\print(closed1(), closed2(), closedBody());
        \\print(open1(), open2());
        \\var noInit = parameterClosureNoInit();
        \\print(parameterClosure(), noInit[0], noInit[1], noInit[2]);
    , "41 42\n41 replaced false Arguments {  }\ninside inside inside\ninside inside\nfalse false true false\n");
}

test "Engine arguments writes prefer the current function binding over outer lexical bindings" {
    try helpers.expectPrints(
        \\let arguments = 'outer';
        \\function ordinary() {
        \\  arguments = 'ordinary';
        \\  return arguments;
        \\}
        \\function parameterDefault(value = (arguments = 'parameter')) {
        \\  return value + ' ' + arguments;
        \\}
        \\function parameterArrow(value = () => (arguments = 'parameter-arrow')) {
        \\  return value() + ' ' + arguments;
        \\}
        \\function explicitParameter(arguments = 'old', value = (arguments = 'new')) {
        \\  return arguments;
        \\}
        \\function destructuredParameter({ arguments } = { arguments: 'old' }, value = (arguments = 'new')) {
        \\  return arguments;
        \\}
        \\var arrow = () => {
        \\  arguments = 'arrow';
        \\  return arguments;
        \\};
        \\print(ordinary(), arguments);
        \\print(parameterDefault(), arguments);
        \\print(parameterArrow(), arguments);
        \\print(explicitParameter(), destructuredParameter());
        \\print(arrow(), arguments);
    , "ordinary outer\nparameter parameter outer\nparameter-arrow parameter-arrow outer\nnew new\narrow arrow\n");
}

test "Engine direct eval shares top-level lexical cells across nested closures" {

    // A direct eval var declaration must skip the temporary catch binding and
    // keep the caller's dynamic var object available after the catch exits.
    // Repeating a plain `var saved` declaration preserves the existing value.
    try helpers.expectPrints(
        \\let x = 500;
        \\function direct() { return eval("x"); }
        \\function write() { eval("x = 501"); }
        \\var nested = eval("() => eval('x')");
        \\var env = { x: 9000, [Symbol.unscopables]: { x: true } };
        \\function makeAdder() {
        \\  with (env) return eval("y => eval('x + y')");
        \\}
        \\var catchValue = 'global';
        \\var catchLog = '';
        \\function catchEval() {
        \\  try { throw 8; } catch (catchValue) {
        \\    eval("var catchValue = 42");
        \\    catchLog += catchValue;
        \\  }
        \\  catchValue = 'local';
        \\  catchLog += catchValue;
        \\}
        \\function preserveEvalVar() {
        \\  eval("var saved = 1");
        \\  eval("var saved");
        \\  return saved;
        \\}
        \\print(direct(), nested());
        \\write();
        \\print(x, makeAdder()(10));
        \\catchEval();
        \\print(catchValue, catchLog);
        \\print(preserveEvalVar());
    , "500 500\n501 511\nglobal 42local\n1\n");
}

test "Engine constructor parameter defaults use the initialized this binding" {
    try helpers.expectPrints(
        \\class A {
        \\  #x = 'hello';
        \\  constructor(value = this.#x) { this.value = value; }
        \\}
        \\var a = new A();
        \\print(a.value);
        \\class B extends A {
        \\  constructor() { super(); print('value' in this, this.value); }
        \\}
        \\new B();
        \\class C extends A {
        \\  constructor(value = this) { super(value); }
        \\}
        \\try { new C(); } catch (error) { print(error.name); }
    , "hello\ntrue hello\nReferenceError\n");
}

test "Engine heritage closures retain the initialized inner class-name binding" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var expressionProbe;
        \\var expressionClass = class InnerExpression extends (
        \\  expressionProbe = function () { return InnerExpression; }, Object
        \\) {};
        \\assert.sameValue(expressionProbe(), expressionClass);
        \\var declarationProbe;
        \\var declarationClass;
        \\{
        \\  class InnerDeclaration extends (
        \\    declarationProbe = function () { return InnerDeclaration; }, Object
        \\  ) {}
        \\  declarationClass = InnerDeclaration;
        \\}
        \\assert.sameValue(declarationProbe(), declarationClass);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "Engine inferred class names precede static initialization across named-evaluation sites" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\  let Assigned;
        \\  Assigned = class { static { this.observedName = this.name; } };
        \\  assert.sameValue(Assigned.name, "Assigned");
        \\  assert.sameValue(Assigned.observedName, "Assigned");
        \\  const computedKey = Symbol("computed");
        \\  const holder = { [computedKey]: class { static { this.observedName = this.name; } } };
        \\  assert.sameValue(holder[computedKey].name, "[computed]");
        \\  assert.sameValue(holder[computedKey].observedName, "[computed]");
        \\  class Outer {
        \\    instance = class { static { this.observedName = this.name; } };
        \\    static field = class { static { this.observedName = this.name; } };
        \\  }
        \\  const outer = new Outer();
        \\  assert.sameValue(outer.instance.name, "instance");
        \\  assert.sameValue(outer.instance.observedName, "instance");
        \\  assert.sameValue(Outer.field.name, "field");
        \\  assert.sameValue(Outer.field.observedName, "field");
        \\  const Sequence = (0, class { static { this.observedName = this.name; } });
        \\  assert.sameValue(Sequence.name, "");
        \\  assert.sameValue(Sequence.observedName, "");
        \\  const Override = class {
        \\    static name = "override";
        \\    static { this.observedName = this.name; }
        \\  };
        \\  assert.sameValue(Override.name, "override");
        \\  assert.sameValue(Override.observedName, "override");
        \\})();
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "Engine eval balances refcounts for refcounted duplicate-key object literals" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    _ = js.runtime;

    _ = try js.eval(
        \\globalThis.__dupLitO1 = { m: 1 };
        \\globalThis.__dupLitO2 = { m: 2 };
    );

    // TestEngine only returns the script completion value for "<repl>".
    _ = try js.evalWithOptions("__dupLitO1", .{ .filename = "<repl>" });
    _ = try js.evalWithOptions("__dupLitO2", .{ .filename = "<repl>" });

    const result = try js.evalWithOptions(
        \\let __dupLitLast = null;
        \\for (let i = 0; i < 16; i++) {
        \\  __dupLitLast = { a: __dupLitO1, a: __dupLitO2, keep: __dupLitO1 };
        \\}
        \\const __dupLitOk = __dupLitLast.a === __dupLitO2 && __dupLitLast.keep === __dupLitO1;
        \\__dupLitLast = null;
        \\__dupLitOk ? 1 : 0
    , .{ .filename = "<repl>" });
    try std.testing.expectEqual(@as(?i32, 1), result.as(.int));

    // Every literal died (last = null): both source objects must be back at
    // their pre-loop refcounts — no per-iteration leak from the duplicate-key
    // replace, no over-free from the append move.
}

test "Engine eval routes host output through global function calls" {
    try helpers.expectPrints(
        \\print(1);
        \\console.log("x");
        \\const out = print;
        \\out(2 + 3, typeof out);
        \\const logger = console.log;
        \\logger("ok");
        \\const c = console;
        \\c.log("alias");
    , "1\nx\n5 function\nok\nalias\n");
}

test "using early exit before await using keeps sync disposal synchronous" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function plainBlockForUsingOpcodeCheck() { { let value = 1; return value; } }
        \\let sameTurn = true;
        \\async function disposeBeforeAwaitUsing() {
        \\  try {
        \\    outer: {
        \\      using resource = { [Symbol.dispose]() { throw "dispose"; } };
        \\      break outer;
        \\      await using neverExecuted = null;
        \\    }
        \\  } catch (error) {
        \\    print(error, sameTurn);
        \\  }
        \\}
        \\disposeBeforeAwaitUsing();
        \\sameTurn = false;
    , &stream);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("dispose true\n", stream.buffered());

    const plain = try globalFunctionBytecode(js, "plainBlockForUsingOpcodeCheck");
    try std.testing.expectEqual(@as(usize, 0), try finalOpcodeCount(plain.byteCode(), op.ext0));

    var disassembly_buffer: [2048]u8 = undefined;
    var disassembly = std.Io.Writer.fixed(&disassembly_buffer);
    try bytecode.dump.dumpFunctionBytecode(&disassembly, plain, js.runtime.atoms, .{});
    try std.testing.expect(std.mem.indexOf(u8, disassembly.buffered(), "using_") == null);
}

test "Engine eval preserves local numeric add host output semantics" {
    try helpers.expectPrints(
        \\let a = 1;
        \\let b = 2;
        \\print(a + b);
        \\let max = 2147483647;
        \\print(max + 1);
        \\let oldPrint = print;
        \\print = function(x) { globalThis.seen = "custom:" + x; };
        \\print(a + b);
        \\oldPrint(globalThis.seen);
        \\print = oldPrint;
    , "3\n2147483648\ncustom:3\n");
}

test "get_array_el2 dense indexed call keeps the receiver" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\var seen;
        \\function rec(x) { seen = this; return x + 1; }
        \\var a = [rec, rec];
        \\function idxcall(arr, i, x) { return arr[i](x); }
        \\assert.sameValue(idxcall(a, 0, 41), 42);
        \\assert.sameValue(seen, a);
        \\assert.sameValue(idxcall(a, 1, 1), 2);
        \\assert.sameValue(seen, a);
        \\assert.sameValue(a[0](8), 9);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "get_array_el dense direct arm preserves hits and indexed fallback" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function read(a, i) { return a[i]; }
        \\var a = [{ value: 7 }, 11];
        \\assert.sameValue(read(a, 0).value, 7);
        \\assert.sameValue(read(a, 1), 11);
        \\assert.sameValue(read(a, -1), undefined);
        \\Array.prototype[5] = 13;
        \\assert.sameValue(read(a, 5), 13);
        \\delete Array.prototype[5];
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "int32 add sub mul overflow stays a number on the generic binary" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function add1(a, b) { return a + b; }
        \\function sub1(a, b) { return a - b; }
        \\function mul1(a, b) { return a * b; }
        \\assert.sameValue(add1(2147483647, 1), 2147483648);
        \\assert.sameValue(add1(-2147483648, -1), -2147483649);
        \\assert.sameValue(sub1(-2147483648, 1), -2147483649);
        \\assert.sameValue(mul1(1 << 30, 4), 4294967296);
        \\assert.sameValue(1 / mul1(-1, 0), -Infinity);
        \\assert.sameValue(add1(1, 2), 3);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "Engine eval preserves collection read host output semantics" {
    try helpers.expectPrints(
        \\let map = new Map();
        \\map.set("a", 1);
        \\print(map.get("a"));
        \\print(map.has("a"));
        \\let key = {};
        \\let weak = new WeakMap();
        \\weak.set(key, 2);
        \\print(weak.get(key));
        \\print(weak.has(key));
        \\let set = new Set();
        \\set.add("s");
        \\print(set.has("s"));
        \\let weakSetKey = {};
        \\let weakSet = new WeakSet();
        \\weakSet.add(weakSetKey);
        \\print(weakSet.has(weakSetKey));
        \\let oldGet = Map.prototype.get;
        \\Map.prototype.get = function(k) { return "custom:" + k; };
        \\print(map.get("a"));
        \\Map.prototype.get = oldGet;
        \\map.get = function(k) { return "own:" + k; };
        \\print(map.get("a"));
        \\delete map.get;
    , "1\ntrue\n2\ntrue\ntrue\ntrue\ncustom:a\nown:a\n");
}

test "runtime teardown preserves closure capture metadata until objects are destroyed" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    // Keeping a captured closure on a builtin prototype while constructing a
    // lifetime-linked weak holder perturbs the intrusive GC-list order. Runtime
    // teardown must not use that incidental order to destroy the closure's FB
    // before the closure consumes FB.closure_var_count and frees its capture array.
    const result = try js.eval(
        \\function assert(value) { if (value !== true) throw 1; }
        \\var calls = 0;
        \\var originalSet = WeakMap.prototype.set;
        \\WeakMap.prototype.set = function(value) {
        \\    calls++;
        \\    return originalSet.call(this, value);
        \\};
        \\var map = new WeakMap([]);
        \\assert(map instanceof WeakMap);
    );
    try std.testing.expect(result.is(.undefined_value));
}
