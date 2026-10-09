//! Exec integration tests: interrupts_spread.
const std = @import("std");
const zjs = @import("zjs");
const engine = zjs;
const core = zjs.core;
const helpers = @import("../harness.zig");
const bytecode = zjs.bytecode;
const op = zjs.bytecode.opcode.op;
const property_ops = zjs.exec.property_ops;
const object_ops = zjs.exec.object_ops;
const frame_mod = zjs.exec.frame;
const inline_calls = zjs.exec.inline_calls;
const vm_call = zjs.exec.vm_opcodes;
const common = @import("common.zig");
const createTailOpcodeFixture = common.createTailOpcodeFixture;
const InterruptTestState = common.InterruptTestState;
const globalFunctionBytecode = common.globalFunctionBytecode;

test "dense parameter arrays spread retains CreateDataProperty constraints" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    var source = try js.evalWithOptions("[7]", .{ .filename = "<repl>" });
    var target_value = core.JSValue.undefinedValue();
    var roots = core.runtime.rootValues(.{ &source, &target_value });
    roots.activate(js.runtime);
    defer roots.deactivate(js.runtime);
    for (0..3) |mode| {
        const target = try core.Object.createArray(js.runtime, null);
        target_value = target.value();
        switch (mode) {
            0 => target.flags.extensible = false,
            1 => target.flags.length_writable = false,
            else => try target.defineOwnProperty(js.runtime, core.Atom.taggedInt(0), core.Descriptor.data(core.JSValue.int32(42), .{ .enumerable = true })),
        }
        const expected: anyerror = switch (mode) {
            0 => error.NotExtensible,
            1 => error.ReadOnly,
            else => error.IncompatibleDescriptor,
        };
        try std.testing.expectError(expected, engine.exec.call_runtime.appendSpreadValuesEnumerate(js.context, null, js.context.global.?, target, source, 0));
        try std.testing.expectEqual(@as(u32, if (mode == 2) 1 else 0), target.arrayLength());
        if (mode == 2) try std.testing.expectEqual(@as(?i32, 42), (try target.getProperty(core.Atom.taggedInt(0))).as(.int));
    }
}

test "dense parameter arrays spread reserves one backing cell for a known dense range" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    var source = try js.evalWithOptions("[1,2,3,4,5,6,7,8]", .{ .filename = "<repl>" });
    var target_value = core.JSValue.undefinedValue();
    var roots = core.runtime.rootValues(.{ &source, &target_value });
    roots.activate(js.runtime);
    defer roots.deactivate(js.runtime);
    const target = try core.Object.createArray(js.runtime, null);
    target_value = target.value();
    const before = js.runtime.gc.liveCountKind(.array_storage);
    try std.testing.expectEqual(@as(i32, 8), try engine.exec.call_runtime.appendSpreadValuesEnumerate(js.context, null, js.context.global.?, target, source, 0));
    try std.testing.expectEqual(before + 1, js.runtime.gc.liveCountKind(.array_storage));
    for (target.arrayElements(), 1..) |value, index| try std.testing.expectEqual(@as(?i32, @intCast(index)), value.as(.int));
}

test "dense parameter arrays spread reserve OOM preserves iterator progress and retries" {
    // A fresh engine: the reserve arm is taken only when the iterator's
    // `next` is the builtin %ArrayIteratorPrototype%.next, which earlier tests
    // may have replaced on the shared engine. The leak census runs every test
    // twice in one process, and its second run took the per-item path.
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var source = try js.evalWithOptions("Array(1024).fill(37).values()", .{ .filename = "<repl>" });
    var target_value = core.JSValue.undefinedValue();
    var roots = core.runtime.rootValues(.{ &source, &target_value });
    roots.activate(js.runtime);
    defer roots.deactivate(js.runtime);
    const target = try core.Object.createArray(js.runtime, null);
    target_value = target.value();
    js.runtime.suppressLimitCollectionForTest(true);
    js.runtime.setNativeBytesLimitForTest(js.runtime.allocation_diagnostics.allocated_bytes + 1024);
    {
        defer js.runtime.setNativeBytesLimitForTest(null);
        defer js.runtime.suppressLimitCollectionForTest(false);
        try std.testing.expectError(error.OutOfMemory, engine.exec.call_runtime.appendSpreadValuesEnumerate(js.context, null, js.context.global.?, target, source, 0));
    }
    try std.testing.expectEqual(@as(usize, 1), helpers.objectFromValue(source).iteratorIndexSlot().*);
    try std.testing.expectEqual(@as(u32, 0), target.arrayLength());
    try std.testing.expectEqual(@as(i32, 1023), try engine.exec.call_runtime.appendSpreadValuesEnumerate(js.context, null, js.context.global.?, target, source, 0));
    for (target.arrayElements()) |value| try std.testing.expectEqual(@as(?i32, 37), value.as(.int));
    try std.testing.expect(helpers.objectFromValue(source).iteratorTargetSlot().* == null);
}

test "dense parameter arrays spread observes iterator methods getters and abrupt completion" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    _ = try js.eval(
        \\let reads = 0, calls = 0;
        \\const it = { get next() {
        \\  reads++;
        \\  return function() {
        \\    assert.sameValue(this, it);
        \\    const value = ++calls;
        \\    return {get done() {$262.gc(); return value > 2;}, get value() {$262.gc(); return {value};}};
        \\  };
        \\}};
        \\const out = [...{[Symbol.iterator]() {return it;}}];
        \\assert.sameValue(reads, 1);
        \\assert.sameValue(calls, 3);
        \\assert.sameValue(out[0].value, 1);
        \\assert.sameValue(out[1].value, 2);
        \\function* gen() {yield 1;}
        \\const g = gen();
        \\g[Symbol.iterator] = function() {return [7,8][Symbol.iterator]();};
        \\assert.sameValue([...g].join(','), '7,8');
        \\const proto = Object.create(Array.prototype);
        \\Object.defineProperty(proto, '0', {get() {return 11;}});
        \\const holes = new Array(2); holes[1] = 13;
        \\Object.setPrototypeOf(holes, proto);
        \\assert.sameValue([...holes].join(','), '11,13');
        \\const nextProto = Object.getPrototypeOf([][Symbol.iterator]());
        \\const originalNext = nextProto.next;
        \\let patchedCalls = 0;
        \\nextProto.next = function() {patchedCalls++; return originalNext.call(this);};
        \\try {assert.sameValue([...[3,4]].join(','), '3,4');}
        \\finally {nextProto.next = originalNext;}
        \\assert.sameValue(patchedCalls, 3);
        \\let closes = 0;
        \\const boom = {};
        \\const bad = {[Symbol.iterator]() {return {next() {throw boom;}, return() {closes++; return {};}};}};
        \\try {[...bad]; throw new Error('missing exception');} catch (e) {assert.sameValue(e, boom);}
        \\assert.sameValue(closes, 0);
        \\const retainedSource = [1,2];
        \\const retainedIterator = retainedSource.values();
        \\assert.sameValue([...{[Symbol.iterator]() {return retainedIterator;}}].join(','), '1,2');
        \\retainedSource.push(3);
        \\assert.sameValue(retainedIterator.next().done, true);
        \\const other = [21,22,23].values();
        \\other.next();
        \\const rebound = [99];
        \\rebound[Symbol.iterator] = () => other;
        \\assert.sameValue([...rebound].join(','), '22,23');
        \\assert.sameValue(other.next().done, true);
        \\const badValue = {[Symbol.iterator]() {return {next() {return {done:false,get value(){throw boom;}};}};}};
        \\try {[...badValue]; throw new Error('missing value exception');} catch (e) {assert.sameValue(e, boom);}
        \\let inheritedSets = 0;
        \\Object.defineProperty(Array.prototype, '0', {set(v) {inheritedSets++;}, configurable:true});
        \\try {
        \\  assert.sameValue([...[17]][0], 17);
        \\  assert.sameValue([...{*[Symbol.iterator]() {yield 19;}}][0], 19);
        \\  assert.sameValue(inheritedSets, 0);
        \\} finally {delete Array.prototype[0];}
    );
}

const TailSetupOomArm = struct {
    calls: usize = 0,
    exhaust: bool = false,

    fn call(ptr: *anyopaque, invocation: core.host_function.ExternalCall) anyerror!core.JSValue {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        if (self.exhaust) {
            const rt = invocation.realm.runtime;
            // Injecting an allocation failure, not testing the collector: see
            // `suppressLimitCollectionForTest`.
            // No `defer` to undo it: this arm runs inside the call whose
            // allocation must fail, so restoring on the way out of the arm
            // would re-arm the collector before the failure happens -- and
            // would clobber the enclosing test's own suppression. The flag is
            // per-Runtime, so it dies with the fixture.
            rt.suppressLimitCollectionForTest(true);
            rt.setNativeBytesLimitForTest(rt.allocation_diagnostics.allocated_bytes);
        }
        return core.JSValue.undefinedValue();
    }
};

const InterruptOomArm = struct {
    calls: usize = 0,
    exhaust: bool = false,

    fn call(ptr: *anyopaque, invocation: core.host_function.ExternalCall) anyerror!core.JSValue {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        if (self.exhaust) {
            invocation.realm.interrupt_counter = 1;
            const rt = invocation.realm.runtime;
            // Injecting an allocation failure, not testing the collector: see
            // `suppressLimitCollectionForTest`.
            // No `defer` to undo it: this arm runs inside the call whose
            // allocation must fail, so restoring on the way out of the arm
            // would re-arm the collector before the failure happens -- and
            // would clobber the enclosing test's own suppression. The flag is
            // per-Runtime, so it dies with the fixture.
            rt.suppressLimitCollectionForTest(true);
            rt.setNativeBytesLimitForTest(rt.allocation_diagnostics.allocated_bytes);
        }
        return core.JSValue.undefinedValue();
    }
};

const NativeFenceProbe = struct {
    cleanup_ran: bool = false,
    invoke_calls: usize = 0,

    fn invoke(ptr: *anyopaque, invocation: core.host_function.ExternalCall) anyerror!core.JSValue {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.invoke_calls += 1;
        self.cleanup_ran = false;
        defer self.cleanup_ran = true;
        if (invocation.args.len == 0) return error.TypeError;
        const global = invocation.realm.global orelse return error.InvalidBuiltinRegistry;
        return engine.exec.call_runtime.callValueOrBytecodeSyncInternal(
            invocation.realm,
            invocation.output,
            global,
            core.JSValue.undefinedValue(),
            invocation.args[0],
            invocation.args[1..],
            null,
            null,
        );
    }

    fn cleanupObserved(ptr: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return core.JSValue.boolean(self.cleanup_ran);
    }
};

test "eval lazily materializes a bare core context global before root closure construction" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    try std.testing.expect(ctx.global == null);

    var wrapper = zjs.borrowContext(ctx);
    const result = try wrapper.eval("'lazy-global-ok'", .{});
    try helpers.expectStringValueBytes(result, "lazy-global-ok");
    try std.testing.expect(ctx.global != null);
}

test "object_slots2 literal allocation preserves data and accessor semantics" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\var stored = 0;
        \\var pair = { a: 3, b: 4 };
        \\var accessor = {
        \\  get x() { return stored; },
        \\  set x(value) { stored = value; }
        \\};
        \\accessor.x = pair.a + pair.b;
        \\pair.c = 5;
        \\if (accessor.x + pair.c !== 12) throw new Error("object_slots2");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "fused cmp_if_false8 interrupt poll stays uncatchable in a for loop" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\globalThis.__fuse_n = 0;
        \\globalThis.__fuse_spin = function () {
        \\    for (var i = 0; i < 1000000000; i++) {
        \\        __fuse_n = i;
        \\    }
        \\    return 1;
        \\};
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const spin_key = try js.runtime.internAtom("__fuse_spin");
    const n_key = try js.runtime.internAtom("__fuse_n");
    _ = n_key;
    const spin = try global.getProperty(spin_key);

    var state = InterruptTestState{ .stop = true };
    js.runtime.setInterruptHandler(InterruptTestState.run, &state);
    defer js.runtime.setInterruptHandler(null, null);
    js.context.interrupt_counter = 8;

    try std.testing.expectError(
        error.Interrupted,
        engine.exec.call_runtime.callValueOrBytecodeRoot(
            js.context,
            null,
            global,
            core.JSValue.undefinedValue(),
            spin,
            &.{},
            null,
            null,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), state.hits);
    try std.testing.expect(js.context.exceptionIsUncatchable());
    _ = js.context.takeException();
    try std.testing.expect(!js.context.exceptionIsUncatchable());
}

test "interrupt budget survives Machine replacement and bypasses catch markers" {
    // Exact interrupt-poll arithmetic; `ZJS_GC_STRESS` overrides the cadence.
    if (core.gc.forensics.stressing()) return error.SkipZigTest;
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    // Machine A takes the fresh-context poll, then is destroyed.
    _ = try js.eval("globalThis.__w2_interrupt_state = 0;");

    // Leave two polls: Machine B entry consumes one and its first conditional
    // branch consumes the second while the try marker is active.
    const priming_polls: usize = @intCast(core.JSContext.interrupt_counter_reset - 2);
    for (0..priming_polls) |_| {
        try std.testing.expect(!js.context.pollInterrupt());
    }

    var state = InterruptTestState{ .stop = true };
    js.runtime.setInterruptHandler(InterruptTestState.run, &state);
    defer js.runtime.setInterruptHandler(null, null);

    try std.testing.expectError(
        error.Interrupted,
        js.eval(
            \\try {
            \\    for (let i = 0; i < 1; i++) {}
            \\    globalThis.__w2_interrupt_state = 1;
            \\} catch (_) {
            \\    globalThis.__w2_interrupt_state = 2;
            \\} finally {
            \\    globalThis.__w2_interrupt_state = 3;
            \\}
        ),
    );

    try std.testing.expectEqual(@as(usize, 1), state.hits);
    try std.testing.expect(js.context.hasException());
    try std.testing.expect(js.context.exceptionIsUncatchable());

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const state_key = try js.runtime.internAtom("__w2_interrupt_state");
    const observed = try global.getProperty(state_key);
    try std.testing.expectEqual(@as(?i32, 0), observed.as(.int));

    var exception = try js.takeExceptionInfo();
    defer exception.deinit();
    const message = try exception.getMessage(std.testing.allocator);
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings("InternalError: interrupted", message);
    try std.testing.expect(!js.context.hasException());
    try std.testing.expect(!js.context.exceptionIsUncatchable());
}

test "interrupt remains uncatchable when error construction runs out of memory" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    defer js.runtime.setNativeBytesLimitForTest(null);

    var arm = InterruptOomArm{};
    try js.defineGlobalExternalHostFunction(
        "__w2ArmInterruptOom",
        0,
        &arm,
        InterruptOomArm.call,
        null,
    );
    _ = try js.eval(
        \\globalThis.__w2_interrupt_oom_caught = false;
        \\globalThis.__w2_interrupt_oom = function (spin) {
        \\    try {
        \\        __w2ArmInterruptOom();
        \\        while (spin) {}
        \\        return 42;
        \\    } catch (_) {
        \\        globalThis.__w2_interrupt_oom_caught = true;
        \\        return -1;
        \\    }
        \\};
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const function_key = try js.runtime.internAtom("__w2_interrupt_oom");
    const caught_key = try js.runtime.internAtom("__w2_interrupt_oom_caught");
    const function = try global.getProperty(function_key);
    const preallocated = js.context.preallocated_oom_error orelse return error.TestUnexpectedResult;

    const baseline_call_depth = js.runtime.stack.call_depth;
    const baseline_native_depth = js.runtime.stack.native_call_depth;
    const baseline_stack_bytes = js.runtime.stack.bytecode_bytes;
    const baseline_arena_mark = js.runtime.vm_stack.mark();

    var state = InterruptTestState{ .stop = true };
    js.runtime.setInterruptHandler(InterruptTestState.run, &state);
    defer js.runtime.setInterruptHandler(null, null);
    js.context.interrupt_counter = 100;
    arm.exhaust = true;

    try std.testing.expectError(
        error.Interrupted,
        engine.exec.call_runtime.callValueOrBytecodeRoot(
            js.context,
            null,
            global,
            core.JSValue.undefinedValue(),
            function,
            &.{core.JSValue.boolean(true)},
            null,
            null,
        ),
    );
    js.runtime.setNativeBytesLimitForTest(null);
    arm.exhaust = false;

    try std.testing.expectEqual(@as(usize, 1), state.hits);
    try std.testing.expectEqual(@as(usize, 1), arm.calls);
    try std.testing.expect(js.context.exceptionIsUncatchable());
    const exception = js.context.takeException();
    try std.testing.expect(preallocated.sameValue(exception));

    const caught = try global.getProperty(caught_key);
    try std.testing.expectEqual(false, caught.as(.boolean).?);
    try std.testing.expectEqual(baseline_call_depth, js.runtime.stack.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.stack.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.stack.bytecode_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());

    js.runtime.setInterruptHandler(null, null);
    const recovered = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        function,
        &.{core.JSValue.boolean(false)},
        null,
        null,
    );
    try std.testing.expectEqual(@as(?i32, 42), recovered.as(.int));
    try std.testing.expectEqual(@as(usize, 2), arm.calls);
    try std.testing.expectEqual(baseline_call_depth, js.runtime.stack.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.stack.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.stack.bytecode_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
}

test "uncatchable interrupt skips outer inline for-of close and catch" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\globalThis.__w2_iterator_closed = false;
        \\globalThis.__w2_outer_caught = false;
        \\globalThis.__w2_spin = function () { while (true) {} };
        \\globalThis.__w2_iterable = {
        \\    [Symbol.iterator]() {
        \\        return {
        \\            next() { return { value: 1, done: false }; },
        \\            return() {
        \\                globalThis.__w2_iterator_closed = true;
        \\                return {};
        \\            }
        \\        };
        \\    }
        \\};
        \\globalThis.__w2_interrupt_outer = function () {
        \\    try {
        \\        for (const value of __w2_iterable) {
        \\            __w2_spin(value);
        \\        }
        \\    } catch (error) {
        \\        globalThis.__w2_outer_caught = true;
        \\    }
        \\};
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const outer_key = try js.runtime.internAtom("__w2_interrupt_outer");
    const closed_key = try js.runtime.internAtom("__w2_iterator_closed");
    const caught_key = try js.runtime.internAtom("__w2_outer_caught");
    const outer = try global.getProperty(outer_key);

    var state = InterruptTestState{ .stop = true };
    js.runtime.setInterruptHandler(InterruptTestState.run, &state);
    defer js.runtime.setInterruptHandler(null, null);
    js.context.interrupt_counter = 100;

    try std.testing.expectError(
        error.Interrupted,
        engine.exec.call_runtime.callValueOrBytecodeRoot(
            js.context,
            null,
            global,
            core.JSValue.undefinedValue(),
            outer,
            &.{},
            null,
            null,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), state.hits);
    try std.testing.expect(js.context.exceptionIsUncatchable());

    const closed = try global.getProperty(closed_key);
    const caught = try global.getProperty(caught_key);
    try std.testing.expectEqual(false, closed.as(.boolean).?);
    try std.testing.expectEqual(false, caught.as(.boolean).?);

    _ = js.context.takeException();
    try std.testing.expect(!js.context.exceptionIsUncatchable());
}

test "synchronous native fence reuses one Machine and restores native cleanup order" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    try js.ensureTest262GlobalsInstalled();

    var probe = NativeFenceProbe{};
    try js.defineGlobalExternalHostFunction(
        "__nativeFenceInvoke",
        1,
        &probe,
        NativeFenceProbe.invoke,
        null,
    );
    try js.defineGlobalExternalHostFunction(
        "__nativeFenceCleanupObserved",
        0,
        &probe,
        NativeFenceProbe.cleanupObserved,
        null,
    );

    const baseline_call_depth = js.runtime.stack.call_depth;
    const baseline_native_depth = js.runtime.stack.native_call_depth;
    const baseline_stack_bytes = js.runtime.stack.bytecode_bytes;
    const baseline_arena_mark = js.runtime.vm_stack.mark();
    inline_calls.resetMachineTestMetrics();

    _ = try js.eval(
        \\var fenceOrder = [];
        \\function fenceHelper(value) {
        \\    if (value < 0) throw new Error("negative");
        \\    return value + 1;
        \\}
        \\function catchesInsideCallback() {
        \\    try {
        \\        fenceHelper(-1);
        \\    } catch (error) {
        \\        fenceOrder.push("inner:" + error.message);
        \\    }
        \\    return 7;
        \\}
        \\assert.sameValue(__nativeFenceInvoke(catchesInsideCallback), 7);
        \\
        \\function throwsThroughFence() {
        \\    fenceOrder.push("callback");
        \\    throw new RangeError("through-fence");
        \\}
        \\try {
        \\    __nativeFenceInvoke(throwsThroughFence);
        \\} catch (error) {
        \\    fenceOrder.push("outer:" + __nativeFenceCleanupObserved());
        \\    assert.sameValue(error instanceof RangeError, true);
        \\    assert.sameValue(error.message, "through-fence");
        \\}
        \\
        \\function tailTarget(value) {
        \\    return value + 1;
        \\}
        \\function tailCallback(value) {
        \\    return tailTarget(value);
        \\}
        \\assert.sameValue(__nativeFenceInvoke(tailCallback, 40), 41);
        \\
        \\function nestedTarget(value) {
        \\    return fenceHelper(value);
        \\}
        \\function reentrantCallback(value) {
        \\    return __nativeFenceInvoke(nestedTarget, value);
        \\}
        \\assert.sameValue(__nativeFenceInvoke(reentrantCallback, 40), 41);
        \\assert.sameValue(
        \\    fenceOrder.join(","),
        \\    "inner:negative,callback,outer:true"
        \\);
    );

    const metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 1), metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 5), metrics.same_machine_sync_calls);
    try std.testing.expectEqual(@as(usize, 1), metrics.entry_chunk_allocations);
    try std.testing.expect(metrics.max_depth >= 2);
    try std.testing.expectEqual(@as(usize, 5), probe.invoke_calls);
    try std.testing.expect(probe.cleanup_ran);
    try std.testing.expect(!js.runtime.execution.hasLiveRecords());
    try std.testing.expectEqual(baseline_call_depth, js.runtime.stack.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.stack.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.stack.bytecode_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
}

test "synchronous native reentry crosses Entry chunk boundaries exactly" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    try js.ensureTest262GlobalsInstalled();

    var probe = NativeFenceProbe{};
    try js.defineGlobalExternalHostFunction(
        "__nativeFenceInvoke",
        1,
        &probe,
        NativeFenceProbe.invoke,
        null,
    );

    _ = try js.eval(
        \\globalThis.__nativeFenceDepth = function nativeFenceDepth(depth) {
        \\    if (depth === 0) return 0;
        \\    return __nativeFenceInvoke(__nativeFenceDepth, depth - 1) + 1;
        \\};
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const function_key = try js.runtime.internAtom("__nativeFenceDepth");
    const function = try global.getProperty(function_key);
    const depths = [_]usize{ 15, 16, 17, 31, 32, 33 };

    for (depths) |depth| {
        const baseline_call_depth = js.runtime.stack.call_depth;
        const baseline_native_depth = js.runtime.stack.native_call_depth;
        const baseline_stack_bytes = js.runtime.stack.bytecode_bytes;
        const baseline_arena_mark = js.runtime.vm_stack.mark();
        inline_calls.resetMachineTestMetrics();

        const result = try engine.exec.call_runtime.callValueOrBytecodeRoot(
            js.context,
            null,
            global,
            core.JSValue.undefinedValue(),
            function,
            &.{core.JSValue.int32(@intCast(depth))},
            null,
            null,
        );
        try std.testing.expectEqual(@as(?i32, @intCast(depth)), result.as(.int));

        const metrics = inline_calls.machineTestMetrics();
        try std.testing.expectEqual(@as(usize, 1), metrics.machine_inits);
        try std.testing.expectEqual(depth, metrics.same_machine_sync_calls);
        try std.testing.expectEqual(depth, metrics.max_depth);
        try std.testing.expectEqual(
            std.math.divCeil(usize, depth, 16) catch unreachable,
            metrics.entry_chunk_allocations,
        );
        try std.testing.expect(js.runtime.execution.active_invocation == null);
        try std.testing.expectEqual(baseline_call_depth, js.runtime.stack.call_depth);
        try std.testing.expectEqual(baseline_native_depth, js.runtime.stack.native_call_depth);
        try std.testing.expectEqual(baseline_stack_bytes, js.runtime.stack.bytecode_bytes);
        try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
    }
}

test "synchronous native fence restores every budget after interrupt" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    try js.ensureTest262GlobalsInstalled();

    var probe = NativeFenceProbe{};
    try js.defineGlobalExternalHostFunction(
        "__nativeFenceInvoke",
        1,
        &probe,
        NativeFenceProbe.invoke,
        null,
    );
    _ = try js.eval(
        \\globalThis.__nativeFenceInterruptCaught = false;
        \\function nativeFenceInterruptCallback(spin) {
        \\    while (spin) {}
        \\}
        \\globalThis.__nativeFenceInterruptOuter = function () {
        \\    try {
        \\        return __nativeFenceInvoke(nativeFenceInterruptCallback, true);
        \\    } catch (_) {
        \\        globalThis.__nativeFenceInterruptCaught = true;
        \\        return -1;
        \\    }
        \\};
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const outer_key = try js.runtime.internAtom("__nativeFenceInterruptOuter");
    const caught_key = try js.runtime.internAtom("__nativeFenceInterruptCaught");
    const outer = try global.getProperty(outer_key);

    const baseline_call_depth = js.runtime.stack.call_depth;
    const baseline_native_depth = js.runtime.stack.native_call_depth;
    const baseline_stack_bytes = js.runtime.stack.bytecode_bytes;
    const baseline_arena_mark = js.runtime.vm_stack.mark();
    var state = InterruptTestState{ .stop = true };
    js.runtime.setInterruptHandler(InterruptTestState.run, &state);
    defer js.runtime.setInterruptHandler(null, null);

    // Root call, native call, and sync-callback entry consume the first three
    // ticks. The callback loop consumes the fourth after its fence is live.
    js.context.interrupt_counter = 4;
    inline_calls.resetMachineTestMetrics();
    try std.testing.expectError(
        error.Interrupted,
        engine.exec.call_runtime.callValueOrBytecodeRoot(
            js.context,
            null,
            global,
            core.JSValue.undefinedValue(),
            outer,
            &.{},
            null,
            null,
        ),
    );

    const metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 1), state.hits);
    try std.testing.expectEqual(@as(usize, 1), probe.invoke_calls);
    try std.testing.expect(probe.cleanup_ran);
    try std.testing.expectEqual(@as(usize, 1), metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 1), metrics.same_machine_sync_calls);
    try std.testing.expect(js.context.exceptionIsUncatchable());
    const caught = try global.getProperty(caught_key);
    try std.testing.expectEqual(false, caught.as(.boolean).?);
    try std.testing.expect(!js.runtime.execution.hasLiveRecords());
    try std.testing.expectEqual(baseline_call_depth, js.runtime.stack.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.stack.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.stack.bytecode_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());

    _ = js.context.takeException();
    try std.testing.expect(!js.context.exceptionIsUncatchable());
}

test "Function and Reflect apply opt into the active Machine explicitly" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\function nativeApplyHelper(value) {
        \\    return value + 1;
        \\}
        \\function nativeApplyCallback(value) {
        \\    return nativeApplyHelper(value);
        \\}
        \\function nativeApplyRecursive(depth) {
        \\    if (depth === 0) return 10;
        \\    return nativeApplyRecursive.apply(null, [depth - 1]) + 1;
        \\}
        \\globalThis.__nativeApplyOuter = function () {
        \\    return nativeApplyCallback.apply(null, [1])
        \\        + Reflect.apply(nativeApplyCallback, null, [2])
        \\        + nativeApplyRecursive(3);
        \\};
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const outer_key = try js.runtime.internAtom("__nativeApplyOuter");
    const outer = try global.getProperty(outer_key);

    inline_calls.resetMachineTestMetrics();
    const result = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        outer,
        &.{},
        null,
        null,
    );
    try std.testing.expectEqual(@as(?i32, 18), result.as(.int));

    const metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 1), metrics.machine_inits);
    // Only Reflect.apply enters through the native sync-call seam;
    // Function.prototype.apply on a bytecode target with a dense list is an
    // in-window method push (native-boundary design §5.4), not a sync call.
    try std.testing.expectEqual(@as(usize, 1), metrics.same_machine_sync_calls);
    try std.testing.expectEqual(@as(usize, 1), metrics.entry_chunk_allocations);
    try std.testing.expect(!js.runtime.execution.hasLiveRecords());
}

test "synchronous apply fallbacks restore the outer active invocation" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\var nativeApplyOther = $262.createRealm().global;
        \\var nativeApplyForeign = nativeApplyOther.eval(
        \\    "(function nativeApplyForeign(value) { return value + 1; })"
        \\);
        \\function nativeApplyLocal(value) {
        \\    return value;
        \\}
        \\globalThis.__nativeApplyFallbackOuter = function () {
        \\    return nativeApplyForeign.apply(null, [20])
        \\        + nativeApplyLocal.apply(null, [21]);
        \\};
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const outer_key = try js.runtime.internAtom("__nativeApplyFallbackOuter");
    const outer = try global.getProperty(outer_key);

    inline_calls.resetMachineTestMetrics();
    const result = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        outer,
        &.{},
        null,
        null,
    );
    try std.testing.expectEqual(@as(?i32, 42), result.as(.int));

    const metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 2), metrics.machine_inits);
    // The same-Realm apply is a §5.4 window push, not a sync call; only the
    // foreign-Realm apply leaves the Machine (and starts the second one).
    try std.testing.expectEqual(@as(usize, 0), metrics.same_machine_sync_calls);
    try std.testing.expect(!js.runtime.execution.hasLiveRecords());
}

test "ordinary spread calls enter eligible bytecode targets on the current Machine" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    try js.ensureTest262GlobalsInstalled();

    _ = try js.eval(
        \\var spreadOther = $262.createRealm().global;
        \\var spreadForeign = spreadOther.eval(
        \\    "(function spreadForeign(value) { return value + 18; })"
        \\);
        \\function spreadPlain(value) {
        \\    return value + 1;
        \\}
        \\var spreadReceiver = {
        \\    base: 20,
        \\    add(value) {
        \\        return this.base + value;
        \\    }
        \\};
        \\function spreadTrace() {
        \\    return new Error("spread").stack;
        \\}
        \\globalThis.__spreadCallOuter = function () {
        \\    var trace = spreadTrace(...[]);
        \\    assert.sameValue(trace.indexOf("    at spreadTrace"), 0);
        \\    assert.sameValue(trace.indexOf("apply (native)"), -1);
        \\    return spreadPlain(...[1])
        \\        + spreadReceiver.add(...[1])
        \\        + spreadForeign(...[1]);
        \\};
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const outer_key = try js.runtime.internAtom("__spreadCallOuter");
    const outer = try global.getProperty(outer_key);

    inline_calls.resetMachineTestMetrics();
    const result = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        outer,
        &.{},
        null,
        null,
    );
    try std.testing.expectEqual(@as(?i32, 42), result.as(.int));

    const metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 2), metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 1), metrics.entry_chunk_allocations);
    try std.testing.expect(!js.runtime.execution.hasLiveRecords());
}

test "publish-time simple-ctor gate keeps prototype-miss and non-simple fallbacks" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    // Both S and NS run the true constructor body. Replacing S.prototype with
    // a non-object still falls back to Object.prototype (qjs js_create_from_ctor).
    // NS honors a replaced prototype object.
    _ = try js.eval(
        \\function S(a) { this.a = a; }
        \\const before = new S(1);
        \\const before_proto_hit = Object.getPrototypeOf(before) === S.prototype;
        \\S.prototype = 42;
        \\const after = new S(2);
        \\function NS(a) { this.a = a; a = a + 1; }
        \\NS.prototype = { marker: 7 };
        \\const ns = new NS(3);
        \\globalThis.__ctor_gate_result =
        \\    (before.a === 1 && before_proto_hit &&
        \\     after.a === 2 && Object.getPrototypeOf(after) === Object.prototype &&
        \\     ns.a === 3 && ns.marker === 7) ? 1 : 0;
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const result_key = try js.runtime.internAtom("__ctor_gate_result");
    const result = try global.getProperty(result_key);
    try std.testing.expectEqual(@as(?i32, 1), result.as(.int));
}

test "constructor allocation profile reserves capacity without skipping the body" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\function Vec(x, y, z) { this.x = x; this.y = y; this.z = z; }
        \\function Quad(a, b, c, d) { this.a = a; this.b = b; this.c = c; this.d = d; }
        \\function G() { this.initialize.apply(this, arguments); }
        \\G.prototype.initialize = function(a, b) { this.a = a; this.b = b; };
        \\function Mid(a) { this.a = a; throw new Error("boom"); }
        \\function Keys(a) {
        \\    this.seen = Object.keys(this).join(",");
        \\    this.a = a;
        \\    this.after = Object.keys(this).join(",");
        \\}
        \\function Override(a) { this.a = a; return { b: a }; }
        \\const v1 = new Vec(1, 2, 3);
        \\const v2 = new Vec(4, 5, 6);
        \\const q1 = new Quad(1, 2, 3, 4);
        \\const q2 = new Quad(5, 6, 7, 8);
        \\const g1 = new G(7, 8);
        \\const g2 = new G(9, 10);
        \\let mid_ok = false;
        \\try { new Mid(1); } catch (e) { mid_ok = e.message === "boom"; }
        \\const k = new Keys(1);
        \\const o = new Override(3);
        \\class Base { constructor() { this.tag = 1; } }
        \\class Derived extends Base { constructor() { super(); this.extra = 2; } }
        \\const d = new Derived();
        \\globalThis.__alloc_profile =
        \\    (v1.x === 1 && v2.z === 6 && q1.a === 1 && q2.d === 8 &&
        \\     g1.a === 7 && g2.b === 10 &&
        \\     mid_ok &&
        \\     k.seen === "" && k.after === "seen,a" &&
        \\     o.b === 3 && o.a === undefined &&
        \\     d.tag === 1 && d.extra === 2) ? 1 : 0;
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const result_key = try js.runtime.internAtom("__alloc_profile");
    const result = try global.getProperty(result_key);
    try std.testing.expectEqual(@as(?i32, 1), result.as(.int));
}

test "constructor return fusion and abrupt teardown each release the fallback exactly once" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    // The fused normal-return pop moves the fallback instance out by plain
    // read and applies qjs's two-branch (keep instance over a primitive
    // result / replace it with an object result / forward a derived result);
    // an abrupt body must instead release the fallback exactly once through
    // Entry.deinit's flag-guarded route. Refcount imbalance on any of the
    // four paths aborts the runtime teardown in this Debug build.
    _ = try js.eval(
        \\function Keep(v) { this.v = v; return 42; }
        \\function Override(v) { this.v = v; return { v: v + 1 }; }
        \\function Abrupt(v) { this.v = v; throw new Error("boom"); }
        \\class DerivedBase { constructor() { this.tag = 1; } }
        \\class Derived extends DerivedBase { constructor() { super(); } }
        \\let total = 0;
        \\for (let i = 0; i < 3; i++) {
        \\    total += new Keep(i).v;
        \\    total += new Override(i).v;
        \\    try {
        \\        new Abrupt(i);
        \\        total += 100;
        \\    } catch (e) {
        \\        total += (e.message === "boom") ? 1 : 50;
        \\    }
        \\    total += new Derived().tag;
        \\}
        \\globalThis.__ctor_fusion_total = total;
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const total_key = try js.runtime.internAtom("__ctor_fusion_total");
    const total = try global.getProperty(total_key);
    // Keep: 0+1+2 = 3, Override: 1+2+3 = 6, Abrupt catch: 3, Derived: 3.
    try std.testing.expectEqual(@as(?i32, 15), total.as(.int));
}

test "constructor spread preserves new target on the current Machine" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    try js.ensureTest262GlobalsInstalled();

    _ = try js.eval(
        \\let spreadConstructorNewTarget;
        \\function SpreadOrdinary(value) {
        \\    this.value = value;
        \\    this.trace = new Error("ordinary spread constructor").stack;
        \\}
        \\class SpreadBase {
        \\    constructor(value) {
        \\        spreadConstructorNewTarget = new.target;
        \\        this.value = value;
        \\    }
        \\}
        \\class SpreadDerived extends SpreadBase {
        \\    constructor(...args) {
        \\        super(...args);
        \\        this.derived = true;
        \\    }
        \\}
        \\globalThis.__spreadBaseConstructor = SpreadBase;
        \\globalThis.__spreadDerivedConstructor = SpreadDerived;
        \\globalThis.__spreadOrdinaryConstructorOuter = function () {
        \\    const ordinary = new SpreadOrdinary(...[20]);
        \\    assert.sameValue(ordinary.trace.indexOf("apply (native)"), -1);
        \\    return ordinary.value;
        \\};
        \\globalThis.__spreadDerivedConstructorOuter = function () {
        \\    const derived = new SpreadDerived(...[21]);
        \\    assert.sameValue(spreadConstructorNewTarget, SpreadDerived);
        \\    assert.sameValue(derived.derived, true);
        \\    return derived.value;
        \\};
        \\
        \\var spreadConstructorOther = $262.createRealm().global;
        \\var spreadConstructorForeign = spreadConstructorOther.eval(
        \\    "(function SpreadConstructorForeign(value) {" +
        \\        "var adjusted = value + 1; this.value = adjusted - 1;" +
        \\    "})"
        \\);
        \\globalThis.__spreadConstructorForeignOuter = function () {
        \\    return new spreadConstructorForeign(...[42]).value;
        \\};
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const base_key = try js.runtime.internAtom("__spreadBaseConstructor");
    const base_constructor = try global.getProperty(base_key);
    const derived_key = try js.runtime.internAtom("__spreadDerivedConstructor");
    const derived_constructor = try global.getProperty(derived_key);
    try std.testing.expect(engine.exec.call_runtime.resolveSameMachineSpreadConstructor(
        global,
        derived_constructor,
        derived_constructor,
    ) != null);
    try std.testing.expect(engine.exec.call_runtime.resolveSameMachineSpreadConstructor(
        global,
        base_constructor,
        derived_constructor,
    ) != null);

    const ordinary_outer_key = try js.runtime.internAtom("__spreadOrdinaryConstructorOuter");
    const ordinary_outer = try global.getProperty(ordinary_outer_key);

    inline_calls.resetMachineTestMetrics();
    const ordinary_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        ordinary_outer,
        &.{},
        null,
        null,
    );
    try std.testing.expectEqual(@as(?i32, 20), ordinary_result.as(.int));
    try std.testing.expectEqual(@as(usize, 1), inline_calls.machineTestMetrics().machine_inits);

    const derived_outer_key = try js.runtime.internAtom("__spreadDerivedConstructorOuter");
    const derived_outer = try global.getProperty(derived_outer_key);

    inline_calls.resetMachineTestMetrics();
    const derived_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        derived_outer,
        &.{},
        null,
        null,
    );
    try std.testing.expectEqual(@as(?i32, 21), derived_result.as(.int));
    const derived_metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 1), derived_metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 1), derived_metrics.entry_chunk_allocations);
    try std.testing.expect(!js.runtime.execution.hasLiveRecords());

    const foreign_outer_key = try js.runtime.internAtom("__spreadConstructorForeignOuter");
    const foreign_outer = try global.getProperty(foreign_outer_key);

    inline_calls.resetMachineTestMetrics();
    const foreign_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        foreign_outer,
        &.{},
        null,
        null,
    );
    try std.testing.expectEqual(@as(?i32, 42), foreign_result.as(.int));
    try std.testing.expectEqual(@as(usize, 2), inline_calls.machineTestMetrics().machine_inits);
}

test "Array and TypedArray synchronous callback cohort stays on one Machine" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    try js.ensureTest262GlobalsInstalled();

    _ = try js.eval(
        \\function arrayCohortHelper(value) {
        \\    return value + 1;
        \\}
        \\function arrayCohortCallback(value) {
        \\    if (value === 2) {
        \\        try {
        \\            throw new Error("local");
        \\        } catch (error) {
        \\            assert.sameValue(error.message, "local");
        \\        }
        \\    }
        \\    return arrayCohortHelper(value);
        \\}
        \\var arrayCohortSeen = 0;
        \\var arrayCohortTraceValue;
        \\var arrayCohortOrder = [];
        \\globalThis.__arrayCallbackCohortOuter = function __arrayCallbackCohortOuter() {
        \\    assert.sameValue([1, 2, 3].map(arrayCohortCallback).join(","), "2,3,4");
        \\    assert.sameValue([1].map(function (value, index, array, missing) {
        \\        assert.sameValue(index, 0);
        \\        assert.sameValue(array.length, 1);
        \\        assert.sameValue(missing, undefined);
        \\        return value;
        \\    })[0], 1);
        \\    assert.sameValue([7].map(function (value) {
        \\        assert.sameValue(arguments.length, 3);
        \\        assert.sameValue(arguments[0], 7);
        \\        assert.sameValue(arguments[1], 0);
        \\        assert.sameValue(arguments[2][0], 7);
        \\        return value;
        \\    })[0], 7);
        \\    arrayCohortSeen = 0;
        \\    [1, 2, 3].forEach(function (value) { arrayCohortSeen += arrayCohortCallback(value); });
        \\    assert.sameValue(arrayCohortSeen, 9);
        \\    assert.sameValue([1, 2, 3].filter(function (value) { return value > 1; }).join(","), "2,3");
        \\    assert.sameValue([1, 2, 3].every(function (value) { return value < 4; }), true);
        \\    assert.sameValue([1, 2, 3].some(function (value) { return value === 2; }), true);
        \\    assert.sameValue([1, 2, 3].find(function (value) { return value === 2; }), 2);
        \\    assert.sameValue([1, 2, 3].findIndex(function (value) { return value === 2; }), 1);
        \\    assert.sameValue([1, 2, 3].reduce(function (sum, value) { return sum + value; }, 0), 6);
        \\    assert.sameValue([1, 2, 3].reduceRight(function (sum, value) { return sum + value; }, 0), 6);
        \\    assert.sameValue([1, 2].flatMap(function (value) { return [value, value + 1]; }).join(","), "1,2,2,3");
        \\    assert.sameValue([3, 1, 2].sort(function (left, right) { return left - right; }).join(","), "1,2,3");
        \\    assert.sameValue(Array.from([1, 2], arrayCohortCallback).join(","), "2,3");
        \\
        \\    assert.sameValue(
        \\        new Uint8Array([1, 2]).map(arrayCohortCallback).join(","),
        \\        "2,3"
        \\    );
        \\    assert.sameValue(
        \\        new Uint8Array([1, 2, 3]).filter(function (value) { return value > 1; }).join(","),
        \\        "2,3"
        \\    );
        \\
        \\    var nested = [1].map(function (value) {
        \\        return [value].map(arrayCohortCallback)[0];
        \\    });
        \\    assert.sameValue(nested[0], 2);
        \\
        \\    arrayCohortTraceValue = undefined;
        \\    [1].map(function arrayCohortTrace(value) {
        \\        arrayCohortTraceValue = new Error("array cohort").stack;
        \\        return value;
        \\    });
        \\    var callbackIndex = arrayCohortTraceValue.indexOf("    at arrayCohortTrace");
        \\    var nativeIndex = arrayCohortTraceValue.indexOf("map (native)");
        \\    var outerIndex = arrayCohortTraceValue.indexOf("    at __arrayCallbackCohortOuter");
        \\    assert.sameValue(callbackIndex, 0);
        \\    assert.sameValue(nativeIndex > callbackIndex, true);
        \\    assert.sameValue(outerIndex > nativeIndex, true);
        \\
        \\    arrayCohortOrder = [];
        \\    try {
        \\        [1].map(function arrayCohortThrow() {
        \\            arrayCohortOrder.push("callback");
        \\            throw new RangeError("array cohort throw");
        \\        });
        \\    } catch (error) {
        \\        arrayCohortOrder.push("outer");
        \\        assert.sameValue(error instanceof RangeError, true);
        \\    }
        \\    assert.sameValue(arrayCohortOrder.join(","), "callback,outer");
        \\    return 42;
        \\};
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const outer_key = try js.runtime.internAtom("__arrayCallbackCohortOuter");
    const outer = try global.getProperty(outer_key);

    inline_calls.resetMachineTestMetrics();
    const result = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        outer,
        &.{},
        null,
        null,
    );
    try std.testing.expectEqual(@as(?i32, 42), result.as(.int));

    const metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 1), metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 42), metrics.same_machine_sync_calls);
    try std.testing.expectEqual(@as(usize, 1), metrics.entry_chunk_allocations);
    try std.testing.expect(!js.runtime.execution.hasLiveRecords());
}

test "Map and Set synchronous callback cohort stays on one Machine" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    try js.ensureTest262GlobalsInstalled();

    _ = try js.eval(
        \\function collectionCohortHelper(value) {
        \\    return value + 1;
        \\}
        \\function collectionCohortCallback(value) {
        \\    "use strict";
        \\    if (value === 2) {
        \\        try {
        \\            throw new Error("local");
        \\        } catch (error) {
        \\            assert.sameValue(error.message, "local");
        \\        }
        \\    }
        \\    return collectionCohortHelper(value);
        \\}
        \\var collectionCohortTraceValue;
        \\var collectionCohortOrder = [];
        \\globalThis.__collectionCallbackCohortOuter = function __collectionCallbackCohortOuter() {
        \\    var mapSum = 0;
        \\    var map = new Map([["one", 1], ["two", 2]]);
        \\    map.forEach(function (value, key, owner, missing) {
        \\        assert.sameValue(arguments.length, 3);
        \\        assert.sameValue(owner, map);
        \\        assert.sameValue(missing, undefined);
        \\        assert.sameValue(owner.get(key), value);
        \\        mapSum += collectionCohortCallback(value);
        \\    });
        \\    assert.sameValue(mapSum, 5);
        \\
        \\    var setSum = 0;
        \\    var set = new Set([1, 2]);
        \\    set.forEach(function (value, key, owner) {
        \\        assert.sameValue(arguments.length, 3);
        \\        assert.sameValue(value, key);
        \\        assert.sameValue(owner, set);
        \\        setSum += collectionCohortCallback(value);
        \\    });
        \\    assert.sameValue(setSum, 5);
        \\
        \\    var objectGroups = Object.groupBy([1, 2, 3], function (value, index) {
        \\        assert.sameValue(index, value - 1);
        \\        return collectionCohortHelper(value) % 2 ? "odd" : "even";
        \\    });
        \\    assert.sameValue(objectGroups.even.join(","), "1,3");
        \\    assert.sameValue(objectGroups.odd.join(","), "2");
        \\
        \\    var mapGroups = Map.groupBy([1, 2, 3], function (value, index) {
        \\        assert.sameValue(index, value - 1);
        \\        return collectionCohortHelper(value) % 2;
        \\    });
        \\    assert.sameValue(mapGroups.get(0).join(","), "1,3");
        \\    assert.sameValue(mapGroups.get(1).join(","), "2");
        \\
        \\    var inserted = new Map();
        \\    assert.sameValue(inserted.getOrInsertComputed("key", function (key) {
        \\        return key + ":" + collectionCohortHelper(6);
        \\    }), "key:7");
        \\    assert.sameValue(inserted.get("key"), "key:7");
        \\
        \\    var setLike = {
        \\        size: 2,
        \\        has: function (key) {
        \\            return collectionCohortHelper(key) > 0;
        \\        },
        \\        keys: function () {
        \\            collectionCohortHelper(0);
        \\            return [3, 4][Symbol.iterator]();
        \\        }
        \\    };
        \\    assert.sameValue(new Set([1, 2]).isSubsetOf(setLike), true);
        \\    assert.sameValue(
        \\        [...new Set([1, 2]).union(setLike)].join(","),
        \\        "1,2,3,4"
        \\    );
        \\
        \\    var nested = 0;
        \\    new Map([["outer", 1]]).forEach(function (value) {
        \\        new Map([["inner", value]]).forEach(function (inner) {
        \\            nested = collectionCohortHelper(inner);
        \\        });
        \\    });
        \\    assert.sameValue(nested, 2);
        \\
        \\    collectionCohortTraceValue = undefined;
        \\    new Map([["trace", 1]]).forEach(function collectionCohortTrace(value) {
        \\        collectionCohortTraceValue = new Error("collection cohort").stack;
        \\        return value;
        \\    });
        \\    var callbackIndex = collectionCohortTraceValue.indexOf("    at collectionCohortTrace");
        \\    var nativeIndex = collectionCohortTraceValue.indexOf("forEach (native)");
        \\    var outerIndex = collectionCohortTraceValue.indexOf("    at __collectionCallbackCohortOuter");
        \\    assert.sameValue(callbackIndex, 0);
        \\    assert.sameValue(nativeIndex > callbackIndex, true);
        \\    assert.sameValue(outerIndex > nativeIndex, true);
        \\
        \\    collectionCohortOrder = [];
        \\    try {
        \\        new Map([["throw", 1]]).forEach(function collectionCohortThrow() {
        \\            collectionCohortOrder.push("callback");
        \\            throw new RangeError("collection cohort throw");
        \\        });
        \\    } catch (error) {
        \\        collectionCohortOrder.push("outer");
        \\        assert.sameValue(error instanceof RangeError, true);
        \\    }
        \\    assert.sameValue(collectionCohortOrder.join(","), "callback,outer");
        \\    return 42;
        \\};
        \\var collectionInterruptMap = new Map([["interrupt", 1]]);
        \\function collectionInterruptHelper(value) {
        \\    return value + 1;
        \\}
        \\globalThis.__collectionCallbackInterrupt = function __collectionCallbackInterrupt() {
        \\    collectionInterruptMap.forEach(function collectionInterruptCallback(value) {
        \\        return collectionInterruptHelper(value);
        \\    });
        \\    return 42;
        \\};
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const outer_key = try js.runtime.internAtom("__collectionCallbackCohortOuter");
    const outer = try global.getProperty(outer_key);

    const baseline_call_depth = js.runtime.stack.call_depth;
    const baseline_native_depth = js.runtime.stack.native_call_depth;
    const baseline_stack_bytes = js.runtime.stack.bytecode_bytes;
    const baseline_arena_mark = js.runtime.vm_stack.mark();

    inline_calls.resetMachineTestMetrics();
    const result = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        outer,
        &.{},
        null,
        null,
    );
    try std.testing.expectEqual(@as(?i32, 42), result.as(.int));

    const metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 1), metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 18), metrics.same_machine_sync_calls);
    try std.testing.expectEqual(@as(usize, 1), metrics.entry_chunk_allocations);
    try std.testing.expectEqual(baseline_call_depth, js.runtime.stack.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.stack.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.stack.bytecode_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
    try std.testing.expect(!js.runtime.execution.hasLiveRecords());

    const interrupt_key = try js.runtime.internAtom("__collectionCallbackInterrupt");
    const interrupt_function = try global.getProperty(interrupt_key);
    var interrupt_state = InterruptTestState{ .stop = true };
    js.runtime.setInterruptHandler(InterruptTestState.run, &interrupt_state);
    js.context.interrupt_counter = 3; // NB2 D7: native calls no longer tick the interrupt counter (qjs parity)
    try std.testing.expectError(
        error.Interrupted,
        engine.exec.call_runtime.callValueOrBytecodeRoot(
            js.context,
            null,
            global,
            core.JSValue.undefinedValue(),
            interrupt_function,
            &.{},
            null,
            null,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), interrupt_state.hits);
    try std.testing.expectEqual(baseline_call_depth, js.runtime.stack.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.stack.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.stack.bytecode_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
    try std.testing.expect(!js.runtime.execution.hasLiveRecords());
    _ = js.context.takeException();

    js.runtime.setInterruptHandler(null, null);
    const recovered = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        interrupt_function,
        &.{},
        null,
        null,
    );
    try std.testing.expectEqual(@as(?i32, 42), recovered.as(.int));
}

test "accessors Proxy traps and primitive coercion stay on the active Machine" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    try js.ensureTest262GlobalsInstalled();

    _ = try js.eval(
        \\function propertyCohortHelper(value) {
        \\    return value + 1;
        \\}
        \\var propertyCohortStorage = 0;
        \\var propertyCohortTrace;
        \\var propertyCohortOrder = [];
        \\var propertyCohortAccessor = {};
        \\Object.defineProperty(propertyCohortAccessor, "value", {
        \\    get: function propertyCohortGetter() {
        \\        try {
        \\            throw new Error("local");
        \\        } catch (error) {
        \\            assert.sameValue(error.message, "local");
        \\        }
        \\        return propertyCohortHelper(propertyCohortStorage);
        \\    },
        \\    set: function propertyCohortSetter(value) {
        \\        propertyCohortStorage = propertyCohortHelper(value);
        \\    }
        \\});
        \\var propertyCohortInherited = Object.create({
        \\    get value() {
        \\        return propertyCohortHelper(6);
        \\    }
        \\});
        \\var propertyCohortDefaultPrimitive = {
        \\    [Symbol.toPrimitive]: function propertyDefaultPrimitive(hint) {
        \\        assert.sameValue(hint, "default");
        \\        return propertyCohortHelper(40);
        \\    }
        \\};
        \\var propertyCohortOrdinaryPrimitive = {
        \\    valueOf: function propertyValueOf() {
        \\        return propertyCohortHelper(8);
        \\    }
        \\};
        \\var propertyCohortKey = {
        \\    [Symbol.toPrimitive]: function propertyKeyPrimitive(hint) {
        \\        assert.sameValue(hint, "string");
        \\        return "cohort";
        \\    }
        \\};
        \\globalThis.__propertyCallbackCohortOuter = function __propertyCallbackCohortOuter() {
        \\    propertyCohortAccessor.value = 4;
        \\    assert.sameValue(propertyCohortAccessor.value, 6);
        \\    assert.sameValue(propertyCohortInherited.value, 7);
        \\    assert.sameValue(propertyCohortDefaultPrimitive + 1, 42);
        \\    assert.sameValue(+propertyCohortOrdinaryPrimitive, 9);
        \\    var keyed = {};
        \\    keyed[propertyCohortKey] = 10;
        \\    assert.sameValue(keyed.cohort, 10);
        \\
        \\    var getProxy = new Proxy({ value: 1 }, {
        \\        get: function propertyGetTrap(target, key, receiver) {
        \\            assert.sameValue(receiver, getProxy);
        \\            return propertyCohortHelper(target[key]);
        \\        }
        \\    });
        \\    assert.sameValue(getProxy.value, 2);
        \\
        \\    var setTarget = { value: 1 };
        \\    var setProxy = new Proxy(setTarget, {
        \\        set: function propertySetTrap(target, key, value, receiver) {
        \\            assert.sameValue(receiver, setProxy);
        \\            target[key] = value;
        \\            return true;
        \\        }
        \\    });
        \\    setProxy.value = 2;
        \\    assert.sameValue(setTarget.value, 2);
        \\
        \\    var hasProxy = new Proxy({ value: 1 }, {
        \\        has: function propertyHasTrap(target, key) {
        \\            return key in target;
        \\        }
        \\    });
        \\    assert.sameValue("value" in hasProxy, true);
        \\
        \\    var deleteTarget = { value: 1 };
        \\    var deleteProxy = new Proxy(deleteTarget, {
        \\        deleteProperty: function propertyDeleteTrap(target, key) {
        \\            return delete target[key];
        \\        }
        \\    });
        \\    assert.sameValue(delete deleteProxy.value, true);
        \\    assert.sameValue("value" in deleteTarget, false);
        \\
        \\    var proto = {};
        \\    var protoTarget = Object.create(proto);
        \\    var getPrototypeProxy = new Proxy(protoTarget, {
        \\        getPrototypeOf: function propertyGetPrototypeTrap(target) {
        \\            return Object.getPrototypeOf(target);
        \\        }
        \\    });
        \\    assert.sameValue(Object.getPrototypeOf(getPrototypeProxy), proto);
        \\
        \\    var newProto = {};
        \\    var setPrototypeTarget = {};
        \\    var setPrototypeProxy = new Proxy(setPrototypeTarget, {
        \\        setPrototypeOf: function propertySetPrototypeTrap(target, value) {
        \\            Object.setPrototypeOf(target, value);
        \\            return true;
        \\        }
        \\    });
        \\    Object.setPrototypeOf(setPrototypeProxy, newProto);
        \\    assert.sameValue(Object.getPrototypeOf(setPrototypeTarget), newProto);
        \\
        \\    var extensibleProxy = new Proxy({}, {
        \\        isExtensible: function propertyIsExtensibleTrap(target) {
        \\            return Object.isExtensible(target);
        \\        }
        \\    });
        \\    assert.sameValue(Object.isExtensible(extensibleProxy), true);
        \\
        \\    var preventTarget = {};
        \\    var preventProxy = new Proxy(preventTarget, {
        \\        preventExtensions: function propertyPreventExtensionsTrap(target) {
        \\            Object.preventExtensions(target);
        \\            return true;
        \\        }
        \\    });
        \\    Object.preventExtensions(preventProxy);
        \\    assert.sameValue(Object.isExtensible(preventTarget), false);
        \\
        \\    var ownKeysProxy = new Proxy({ value: 1 }, {
        \\        ownKeys: function propertyOwnKeysTrap(target) {
        \\            return Reflect.ownKeys(target);
        \\        }
        \\    });
        \\    assert.sameValue(Reflect.ownKeys(ownKeysProxy).join(","), "value");
        \\
        \\    var descriptorProxy = new Proxy({ value: 1 }, {
        \\        getOwnPropertyDescriptor: function propertyDescriptorTrap(target, key) {
        \\            return Object.getOwnPropertyDescriptor(target, key);
        \\        }
        \\    });
        \\    assert.sameValue(Object.getOwnPropertyDescriptor(descriptorProxy, "value").value, 1);
        \\
        \\    var defineTarget = {};
        \\    var defineProxy = new Proxy(defineTarget, {
        \\        defineProperty: function propertyDefineTrap(target, key, descriptor) {
        \\            Object.defineProperty(target, key, descriptor);
        \\            return true;
        \\        }
        \\    });
        \\    Object.defineProperty(defineProxy, "value", {
        \\        value: 2,
        \\        configurable: true
        \\    });
        \\    assert.sameValue(defineTarget.value, 2);
        \\
        \\    function propertyApplyTarget() {}
        \\    var applyProxy = new Proxy(propertyApplyTarget, {
        \\        apply: function propertyApplyTrap(target, receiver, args) {
        \\            assert.sameValue(target, propertyApplyTarget);
        \\            return propertyCohortHelper(args[0]);
        \\        }
        \\    });
        \\    assert.sameValue(applyProxy(2), 3);
        \\
        \\    function propertyConstructTarget() {}
        \\    var constructProxy = new Proxy(propertyConstructTarget, {
        \\        construct: function propertyConstructTrap(target, args, newTarget) {
        \\            assert.sameValue(target, propertyConstructTarget);
        \\            assert.sameValue(newTarget, constructProxy);
        \\            return { value: propertyCohortHelper(args[0]) };
        \\        }
        \\    });
        \\    assert.sameValue(new constructProxy(3).value, 4);
        \\
        \\    function propertyForwardTarget(value) {
        \\        return propertyCohortHelper(value);
        \\    }
        \\    assert.sameValue(new Proxy(propertyForwardTarget, {})(4), 5);
        \\
        \\    var nestedAccessor = {
        \\        get value() {
        \\            return new Proxy({ value: 5 }, {
        \\                get: function propertyNestedGetTrap(target, key) {
        \\                    return propertyCohortHelper(target[key]);
        \\                }
        \\            }).value;
        \\        }
        \\    };
        \\    assert.sameValue(nestedAccessor.value, 6);
        \\
        \\    propertyCohortTrace = undefined;
        \\    var traceProxy = new Proxy({ value: 1 }, {
        \\        ownKeys: function propertyTraceOwnKeysTrap(target) {
        \\            propertyCohortTrace = new Error("property cohort").stack;
        \\            return Reflect.ownKeys(target);
        \\        }
        \\    });
        \\    assert.sameValue(Object.keys(traceProxy).join(","), "value");
        \\    var callbackIndex = propertyCohortTrace.indexOf("    at propertyTraceOwnKeysTrap");
        \\    var nativeIndex = propertyCohortTrace.indexOf("keys (native)");
        \\    var outerIndex = propertyCohortTrace.indexOf("    at __propertyCallbackCohortOuter");
        \\    assert.sameValue(callbackIndex, 0);
        \\    assert.sameValue(nativeIndex > callbackIndex, true);
        \\    assert.sameValue(outerIndex > nativeIndex, true);
        \\
        \\    propertyCohortOrder = [];
        \\    try {
        \\        new Proxy({}, {
        \\            get: function propertyThrowingGetTrap() {
        \\                propertyCohortOrder.push("callback");
        \\                throw new RangeError("property cohort throw");
        \\            }
        \\        }).value;
        \\    } catch (error) {
        \\        propertyCohortOrder.push("outer");
        \\        assert.sameValue(error instanceof RangeError, true);
        \\    }
        \\    assert.sameValue(propertyCohortOrder.join(","), "callback,outer");
        \\    return 42;
        \\};
        \\
        \\var propertyOther = $262.createRealm().global;
        \\var propertyForeignObject = propertyOther.eval(
        \\    "Object.defineProperty({}, 'value', {" +
        \\    "get: function propertyForeignGetter() { return 20; }})"
        \\);
        \\var propertyLocalObject = Object.defineProperty({}, "value", {
        \\    get: function propertyLocalGetter() {
        \\        return 22;
        \\    }
        \\});
        \\globalThis.__propertyCallbackForeignOuter = function () {
        \\    return propertyForeignObject.value + propertyLocalObject.value;
        \\};
        \\var propertyInterruptObject = Object.defineProperty({}, "value", {
        \\    get: function propertyInterruptGetter() {
        \\        return propertyCohortHelper(41);
        \\    }
        \\});
        \\globalThis.__propertyCallbackInterrupt = function () {
        \\    return propertyInterruptObject.value;
        \\};
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const outer_key = try js.runtime.internAtom("__propertyCallbackCohortOuter");
    const outer = try global.getProperty(outer_key);

    const baseline_call_depth = js.runtime.stack.call_depth;
    const baseline_native_depth = js.runtime.stack.native_call_depth;
    const baseline_stack_bytes = js.runtime.stack.bytecode_bytes;
    const baseline_arena_mark = js.runtime.vm_stack.mark();

    inline_calls.resetMachineTestMetrics();
    const result = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        outer,
        &.{},
        null,
        null,
    );
    try std.testing.expectEqual(@as(?i32, 42), result.as(.int));

    const metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 1), metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 21), metrics.same_machine_sync_calls);
    try std.testing.expectEqual(@as(usize, 1), metrics.entry_chunk_allocations);
    try std.testing.expectEqual(baseline_call_depth, js.runtime.stack.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.stack.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.stack.bytecode_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
    try std.testing.expect(!js.runtime.execution.hasLiveRecords());

    const foreign_key = try js.runtime.internAtom("__propertyCallbackForeignOuter");
    const foreign = try global.getProperty(foreign_key);
    inline_calls.resetMachineTestMetrics();
    const foreign_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        foreign,
        &.{},
        null,
        null,
    );
    try std.testing.expectEqual(@as(?i32, 42), foreign_result.as(.int));
    const foreign_metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 2), foreign_metrics.machine_inits);
    // The local plain accessor is already emitted as a direct VM
    // InlineCallRequest; only the foreign accessor needs a fresh root.
    try std.testing.expectEqual(@as(usize, 0), foreign_metrics.same_machine_sync_calls);
    try std.testing.expect(!js.runtime.execution.hasLiveRecords());

    const interrupt_key = try js.runtime.internAtom("__propertyCallbackInterrupt");
    const interrupt_function = try global.getProperty(interrupt_key);
    var interrupt_state = InterruptTestState{ .stop = true };
    js.runtime.setInterruptHandler(InterruptTestState.run, &interrupt_state);
    js.context.interrupt_counter = 3;
    try std.testing.expectError(
        error.Interrupted,
        engine.exec.call_runtime.callValueOrBytecodeRoot(
            js.context,
            null,
            global,
            core.JSValue.undefinedValue(),
            interrupt_function,
            &.{},
            null,
            null,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), interrupt_state.hits);
    try std.testing.expectEqual(baseline_call_depth, js.runtime.stack.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.stack.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.stack.bytecode_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
    try std.testing.expect(!js.runtime.execution.hasLiveRecords());
    _ = js.context.takeException();

    js.runtime.setInterruptHandler(null, null);
    const recovered = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        interrupt_function,
        &.{},
        null,
        null,
    );
    try std.testing.expectEqual(@as(?i32, 42), recovered.as(.int));
}

test "JSON synchronous callback cohort stays on one Machine" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    try js.ensureTest262GlobalsInstalled();

    _ = try js.eval(
        \\function jsonCohortHelper(value) {
        \\    return value + 1;
        \\}
        \\var jsonCohortTrace;
        \\var jsonCohortOrder = [];
        \\globalThis.__jsonCallbackCohortOuter = function __jsonCallbackCohortOuter() {
        \\    var parsed = JSON.parse(
        \\        '{"a":1,"nested":{"b":2},"array":[3]}',
        \\        function jsonCohortReviver(key, value, context) {
        \\            assert.sameValue(arguments.length, 3);
        \\            assert.sameValue(typeof this, "object");
        \\            if (key === "b") {
        \\                try {
        \\                    throw new Error("local");
        \\                } catch (error) {
        \\                    assert.sameValue(error.message, "local");
        \\                }
        \\            }
        \\            if (typeof value === "number") {
        \\                assert.sameValue(context.source, String(value));
        \\                return jsonCohortHelper(value);
        \\            }
        \\            assert.sameValue(context.source, undefined);
        \\            return value;
        \\        }
        \\    );
        \\    assert.sameValue(parsed.a, 2);
        \\    assert.sameValue(parsed.nested.b, 3);
        \\    assert.sameValue(parsed.array[0], 4);
        \\
        \\    var serializable = {
        \\        first: 1,
        \\        nested: {
        \\            value: 2,
        \\            toJSON: function jsonCohortToJSON(key) {
        \\                assert.sameValue(arguments.length, 1);
        \\                assert.sameValue(key, "nested");
        \\                return { converted: jsonCohortHelper(this.value) };
        \\            }
        \\        }
        \\    };
        \\    var text = JSON.stringify(serializable, function jsonCohortReplacer(key, value) {
        \\        assert.sameValue(arguments.length, 2);
        \\        assert.sameValue(typeof this, "object");
        \\        return value;
        \\    });
        \\    assert.sameValue(text, '{"first":1,"nested":{"converted":3}}');
        \\
        \\    var nested = JSON.parse("1", function jsonOuterReviver(key, value) {
        \\        if (key === "") {
        \\            return JSON.parse("2", function jsonInnerReviver(innerKey, innerValue) {
        \\                return innerKey === "" ? jsonCohortHelper(innerValue) : innerValue;
        \\            });
        \\        }
        \\        return value;
        \\    });
        \\    assert.sameValue(nested, 3);
        \\
        \\    jsonCohortTrace = undefined;
        \\    JSON.parse("1", function jsonCohortTraceReviver(key, value) {
        \\        jsonCohortTrace = new Error("json cohort").stack;
        \\        return value;
        \\    });
        \\    var callbackIndex = jsonCohortTrace.indexOf("    at jsonCohortTraceReviver");
        \\    var nativeIndex = jsonCohortTrace.indexOf("parse (native)");
        \\    var outerIndex = jsonCohortTrace.indexOf("    at __jsonCallbackCohortOuter");
        \\    assert.sameValue(callbackIndex, 0);
        \\    assert.sameValue(nativeIndex > callbackIndex, true);
        \\    assert.sameValue(outerIndex > nativeIndex, true);
        \\
        \\    jsonCohortOrder = [];
        \\    try {
        \\        JSON.parse("1", function jsonCohortThrowingReviver() {
        \\            jsonCohortOrder.push("callback");
        \\            throw new RangeError("json cohort throw");
        \\        });
        \\    } catch (error) {
        \\        jsonCohortOrder.push("outer");
        \\        assert.sameValue(error instanceof RangeError, true);
        \\    }
        \\    assert.sameValue(jsonCohortOrder.join(","), "callback,outer");
        \\    return 42;
        \\};
        \\
        \\var jsonOther = $262.createRealm().global;
        \\var jsonForeignReviver = jsonOther.eval(
        \\    "(function jsonForeignReviver(key, value) { return value; })"
        \\);
        \\globalThis.__jsonCallbackForeignOuter = function () {
        \\    return JSON.parse("20", jsonForeignReviver);
        \\};
        \\globalThis.__jsonCallbackInterrupt = function () {
        \\    return JSON.parse("41", function jsonInterruptReviver(key, value) {
        \\        return jsonCohortHelper(value);
        \\    });
        \\};
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const outer_key = try js.runtime.internAtom("__jsonCallbackCohortOuter");
    const outer = try global.getProperty(outer_key);

    const baseline_call_depth = js.runtime.stack.call_depth;
    const baseline_native_depth = js.runtime.stack.native_call_depth;
    const baseline_stack_bytes = js.runtime.stack.bytecode_bytes;
    const baseline_arena_mark = js.runtime.vm_stack.mark();

    inline_calls.resetMachineTestMetrics();
    const result = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        outer,
        &.{},
        null,
        null,
    );
    try std.testing.expectEqual(@as(?i32, 42), result.as(.int));

    const metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 1), metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 15), metrics.same_machine_sync_calls);
    try std.testing.expectEqual(@as(usize, 1), metrics.entry_chunk_allocations);
    try std.testing.expectEqual(baseline_call_depth, js.runtime.stack.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.stack.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.stack.bytecode_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
    try std.testing.expect(!js.runtime.execution.hasLiveRecords());

    const foreign_key = try js.runtime.internAtom("__jsonCallbackForeignOuter");
    const foreign = try global.getProperty(foreign_key);
    inline_calls.resetMachineTestMetrics();
    const foreign_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        foreign,
        &.{},
        null,
        null,
    );
    try std.testing.expectEqual(@as(?i32, 20), foreign_result.as(.int));
    const foreign_metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 2), foreign_metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 0), foreign_metrics.same_machine_sync_calls);
    try std.testing.expect(!js.runtime.execution.hasLiveRecords());

    const interrupt_key = try js.runtime.internAtom("__jsonCallbackInterrupt");
    const interrupt_function = try global.getProperty(interrupt_key);
    var interrupt_state = InterruptTestState{ .stop = true };
    js.runtime.setInterruptHandler(InterruptTestState.run, &interrupt_state);
    js.context.interrupt_counter = 3; // NB2 D7: native calls no longer tick the interrupt counter (qjs parity)
    try std.testing.expectError(
        error.Interrupted,
        engine.exec.call_runtime.callValueOrBytecodeRoot(
            js.context,
            null,
            global,
            core.JSValue.undefinedValue(),
            interrupt_function,
            &.{},
            null,
            null,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), interrupt_state.hits);
    try std.testing.expectEqual(baseline_call_depth, js.runtime.stack.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.stack.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.stack.bytecode_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
    try std.testing.expect(!js.runtime.execution.hasLiveRecords());
    _ = js.context.takeException();

    js.runtime.setInterruptHandler(null, null);
    const recovered = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        interrupt_function,
        &.{},
        null,
        null,
    );
    try std.testing.expectEqual(@as(?i32, 42), recovered.as(.int));
}

test "string regexp iterator helpers and DisposableStack stay on one Machine" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    try js.ensureTest262GlobalsInstalled();

    _ = try js.eval(
        \\function cohortFiveHelper(value) {
        \\    return value + 1;
        \\}
        \\function cohortFiveIterator(values, closeOrder) {
        \\    var index = 0;
        \\    var iterator = values.values();
        \\    iterator.next = function cohortFiveIteratorNext() {
        \\        if (index >= values.length) return { value: undefined, done: true };
        \\        return { value: values[index++], done: false };
        \\    };
        \\    iterator.return = function cohortFiveIteratorReturn() {
        \\        if (closeOrder) closeOrder.push("close");
        \\        return { value: undefined, done: true };
        \\    };
        \\    return iterator;
        \\}
        \\var cohortFiveTrace;
        \\var cohortFiveOrder = [];
        \\globalThis.__cohortFiveOuter = function __cohortFiveOuter() {
        \\    var tailResult = "1".replace("1", function cohortFiveTailReplacer(value) {
        \\        cohortFiveTrace = new Error("cohort five").stack;
        \\        return cohortFiveHelper(Number(value));
        \\    });
        \\    assert.sameValue(tailResult, "2");
        \\    var callbackIndex = cohortFiveTrace.indexOf("    at cohortFiveTailReplacer");
        \\    var nativeIndex = cohortFiveTrace.indexOf("replace (native)");
        \\    var outerIndex = cohortFiveTrace.indexOf("    at __cohortFiveOuter");
        \\    assert.sameValue(callbackIndex, 0);
        \\    assert.sameValue(nativeIndex > callbackIndex, true);
        \\    assert.sameValue(outerIndex > nativeIndex, true);
        \\
        \\    assert.sameValue("aa".replaceAll("a", function cohortFiveReplaceAll() {
        \\        return "b";
        \\    }), "bb");
        \\    assert.sameValue("aa".replace(/a/g, function cohortFiveRegExpReplacer() {
        \\        return "c";
        \\    }), "cc");
        \\
        \\    var customReplace = {
        \\        [Symbol.replace]: function cohortFiveSymbolReplace(value, replacer) {
        \\            return replacer(value, 0, value);
        \\        }
        \\    };
        \\    assert.sameValue("x".replace(customReplace, function cohortFiveDelegatedReplacer() {
        \\        return "d";
        \\    }), "d");
        \\
        \\    var execCalls = 0;
        \\    var customRegExp = {
        \\        flags: "",
        \\        exec: function cohortFiveExec(value) {
        \\            execCalls++;
        \\            return { 0: value, index: 0, length: 1, groups: undefined };
        \\        }
        \\    };
        \\    assert.sameValue(
        \\        RegExp.prototype[Symbol.replace].call(
        \\            customRegExp,
        \\            "q",
        \\            function cohortFiveCustomExecReplacer(value) {
        \\                return cohortFiveHelper(value.charCodeAt(0)) === 114 ? "r" : "bad";
        \\            }
        \\        ),
        \\        "r"
        \\    );
        \\    assert.sameValue(execCalls, 1);
        \\
        \\    assert.sameValue("x".replace("x", function cohortFiveOuterReplace(value) {
        \\        return value.replace("x", function cohortFiveInnerReplace() {
        \\            return "y";
        \\        });
        \\    }), "y");
        \\
        \\    cohortFiveOrder = [];
        \\    try {
        \\        "x".replace("x", function cohortFiveThrowingReplace() {
        \\            cohortFiveOrder.push("callback");
        \\            throw new RangeError("replace");
        \\        });
        \\    } catch (error) {
        \\        cohortFiveOrder.push("outer");
        \\        assert.sameValue(error instanceof RangeError, true);
        \\    }
        \\    assert.sameValue(cohortFiveOrder.join(","), "callback,outer");
        \\
        \\    var mapped = cohortFiveIterator([1, 2], null).map(function cohortFiveMap(value) {
        \\        return cohortFiveHelper(value);
        \\    }).toArray();
        \\    assert.compareArray(mapped, [2, 3]);
        \\    var reduced = cohortFiveIterator([1, 2], null).reduce(function cohortFiveReduce(accumulator, value) {
        \\        return accumulator + value;
        \\    }, 0);
        \\    assert.sameValue(reduced, 3);
        \\
        \\    cohortFiveOrder = [];
        \\    try {
        \\        cohortFiveIterator([1], cohortFiveOrder).forEach(function cohortFiveThrowingIteratorCallback() {
        \\            cohortFiveOrder.push("callback");
        \\            throw new RangeError("iterator");
        \\        });
        \\    } catch (error) {
        \\        cohortFiveOrder.push("outer");
        \\        assert.sameValue(error instanceof RangeError, true);
        \\    }
        \\    assert.sameValue(cohortFiveOrder.join(","), "callback,close,outer");
        \\
        \\    cohortFiveOrder = [];
        \\    var stack = new DisposableStack();
        \\    stack.defer(function cohortFiveDeferredDispose() {
        \\        cohortFiveOrder.push("defer");
        \\    });
        \\    stack.adopt(2, function cohortFiveAdoptDispose(value) {
        \\        cohortFiveOrder.push("adopt:" + value);
        \\    });
        \\    stack.use({
        \\        [Symbol.dispose]: function cohortFiveUseDispose() {
        \\            cohortFiveOrder.push("use");
        \\        }
        \\    });
        \\    stack.dispose();
        \\    assert.sameValue(cohortFiveOrder.join(","), "use,adopt:2,defer");
        \\
        \\    cohortFiveOrder = [];
        \\    var throwingStack = new DisposableStack();
        \\    throwingStack.defer(function cohortFiveDisposeCleanup() {
        \\        cohortFiveOrder.push("cleanup");
        \\    });
        \\    throwingStack.defer(function cohortFiveThrowingDispose() {
        \\        cohortFiveOrder.push("callback");
        \\        throw new RangeError("dispose");
        \\    });
        \\    try {
        \\        throwingStack.dispose();
        \\    } catch (error) {
        \\        cohortFiveOrder.push("outer");
        \\        assert.sameValue(error instanceof RangeError, true);
        \\    }
        \\    assert.sameValue(cohortFiveOrder.join(","), "callback,cleanup,outer");
        \\    return 42;
        \\};
        \\
        \\var cohortFiveOther = $262.createRealm().global;
        \\var cohortFiveForeignReplacer = cohortFiveOther.eval(
        \\    "(function cohortFiveForeignReplacer() { return 'a'; })"
        \\);
        \\globalThis.__cohortFiveForeignOuter = function () {
        \\    return "x".replace("x", cohortFiveForeignReplacer)
        \\        + "y".replace("y", function cohortFiveLocalReplacer() { return "b"; });
        \\};
        \\globalThis.__cohortFiveInterrupt = function () {
        \\    return "41".replace("41", function cohortFiveInterruptReplacer(value) {
        \\        return cohortFiveHelper(Number(value));
        \\    });
        \\};
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const outer_key = try js.runtime.internAtom("__cohortFiveOuter");
    const outer = try global.getProperty(outer_key);

    const baseline_call_depth = js.runtime.stack.call_depth;
    const baseline_native_depth = js.runtime.stack.native_call_depth;
    const baseline_stack_bytes = js.runtime.stack.bytecode_bytes;
    const baseline_arena_mark = js.runtime.vm_stack.mark();

    inline_calls.resetMachineTestMetrics();
    const result = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        outer,
        &.{},
        null,
        null,
    );
    try std.testing.expectEqual(@as(?i32, 42), result.as(.int));

    const metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 1), metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 29), metrics.same_machine_sync_calls);
    try std.testing.expectEqual(@as(usize, 1), metrics.entry_chunk_allocations);
    try std.testing.expectEqual(baseline_call_depth, js.runtime.stack.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.stack.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.stack.bytecode_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
    try std.testing.expect(!js.runtime.execution.hasLiveRecords());

    const foreign_key = try js.runtime.internAtom("__cohortFiveForeignOuter");
    const foreign = try global.getProperty(foreign_key);
    inline_calls.resetMachineTestMetrics();
    const foreign_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        foreign,
        &.{},
        null,
        null,
    );
    try helpers.expectStringValueBytes(foreign_result, "ab");
    const foreign_metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 2), foreign_metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 1), foreign_metrics.same_machine_sync_calls);
    try std.testing.expect(!js.runtime.execution.hasLiveRecords());

    const interrupt_key = try js.runtime.internAtom("__cohortFiveInterrupt");
    const interrupt_function = try global.getProperty(interrupt_key);
    var interrupt_state = InterruptTestState{ .stop = true };
    js.runtime.setInterruptHandler(InterruptTestState.run, &interrupt_state);
    js.context.interrupt_counter = 4;
    try std.testing.expectError(
        error.Interrupted,
        engine.exec.call_runtime.callValueOrBytecodeRoot(
            js.context,
            null,
            global,
            core.JSValue.undefinedValue(),
            interrupt_function,
            &.{},
            null,
            null,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), interrupt_state.hits);
    try std.testing.expectEqual(baseline_call_depth, js.runtime.stack.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.stack.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.stack.bytecode_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
    try std.testing.expect(!js.runtime.execution.hasLiveRecords());
    _ = js.context.takeException();

    js.runtime.setInterruptHandler(null, null);
    const recovered = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        interrupt_function,
        &.{},
        null,
        null,
    );
    try helpers.expectStringValueBytes(recovered, "42");
}

test "Promise executor reuses the active Machine while reactions remain roots" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    try js.ensureTest262GlobalsInstalled();

    _ = try js.eval(
        \\function promiseExecutorHelper(value) {
        \\    return value + 1;
        \\}
        \\function promiseExecutorResolveHelper(resolve, value) {
        \\    return resolve(promiseExecutorHelper(value));
        \\}
        \\var promiseExecutorTrace;
        \\var promiseExecutorSubclassTrace;
        \\var promiseExecutorOrder = [];
        \\var promiseExecutorJobCount = 0;
        \\globalThis.__promiseExecutorReactionValue = 0;
        \\globalThis.__promiseExecutorJobOrder = "";
        \\function promiseExecutorRecordJob(label) {
        \\    promiseExecutorOrder.push(label);
        \\    promiseExecutorJobCount++;
        \\    if (promiseExecutorJobCount === 2) {
        \\        globalThis.__promiseExecutorJobOrder = promiseExecutorOrder.join(",");
        \\    }
        \\}
        \\function promiseExecutorPrimary(resolve) {
        \\    promiseExecutorTrace = new Error("promise executor").stack;
        \\    return promiseExecutorResolveHelper(resolve, 41);
        \\}
        \\class PromiseExecutorSubclass extends Promise {}
        \\globalThis.__promiseExecutorOuter = function __promiseExecutorOuter() {
        \\    var caught = false;
        \\    try {
        \\        var fulfilled = new Promise(promiseExecutorPrimary);
        \\        fulfilled.then(function promiseExecutorSuccessReaction(value) {
        \\            globalThis.__promiseExecutorReactionValue = value;
        \\            promiseExecutorRecordJob("success-job");
        \\        });
        \\
        \\        new Promise(function promiseExecutorReentrant(resolve) {
        \\            new Promise(function promiseExecutorNested(nestedResolve) {
        \\                nestedResolve(1);
        \\            });
        \\            resolve(2);
        \\        });
        \\
        \\        new Promise(function promiseExecutorThrowing() {
        \\            promiseExecutorOrder.push("throw");
        \\            throw new RangeError("executor");
        \\        }).catch(function promiseExecutorRejectReaction(error) {
        \\            assert.sameValue(error instanceof RangeError, true);
        \\            promiseExecutorRecordJob("reject-job");
        \\        });
        \\
        \\        new PromiseExecutorSubclass(function promiseExecutorSubclass(resolve) {
        \\            promiseExecutorSubclassTrace = new Error("subclass executor").stack;
        \\            resolve(3);
        \\        });
        \\
        \\        var prototypeOrder = [];
        \\        var customNewTarget = (function () {}).bind();
        \\        Object.defineProperty(customNewTarget, "prototype", {
        \\            get: function promisePrototypeGetter() {
        \\                prototypeOrder.push("prototype");
        \\                throw new RangeError("prototype");
        \\            }
        \\        });
        \\        try {
        \\            Reflect.construct(Promise, [function promiseExecutorMustNotRun() {
        \\                prototypeOrder.push("executor");
        \\            }], customNewTarget);
        \\        } catch (error) {
        \\            assert.sameValue(error instanceof RangeError, true);
        \\            var getterAt = error.stack.indexOf("    at promisePrototypeGetter");
        \\            var getterPromiseAt = error.stack.indexOf("Promise (native)", getterAt);
        \\            var getterOuterAt = error.stack.indexOf("    at __promiseExecutorOuter");
        \\            assert.sameValue(getterAt, 0);
        \\            assert.sameValue(getterPromiseAt > getterAt, true);
        \\            assert.sameValue(getterOuterAt > getterPromiseAt, true);
        \\            prototypeOrder.push("outer");
        \\        }
        \\        assert.sameValue(prototypeOrder.join(","), "prototype,outer");
        \\    } catch (error) {
        \\        caught = true;
        \\    }
        \\    promiseExecutorOrder.push("outer");
        \\    assert.sameValue(caught, false);
        \\    assert.sameValue(promiseExecutorOrder.join(","), "throw,outer");
        \\
        \\    var callbackIndex = promiseExecutorTrace.indexOf("    at promiseExecutorPrimary");
        \\    var nativeIndex = promiseExecutorTrace.indexOf("Promise (native)");
        \\    var outerIndex = promiseExecutorTrace.indexOf("    at __promiseExecutorOuter");
        \\    assert.sameValue(callbackIndex, 0);
        \\    assert.sameValue(nativeIndex > callbackIndex, true);
        \\    assert.sameValue(outerIndex > nativeIndex, true);
        \\
        \\    var subclassCallbackIndex = promiseExecutorSubclassTrace.indexOf(
        \\        "    at promiseExecutorSubclass"
        \\    );
        \\    var subclassNativeIndex = promiseExecutorSubclassTrace.indexOf("Promise (native)");
        \\    var subclassOuterIndex = promiseExecutorSubclassTrace.indexOf(
        \\        "    at __promiseExecutorOuter"
        \\    );
        \\    assert.sameValue(subclassCallbackIndex, 0);
        \\    assert.sameValue(subclassNativeIndex > subclassCallbackIndex, true);
        \\    assert.sameValue(subclassOuterIndex > subclassNativeIndex, true);
        \\    return 42;
        \\};
        \\
        \\var promiseExecutorOther = $262.createRealm().global;
        \\var promiseExecutorForeign = promiseExecutorOther.eval(
        \\    "(function promiseExecutorForeign(resolve) { resolve(20); })"
        \\);
        \\globalThis.__promiseExecutorForeignOuter = function () {
        \\    new Promise(promiseExecutorForeign);
        \\    new Promise(function promiseExecutorLocal(resolve) {
        \\        resolve(22);
        \\    });
        \\    return 42;
        \\};
        \\globalThis.__promiseExecutorInterrupt = function () {
        \\    globalThis.__promiseExecutorInterruptReason = "";
        \\    new Promise(function promiseExecutorInterruptCallback(resolve) {
        \\        resolve(promiseExecutorHelper(41));
        \\    }).catch(function promiseExecutorInterruptReaction(error) {
        \\        globalThis.__promiseExecutorInterruptReason =
        \\            error.name + ":" + error.message;
        \\    });
        \\    return 42;
        \\};
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const outer_key = try js.runtime.internAtom("__promiseExecutorOuter");
    const outer = try global.getProperty(outer_key);

    const baseline_call_depth = js.runtime.stack.call_depth;
    const baseline_native_depth = js.runtime.stack.native_call_depth;
    const baseline_stack_bytes = js.runtime.stack.bytecode_bytes;
    const baseline_arena_mark = js.runtime.vm_stack.mark();

    inline_calls.resetMachineTestMetrics();
    const result = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        outer,
        &.{},
        null,
        null,
    );
    try std.testing.expectEqual(@as(?i32, 42), result.as(.int));

    const executor_metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 1), executor_metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 6), executor_metrics.same_machine_sync_calls);
    try std.testing.expectEqual(@as(usize, 1), executor_metrics.entry_chunk_allocations);
    try std.testing.expectEqual(baseline_call_depth, js.runtime.stack.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.stack.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.stack.bytecode_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
    try std.testing.expect(!js.runtime.execution.hasLiveRecords());

    try js.runJobs();
    const reaction_metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 3), reaction_metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 6), reaction_metrics.same_machine_sync_calls);
    try std.testing.expect(!js.runtime.execution.hasLiveRecords());

    const reaction_value_key = try js.runtime.internAtom("__promiseExecutorReactionValue");
    const reaction_value = try global.getProperty(reaction_value_key);
    try std.testing.expectEqual(@as(?i32, 42), reaction_value.as(.int));
    const order_key = try js.runtime.internAtom("__promiseExecutorJobOrder");
    const order = try global.getProperty(order_key);
    try helpers.expectStringValueBytes(order, "throw,outer,success-job,reject-job");

    const foreign_key = try js.runtime.internAtom("__promiseExecutorForeignOuter");
    const foreign = try global.getProperty(foreign_key);
    inline_calls.resetMachineTestMetrics();
    const foreign_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        foreign,
        &.{},
        null,
        null,
    );
    try std.testing.expectEqual(@as(?i32, 42), foreign_result.as(.int));
    const foreign_metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 2), foreign_metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 1), foreign_metrics.same_machine_sync_calls);
    try std.testing.expect(!js.runtime.execution.hasLiveRecords());

    const interrupt_key = try js.runtime.internAtom("__promiseExecutorInterrupt");
    const interrupt_function = try global.getProperty(interrupt_key);
    var interrupt_state = InterruptTestState{ .stop = true };
    js.runtime.setInterruptHandler(InterruptTestState.run, &interrupt_state);
    js.context.interrupt_counter = 4;
    inline_calls.resetMachineTestMetrics();
    const interrupted_executor_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        interrupt_function,
        &.{},
        null,
        null,
    );
    try std.testing.expectEqual(@as(?i32, 42), interrupted_executor_result.as(.int));
    try std.testing.expectEqual(@as(usize, 1), interrupt_state.hits);
    try std.testing.expectEqual(baseline_call_depth, js.runtime.stack.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.stack.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.stack.bytecode_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
    try std.testing.expect(!js.runtime.execution.hasLiveRecords());
    try std.testing.expect(!js.context.hasException());

    js.runtime.setInterruptHandler(null, null);
    try js.runJobs();
    const interrupt_metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 2), interrupt_metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 1), interrupt_metrics.same_machine_sync_calls);
    const interrupt_reason_key = try js.runtime.internAtom("__promiseExecutorInterruptReason");
    const interrupt_reason = try global.getProperty(interrupt_reason_key);
    try helpers.expectStringValueBytes(interrupt_reason, "InternalError:interrupted");

    const recovered = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        interrupt_function,
        &.{},
        null,
        null,
    );
    try std.testing.expectEqual(@as(?i32, 42), recovered.as(.int));
}

test "nested calls and generator resumes share one Realm interrupt cadence" {
    // Exact interrupt-poll arithmetic; `ZJS_GC_STRESS` overrides the cadence.
    if (core.gc.forensics.stressing()) return error.SkipZigTest;
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\globalThis.__w2_inner = function () { return 7; };
        \\globalThis.__w2_outer = function () { return __w2_inner(); };
        \\globalThis.__w2_numeric_branch = function (value) {
        \\    if (value) return 11;
        \\    return 12;
        \\};
        \\globalThis.__w2_constructor = function (value) {
        \\    this.value = value;
        \\};
        \\globalThis.__w2_forwarded = function () { return 13; };
        \\globalThis.__w2_forward_wrapper = function () {
        \\    return __w2_forwarded.call();
        \\};
        \\globalThis.__w2_async = async function () { return 17; };
        \\globalThis.__w2_generator = (function* () { yield 1; yield 2; })();
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const outer_key = try js.runtime.internAtom("__w2_outer");
    const numeric_branch_key = try js.runtime.internAtom("__w2_numeric_branch");
    const constructor_key = try js.runtime.internAtom("__w2_constructor");
    const forward_wrapper_key = try js.runtime.internAtom("__w2_forward_wrapper");
    const async_key = try js.runtime.internAtom("__w2_async");
    const generator_key = try js.runtime.internAtom("__w2_generator");
    const next_key = try js.runtime.internAtom("next");

    const outer = try global.getProperty(outer_key);
    const numeric_branch = try global.getProperty(numeric_branch_key);
    const constructor = try global.getProperty(constructor_key);
    const forward_wrapper = try global.getProperty(forward_wrapper_key);
    const async_function = try global.getProperty(async_key);
    const generator = try global.getProperty(generator_key);
    const generator_object = try core.Object.expect(generator);
    const next = try generator_object.getProperty(next_key);

    var state = InterruptTestState{};
    js.runtime.setInterruptHandler(InterruptTestState.run, &state);
    defer js.runtime.setInterruptHandler(null, null);

    // The host-to-outer entry leaves one poll; the nested/tail call consumes it.
    js.context.interrupt_counter = 2;
    const nested_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        outer,
        &.{},
        null,
        null,
    );
    try std.testing.expectEqual(@as(?i32, 7), nested_result.as(.int));
    try std.testing.expectEqual(@as(usize, 1), state.hits);
    try std.testing.expectEqual(core.JSContext.interrupt_counter_reset, js.context.interrupt_counter);

    // A numeric condition takes the generic branch handler. It must not also
    // pay the boolean/plain-object hot-handler poll.
    js.context.interrupt_counter = 2;
    const branch_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        numeric_branch,
        &.{core.JSValue.int32(1)},
        null,
        null,
    );
    try std.testing.expectEqual(@as(?i32, 11), branch_result.as(.int));
    try std.testing.expectEqual(@as(usize, 2), state.hits);
    try std.testing.expectEqual(core.JSContext.interrupt_counter_reset, js.context.interrupt_counter);

    // Bytecode construction has one JS_CallConstructorInternal poll and one
    // JS_CallInternal poll, including the simple-field constructor fast path.
    js.context.interrupt_counter = 2;
    _ = try engine.exec.call_runtime.constructValueOrBytecode(
        js.context,
        null,
        global,
        constructor,
        &.{core.JSValue.int32(23)},
        null,
        null,
    );
    try std.testing.expectEqual(@as(usize, 3), state.hits);
    try std.testing.expectEqual(core.JSContext.interrupt_counter_reset, js.context.interrupt_counter);

    // Function.prototype.call on a bytecode target is a window rewrite
    // (native-boundary design §5.4): no native frame is entered, so only the
    // target's own bytecode entry consumes the budget (D7: native dispatch
    // does not tick). The wrapper entry and the forwarded entry leave one.
    js.context.interrupt_counter = 3;
    const forwarded_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        forward_wrapper,
        &.{},
        null,
        null,
    );
    try std.testing.expectEqual(@as(?i32, 13), forwarded_result.as(.int));
    try std.testing.expectEqual(@as(usize, 3), state.hits);
    try std.testing.expectEqual(@as(i32, 1), js.context.interrupt_counter);

    // Initial async invocation pays the outer JS_CallInternal entry, one
    // async_func_resume entry, and the resolving-function call used to settle
    // its Promise. async_func_init only prepares the resident frame; charging
    // it as a fourth entry would fire this counter.
    js.context.interrupt_counter = 4;
    _ = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        async_function,
        &.{},
        null,
        null,
    );
    try std.testing.expectEqual(@as(usize, 3), state.hits);
    try std.testing.expectEqual(@as(i32, 1), js.context.interrupt_counter);

    // Generator.next has one native call entry and one bytecode-resume entry.
    // The second next creates another Machine but continues the same counter.
    js.context.interrupt_counter = 3;
    _ = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        generator,
        next,
        &.{},
        null,
        null,
    );
    try std.testing.expectEqual(@as(usize, 3), state.hits);
    try std.testing.expectEqual(@as(i32, 1), js.context.interrupt_counter);

    _ = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        generator,
        next,
        &.{},
        null,
        null,
    );
    try std.testing.expectEqual(@as(usize, 4), state.hits);
    // The resumed body reaches its next yield through one additional jump poll.
    try std.testing.expectEqual(core.JSContext.interrupt_counter_reset - 2, js.context.interrupt_counter);
}

test "initial async resume rejects with the caller-Realm interrupt exception" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var parent_facade = zjs.borrowContext(js.context);
    const parent_global = try zjs.globalObjectPtr(&parent_facade);
    const child_holder = try engine.exec.call.createRealmObject(js.context);
    const child_record = try core.Object.expect(child_holder);
    const child = child_record.realmContext() orelse return error.TestUnexpectedResult;
    const child_global = try engine.exec.zjs_vm.contextGlobal(child);

    var child_facade = zjs.borrowContext(child);
    _ = try child_facade.eval(
        "globalThis.__w2_async_interrupt = async function () { return 17; };",
        .{},
    );

    const function_key = try js.runtime.internAtom("__w2_async_interrupt");
    const async_function = try child_global.getProperty(function_key);

    const baseline_call_depth = js.runtime.stack.call_depth;
    const baseline_native_depth = js.runtime.stack.native_call_depth;
    const baseline_stack_bytes = js.runtime.stack.bytecode_bytes;
    const baseline_arena_mark = js.runtime.vm_stack.mark();

    var state = InterruptTestState{ .stop = true };
    js.runtime.setInterruptHandler(InterruptTestState.run, &state);
    defer js.runtime.setInterruptHandler(null, null);
    js.context.interrupt_counter = 2;
    child.interrupt_counter = 100;

    const promise_value = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        parent_global,
        core.JSValue.undefinedValue(),
        async_function,
        &.{},
        null,
        null,
    );
    const promise = try core.Object.expect(promise_value);
    try std.testing.expect(promise.promiseIsRejected());
    const reason = promise.promiseResult() orelse return error.TestUnexpectedResult;
    const reason_object = try core.Object.expect(reason);

    const parent_internal_error = object_ops.constructorPrototypeFromGlobal(
        js.runtime,
        parent_global,
        "InternalError",
    ) orelse return error.TestUnexpectedResult;
    const child_internal_error = object_ops.constructorPrototypeFromGlobal(
        js.runtime,
        child_global,
        "InternalError",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(parent_internal_error, reason_object.getPrototype().?);
    try std.testing.expect(parent_internal_error != child_internal_error);

    const name = try reason_object.getProperty(core.atom.ids.name);
    try helpers.expectStringValueBytes(name, "InternalError");
    const message_key = try js.runtime.internAtom("message");
    const message = try reason_object.getProperty(message_key);
    try helpers.expectStringValueBytes(message, "interrupted");

    try std.testing.expectEqual(@as(usize, 1), state.hits);
    try std.testing.expect(!js.context.hasException());
    try std.testing.expect(!js.context.exceptionIsUncatchable());
    try std.testing.expectEqual(baseline_call_depth, js.runtime.stack.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.stack.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.stack.bytecode_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
}

test "cross-Realm interrupt polls charge caller entry and callee body separately" {
    // Exact interrupt-poll arithmetic; `ZJS_GC_STRESS` overrides the cadence.
    if (core.gc.forensics.stressing()) return error.SkipZigTest;
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var parent_facade = zjs.borrowContext(js.context);
    const parent_global = try zjs.globalObjectPtr(&parent_facade);
    const child_holder = try engine.exec.call.createRealmObject(js.context);
    const child_record = try core.Object.expect(child_holder);
    const child = child_record.realmContext() orelse return error.TestUnexpectedResult;
    const child_global = try engine.exec.zjs_vm.contextGlobal(child);

    var child_facade = zjs.borrowContext(child);
    _ = try child_facade.eval(
        \\globalThis.__w2_body_ran = false;
        \\globalThis.__w2_foreign = function () {
        \\    globalThis.__w2_body_ran = true;
        \\    while (true) {}
        \\};
        \\globalThis.__w2_stack_body_ran = false;
        \\globalThis.__w2_stack_foreign = function (a, b) {
        \\    globalThis.__w2_stack_body_ran = true;
        \\    return a + b;
        \\};
    , .{});

    const foreign_key = try js.runtime.internAtom("__w2_foreign");
    const body_key = try js.runtime.internAtom("__w2_body_ran");
    const stack_foreign_key = try js.runtime.internAtom("__w2_stack_foreign");
    const stack_body_key = try js.runtime.internAtom("__w2_stack_body_ran");
    const foreign = try child_global.getProperty(foreign_key);
    const stack_foreign = try child_global.getProperty(stack_foreign_key);

    var state = InterruptTestState{ .stop = true };
    js.runtime.setInterruptHandler(InterruptTestState.run, &state);
    defer js.runtime.setInterruptHandler(null, null);

    // Call-entry polling precedes the function-Realm switch.
    js.context.interrupt_counter = 1;
    child.interrupt_counter = 100;
    try std.testing.expectError(
        error.Interrupted,
        engine.exec.call_runtime.callValueOrBytecodeRoot(
            js.context,
            null,
            parent_global,
            core.JSValue.undefinedValue(),
            foreign,
            &.{},
            null,
            null,
        ),
    );
    try std.testing.expectEqual(core.JSContext.interrupt_counter_reset, js.context.interrupt_counter);
    try std.testing.expectEqual(@as(i32, 100), child.interrupt_counter);
    const before_body = try child_global.getProperty(body_key);
    try std.testing.expectEqual(false, before_body.as(.boolean).?);

    const caller_exception = js.context.takeException();
    const caller_error = try core.Object.expect(caller_exception);
    const caller_internal_error = object_ops.constructorPrototypeFromGlobal(js.runtime, parent_global, "InternalError") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(caller_internal_error, caller_error.getPrototype().?);

    // Once entered, the loop backedge polls the callee Realm and constructs its
    // InternalError from that Realm's intrinsic.
    js.context.interrupt_counter = 100;
    child.interrupt_counter = 1;
    try std.testing.expectError(
        error.Interrupted,
        engine.exec.call_runtime.callValueOrBytecodeRoot(
            js.context,
            null,
            parent_global,
            core.JSValue.undefinedValue(),
            foreign,
            &.{},
            null,
            null,
        ),
    );
    try std.testing.expectEqual(@as(i32, 99), js.context.interrupt_counter);
    try std.testing.expectEqual(core.JSContext.interrupt_counter_reset, child.interrupt_counter);
    const after_body = try child_global.getProperty(body_key);
    try std.testing.expectEqual(true, after_body.as(.boolean).?);

    const callee_exception = child.takeException();
    const callee_error = try core.Object.expect(callee_exception);
    const callee_internal_error = object_ops.constructorPrototypeFromGlobal(js.runtime, child_global, "InternalError") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(callee_internal_error, callee_error.getPrototype().?);

    // The planned-frame guard also runs before the Realm switch, so its
    // catchable InternalError belongs to the caller and the callee body never
    // starts.
    js.runtime.setInterruptHandler(null, null);
    js.runtime.setNativeStackSize(1);
    defer js.runtime.setNativeStackSize(0);
    try std.testing.expectError(
        error.StackOverflow,
        engine.exec.call_runtime.callValueOrBytecodeRoot(
            js.context,
            null,
            parent_global,
            core.JSValue.undefinedValue(),
            stack_foreign,
            &.{ core.JSValue.int32(20), core.JSValue.int32(22) },
            null,
            null,
        ),
    );
    const stack_body_before = try child_global.getProperty(stack_body_key);
    try std.testing.expectEqual(false, stack_body_before.as(.boolean).?);
    const stack_exception = js.context.takeException();
    const stack_error = try core.Object.expect(stack_exception);
    try std.testing.expectEqual(caller_internal_error, stack_error.getPrototype().?);

    // When both limits are ready to fire, the caller interrupt wins and stays
    // uncatchable, matching JS_CallInternal's poll-before-stack order.
    js.runtime.setInterruptHandler(InterruptTestState.run, &state);
    js.context.interrupt_counter = 1;
    child.interrupt_counter = 100;
    try std.testing.expectError(
        error.Interrupted,
        engine.exec.call_runtime.callValueOrBytecodeRoot(
            js.context,
            null,
            parent_global,
            core.JSValue.undefinedValue(),
            stack_foreign,
            &.{ core.JSValue.int32(20), core.JSValue.int32(22) },
            null,
            null,
        ),
    );
    const precedence_exception = js.context.takeException();
    const precedence_error = try core.Object.expect(precedence_exception);
    try std.testing.expectEqual(caller_internal_error, precedence_error.getPrototype().?);
    try std.testing.expectEqual(@as(usize, 3), state.hits);
}

test "tail-frame reuse charges planned stack bytes and fully restores both budgets" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    js.runtime.setNativeStackSize(128 * 1024);

    const baseline_call_depth = js.runtime.stack.call_depth;
    const baseline_native_depth = js.runtime.stack.native_call_depth;
    const baseline_tail_bytes = js.runtime.stack.bytecode_bytes;

    _ = try js.eval(
        \\globalThis.__w2SmallLinks = 0;
        \\globalThis.__w2LargeLinks = 0;
        \\function __w2Small(eval) {
        \\    __w2SmallLinks++;
        \\    return eval(eval);
        \\}
        \\function __w2Large(eval) {
        \\    __w2LargeLinks++;
        \\    let a00=0,a01=1,a02=2,a03=3,a04=4,a05=5,a06=6,a07=7;
        \\    let a08=8,a09=9,a10=10,a11=11,a12=12,a13=13,a14=14,a15=15;
        \\    let a16=16,a17=17,a18=18,a19=19,a20=20,a21=21,a22=22,a23=23;
        \\    let a24=24,a25=25,a26=26,a27=27,a28=28,a29=29,a30=30,a31=31;
        \\    let a32=32,a33=33,a34=34,a35=35,a36=36,a37=37,a38=38,a39=39;
        \\    let a40=40,a41=41,a42=42,a43=43,a44=44,a45=45,a46=46,a47=47;
        \\    let a48=48,a49=49,a50=50,a51=51,a52=52,a53=53,a54=54,a55=55;
        \\    let a56=56,a57=57,a58=58,a59=59,a60=60,a61=61,a62=62,a63=63;
        \\    if (a00 + a63 === -1) return "unreachable";
        \\    return eval(eval);
        \\}
        \\function __w2Down(eval, n) {
        \\    if (n === 0) return "done";
        \\    return eval(eval, n - 1);
        \\}
        \\function __w2CatchOwn(eval) {
        \\    try { return eval(eval); }
        \\    catch (e) { return e.name + ":" + e.message; }
        \\}
        \\globalThis.__w2OuterLinks = 0;
        \\function __w2Ordinary(inner) {
        \\    return 1 + inner(inner);
        \\}
        \\function __w2Outer(eval, n, inner) {
        \\    __w2OuterLinks++;
        \\    if (n === 0) return 1 + __w2Ordinary(inner);
        \\    return eval(eval, n - 1, inner);
        \\}
    );

    const small_fb = try globalFunctionBytecode(&js, "__w2Small");
    const large_fb = try globalFunctionBytecode(&js, "__w2Large");
    try std.testing.expect(large_fb.var_count > small_fb.var_count);
    try std.testing.expect(hasTailEvalReturn(small_fb));
    try std.testing.expect(hasTailEvalReturn(large_fb));

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\try { __w2Small(__w2Small); }
        \\catch (e) { print("small-1:" + e.name + ":" + e.message); }
        \\const firstSmallLinks = __w2SmallLinks;
        \\__w2SmallLinks = 0;
        \\try { __w2Small(__w2Small); }
        \\catch (e) { print("small-2:" + e.name + ":" + e.message); }
        \\const secondSmallLinks = __w2SmallLinks;
        \\try { __w2Large(__w2Large); }
        \\catch (e) { print("large:" + e.name + ":" + e.message); }
        \\assert.sameValue(firstSmallLinks > 0, true);
        \\assert.sameValue(secondSmallLinks > 0, true);
        \\assert.sameValue(__w2LargeLinks < secondSmallLinks, true);
        \\print("weighted:true");
        \\__w2SmallLinks = 0;
        \\const outerSteps = Math.max(1, (secondSmallLinks / 16) | 0);
        \\try { __w2Outer(__w2Outer, outerSteps, __w2Small); }
        \\catch (e) { print("nested:" + e.name + ":" + e.message); }
        \\assert.sameValue(__w2OuterLinks, outerSteps + 1);
        \\assert.sameValue(__w2SmallLinks > 0, true);
        \\assert.sameValue(__w2SmallLinks < secondSmallLinks, true);
        \\print("nested-weighted:true");
        \\print("own-catch:" + __w2CatchOwn(__w2CatchOwn));
        \\print("bounded:" + __w2Down(__w2Down, 100));
    , &stream);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings(
        "small-1:InternalError:stack overflow\n" ++
            "small-2:InternalError:stack overflow\n" ++
            "large:InternalError:stack overflow\n" ++
            "weighted:true\n" ++
            "nested:InternalError:stack overflow\n" ++
            "nested-weighted:true\n" ++
            "own-catch:InternalError:stack overflow\n" ++
            "bounded:done\n",
        stream.buffered(),
    );
    try std.testing.expectEqual(baseline_call_depth, js.runtime.stack.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.stack.native_call_depth);
    try std.testing.expectEqual(baseline_tail_bytes, js.runtime.stack.bytecode_bytes);
}

test "exact-simple method admission respects aggregate stack byte budget" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const rt = js.runtime;
    const budget = rt.stackSize();
    try std.testing.expect(vm_call.callBudgetWouldOverflow(
        rt,
        budget,
        0,
        0,
    ));
    try std.testing.expect(!vm_call.callBudgetWouldOverflow(
        rt,
        budget - 1,
        budget,
        0,
    ));

    _ = try js.eval(
        \\globalThis.__stackBudgetEntries = 0;
        \\globalThis.__stackBudgetReceiver = {
        \\  recurse(n) {
        \\    let a=0,b=1,c=2,d=3,e=4,f=5,g=6,h=7;
        \\    __stackBudgetEntries++;
        \\    if (n === 0) return a+b+c+d+e+f+g+h;
        \\    return this.recurse(n - 1) + 1;
        \\  }
        \\};
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const receiver_name = try rt.internAtom("__stackBudgetReceiver");
    const receiver = try global.getProperty(receiver_name);
    const receiver_object = try property_ops.expectObject(receiver);
    const method_name = try rt.internAtom("recurse");
    const method = try receiver_object.getProperty(method_name);
    const resolved = inline_calls.resolveInlineFunction(global, method) orelse
        return error.InvalidFunctionBytecode;
    try std.testing.expect(resolved.call_facts.execution.simple_inline_eligible);
    try std.testing.expect(!resolved.fb.simpleInlineEmptyLeaf());

    const planned_bytes = vm_call.bytecodeFrameAllocaSize(resolved.fb, 1, false);
    try std.testing.expect(planned_bytes > 1);
    const stack_budget = planned_bytes * 4 - 1;
    const old_stack_size = rt.stackSize();
    const old_native_stack_size = rt.nativeStackSize();
    defer {
        rt.setStackSize(old_stack_size);
        rt.setNativeStackSize(old_native_stack_size);
    }
    rt.setStackSize(stack_budget);
    rt.setNativeStackSize(0);

    // The host entry plus two recursive frames fit. Those recursive pushes
    // warm the Machine entry chunk and VM arena, so the next exact-simple
    // probe crosses the aggregate byte budget while logical depth is still
    // far below stack_budget. It must miss so the authoritative path can
    // raise StackOverflow.
    try std.testing.expectError(
        error.StackOverflow,
        engine.exec.call_runtime.callValueOrBytecodeRoot(
            js.context,
            null,
            global,
            receiver,
            method,
            &.{core.JSValue.int32(10)},
            null,
            null,
        ),
    );

    const entries_name = try rt.internAtom("__stackBudgetEntries");
    const entries = try global.getProperty(entries_name);
    try std.testing.expectEqual(@as(?i32, 3), entries.as(.int));
    try std.testing.expectEqual(@as(usize, 0), rt.stack.call_depth);
    try std.testing.expectEqual(@as(usize, 0), rt.stack.native_call_depth);
    try std.testing.expectEqual(@as(usize, 0), rt.stack.bytecode_bytes);
}

test "raw tail call opcodes share the bounded tail-chain stack contract" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    js.runtime.setNativeStackSize(128 * 1024);

    const plain_code = [_]u8{
        op.special_object,
        bytecode.opcode.special_object_subtype.current_function,
        op.call,
        0,
        0,
        op.@"return",
    };
    const method_code = [_]u8{
        op.push_this,
        op.special_object,
        bytecode.opcode.special_object_subtype.current_function,
        op.tail_call_method,
        0,
        0,
    };
    const plain = try createTailOpcodeFixture(&js, "__w2RawTail", &plain_code, 1);
    const method = try createTailOpcodeFixture(&js, "__w2RawMethodTail", &method_code, 2);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const plain_key = try js.runtime.internAtom("__w2RawTail");
    const method_key = try js.runtime.internAtom("__w2RawMethodTail");
    try global.defineOwnProperty(
        js.runtime,
        plain_key,
        core.Descriptor.data(plain, .all),
    );
    try global.defineOwnProperty(
        js.runtime,
        method_key,
        core.Descriptor.data(method, .all),
    );

    const baseline_call_depth = js.runtime.stack.call_depth;
    const baseline_native_depth = js.runtime.stack.native_call_depth;
    const baseline_tail_bytes = js.runtime.stack.bytecode_bytes;
    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function __w2InvokeRaw(fn) { return 1 + fn(); }
        \\function __w2ExpectRaw(label, fn) {
        \\    try { __w2InvokeRaw(fn); print(label + ":missing"); }
        \\    catch (e) { print(label + ":" + e.name + ":" + e.message); }
        \\}
        \\__w2ExpectRaw("plain", __w2RawTail);
        \\__w2ExpectRaw("method", __w2RawMethodTail);
        \\print("recovered:" + (20 + 22));
    , &stream);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings(
        "plain:InternalError:stack overflow\n" ++
            "method:InternalError:stack overflow\n" ++
            "recovered:42\n",
        stream.buffered(),
    );
    try std.testing.expectEqual(baseline_call_depth, js.runtime.stack.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.stack.native_call_depth);
    try std.testing.expectEqual(baseline_tail_bytes, js.runtime.stack.bytecode_bytes);
}

test "tail target setup OOM remains catchable in the retiring caller" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    defer js.runtime.setNativeBytesLimitForTest(null);
    // The subject is the unwind out of a faulting target setup, not whether a
    // collection could have avoided the fault: see
    // `suppressLimitCollectionForTest`.
    js.runtime.suppressLimitCollectionForTest(true);
    defer js.runtime.suppressLimitCollectionForTest(false);

    var arm = TailSetupOomArm{};
    try js.defineGlobalExternalHostFunction(
        "__w2ArmTailSetupOom",
        0,
        &arm,
        TailSetupOomArm.call,
        null,
    );
    // The handler runs with the account still clamped, so it has to be
    // allocation-free: a string literal in the catch body would need a fresh
    // string and fail a second time, this time with nothing left to catch it.
    // The expected texts are therefore built before the clamp; `===` compares
    // them by content, so the assertion is the same one.
    _ = try js.eval(
        \\globalThis.__w2TailSetupBodyRuns = 0;
        \\globalThis.__w2TailSetupOomName = "InternalError";
        \\globalThis.__w2TailSetupOomMessage = "out of memory";
        \\function __w2TailSetupOomTarget(value) {
        \\    "use strict";
        \\    __w2TailSetupBodyRuns++;
        \\    return arguments[0];
        \\}
        \\function __w2TailSetupOomForward(eval) {
        \\    __w2ArmTailSetupOom();
        \\    return eval(41);
        \\}
        \\function __w2TailSetupOomDriver() {
        \\    try {
        \\        return 1 + __w2TailSetupOomForward(
        \\            __w2TailSetupOomTarget
        \\        );
        \\    } catch (error) {
        \\        return error.name === __w2TailSetupOomName &&
        \\            error.message === __w2TailSetupOomMessage ? 100 : -1000;
        \\    }
        \\}
    );

    const forward_fb = try globalFunctionBytecode(&js, "__w2TailSetupOomForward");
    const target_fb = try globalFunctionBytecode(&js, "__w2TailSetupOomTarget");
    try std.testing.expect(hasTailEvalReturn(forward_fb));
    try std.testing.expect(target_fb.isStrictMode());
    try std.testing.expect(frame_mod.argumentsNeedsOriginalSnapshot(target_fb));

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const body_runs_key = try js.runtime.internAtom("__w2TailSetupBodyRuns");
    const driver_key = try js.runtime.internAtom("__w2TailSetupOomDriver");
    const driver = try global.getProperty(driver_key);

    const warm = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        driver,
        &.{},
        null,
        null,
    );
    try std.testing.expectEqual(@as(?f64, 42), warm.asNumber());

    const body_runs_before = try global.getProperty(body_runs_key);
    try std.testing.expectEqual(@as(?f64, 1), body_runs_before.asNumber());

    const baseline_call_depth = js.runtime.stack.call_depth;
    const baseline_native_depth = js.runtime.stack.native_call_depth;
    const baseline_tail_bytes = js.runtime.stack.bytecode_bytes;
    const baseline_arena_mark = js.runtime.vm_stack.mark();

    // The host callback clamps the account after all native-call setup. argc=1
    // keeps tail scratch inline; the strict target's `arguments` snapshot then
    // makes FrameCold allocation the first growing target-setup operation.
    // Keeping the forwarder live until setup commits lets ordinary unwind pop
    // that faulting frame and deliver the error to the driver's catch.
    arm.exhaust = true;
    const caught = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        driver,
        &.{},
        null,
        null,
    );
    js.runtime.setNativeBytesLimitForTest(null);
    arm.exhaust = false;
    try std.testing.expectEqual(@as(?f64, 100), caught.asNumber());
    try std.testing.expectEqual(@as(usize, 2), arm.calls);
    try std.testing.expect(!js.context.hasException());
    const body_runs_after_oom = try global.getProperty(body_runs_key);
    try std.testing.expectEqual(@as(?f64, 1), body_runs_after_oom.asNumber());
    try std.testing.expectEqual(baseline_call_depth, js.runtime.stack.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.stack.native_call_depth);
    try std.testing.expectEqual(baseline_tail_bytes, js.runtime.stack.bytecode_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
    // The two metrics below are live-allocation metrics, so both the reading
    // taken here and every reading compared against it have to be taken with
    // the debris of the failed attempt already returned to the account -- which
    // is what unwinding did on its own under refcounting.
    helpers.reclaimNow(js.runtime);
    const stable_allocated_bytes = js.runtime.allocation_diagnostics.allocated_bytes;
    const stable_allocation_count = js.runtime.allocation_diagnostics.allocation_count;

    // The first catch may publish cold metadata after active-frame teardown
    // creates headroom under the clamped limit. A second identical failure
    // must not grow either live allocation metric.
    arm.exhaust = true;
    const caught_again = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        driver,
        &.{},
        null,
        null,
    );
    js.runtime.setNativeBytesLimitForTest(null);
    arm.exhaust = false;
    try std.testing.expectEqual(@as(?f64, 100), caught_again.asNumber());
    try std.testing.expectEqual(@as(usize, 3), arm.calls);
    try std.testing.expect(!js.context.hasException());
    const body_runs_after_second_oom = try global.getProperty(body_runs_key);
    try std.testing.expectEqual(@as(?f64, 1), body_runs_after_second_oom.asNumber());
    try std.testing.expectEqual(baseline_call_depth, js.runtime.stack.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.stack.native_call_depth);
    try std.testing.expectEqual(baseline_tail_bytes, js.runtime.stack.bytecode_bytes);
    helpers.reclaimNow(js.runtime);
    try std.testing.expectEqual(stable_allocated_bytes, js.runtime.allocation_diagnostics.allocated_bytes);
    try std.testing.expectEqual(stable_allocation_count, js.runtime.allocation_diagnostics.allocation_count);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());

    const recovered = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        driver,
        &.{},
        null,
        null,
    );
    try std.testing.expectEqual(@as(?f64, 42), recovered.asNumber());
    try std.testing.expectEqual(@as(usize, 4), arm.calls);
    const body_runs_after_recovery = try global.getProperty(body_runs_key);
    try std.testing.expectEqual(@as(?f64, 2), body_runs_after_recovery.asNumber());
    try std.testing.expectEqual(baseline_call_depth, js.runtime.stack.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.stack.native_call_depth);
    try std.testing.expectEqual(baseline_tail_bytes, js.runtime.stack.bytecode_bytes);
    helpers.reclaimNow(js.runtime);
    try std.testing.expectEqual(stable_allocated_bytes, js.runtime.allocation_diagnostics.allocated_bytes);
    try std.testing.expectEqual(stable_allocation_count, js.runtime.allocation_diagnostics.allocation_count);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
}

fn hasTailEvalReturn(function: *const bytecode.FunctionBytecode) bool {
    const code = function.byteCode();
    var pc: usize = 0;
    while (pc < code.len) {
        const op_id = code[pc];
        const size = bytecode.opcode.sizeOf(op_id);
        if (size == 0 or pc + size > code.len) return false;
        const next_pc = pc + size;
        if ((op_id == op.eval or op_id == op.apply_eval) and
            next_pc < code.len and code[next_pc] == op.@"return")
        {
            return true;
        }
        pc = next_pc;
    }
    return false;
}

test "js_function_set_properties publishes configurable length then name" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\function namedPair(a, b) { return a; }
        \\var dlen = Object.getOwnPropertyDescriptor(namedPair, "length");
        \\var dname = Object.getOwnPropertyDescriptor(namedPair, "name");
        \\var dproto = Object.getOwnPropertyDescriptor(namedPair, "prototype");
        \\var dctor = Object.getOwnPropertyDescriptor(dproto.value, "constructor");
        \\globalThis.__r11_name_ok = (dlen.value === 2 && dlen.writable === false && dlen.enumerable === false && dlen.configurable === true
        \\  && dname.value === "namedPair" && dname.writable === false && dname.enumerable === false && dname.configurable === true
        \\  && dproto.writable === true && dproto.enumerable === false && dproto.configurable === false
        \\  && dctor.value === namedPair && dctor.writable === true && dctor.enumerable === false && dctor.configurable === true) ? 1 : 0;
    );
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const key = try js.runtime.internAtom("__r11_name_ok");
    const result = try global.getProperty(key);
    try std.testing.expect(result.as(.int) == @as(?i32, 1) or result.asNumber() == @as(?f64, 1.0));
}

test "get_var_ref reuses the open cell on a second capture of the same local" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const name = try rt.internAtom("r11-reuse-open-cell");
    const execution_function = try bytecode.FunctionBytecode.createFixture(rt, .{ .name = name, .var_count = 1, .var_ref_count = 1 });
    defer execution_function.destroyUnpublishedFixture(rt);
    execution_function.allVarDefs()[0] = bytecode.function_bytecode.BytecodeVarDef.init(.{
        .var_name = core.atom.null_atom,
        .is_captured = true,
        .var_ref_idx = 0,
    });

    var locals = [_]core.JSValue{core.JSValue.int32(7)};
    var open_refs = [_]?*core.VarRef{null};
    var frame = frame_mod.Frame.init(execution_function);
    defer frame.deinit(rt.nativeAllocator(), rt);
    frame.locals = &locals;
    frame.open_var_refs = &open_refs;
    frame.ownership.storage = .borrowed;

    const first = try frame.captureLocal(rt, 0);
    const second = try frame.captureLocal(rt, 0);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(first, open_refs[0].?);
}

test "CallSite function names interned during capture survive a collection" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    _ = try js.eval(
        \\function f() { return new Error().stack; }
        \\Error.prepareStackTrace = (e, sites) => sites[0].getFunctionName();
        \\var n = 0;
        \\function run() {
        \\  const name = ["fresh", "Name", ++n].join("");
        \\  Object.defineProperty(f, "name", { value: name, configurable: true });
        \\  globalThis.out = f() === name;
        \\}
        \\run();
    );

    // The warm-up run interned every other atom, so the next new one is the
    // name the capture interns. It requests an atom-growth major, which runs
    // at the CallSite's first allocation while only the frame snapshot holds
    // the name.
    js.runtime.atoms.interned_since_sweep = core.atom.AtomTable.sweep_growth_floor - 1;
    _ = try js.eval("run()");

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const out = try global.getProperty(try js.runtime.internAtom("out"));
    try std.testing.expect(out.same(core.JSValue.boolean(true)));
}

test "js_closure2 attach roots captures through the function object" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\function __r11_make(n) {
        \\  var a = n, b = n + 1, c = n + 2;
        \\  function inner() {
        \\    function deeper() { return a + b + c; }
        \\    return deeper;
        \\  }
        \\  return inner();
        \\}
        \\globalThis.__r11_fn = __r11_make(10);
        \\globalThis.__r11_out = globalThis.__r11_fn();
    );

    const old_threshold = js.runtime.gcThreshold();
    js.runtime.setGCThreshold(0);
    defer js.runtime.setGCThreshold(old_threshold);
    _ = try js.runtime.collectForTest();

    _ = try js.eval("globalThis.__r11_out = globalThis.__r11_fn()");

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const out_key = try js.runtime.internAtom("__r11_out");
    const total = try global.getProperty(out_key);
    try std.testing.expect(total.as(.int) == @as(?i32, 33) or total.asNumber() == @as(?f64, 33.0));
}

test "var-ref growth promotes borrowed captures to owned cells" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    const name = try rt.internAtom("frame-borrowed-var-ref-growth-test");
    const execution_function = try bytecode.FunctionBytecode.createFixture(rt, .{ .name = name });
    defer execution_function.destroyUnpublishedFixture(rt);

    const captured = try core.VarRef.createClosed(rt, core.JSValue.int32(41));
    var captures = [_]*core.VarRef{captured};
    var exec_frame = frame_mod.Frame.init(execution_function);
    defer exec_frame.deinit(rt.nativeAllocator(), rt);
    exec_frame.var_refs = &captures;
    exec_frame.ownership.var_refs = .borrowed;

    try frame_mod.ensureVarRefsCapacity(ctx, &exec_frame, 1);
    try std.testing.expectEqual(@as(usize, 2), exec_frame.var_refs.len);
    try std.testing.expectEqual(captured, exec_frame.var_refs[0]);
    try std.testing.expectEqual(frame_mod.Ownership.owned, exec_frame.ownership.var_refs);
}

test "ordinary global closure selector preserves QuickJS cell waterfall and owner metadata" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    try js.ensureTest262GlobalsInstalled();
    const rt = js.runtime;
    const ctx = js.context;
    const global = try engine.exec.zjs_vm.contextGlobal(ctx);

    const lexical_name = try rt.internAtom("__selectorLexicalWins");
    const lexical_value = try engine.exec.call_runtime.ensureGlobalLexicalCell(ctx, global, lexical_name, false);
    const object_value = (try engine.exec.call_runtime.ensureGlobalObjectVarRefCell(
        ctx,
        global,
        lexical_name,
        false,
        false,
    )) orelse return error.TestExpectedEqual;
    const lexical_selected = try engine.exec.call_runtime.selectOrdinaryGlobalClosureCell(ctx, global, lexical_name);
    try std.testing.expectEqual(core.VarRef.fromValue(lexical_value).?, core.VarRef.fromValue(lexical_selected).?);
    try std.testing.expect(core.VarRef.fromValue(object_value).? != core.VarRef.fromValue(lexical_selected).?);

    const varref_name = try rt.internAtom("__selectorGlobalVarRef");
    const global_varref = (try engine.exec.call_runtime.ensureGlobalObjectVarRefCell(
        ctx,
        global,
        varref_name,
        false,
        false,
    )) orelse return error.TestExpectedEqual;
    const global_selected = try engine.exec.call_runtime.selectOrdinaryGlobalClosureCell(ctx, global, varref_name);
    try std.testing.expectEqual(core.VarRef.fromValue(global_varref).?, core.VarRef.fromValue(global_selected).?);

    const data_name = try rt.internAtom("__selectorDataParks");
    try global.defineOwnProperty(rt, data_name, core.Descriptor.data(core.JSValue.int32(41), .all));
    const parked_first = try engine.exec.call_runtime.selectOrdinaryGlobalClosureCell(ctx, global, data_name);
    const parked_cell = core.VarRef.fromValue(parked_first) orelse return error.TestExpectedEqual;
    try std.testing.expect(parked_cell.varRefValue().is(.uninitialized));
    parked_cell.is_lexical = true;
    parked_cell.varRefIsConstSlot().* = true;
    parked_cell.varRefIsFunctionNameSlot().* = true;
    const parked_second = try engine.exec.call_runtime.selectOrdinaryGlobalClosureCell(ctx, global, data_name);
    try std.testing.expectEqual(parked_cell, core.VarRef.fromValue(parked_second).?);
    try std.testing.expect(parked_cell.is_lexical);
    try std.testing.expect(parked_cell.varRefIsConstSlot().*);
    try std.testing.expect(parked_cell.varRefIsFunctionNameSlot().*);

    _ = try js.eval(
        \\globalThis.__selectorAccessorReads = 0;
        \\Object.defineProperty(globalThis, "__selectorAccessor", {
        \\    configurable: true,
        \\    get: function () { __selectorAccessorReads++; return 1; }
        \\});
    );
    const accessor_name = try rt.internAtom("__selectorAccessor");
    _ = try engine.exec.call_runtime.selectOrdinaryGlobalClosureCell(ctx, global, accessor_name);
    _ = try js.eval("assert.sameValue(__selectorAccessorReads, 0);");

    const auto_name = try rt.internAtom("__selectorAutoInit");
    const AutoValue = struct {
        fn make(_: *core.gc.Header) engine.RuntimeError!core.JSValue {
            return core.JSValue.int32(7);
        }
    };
    const auto_descriptor: core.property.AutoInit = .{ .name = "__selectorAutoInit", .length = 0, .materialize_host = AutoValue.make };
    try global.defineAutoInitPropertyFromDescriptor(rt, auto_name, core.property.Flags.data(.method), global, &auto_descriptor);
    const auto_index = global.findProperty(auto_name) orelse return error.TestExpectedEqual;
    try std.testing.expect(global.propFlagsAt(auto_index).isAutoInit());
    const auto_selected = try engine.exec.call_runtime.selectOrdinaryGlobalClosureCell(ctx, global, auto_name);
    const materialized_index = global.findProperty(auto_name) orelse return error.TestExpectedEqual;
    try std.testing.expect(!global.propFlagsAt(materialized_index).isAutoInit());
    const auto_again = try engine.exec.call_runtime.selectOrdinaryGlobalClosureCell(ctx, global, auto_name);
    try std.testing.expectEqual(core.VarRef.fromValue(auto_selected).?, core.VarRef.fromValue(auto_again).?);
}

test "hidden uninitialized globals compact at the QuickJS sawtooth bound" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const rt = js.runtime;
    const ctx = js.context;
    const global = try engine.exec.zjs_vm.contextGlobal(ctx);

    const live_count = 78;
    const churn_width = 12;
    var names: [live_count]core.Atom = undefined;
    var initialized: usize = 0;
    for (&names, 0..) |*name, index| {
        var buffer: [48]u8 = undefined;
        name.* = try rt.internAtom(try std.fmt.bufPrint(&buffer, "__compact_hidden_{d}", .{index}));
        initialized += 1;
        _ = try engine.exec.call_runtime.globalObjectGetUninitializedVar(ctx, global, name.*);
    }

    const hidden = global.globalUninitializedVars() orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u32, 78), hidden.shape_ref.prop_count);
    try std.testing.expectEqual(@as(u32, 0), hidden.shape_ref.deletedPropCount());

    const expected_counts = [_]struct { props: u32, deleted: u32 }{
        .{ .props = 90, .deleted = 12 },
        .{ .props = 102, .deleted = 24 },
        .{ .props = 114, .deleted = 36 },
        .{ .props = 126, .deleted = 48 },
        .{ .props = 138, .deleted = 60 },
        .{ .props = 150, .deleted = 72 },
        .{ .props = 86, .deleted = 8 },
    };
    var peak_deleted: u32 = 0;
    var saw_compaction = false;
    for (expected_counts) |expected| {
        for (names[0..churn_width]) |name| {
            _ = try engine.exec.call_runtime.globalObjectFindUninitializedVar(ctx, global, name, false) orelse
                return error.TestExpectedEqual;
            const deleted = hidden.shape_ref.deletedPropCount();
            const live = hidden.shape_ref.prop_count - deleted;
            try std.testing.expect(deleted < @max(@as(u32, 8), live + 1));
            if (deleted == 0) saw_compaction = true;
            peak_deleted = @max(peak_deleted, deleted);

            _ = try engine.exec.call_runtime.globalObjectGetUninitializedVar(ctx, global, name);
        }
        try std.testing.expectEqual(expected.props, hidden.shape_ref.prop_count);
        try std.testing.expectEqual(expected.deleted, hidden.shape_ref.deletedPropCount());
    }

    try std.testing.expect(saw_compaction);
    try std.testing.expectEqual(@as(u32, 75), peak_deleted);
    try std.testing.expectEqual(@as(u32, live_count), hidden.shape_ref.prop_count - hidden.shape_ref.deletedPropCount());
    for (names) |name| try std.testing.expect(hidden.hasOwnProperty(name));
}

test "W1 two own layouts keep the VM property site active" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    _ = try js.eval(
        \\function readTwo(o) { return o.field; }
        \\var a = { field: 3, x: 1 };
        \\var b = { y: 2, field: 5 };
        \\var total = 0;
        \\for (var i = 0; i < 64; i++) total += readTwo(i % 2 ? a : b);
        \\assert.sameValue(total, 256);
        \\readTwo;
    );
    const function = try globalFunctionBytecode(js, "readTwo");
    const hot = function.hotExtension() orelse return error.InvalidFunctionBytecode;
    try std.testing.expectEqual(@as(u16, 1), hot.prop_site_count);
    const site = &hot.prop_sites.?[0];
    try std.testing.expectEqual(engine.exec.vm_property_field.site_own, site.state);
    try std.testing.expectEqual(@as(u8, 1), site.misses);
    try std.testing.expect(site.secondary_guard_key != 0);
    try std.testing.expect(site.secondary_guard_key != site.guard_key);
    try std.testing.expect(site.secondary_slot != site.slot);

    // b was captured first and is the secondary arm. Changing its property
    // kind must miss that guard and invoke the getter exactly once.
    _ = try js.eval(
        \\var getterCalls = 0;
        \\Object.defineProperty(b, "field", { get: function () { getterCalls++; return 7; }, configurable: true });
        \\assert.sameValue(readTwo(b), 7);
        \\assert.sameValue(getterCalls, 1);
        \\assert.sameValue(readTwo(a), 3);
    );
    try std.testing.expectEqual(engine.exec.vm_property_field.site_mega, site.state);
    try std.testing.expectEqual(@as(u64, 0), site.secondary_guard_key);

    // A site encountering more than two layouts retains the existing finite
    // miss policy. A second arm must not bypass retirement.
    _ = try js.eval(
        \\function readMany(o) { return o.field; }
        \\var many = [];
        \\for (var j = 0; j < 8; j++) {
        \\    var o = {};
        \\    for (var k = 0; k <= j; k++) o["p" + k] = k;
        \\    o.field = j;
        \\    many.push(o);
        \\}
        \\var sum = 0;
        \\for (var i = 0; i < 64; i++) sum += readMany(many[i % 8]);
        \\assert.sameValue(sum, 224);
    );
    const many_function = try globalFunctionBytecode(js, "readMany");
    const many_hot = many_function.hotExtension().?;
    try std.testing.expectEqual(@as(u16, 1), many_hot.prop_site_count);
    const many_site = &many_hot.prop_sites.?[0];
    try std.testing.expectEqual(engine.exec.vm_property_field.site_mega, many_site.state);
    try std.testing.expectEqual(@as(u64, 0), many_site.secondary_guard_key);
}

test "W1 property sites stay correct across every shape mutation that invalidates them" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Every case warms one property site past the monomorphic threshold and
    // then performs a mutation whose only invalidation channel is
    // `Shape.identity` (there is no explicit site-invalidation hook, by
    // design -- vm-value-representation-contract 5.2.1).
    const result = try js.eval(
        \\// --- own arm: delete must be observed (markPropertyDeleted) ---
        \\function readA(o) { return o.a; }
        \\var own = { a: 1, b: 2 };
        \\for (var i = 0; i < 200; i++) readA(own);
        \\delete own.a;
        \\assert.sameValue(readA(own), undefined, "own delete");
        \\
        \\// --- own arm: an APPEND on the same object keeps the slot valid ---
        \\var grow = { a: 1 };
        \\for (var i = 0; i < 200; i++) readA(grow);
        \\for (var i = 0; i < 40; i++) grow["k" + i] = i;   // forces FAM relocation
        \\assert.sameValue(readA(grow), 1, "own after grow-relocation");
        \\
        \\// --- prototype arm: shadowing on the instance wins ---
        \\function Proto() {}
        \\Proto.prototype.m = 10;
        \\function readM(o) { return o.m; }
        \\var inst = new Proto();
        \\for (var i = 0; i < 200; i++) readM(inst);
        \\assert.sameValue(readM(inst), 10, "proto warm");
        \\inst.m = 99;
        \\assert.sameValue(readM(inst), 99, "proto shadowed by own");
        \\
        \\// --- prototype arm: mutating the HOLDER is observed ---
        \\var inst2 = new Proto();
        \\for (var i = 0; i < 200; i++) readM(inst2);
        \\Proto.prototype.m = 11;
        \\assert.sameValue(readM(inst2), 11, "holder value change");
        \\delete Proto.prototype.m;
        \\assert.sameValue(readM(inst2), undefined, "holder delete");
        \\
        \\// --- prototype arm: a proto SWAP is observed (replacePrototype) ---
        \\function readP(o) { return o.p; }
        \\var swapProtoA = { p: "A" };
        \\var swapProtoB = { p: "B" };
        \\var swap = Object.create(swapProtoA);
        \\for (var i = 0; i < 200; i++) readP(swap);
        \\assert.sameValue(readP(swap), "A", "proto swap before");
        \\Object.setPrototypeOf(swap, swapProtoB);
        \\assert.sameValue(readP(swap), "B", "proto swap after");
        \\
        \\// --- a data property turned into an ACCESSOR (updatePropertyFlags) ---
        \\var toAccessor = { a: 1 };
        \\for (var i = 0; i < 200; i++) readA(toAccessor);
        \\var accessorCalls = 0;
        \\Object.defineProperty(toAccessor, "a", { get: function () { accessorCalls++; return 7; }, configurable: true });
        \\assert.sameValue(readA(toAccessor), 7, "data -> accessor");
        \\assert.sameValue(accessorCalls, 1, "accessor actually ran");
        \\
        \\// --- put_field: a warm write site must observe read-only ---
        \\function writeA(o, v) { o.a = v; }
        \\var w = { a: 0 };
        \\for (var i = 0; i < 200; i++) writeA(w, i);
        \\assert.sameValue(w.a, 199, "warm write");
        \\Object.defineProperty(w, "a", { writable: false });
        \\writeA(w, 1234);
        \\assert.sameValue(w.a, 199, "write to a frozen slot is ignored");
        \\
        \\// --- put_field: a warm write site must observe a setter ---
        \\var setterSeen = null;
        \\var ws = { a: 0 };
        \\for (var i = 0; i < 200; i++) writeA(ws, i);
        \\Object.defineProperty(ws, "a", { set: function (v) { setterSeen = v; }, get: function () { return -1; }, configurable: true });
        \\writeA(ws, 42);
        \\assert.sameValue(setterSeen, 42, "data -> setter");
        \\
        \\// --- polymorphic site: every shape must keep answering correctly ---
        \\var shapes = [{ a: 1 }, { z: 0, a: 2 }, { y: 0, x: 0, a: 3 }, { a: 4, q: 0 }, Object.create({ a: 5 })];
        \\var poly = 0;
        \\for (var i = 0; i < 500; i++) poly += readA(shapes[i % shapes.length]);
        \\assert.sameValue(poly, 1500, "polymorphic site sum");
        \\
        \\// --- exotic receivers must never take a cached arm ---
        \\function readLen(o) { return o.length; }
        \\var arr = [1, 2, 3];
        \\for (var i = 0; i < 200; i++) readLen(arr);
        \\arr.push(4);
        \\assert.sameValue(readLen(arr), 4, "array length after push");
        \\assert.sameValue(readLen("abcde"), 5, "string length through the same site");
        \\
        \\// --- a Proxy through a warmed site keeps its trap ---
        \\var trapped = 0;
        \\var px = new Proxy({ a: 1 }, { get: function (t, k) { trapped++; return t[k]; } });
        \\var mixed = { a: 1 };
        \\for (var i = 0; i < 200; i++) readA(mixed);
        \\assert.sameValue(readA(px), 1, "proxy value");
        \\assert.sameValue(trapped, 1, "proxy trap ran");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "W1 native-getter sites re-resolve the accessor out of the guarded slot" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // The `.native_getter` arm caches the accessor SLOT, never the resolved
    // NativeEntry: `defineProperty` can swap the getter function without
    // touching a shape flag.
    const result = try js.eval(
        \\function readFlags(r) { return r.flags; }
        \\var re = /ab/gi;
        \\for (var i = 0; i < 200; i++) readFlags(re);
        \\assert.sameValue(readFlags(re), "gi", "native getter warm");
        \\assert.sameValue(readFlags(/c/m), "m", "same site, other receiver");
        \\
        \\function readSize(m) { return m.size; }
        \\var map = new Map([[1, 1], [2, 2]]);
        \\for (var i = 0; i < 200; i++) readSize(map);
        \\map.set(3, 3);
        \\assert.sameValue(readSize(map), 3, "Map.prototype.size after warm");
        \\
        \\// Replacing the prototype's getter must be observed.
        \\function readG(o) { return o.g; }
        \\function K() {}
        \\Object.defineProperty(K.prototype, "g", { get: function () { return 1; }, configurable: true });
        \\var k = new K();
        \\for (var i = 0; i < 200; i++) readG(k);
        \\assert.sameValue(readG(k), 1, "js getter warm");
        \\Object.defineProperty(K.prototype, "g", { get: function () { return 2; }, configurable: true });
        \\assert.sameValue(readG(k), 2, "js getter replaced");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "runtime-strict script still constructs its global function declaration" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [8]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOptions(
        \\function __qjsRuntimeStrictGlobalFunction() {}
        \\print(Object.prototype.hasOwnProperty.call(globalThis, "__qjsRuntimeStrictGlobalFunction"));
    , .{ .output = &output, .mode = .script, .filename = "runtime-strict-global-function.js", .parse_strict = true, .runtime_strict = true });

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("true\n", output.buffered());
}

test "var-ref growth rejects an owned composite frame slab" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    const name = try rt.internAtom("frame-composite-var-ref-growth-test");
    const execution_function = try bytecode.FunctionBytecode.createFixture(rt, .{ .name = name });
    defer execution_function.destroyUnpublishedFixture(rt);

    const slab = try frame_mod.FrameSlab.allocHeap(rt.nativeAllocator(), .{ .stack = 1, .var_refs = 1 });
    slab.stack[0] = core.JSValue.undefinedValue();
    slab.var_refs[0] = try core.VarRef.createClosed(rt, core.JSValue.int32(7));
    var exec_frame = frame_mod.Frame.init(execution_function);
    defer exec_frame.deinit(rt.nativeAllocator(), rt);
    exec_frame.installOwnedStorage(slab.storage);
    exec_frame.var_refs = slab.var_refs;

    const storage_ptr = exec_frame.storage_values.ptr;
    const var_refs_ptr = exec_frame.var_refs.ptr;
    try std.testing.expectError(error.InvalidBytecode, frame_mod.ensureVarRefsCapacity(ctx, &exec_frame, 1));
    try std.testing.expectEqual(storage_ptr, exec_frame.storage_values.ptr);
    try std.testing.expectEqual(var_refs_ptr, exec_frame.var_refs.ptr);
}

test "local growth rejects an owned composite frame slab" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const name = try rt.internAtom("frame-composite-local-growth-test");
    const execution_function = try bytecode.FunctionBytecode.createFixture(rt, .{ .name = name });
    defer execution_function.destroyUnpublishedFixture(rt);

    const slab = try frame_mod.FrameSlab.allocHeap(rt.nativeAllocator(), .{ .locals = 1, .stack = 1 });
    slab.locals[0] = core.JSValue.int32(3);
    slab.stack[0] = core.JSValue.undefinedValue();
    var exec_frame = frame_mod.Frame.init(execution_function);
    defer exec_frame.deinit(rt.nativeAllocator(), rt);
    exec_frame.installOwnedStorage(slab.storage);
    exec_frame.locals = slab.locals;

    const storage_ptr = exec_frame.storage_values.ptr;
    const locals_ptr = exec_frame.locals.ptr;
    try std.testing.expectError(error.InvalidBytecode, exec_frame.setLocal(rt.nativeAllocator(), 1, core.JSValue.int32(4)));
    try std.testing.expectEqual(storage_ptr, exec_frame.storage_values.ptr);
    try std.testing.expectEqual(locals_ptr, exec_frame.locals.ptr);
}

test "arg aliases reject missing open-ref storage without cellifying the slot" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const name = try js.runtime.internAtom("frame-arg-open-ref-capacity-test");
    const execution_function = try bytecode.FunctionBytecode.createFixture(js.runtime, .{
        .name = name,
        .flags = .{ .has_simple_parameter_list = true },
        .arg_count = 1,
        .var_ref_count = 1,
    });
    defer execution_function.destroyUnpublishedFixture(js.runtime);
    execution_function.allVarDefs()[0] = bytecode.function_bytecode.BytecodeVarDef.init(.{ .var_name = core.atom.null_atom, .is_captured = true, .var_ref_idx = 0 });

    var args = [_]core.JSValue{core.JSValue.int32(41)};
    var no_open_refs = [_]?*core.VarRef{};
    var exec_frame = frame_mod.Frame.init(execution_function);
    defer exec_frame.deinit(js.runtime.nativeAllocator(), js.runtime);
    exec_frame.args = &args;
    exec_frame.actual_arg_count = args.len;
    exec_frame.open_var_refs = &no_open_refs;
    exec_frame.ownership.storage = .borrowed;

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    var rejected = false;
    if (object_ops.createArgumentsObject(js.context, global, &exec_frame, true)) |_| {
        args[0] = core.JSValue.int32(41);
    } else |err| {
        try std.testing.expectEqual(error.InvalidBytecode, err);
        rejected = true;
    }
    try std.testing.expect(rejected);
    try std.testing.expectEqual(@as(?i32, 41), args[0].as(.int));
    try std.testing.expect(core.VarRef.fromValue(args[0]) == null);

    // The two alias-consistency checks below exist only in safety builds;
    // like qjs get_var_ref, production trusts the compiler's slot layout.
    if (!std.debug.runtime_safety) return;
    var occupied_value = core.JSValue.int32(7);
    const occupied_ref = try core.VarRef.createOpen(js.runtime, &occupied_value);
    var full_open_refs = [_]?*core.VarRef{occupied_ref};
    exec_frame.open_var_refs = &full_open_refs;
    rejected = false;
    if (object_ops.createArgumentsObject(js.context, global, &exec_frame, true)) |_| {} else |err| {
        try std.testing.expectEqual(error.InvalidBytecode, err);
        rejected = true;
    }
    try std.testing.expect(rejected);
    try std.testing.expectEqual(@as(?i32, 41), args[0].as(.int));
    try std.testing.expect(core.VarRef.fromValue(args[0]) == null);
    try std.testing.expectEqual(occupied_ref, full_open_refs[0].?);

    const malformed_cell = try core.VarRef.createClosed(js.runtime, args[0]);
    args[0] = malformed_cell.valueRef();
    rejected = false;
    if (object_ops.createArgumentsObject(js.context, global, &exec_frame, true)) |_| {} else |err| {
        try std.testing.expectEqual(error.InvalidBytecode, err);
        rejected = true;
    }
    try std.testing.expect(rejected);
    try std.testing.expectEqual(malformed_cell, core.VarRef.fromValue(args[0]).?);
    args[0] = core.JSValue.int32(41);
}

test "local growth rejects moving storage after an open binding is published" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const name = try rt.internAtom("frame-open-local-growth-test");
    const execution_function = try bytecode.FunctionBytecode.createFixture(rt, .{ .name = name });
    defer execution_function.destroyUnpublishedFixture(rt);

    var locals = [_]core.JSValue{core.JSValue.int32(7)};
    const open_ref = try core.VarRef.createOpen(rt, &locals[0]);
    var open_refs = [_]?*core.VarRef{open_ref};
    var exec_frame = frame_mod.Frame.init(execution_function);
    defer exec_frame.deinit(rt.nativeAllocator(), rt);
    exec_frame.locals = &locals;
    exec_frame.open_var_refs = &open_refs;
    exec_frame.ownership.storage = .borrowed;

    // Injecting an allocation failure, not testing the collector: see
    // `suppressLimitCollectionForTest`.
    rt.suppressLimitCollectionForTest(true);
    defer rt.suppressLimitCollectionForTest(false);
    rt.setNativeBytesLimitForTest(rt.allocation_diagnostics.allocated_bytes);
    try std.testing.expectError(error.InvalidBytecode, exec_frame.setLocal(rt.nativeAllocator(), 1, core.JSValue.int32(8)));
    rt.setNativeBytesLimitForTest(null);
    try exec_frame.setLocal(rt.nativeAllocator(), 0, core.JSValue.int32(9));
    try std.testing.expectEqual(@as(?i32, 9), open_ref.varRefValue().as(.int));
}

test "call-binding OOM leaves input references with the caller" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const name = try rt.internAtom("frame-call-binding-oom-test");
    const execution_function = try bytecode.FunctionBytecode.createFixture(rt, .{ .name = name });
    defer execution_function.destroyUnpublishedFixture(rt);

    const held = try core.Object.create(rt, core.class.ids.object, null);
    var exec_frame = frame_mod.Frame.init(execution_function);
    defer exec_frame.deinit(rt.nativeAllocator(), rt);

    // Injecting an allocation failure, not testing the collector: see
    // `suppressLimitCollectionForTest`.
    rt.suppressLimitCollectionForTest(true);
    defer rt.suppressLimitCollectionForTest(false);
    rt.setNativeBytesLimitForTest(rt.allocation_diagnostics.allocated_bytes);
    const result = exec_frame.initCallBindings(rt, .{
        .initial_this_value = held.value(),
        .current_function_value = held.value(),
        .new_target_value = held.value(),
    });
    rt.setNativeBytesLimitForTest(null);

    try std.testing.expectError(error.OutOfMemory, result);
}

test "original-args cold-state OOM does not retain copied references" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const name = try rt.internAtom("frame-original-args-oom-test");
    const execution_function = try bytecode.FunctionBytecode.createFixture(rt, .{ .name = name });
    defer execution_function.destroyUnpublishedFixture(rt);

    const held = try core.Object.create(rt, core.class.ids.object, null);
    var source_args = [_]core.JSValue{held.value()};
    var original_args = [_]core.JSValue{core.JSValue.undefinedValue()};
    var exec_frame = frame_mod.Frame.init(execution_function);
    defer exec_frame.deinit(rt.nativeAllocator(), rt);

    // Injecting an allocation failure, not testing the collector: see
    // `suppressLimitCollectionForTest`.
    rt.suppressLimitCollectionForTest(true);
    defer rt.suppressLimitCollectionForTest(false);
    rt.setNativeBytesLimitForTest(rt.allocation_diagnostics.allocated_bytes);
    const result = exec_frame.initArgumentsBorrowedSlots(
        rt.nativeAllocator(),
        &source_args,
        true,
        .{ .original_args = &original_args },
    );
    rt.setNativeBytesLimitForTest(null);

    try std.testing.expectError(error.OutOfMemory, result);
}

test "strict generator resident frame supports qjs argument counts beyond u16 storage" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function* manyArgs() {
        \\    "use strict";
        \\    return arguments.length;
        \\}
        \\assert.sameValue(manyArgs.apply(null, Array(40000)).next().value, 40000);
    );
    try std.testing.expect(result.is(.undefined_value));
}
