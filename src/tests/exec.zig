const std = @import("std");
const zjs = @import("zjs");
const engine = zjs;

const core = zjs.core;
const QjsLexer = zjs.parser.Lexer;
const parser_core = zjs.parser.Parser;
const ParseState = parser_core.ParseState;
const bytecode = zjs.bytecode;
const function_def = zjs.bytecode.function_def;
const op = zjs.bytecode.opcode.op;
const property_ops = zjs.exec.property_ops;
const object_ops = zjs.exec.object_ops;
const array_ops = zjs.exec.array_ops;
const frame_mod = zjs.exec.frame;
const inline_calls = zjs.exec.inline_calls;
const test_entry = zjs.compiler.test_entry;

const makeFunction = helpers.makeFunction;
const runFunction = helpers.runFunction;
const countJob = helpers.countJob;
const countJobArgs = helpers.countJobArgs;

const InterruptTestState = struct {
    hits: usize = 0,
    stop: bool = false,

    fn run(_: *core.JSRuntime, userdata: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(userdata.?));
        self.hits += 1;
        return self.stop;
    }
};

const TailSetupOomArm = struct {
    calls: usize = 0,
    exhaust: bool = false,

    fn call(ptr: *anyopaque, invocation: core.host_function.ExternalCall) anyerror!core.JSValue {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        if (self.exhaust) {
            const rt = invocation.realm.runtime;
            rt.setMemoryLimit(rt.memory.allocated_bytes);
        }
        return core.JSValue.undefinedValue();
    }
};

const HostBacktraceErrorProbe = struct {
    fn call(_: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
        return error.TypeError;
    }
};

const NativeRecordStackProbe = struct {
    var callable: core.JSValue = core.JSValue.undefinedValue();
    var calls: usize = 0;
    var recurse: bool = true;

    const record: core.host_function.InternalRecord = .{
        .length = 0,
        .cproto = .generic,
        .native_function = .{ .generic = call },
    };

    fn call(ctx: *core.JSContext, _: core.JSValue, _: []const core.JSValue) anyerror!core.JSValue {
        calls += 1;
        if (!recurse or calls >= 256) return core.JSValue.int32(7);
        return engine.exec.call.callValue(ctx, null, callable, &.{});
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
            rt.setMemoryLimit(rt.memory.allocated_bytes);
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
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    helpers.registerStandardGlobalsBare(rt);
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    try std.testing.expect(ctx.global == null);

    var wrapper = zjs.JSContext.borrowCore(ctx);
    const result = try wrapper.eval("'lazy-global-ok'", .{});
    defer result.free(rt);
    try helpers.expectStringValueBytes(result, "lazy-global-ok");
    try std.testing.expect(ctx.global != null);
}

test "fused cmp_if_false8 interrupt poll stays uncatchable in a for loop" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const setup = try js.eval(
        \\globalThis.__fuse_n = 0;
        \\globalThis.__fuse_spin = function () {
        \\    for (var i = 0; i < 1000000000; i++) {
        \\        __fuse_n = i;
        \\    }
        \\    return 1;
        \\};
    );
    setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const spin_key = try js.runtime.internAtom("__fuse_spin");
    defer js.runtime.atoms.free(spin_key);
    const n_key = try js.runtime.internAtom("__fuse_n");
    defer js.runtime.atoms.free(n_key);
    const spin = try global.getProperty(spin_key);
    defer spin.free(js.runtime);

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
    const exception = js.context.takeException();
    exception.free(js.runtime);
    try std.testing.expect(!js.context.exceptionIsUncatchable());
}

test "interrupt budget survives Machine replacement and bypasses catch markers" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    // Machine A takes the fresh-context poll, then is destroyed.
    const setup = try js.eval("globalThis.__w2_interrupt_state = 0;");
    setup.free(js.runtime);

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
    defer js.runtime.atoms.free(state_key);
    const observed = try global.getProperty(state_key);
    defer observed.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 0), observed.asInt32());

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
    defer js.runtime.setMemoryLimit(null);

    var arm = InterruptOomArm{};
    try js.defineGlobalExternalHostFunction(
        "__w2ArmInterruptOom",
        0,
        &arm,
        InterruptOomArm.call,
        null,
    );
    const setup = try js.eval(
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
    setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const function_key = try js.runtime.internAtom("__w2_interrupt_oom");
    defer js.runtime.atoms.free(function_key);
    const caught_key = try js.runtime.internAtom("__w2_interrupt_oom_caught");
    defer js.runtime.atoms.free(caught_key);
    const function = try global.getProperty(function_key);
    defer function.free(js.runtime);
    const preallocated = js.context.preallocated_oom_error orelse return error.TestUnexpectedResult;

    const baseline_call_depth = js.runtime.hot.call_depth;
    const baseline_native_depth = js.runtime.hot.native_call_depth;
    const baseline_stack_bytes = js.runtime.hot.active_bytecode_stack_bytes;
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
    js.runtime.setMemoryLimit(null);
    arm.exhaust = false;

    try std.testing.expectEqual(@as(usize, 1), state.hits);
    try std.testing.expectEqual(@as(usize, 1), arm.calls);
    try std.testing.expect(js.context.exceptionIsUncatchable());
    const exception = js.context.takeException();
    defer exception.free(js.runtime);
    try std.testing.expect(preallocated.sameValue(exception));

    const caught = try global.getProperty(caught_key);
    defer caught.free(js.runtime);
    try std.testing.expectEqual(false, caught.asBool().?);
    try std.testing.expectEqual(baseline_call_depth, js.runtime.hot.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.hot.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.hot.active_bytecode_stack_bytes);
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
    defer recovered.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 42), recovered.asInt32());
    try std.testing.expectEqual(@as(usize, 2), arm.calls);
    try std.testing.expectEqual(baseline_call_depth, js.runtime.hot.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.hot.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.hot.active_bytecode_stack_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
}

test "uncatchable interrupt skips outer inline for-of close and catch" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const setup = try js.eval(
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
    setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const outer_key = try js.runtime.internAtom("__w2_interrupt_outer");
    defer js.runtime.atoms.free(outer_key);
    const closed_key = try js.runtime.internAtom("__w2_iterator_closed");
    defer js.runtime.atoms.free(closed_key);
    const caught_key = try js.runtime.internAtom("__w2_outer_caught");
    defer js.runtime.atoms.free(caught_key);
    const outer = try global.getProperty(outer_key);
    defer outer.free(js.runtime);

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
    defer closed.free(js.runtime);
    const caught = try global.getProperty(caught_key);
    defer caught.free(js.runtime);
    try std.testing.expectEqual(false, closed.asBool().?);
    try std.testing.expectEqual(false, caught.asBool().?);

    const exception = js.context.takeException();
    exception.free(js.runtime);
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

    const baseline_call_depth = js.runtime.hot.call_depth;
    const baseline_native_depth = js.runtime.hot.native_call_depth;
    const baseline_stack_bytes = js.runtime.hot.active_bytecode_stack_bytes;
    const baseline_arena_mark = js.runtime.vm_stack.mark();
    inline_calls.resetMachineTestMetrics();

    const result = try js.eval(
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
    defer result.free(js.runtime);

    const metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 1), metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 5), metrics.same_machine_sync_calls);
    try std.testing.expectEqual(@as(usize, 1), metrics.entry_chunk_allocations);
    try std.testing.expect(metrics.max_depth >= 2);
    try std.testing.expectEqual(@as(usize, 5), probe.invoke_calls);
    try std.testing.expect(probe.cleanup_ran);
    try std.testing.expect(js.runtime.active_invocation == null);
    try std.testing.expect(js.runtime.hot.current_backtrace_frame == null);
    try std.testing.expectEqual(baseline_call_depth, js.runtime.hot.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.hot.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.hot.active_bytecode_stack_bytes);
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

    const setup = try js.eval(
        \\globalThis.__nativeFenceDepth = function nativeFenceDepth(depth) {
        \\    if (depth === 0) return 0;
        \\    return __nativeFenceInvoke(__nativeFenceDepth, depth - 1) + 1;
        \\};
    );
    setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const function_key = try js.runtime.internAtom("__nativeFenceDepth");
    defer js.runtime.atoms.free(function_key);
    const function = try global.getProperty(function_key);
    defer function.free(js.runtime);
    const depths = [_]usize{ 15, 16, 17, 31, 32, 33 };

    for (depths) |depth| {
        const baseline_call_depth = js.runtime.hot.call_depth;
        const baseline_native_depth = js.runtime.hot.native_call_depth;
        const baseline_stack_bytes = js.runtime.hot.active_bytecode_stack_bytes;
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
        defer result.free(js.runtime);
        try std.testing.expectEqual(@as(?i32, @intCast(depth)), result.asInt32());

        const metrics = inline_calls.machineTestMetrics();
        try std.testing.expectEqual(@as(usize, 1), metrics.machine_inits);
        try std.testing.expectEqual(depth, metrics.same_machine_sync_calls);
        try std.testing.expectEqual(depth, metrics.max_depth);
        try std.testing.expectEqual(
            std.math.divCeil(usize, depth, 16) catch unreachable,
            metrics.entry_chunk_allocations,
        );
        try std.testing.expect(js.runtime.active_invocation == null);
        try std.testing.expectEqual(baseline_call_depth, js.runtime.hot.call_depth);
        try std.testing.expectEqual(baseline_native_depth, js.runtime.hot.native_call_depth);
        try std.testing.expectEqual(baseline_stack_bytes, js.runtime.hot.active_bytecode_stack_bytes);
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
    const setup = try js.eval(
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
    setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const outer_key = try js.runtime.internAtom("__nativeFenceInterruptOuter");
    defer js.runtime.atoms.free(outer_key);
    const caught_key = try js.runtime.internAtom("__nativeFenceInterruptCaught");
    defer js.runtime.atoms.free(caught_key);
    const outer = try global.getProperty(outer_key);
    defer outer.free(js.runtime);

    const baseline_call_depth = js.runtime.hot.call_depth;
    const baseline_native_depth = js.runtime.hot.native_call_depth;
    const baseline_stack_bytes = js.runtime.hot.active_bytecode_stack_bytes;
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
    defer caught.free(js.runtime);
    try std.testing.expectEqual(false, caught.asBool().?);
    try std.testing.expect(js.runtime.active_invocation == null);
    try std.testing.expect(js.runtime.hot.current_backtrace_frame == null);
    try std.testing.expectEqual(baseline_call_depth, js.runtime.hot.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.hot.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.hot.active_bytecode_stack_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());

    const exception = js.context.takeException();
    exception.free(js.runtime);
    try std.testing.expect(!js.context.exceptionIsUncatchable());
}

test "Function and Reflect apply opt into the active Machine explicitly" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const setup = try js.eval(
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
    setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const outer_key = try js.runtime.internAtom("__nativeApplyOuter");
    defer js.runtime.atoms.free(outer_key);
    const outer = try global.getProperty(outer_key);
    defer outer.free(js.runtime);

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
    defer result.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 18), result.asInt32());

    const metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 1), metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 5), metrics.same_machine_sync_calls);
    try std.testing.expectEqual(@as(usize, 1), metrics.entry_chunk_allocations);
    try std.testing.expect(js.runtime.active_invocation == null);
    try std.testing.expect(js.runtime.hot.current_backtrace_frame == null);
}

test "synchronous apply fallbacks restore the outer active invocation" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const setup = try js.eval(
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
    setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const outer_key = try js.runtime.internAtom("__nativeApplyFallbackOuter");
    defer js.runtime.atoms.free(outer_key);
    const outer = try global.getProperty(outer_key);
    defer outer.free(js.runtime);

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
    defer result.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 42), result.asInt32());

    const metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 2), metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 1), metrics.same_machine_sync_calls);
    try std.testing.expect(js.runtime.active_invocation == null);
    try std.testing.expect(js.runtime.hot.current_backtrace_frame == null);
}

test "ordinary spread calls enter eligible bytecode targets on the current Machine" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    try js.ensureTest262GlobalsInstalled();

    const setup = try js.eval(
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
    setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const outer_key = try js.runtime.internAtom("__spreadCallOuter");
    defer js.runtime.atoms.free(outer_key);
    const outer = try global.getProperty(outer_key);
    defer outer.free(js.runtime);

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
    defer result.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 42), result.asInt32());

    const metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 2), metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 1), metrics.entry_chunk_allocations);
    try std.testing.expect(js.runtime.active_invocation == null);
    try std.testing.expect(js.runtime.hot.current_backtrace_frame == null);
}

test "publish-time simple-ctor gate keeps prototype-miss and non-simple fallbacks" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    // Both S and NS run the true constructor body. Replacing S.prototype with
    // a non-object still falls back to Object.prototype (qjs js_create_from_ctor).
    // NS honors a replaced prototype object.
    const setup = try js.eval(
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
    setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const result_key = try js.runtime.internAtom("__ctor_gate_result");
    defer js.runtime.atoms.free(result_key);
    const result = try global.getProperty(result_key);
    defer result.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 1), result.asInt32());
}

test "constructor allocation profile reserves capacity without skipping the body" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const setup = try js.eval(
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
    setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const result_key = try js.runtime.internAtom("__alloc_profile");
    defer js.runtime.atoms.free(result_key);
    const result = try global.getProperty(result_key);
    defer result.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 1), result.asInt32());
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
    const setup = try js.eval(
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
    setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const total_key = try js.runtime.internAtom("__ctor_fusion_total");
    defer js.runtime.atoms.free(total_key);
    const total = try global.getProperty(total_key);
    defer total.free(js.runtime);
    // Keep: 0+1+2 = 3, Override: 1+2+3 = 6, Abrupt catch: 3, Derived: 3.
    try std.testing.expectEqual(@as(?i32, 15), total.asInt32());
}

test "constructor spread preserves new target on the current Machine" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    try js.ensureTest262GlobalsInstalled();

    const setup = try js.eval(
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
    setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const base_key = try js.runtime.internAtom("__spreadBaseConstructor");
    defer js.runtime.atoms.free(base_key);
    const base_constructor = try global.getProperty(base_key);
    defer base_constructor.free(js.runtime);
    const derived_key = try js.runtime.internAtom("__spreadDerivedConstructor");
    defer js.runtime.atoms.free(derived_key);
    const derived_constructor = try global.getProperty(derived_key);
    defer derived_constructor.free(js.runtime);
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
    defer js.runtime.atoms.free(ordinary_outer_key);
    const ordinary_outer = try global.getProperty(ordinary_outer_key);
    defer ordinary_outer.free(js.runtime);

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
    defer ordinary_result.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 20), ordinary_result.asInt32());
    try std.testing.expectEqual(@as(usize, 1), inline_calls.machineTestMetrics().machine_inits);

    const derived_outer_key = try js.runtime.internAtom("__spreadDerivedConstructorOuter");
    defer js.runtime.atoms.free(derived_outer_key);
    const derived_outer = try global.getProperty(derived_outer_key);
    defer derived_outer.free(js.runtime);

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
    defer derived_result.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 21), derived_result.asInt32());
    const derived_metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 1), derived_metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 1), derived_metrics.entry_chunk_allocations);
    try std.testing.expect(js.runtime.active_invocation == null);
    try std.testing.expect(js.runtime.hot.current_backtrace_frame == null);

    const foreign_outer_key = try js.runtime.internAtom("__spreadConstructorForeignOuter");
    defer js.runtime.atoms.free(foreign_outer_key);
    const foreign_outer = try global.getProperty(foreign_outer_key);
    defer foreign_outer.free(js.runtime);

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
    defer foreign_result.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 42), foreign_result.asInt32());
    try std.testing.expectEqual(@as(usize, 2), inline_calls.machineTestMetrics().machine_inits);
}

test "Array and TypedArray synchronous callback cohort stays on one Machine" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    try js.ensureTest262GlobalsInstalled();

    const setup = try js.eval(
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
    setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const outer_key = try js.runtime.internAtom("__arrayCallbackCohortOuter");
    defer js.runtime.atoms.free(outer_key);
    const outer = try global.getProperty(outer_key);
    defer outer.free(js.runtime);

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
    defer result.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 42), result.asInt32());

    const metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 1), metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 42), metrics.same_machine_sync_calls);
    try std.testing.expectEqual(@as(usize, 1), metrics.entry_chunk_allocations);
    try std.testing.expect(js.runtime.active_invocation == null);
    try std.testing.expect(js.runtime.hot.current_backtrace_frame == null);
}

test "Map and Set synchronous callback cohort stays on one Machine" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    try js.ensureTest262GlobalsInstalled();

    const setup = try js.eval(
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
    setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const outer_key = try js.runtime.internAtom("__collectionCallbackCohortOuter");
    defer js.runtime.atoms.free(outer_key);
    const outer = try global.getProperty(outer_key);
    defer outer.free(js.runtime);

    const baseline_call_depth = js.runtime.hot.call_depth;
    const baseline_native_depth = js.runtime.hot.native_call_depth;
    const baseline_stack_bytes = js.runtime.hot.active_bytecode_stack_bytes;
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
    defer result.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 42), result.asInt32());

    const metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 1), metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 18), metrics.same_machine_sync_calls);
    try std.testing.expectEqual(@as(usize, 1), metrics.entry_chunk_allocations);
    try std.testing.expectEqual(baseline_call_depth, js.runtime.hot.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.hot.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.hot.active_bytecode_stack_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
    try std.testing.expect(js.runtime.active_invocation == null);
    try std.testing.expect(js.runtime.hot.current_backtrace_frame == null);

    const interrupt_key = try js.runtime.internAtom("__collectionCallbackInterrupt");
    defer js.runtime.atoms.free(interrupt_key);
    const interrupt_function = try global.getProperty(interrupt_key);
    defer interrupt_function.free(js.runtime);
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
    try std.testing.expectEqual(baseline_call_depth, js.runtime.hot.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.hot.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.hot.active_bytecode_stack_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
    try std.testing.expect(js.runtime.active_invocation == null);
    try std.testing.expect(js.runtime.hot.current_backtrace_frame == null);
    const interrupt_exception = js.context.takeException();
    interrupt_exception.free(js.runtime);

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
    defer recovered.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 42), recovered.asInt32());
}

test "accessors Proxy traps and primitive coercion stay on the active Machine" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    try js.ensureTest262GlobalsInstalled();

    const setup = try js.eval(
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
    setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const outer_key = try js.runtime.internAtom("__propertyCallbackCohortOuter");
    defer js.runtime.atoms.free(outer_key);
    const outer = try global.getProperty(outer_key);
    defer outer.free(js.runtime);

    const baseline_call_depth = js.runtime.hot.call_depth;
    const baseline_native_depth = js.runtime.hot.native_call_depth;
    const baseline_stack_bytes = js.runtime.hot.active_bytecode_stack_bytes;
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
    defer result.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 42), result.asInt32());

    const metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 1), metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 21), metrics.same_machine_sync_calls);
    try std.testing.expectEqual(@as(usize, 1), metrics.entry_chunk_allocations);
    try std.testing.expectEqual(baseline_call_depth, js.runtime.hot.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.hot.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.hot.active_bytecode_stack_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
    try std.testing.expect(js.runtime.active_invocation == null);
    try std.testing.expect(js.runtime.hot.current_backtrace_frame == null);

    const foreign_key = try js.runtime.internAtom("__propertyCallbackForeignOuter");
    defer js.runtime.atoms.free(foreign_key);
    const foreign = try global.getProperty(foreign_key);
    defer foreign.free(js.runtime);
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
    defer foreign_result.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 42), foreign_result.asInt32());
    const foreign_metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 2), foreign_metrics.machine_inits);
    // The local plain accessor is already emitted as a direct VM
    // InlineCallRequest; only the foreign accessor needs a fresh root.
    try std.testing.expectEqual(@as(usize, 0), foreign_metrics.same_machine_sync_calls);
    try std.testing.expect(js.runtime.active_invocation == null);
    try std.testing.expect(js.runtime.hot.current_backtrace_frame == null);

    const interrupt_key = try js.runtime.internAtom("__propertyCallbackInterrupt");
    defer js.runtime.atoms.free(interrupt_key);
    const interrupt_function = try global.getProperty(interrupt_key);
    defer interrupt_function.free(js.runtime);
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
    try std.testing.expectEqual(baseline_call_depth, js.runtime.hot.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.hot.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.hot.active_bytecode_stack_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
    try std.testing.expect(js.runtime.active_invocation == null);
    try std.testing.expect(js.runtime.hot.current_backtrace_frame == null);
    const interrupt_exception = js.context.takeException();
    interrupt_exception.free(js.runtime);

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
    defer recovered.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 42), recovered.asInt32());
}

test "JSON synchronous callback cohort stays on one Machine" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    try js.ensureTest262GlobalsInstalled();

    const setup = try js.eval(
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
    setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const outer_key = try js.runtime.internAtom("__jsonCallbackCohortOuter");
    defer js.runtime.atoms.free(outer_key);
    const outer = try global.getProperty(outer_key);
    defer outer.free(js.runtime);

    const baseline_call_depth = js.runtime.hot.call_depth;
    const baseline_native_depth = js.runtime.hot.native_call_depth;
    const baseline_stack_bytes = js.runtime.hot.active_bytecode_stack_bytes;
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
    defer result.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 42), result.asInt32());

    const metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 1), metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 15), metrics.same_machine_sync_calls);
    try std.testing.expectEqual(@as(usize, 1), metrics.entry_chunk_allocations);
    try std.testing.expectEqual(baseline_call_depth, js.runtime.hot.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.hot.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.hot.active_bytecode_stack_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
    try std.testing.expect(js.runtime.active_invocation == null);
    try std.testing.expect(js.runtime.hot.current_backtrace_frame == null);

    const foreign_key = try js.runtime.internAtom("__jsonCallbackForeignOuter");
    defer js.runtime.atoms.free(foreign_key);
    const foreign = try global.getProperty(foreign_key);
    defer foreign.free(js.runtime);
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
    defer foreign_result.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 20), foreign_result.asInt32());
    const foreign_metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 2), foreign_metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 0), foreign_metrics.same_machine_sync_calls);
    try std.testing.expect(js.runtime.active_invocation == null);
    try std.testing.expect(js.runtime.hot.current_backtrace_frame == null);

    const interrupt_key = try js.runtime.internAtom("__jsonCallbackInterrupt");
    defer js.runtime.atoms.free(interrupt_key);
    const interrupt_function = try global.getProperty(interrupt_key);
    defer interrupt_function.free(js.runtime);
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
    try std.testing.expectEqual(baseline_call_depth, js.runtime.hot.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.hot.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.hot.active_bytecode_stack_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
    try std.testing.expect(js.runtime.active_invocation == null);
    try std.testing.expect(js.runtime.hot.current_backtrace_frame == null);
    const interrupt_exception = js.context.takeException();
    interrupt_exception.free(js.runtime);

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
    defer recovered.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 42), recovered.asInt32());
}

test "string regexp iterator helpers and DisposableStack stay on one Machine" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    try js.ensureTest262GlobalsInstalled();

    const setup = try js.eval(
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
    setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const outer_key = try js.runtime.internAtom("__cohortFiveOuter");
    defer js.runtime.atoms.free(outer_key);
    const outer = try global.getProperty(outer_key);
    defer outer.free(js.runtime);

    const baseline_call_depth = js.runtime.hot.call_depth;
    const baseline_native_depth = js.runtime.hot.native_call_depth;
    const baseline_stack_bytes = js.runtime.hot.active_bytecode_stack_bytes;
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
    defer result.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 42), result.asInt32());

    const metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 1), metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 29), metrics.same_machine_sync_calls);
    try std.testing.expectEqual(@as(usize, 1), metrics.entry_chunk_allocations);
    try std.testing.expectEqual(baseline_call_depth, js.runtime.hot.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.hot.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.hot.active_bytecode_stack_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
    try std.testing.expect(js.runtime.active_invocation == null);
    try std.testing.expect(js.runtime.hot.current_backtrace_frame == null);

    const foreign_key = try js.runtime.internAtom("__cohortFiveForeignOuter");
    defer js.runtime.atoms.free(foreign_key);
    const foreign = try global.getProperty(foreign_key);
    defer foreign.free(js.runtime);
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
    defer foreign_result.free(js.runtime);
    try helpers.expectStringValueBytes(foreign_result, "ab");
    const foreign_metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 2), foreign_metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 1), foreign_metrics.same_machine_sync_calls);
    try std.testing.expect(js.runtime.active_invocation == null);
    try std.testing.expect(js.runtime.hot.current_backtrace_frame == null);

    const interrupt_key = try js.runtime.internAtom("__cohortFiveInterrupt");
    defer js.runtime.atoms.free(interrupt_key);
    const interrupt_function = try global.getProperty(interrupt_key);
    defer interrupt_function.free(js.runtime);
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
    try std.testing.expectEqual(baseline_call_depth, js.runtime.hot.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.hot.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.hot.active_bytecode_stack_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
    try std.testing.expect(js.runtime.active_invocation == null);
    try std.testing.expect(js.runtime.hot.current_backtrace_frame == null);
    const interrupt_exception = js.context.takeException();
    interrupt_exception.free(js.runtime);

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
    defer recovered.free(js.runtime);
    try helpers.expectStringValueBytes(recovered, "42");
}

test "Promise executor reuses the active Machine while reactions remain roots" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    try js.ensureTest262GlobalsInstalled();

    const setup = try js.eval(
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
    setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const outer_key = try js.runtime.internAtom("__promiseExecutorOuter");
    defer js.runtime.atoms.free(outer_key);
    const outer = try global.getProperty(outer_key);
    defer outer.free(js.runtime);

    const baseline_call_depth = js.runtime.hot.call_depth;
    const baseline_native_depth = js.runtime.hot.native_call_depth;
    const baseline_stack_bytes = js.runtime.hot.active_bytecode_stack_bytes;
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
    defer result.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 42), result.asInt32());

    const executor_metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 1), executor_metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 6), executor_metrics.same_machine_sync_calls);
    try std.testing.expectEqual(@as(usize, 1), executor_metrics.entry_chunk_allocations);
    try std.testing.expectEqual(baseline_call_depth, js.runtime.hot.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.hot.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.hot.active_bytecode_stack_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
    try std.testing.expect(js.runtime.active_invocation == null);
    try std.testing.expect(js.runtime.hot.current_backtrace_frame == null);

    try js.runJobs();
    const reaction_metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 3), reaction_metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 6), reaction_metrics.same_machine_sync_calls);
    try std.testing.expect(js.runtime.active_invocation == null);
    try std.testing.expect(js.runtime.hot.current_backtrace_frame == null);

    const reaction_value_key = try js.runtime.internAtom("__promiseExecutorReactionValue");
    defer js.runtime.atoms.free(reaction_value_key);
    const reaction_value = try global.getProperty(reaction_value_key);
    defer reaction_value.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 42), reaction_value.asInt32());
    const order_key = try js.runtime.internAtom("__promiseExecutorJobOrder");
    defer js.runtime.atoms.free(order_key);
    const order = try global.getProperty(order_key);
    defer order.free(js.runtime);
    try helpers.expectStringValueBytes(order, "throw,outer,success-job,reject-job");

    const foreign_key = try js.runtime.internAtom("__promiseExecutorForeignOuter");
    defer js.runtime.atoms.free(foreign_key);
    const foreign = try global.getProperty(foreign_key);
    defer foreign.free(js.runtime);
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
    defer foreign_result.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 42), foreign_result.asInt32());
    const foreign_metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 2), foreign_metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 1), foreign_metrics.same_machine_sync_calls);
    try std.testing.expect(js.runtime.active_invocation == null);
    try std.testing.expect(js.runtime.hot.current_backtrace_frame == null);

    const interrupt_key = try js.runtime.internAtom("__promiseExecutorInterrupt");
    defer js.runtime.atoms.free(interrupt_key);
    const interrupt_function = try global.getProperty(interrupt_key);
    defer interrupt_function.free(js.runtime);
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
    defer interrupted_executor_result.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 42), interrupted_executor_result.asInt32());
    try std.testing.expectEqual(@as(usize, 1), interrupt_state.hits);
    try std.testing.expectEqual(baseline_call_depth, js.runtime.hot.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.hot.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.hot.active_bytecode_stack_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
    try std.testing.expect(js.runtime.active_invocation == null);
    try std.testing.expect(js.runtime.hot.current_backtrace_frame == null);
    try std.testing.expect(!js.context.hasException());

    js.runtime.setInterruptHandler(null, null);
    try js.runJobs();
    const interrupt_metrics = inline_calls.machineTestMetrics();
    try std.testing.expectEqual(@as(usize, 2), interrupt_metrics.machine_inits);
    try std.testing.expectEqual(@as(usize, 1), interrupt_metrics.same_machine_sync_calls);
    const interrupt_reason_key = try js.runtime.internAtom("__promiseExecutorInterruptReason");
    defer js.runtime.atoms.free(interrupt_reason_key);
    const interrupt_reason = try global.getProperty(interrupt_reason_key);
    defer interrupt_reason.free(js.runtime);
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
    defer recovered.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 42), recovered.asInt32());
}

test "nested calls and generator resumes share one Realm interrupt cadence" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const setup = try js.eval(
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
    setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const outer_key = try js.runtime.internAtom("__w2_outer");
    defer js.runtime.atoms.free(outer_key);
    const numeric_branch_key = try js.runtime.internAtom("__w2_numeric_branch");
    defer js.runtime.atoms.free(numeric_branch_key);
    const constructor_key = try js.runtime.internAtom("__w2_constructor");
    defer js.runtime.atoms.free(constructor_key);
    const forward_wrapper_key = try js.runtime.internAtom("__w2_forward_wrapper");
    defer js.runtime.atoms.free(forward_wrapper_key);
    const async_key = try js.runtime.internAtom("__w2_async");
    defer js.runtime.atoms.free(async_key);
    const generator_key = try js.runtime.internAtom("__w2_generator");
    defer js.runtime.atoms.free(generator_key);
    const next_key = try js.runtime.internAtom("next");
    defer js.runtime.atoms.free(next_key);

    const outer = try global.getProperty(outer_key);
    defer outer.free(js.runtime);
    const numeric_branch = try global.getProperty(numeric_branch_key);
    defer numeric_branch.free(js.runtime);
    const constructor = try global.getProperty(constructor_key);
    defer constructor.free(js.runtime);
    const forward_wrapper = try global.getProperty(forward_wrapper_key);
    defer forward_wrapper.free(js.runtime);
    const async_function = try global.getProperty(async_key);
    defer async_function.free(js.runtime);
    const generator = try global.getProperty(generator_key);
    defer generator.free(js.runtime);
    const generator_object = try core.Object.expect(generator);
    const next = try generator_object.getProperty(next_key);
    defer next.free(js.runtime);

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
    defer nested_result.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 7), nested_result.asInt32());
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
    defer branch_result.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 11), branch_result.asInt32());
    try std.testing.expectEqual(@as(usize, 2), state.hits);
    try std.testing.expectEqual(core.JSContext.interrupt_counter_reset, js.context.interrupt_counter);

    // Bytecode construction has one JS_CallConstructorInternal poll and one
    // JS_CallInternal poll, including the simple-field constructor fast path.
    js.context.interrupt_counter = 2;
    const constructed = try engine.exec.call_runtime.constructValueOrBytecode(
        js.context,
        null,
        global,
        constructor,
        &.{core.JSValue.int32(23)},
        null,
        null,
    );
    defer constructed.free(js.runtime);
    try std.testing.expectEqual(@as(usize, 3), state.hits);
    try std.testing.expectEqual(core.JSContext.interrupt_counter_reset, js.context.interrupt_counter);

    // The same-Machine Function.prototype.call fast path fuses an outer native
    // call and an inner target call, but both entries still consume the budget.
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
    defer forwarded_result.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 13), forwarded_result.asInt32());
    try std.testing.expectEqual(@as(usize, 4), state.hits);
    try std.testing.expectEqual(core.JSContext.interrupt_counter_reset, js.context.interrupt_counter);

    // Initial async invocation pays the outer JS_CallInternal entry, one
    // async_func_resume entry, and the resolving-function call used to settle
    // its Promise. async_func_init only prepares the resident frame; charging
    // it as a fourth entry would fire this counter.
    js.context.interrupt_counter = 4;
    const async_promise = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        async_function,
        &.{},
        null,
        null,
    );
    defer async_promise.free(js.runtime);
    try std.testing.expectEqual(@as(usize, 4), state.hits);
    try std.testing.expectEqual(@as(i32, 1), js.context.interrupt_counter);

    // Generator.next has one native call entry and one bytecode-resume entry.
    // The second next creates another Machine but continues the same counter.
    js.context.interrupt_counter = 3;
    const first = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        generator,
        next,
        &.{},
        null,
        null,
    );
    first.free(js.runtime);
    try std.testing.expectEqual(@as(usize, 4), state.hits);
    try std.testing.expectEqual(@as(i32, 1), js.context.interrupt_counter);

    const second = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        generator,
        next,
        &.{},
        null,
        null,
    );
    second.free(js.runtime);
    try std.testing.expectEqual(@as(usize, 5), state.hits);
    // The resumed body reaches its next yield through one additional jump poll.
    try std.testing.expectEqual(core.JSContext.interrupt_counter_reset - 2, js.context.interrupt_counter);
}

test "initial async resume rejects with the caller-Realm interrupt exception" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var parent_facade = zjs.JSContext.borrowCore(js.context);
    const parent_global = try parent_facade.globalObject();
    const child_holder = try engine.exec.call.createRealmObject(js.context);
    defer child_holder.free(js.runtime);
    const child_record = try core.Object.expect(child_holder);
    const child = child_record.realmContext() orelse return error.TestUnexpectedResult;
    const child_global = try engine.exec.zjs_vm.contextGlobal(child);

    var child_facade = zjs.JSContext.borrowCore(child);
    const setup = try child_facade.eval(
        "globalThis.__w2_async_interrupt = async function () { return 17; };",
        .{},
    );
    setup.free(js.runtime);

    const function_key = try js.runtime.internAtom("__w2_async_interrupt");
    defer js.runtime.atoms.free(function_key);
    const async_function = try child_global.getProperty(function_key);
    defer async_function.free(js.runtime);

    const baseline_call_depth = js.runtime.hot.call_depth;
    const baseline_native_depth = js.runtime.hot.native_call_depth;
    const baseline_stack_bytes = js.runtime.hot.active_bytecode_stack_bytes;
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
    defer promise_value.free(js.runtime);
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
    defer name.free(js.runtime);
    try helpers.expectStringValueBytes(name, "InternalError");
    const message_key = try js.runtime.internAtom("message");
    defer js.runtime.atoms.free(message_key);
    const message = try reason_object.getProperty(message_key);
    defer message.free(js.runtime);
    try helpers.expectStringValueBytes(message, "interrupted");

    try std.testing.expectEqual(@as(usize, 1), state.hits);
    try std.testing.expect(!js.context.hasException());
    try std.testing.expect(!js.context.exceptionIsUncatchable());
    try std.testing.expectEqual(baseline_call_depth, js.runtime.hot.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.hot.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.hot.active_bytecode_stack_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
}

test "cross-Realm interrupt polls charge caller entry and callee body separately" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var parent_facade = zjs.JSContext.borrowCore(js.context);
    const parent_global = try parent_facade.globalObject();
    const child_holder = try engine.exec.call.createRealmObject(js.context);
    defer child_holder.free(js.runtime);
    const child_record = try core.Object.expect(child_holder);
    const child = child_record.realmContext() orelse return error.TestUnexpectedResult;
    const child_global = try engine.exec.zjs_vm.contextGlobal(child);

    var child_facade = zjs.JSContext.borrowCore(child);
    const setup = try child_facade.eval(
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
    setup.free(js.runtime);

    const foreign_key = try js.runtime.internAtom("__w2_foreign");
    defer js.runtime.atoms.free(foreign_key);
    const body_key = try js.runtime.internAtom("__w2_body_ran");
    defer js.runtime.atoms.free(body_key);
    const stack_foreign_key = try js.runtime.internAtom("__w2_stack_foreign");
    defer js.runtime.atoms.free(stack_foreign_key);
    const stack_body_key = try js.runtime.internAtom("__w2_stack_body_ran");
    defer js.runtime.atoms.free(stack_body_key);
    const foreign = try child_global.getProperty(foreign_key);
    defer foreign.free(js.runtime);
    const stack_foreign = try child_global.getProperty(stack_foreign_key);
    defer stack_foreign.free(js.runtime);

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
    defer before_body.free(js.runtime);
    try std.testing.expectEqual(false, before_body.asBool().?);

    const caller_exception = js.context.takeException();
    defer caller_exception.free(js.runtime);
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
    defer after_body.free(js.runtime);
    try std.testing.expectEqual(true, after_body.asBool().?);

    const callee_exception = child.takeException();
    defer callee_exception.free(js.runtime);
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
    defer stack_body_before.free(js.runtime);
    try std.testing.expectEqual(false, stack_body_before.asBool().?);
    const stack_exception = js.context.takeException();
    defer stack_exception.free(js.runtime);
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
    defer precedence_exception.free(js.runtime);
    const precedence_error = try core.Object.expect(precedence_exception);
    try std.testing.expectEqual(caller_internal_error, precedence_error.getPrototype().?);
    try std.testing.expectEqual(@as(usize, 3), state.hits);
}

test "tail-frame reuse charges planned stack bytes and fully restores both budgets" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    js.runtime.setNativeStackSize(128 * 1024);

    const baseline_call_depth = js.runtime.hot.call_depth;
    const baseline_native_depth = js.runtime.hot.native_call_depth;
    const baseline_tail_bytes = js.runtime.hot.active_bytecode_stack_bytes;

    const setup = try js.eval(
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
    setup.free(js.runtime);

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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
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
    try std.testing.expectEqual(baseline_call_depth, js.runtime.hot.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.hot.native_call_depth);
    try std.testing.expectEqual(baseline_tail_bytes, js.runtime.hot.active_bytecode_stack_bytes);
}

test "tail target setup OOM remains catchable in the retiring caller" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    defer js.runtime.setMemoryLimit(null);

    var arm = TailSetupOomArm{};
    try js.defineGlobalExternalHostFunction(
        "__w2ArmTailSetupOom",
        0,
        &arm,
        TailSetupOomArm.call,
        null,
    );
    const setup = try js.eval(
        \\globalThis.__w2TailSetupBodyRuns = 0;
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
        \\        return error.name === "InternalError" &&
        \\            error.message === "out of memory" ? 100 : -1000;
        \\    }
        \\}
    );
    setup.free(js.runtime);

    const forward_fb = try globalFunctionBytecode(&js, "__w2TailSetupOomForward");
    const target_fb = try globalFunctionBytecode(&js, "__w2TailSetupOomTarget");
    try std.testing.expect(hasTailEvalReturn(forward_fb));
    try std.testing.expect(target_fb.isStrictMode());
    try std.testing.expect(frame_mod.argumentsNeedsOriginalSnapshot(target_fb));

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const body_runs_key = try js.runtime.internAtom("__w2TailSetupBodyRuns");
    defer js.runtime.atoms.free(body_runs_key);
    const driver_key = try js.runtime.internAtom("__w2TailSetupOomDriver");
    defer js.runtime.atoms.free(driver_key);
    const driver = try global.getProperty(driver_key);
    defer driver.free(js.runtime);

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
    defer warm.free(js.runtime);
    try std.testing.expectEqual(@as(?f64, 42), warm.asNumber());

    const body_runs_before = try global.getProperty(body_runs_key);
    defer body_runs_before.free(js.runtime);
    try std.testing.expectEqual(@as(?f64, 1), body_runs_before.asNumber());

    const baseline_call_depth = js.runtime.hot.call_depth;
    const baseline_native_depth = js.runtime.hot.native_call_depth;
    const baseline_tail_bytes = js.runtime.hot.active_bytecode_stack_bytes;
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
    js.runtime.setMemoryLimit(null);
    arm.exhaust = false;
    defer caught.free(js.runtime);
    try std.testing.expectEqual(@as(?f64, 100), caught.asNumber());
    try std.testing.expectEqual(@as(usize, 2), arm.calls);
    try std.testing.expect(!js.context.hasException());
    const body_runs_after_oom = try global.getProperty(body_runs_key);
    defer body_runs_after_oom.free(js.runtime);
    try std.testing.expectEqual(@as(?f64, 1), body_runs_after_oom.asNumber());
    try std.testing.expectEqual(baseline_call_depth, js.runtime.hot.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.hot.native_call_depth);
    try std.testing.expectEqual(baseline_tail_bytes, js.runtime.hot.active_bytecode_stack_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
    const stable_allocated_bytes = js.runtime.memory.allocated_bytes;
    const stable_allocation_count = js.runtime.memory.allocation_count;

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
    js.runtime.setMemoryLimit(null);
    arm.exhaust = false;
    defer caught_again.free(js.runtime);
    try std.testing.expectEqual(@as(?f64, 100), caught_again.asNumber());
    try std.testing.expectEqual(@as(usize, 3), arm.calls);
    try std.testing.expect(!js.context.hasException());
    const body_runs_after_second_oom = try global.getProperty(body_runs_key);
    defer body_runs_after_second_oom.free(js.runtime);
    try std.testing.expectEqual(@as(?f64, 1), body_runs_after_second_oom.asNumber());
    try std.testing.expectEqual(baseline_call_depth, js.runtime.hot.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.hot.native_call_depth);
    try std.testing.expectEqual(baseline_tail_bytes, js.runtime.hot.active_bytecode_stack_bytes);
    try std.testing.expectEqual(stable_allocated_bytes, js.runtime.memory.allocated_bytes);
    try std.testing.expectEqual(stable_allocation_count, js.runtime.memory.allocation_count);
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
    defer recovered.free(js.runtime);
    try std.testing.expectEqual(@as(?f64, 42), recovered.asNumber());
    try std.testing.expectEqual(@as(usize, 4), arm.calls);
    const body_runs_after_recovery = try global.getProperty(body_runs_key);
    defer body_runs_after_recovery.free(js.runtime);
    try std.testing.expectEqual(@as(?f64, 2), body_runs_after_recovery.asNumber());
    try std.testing.expectEqual(baseline_call_depth, js.runtime.hot.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.hot.native_call_depth);
    try std.testing.expectEqual(baseline_tail_bytes, js.runtime.hot.active_bytecode_stack_bytes);
    try std.testing.expectEqual(stable_allocated_bytes, js.runtime.memory.allocated_bytes);
    try std.testing.expectEqual(stable_allocation_count, js.runtime.memory.allocation_count);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
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
    defer plain.free(js.runtime);
    const method = try createTailOpcodeFixture(&js, "__w2RawMethodTail", &method_code, 2);
    defer method.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const plain_key = try js.runtime.internAtom("__w2RawTail");
    defer js.runtime.atoms.free(plain_key);
    const method_key = try js.runtime.internAtom("__w2RawMethodTail");
    defer js.runtime.atoms.free(method_key);
    try global.defineOwnProperty(
        js.runtime,
        plain_key,
        core.Descriptor.data(plain, true, true, true),
    );
    try global.defineOwnProperty(
        js.runtime,
        method_key,
        core.Descriptor.data(method, true, true, true),
    );

    const baseline_call_depth = js.runtime.hot.call_depth;
    const baseline_native_depth = js.runtime.hot.native_call_depth;
    const baseline_tail_bytes = js.runtime.hot.active_bytecode_stack_bytes;
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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "plain:InternalError:stack overflow\n" ++
            "method:InternalError:stack overflow\n" ++
            "recovered:42\n",
        stream.buffered(),
    );
    try std.testing.expectEqual(baseline_call_depth, js.runtime.hot.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.hot.native_call_depth);
    try std.testing.expectEqual(baseline_tail_bytes, js.runtime.hot.active_bytecode_stack_bytes);
}

const CrossRealmNativeProbe = struct {
    seen_realm: ?*core.RealmContext = null,
    seen_global: ?*core.Object = null,
};

fn crossRealmNativeProbe(ptr: *anyopaque, call: core.host_function.ExternalCall) anyerror!core.JSValue {
    const probe: *CrossRealmNativeProbe = @ptrCast(@alignCast(ptr));
    const global = call.realm.global orelse return error.InvalidBuiltinRegistry;
    probe.seen_realm = call.realm;
    probe.seen_global = global;

    const key = try call.realm.runtime.internAtom("__native_realm_mutation");
    defer call.realm.runtime.atoms.free(key);
    try global.defineOwnProperty(
        call.realm.runtime,
        key,
        core.Descriptor.data(core.JSValue.int32(1), true, true, true),
    );
    return error.TypeError;
}

fn localIndexNamed(rt: *core.JSRuntime, function: *const bytecode.FunctionBytecode, name: []const u8) ?usize {
    for (function.varDefs(), 0..) |vd, idx| {
        const bytes = rt.atoms.name(vd.var_name) orelse continue;
        if (std.mem.eql(u8, bytes, name)) return idx;
    }
    return null;
}

fn derivedThisLocalIndex(function: *const bytecode.FunctionBytecode) ?usize {
    for (function.varDefs(), 0..) |vd, idx| {
        if (vd.var_name == core.atom.ids.this_) return idx;
    }
    return null;
}

fn globalFunctionBytecode(js: *helpers.TestEngine, name: []const u8) !*const bytecode.FunctionBytecode {
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const name_atom = try js.runtime.internAtom(name);
    defer js.runtime.atoms.free(name_atom);
    const function_value = try global.getProperty(name_atom);
    defer function_value.free(js.runtime);
    const function_object = try property_ops.expectObject(function_value);
    const stored_bytecode = function_object.functionBytecode() orelse return error.InvalidFunctionBytecode;
    return engine.exec.call_runtime.functionBytecodeFromValue(stored_bytecode) orelse error.InvalidFunctionBytecode;
}

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

fn createTailOpcodeFixture(
    js: *helpers.TestEngine,
    name_bytes: []const u8,
    code: []const u8,
    stack_size: u16,
) !core.JSValue {
    const name = try js.runtime.internAtom(name_bytes);
    defer js.runtime.atoms.free(name);
    const fb = try bytecode.FunctionBytecode.createFixture(js.runtime, .{
        .name = name,
        .realm = js.context,
        .flags = .{
            .has_simple_parameter_list = true,
            .func_kind = .normal,
        },
        .stack_size = stack_size,
        .byte_code = code,
    });
    fb.publishFixtureNoFail(js.runtime);
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    return object_ops.createRootBytecodeFunctionObject(
        js.context,
        global,
        core.JSValue.functionBytecode(&fb.header),
        .root_global,
    );
}

fn finalOpcodeCount(code: []const u8, wanted: u8) !usize {
    var count: usize = 0;
    var pc: usize = 0;
    while (pc < code.len) {
        const op_id = code[pc];
        const size = bytecode.opcode.sizeOf(op_id);
        if (size == 0 or pc + size > code.len) return error.InvalidFunctionBytecode;
        if (op_id == wanted) count += 1;
        pc += size;
    }
    return count;
}

const SetVarRefStats = struct {
    count: usize = 0,
    first_idx: ?u16 = null,
};

fn finalSetVarRefStats(code: []const u8) !SetVarRefStats {
    var stats: SetVarRefStats = .{};
    var pc: usize = 0;
    while (pc < code.len) {
        const op_id = code[pc];
        const size = bytecode.opcode.sizeOf(op_id);
        if (size == 0 or pc + size > code.len) return error.InvalidFunctionBytecode;
        const idx: ?u16 = if (op_id == op.set_var_ref)
            std.mem.readInt(u16, code[pc + 1 ..][0..2], .little)
        else if (op_id >= op.set_var_ref0 and op_id <= op.set_var_ref3)
            op_id - op.set_var_ref0
        else
            null;
        if (idx) |ref_idx| {
            stats.count += 1;
            if (stats.first_idx == null) stats.first_idx = ref_idx;
        }
        pc += size;
    }
    return stats;
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

fn expectSingleDerivedThisClosureCapture(function: *const bytecode.FunctionBytecode) !void {
    const this_idx = derivedThisLocalIndex(function) orelse return error.InvalidFunctionBytecode;
    const this_vardef = function.varDefs()[this_idx];
    try std.testing.expect(this_vardef.isCaptured());
    try std.testing.expectEqual(@as(u16, 1), function.openVarRefCount());
    try std.testing.expectEqual(@as(u16, 0), this_vardef.var_ref_idx);
    try std.testing.expectEqual(@as(usize, 0), try finalOpcodeCount(function.byteCode(), op.close_loc));

    var capturing_function: ?*const bytecode.FunctionBytecode = null;
    var capturing_function_count: usize = 0;
    for (function.cpoolSlice()) |constant| {
        const child = engine.exec.call_runtime.functionBytecodeFromValue(constant) orelse continue;
        var captures_derived_this = false;
        for (child.closureVar()) |capture| {
            captures_derived_this = captures_derived_this or
                (capture.var_name == core.atom.ids.this_ and
                    capture.closureType() == .local and
                    capture.var_idx == @as(u16, @intCast(this_idx)));
        }
        if (!captures_derived_this) continue;
        capturing_function = child;
        capturing_function_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), capturing_function_count);

    const closure = capturing_function.?;
    try std.testing.expectEqual(function_def.FunctionKind.normal, closure.functionKind());
    try std.testing.expect(!closure.hasPrototype());

    var this_capture_count: usize = 0;
    for (closure.closureVar()) |capture| {
        if (capture.var_name != core.atom.ids.this_) continue;
        this_capture_count += 1;
        try std.testing.expectEqual(function_def.ClosureType.local, capture.closureType());
        try std.testing.expectEqual(@as(u16, @intCast(this_idx)), capture.var_idx);
    }
    try std.testing.expectEqual(@as(usize, 1), this_capture_count);
}

test "js_function_set_properties publishes configurable length then name" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const setup = try js.eval(
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
    setup.free(js.runtime);
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const key = try js.runtime.internAtom("__r11_name_ok");
    defer js.runtime.atoms.free(key);
    const result = try global.getProperty(key);
    defer result.free(js.runtime);
    try std.testing.expect(result.asInt32() == @as(?i32, 1) or result.asNumber() == @as(?f64, 1.0));
}

test "get_var_ref reuses the open cell on a second capture of the same local" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("r11-reuse-open-cell");
    defer rt.atoms.free(name);
    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    function.var_count = 1;
    function.open_var_ref_count = 1;
    function.vardefs = try rt.memory.alloc(bytecode.function_bytecode.BytecodeVarDef, 1);
    function.vardefs[0] = bytecode.function_bytecode.BytecodeVarDef.init(.{
        .var_name = core.atom.null_atom,
        .is_captured = true,
        .var_ref_idx = 0,
    });

    var locals = [_]core.JSValue{core.JSValue.int32(7)};
    var open_refs = [_]?*core.VarRef{null};
    var execution_adapter: bytecode.LegacyExecutionAdapter = undefined;
    const execution_function = execution_adapter.init(&function);
    var frame = frame_mod.Frame.init(execution_function);
    defer frame.deinit(&rt.memory, rt);
    frame.locals = &locals;
    frame.open_var_refs = &open_refs;
    frame.ownership.storage = .borrowed;

    const first = try frame.captureLocal(rt, 0);
    const second = try frame.captureLocal(rt, 0);
    defer first.freeCell(rt);
    defer second.freeCell(rt);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(first, open_refs[0].?);
}

test "js_closure2 attach roots captures through the function object" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const setup = try js.eval(
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
    setup.free(js.runtime);

    const old_threshold = js.runtime.gcThreshold();
    js.runtime.setGCThreshold(0);
    defer js.runtime.setGCThreshold(old_threshold);
    _ = js.runtime.runObjectCycleRemoval();

    const again = try js.eval("globalThis.__r11_out = globalThis.__r11_fn()");
    again.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const out_key = try js.runtime.internAtom("__r11_out");
    defer js.runtime.atoms.free(out_key);
    const total = try global.getProperty(out_key);
    defer total.free(js.runtime);
    try std.testing.expect(total.asInt32() == @as(?i32, 33) or total.asNumber() == @as(?f64, 33.0));
}

test "var-ref growth promotes borrowed captures to owned cells" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const name = try rt.internAtom("frame-borrowed-var-ref-growth-test");
    defer rt.atoms.free(name);
    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    const captured = try core.VarRef.createClosed(rt, core.JSValue.int32(41));
    defer captured.freeCell(rt);
    var captures = [_]*core.VarRef{captured};
    var execution_adapter: bytecode.LegacyExecutionAdapter = undefined;
    const execution_function = execution_adapter.init(&function);
    var exec_frame = frame_mod.Frame.init(execution_function);
    defer exec_frame.deinit(&rt.memory, rt);
    exec_frame.var_refs = &captures;
    exec_frame.ownership.var_refs = .borrowed;

    try frame_mod.ensureVarRefsCapacity(ctx, &exec_frame, 1);
    try std.testing.expectEqual(@as(usize, 2), exec_frame.var_refs.len);
    try std.testing.expectEqual(captured, exec_frame.var_refs[0]);
    try std.testing.expectEqual(frame_mod.Ownership.owned, exec_frame.ownership.var_refs);
}

test "global declaration construction rebinds duplicate carriers one slot at a time" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);

    const binding_name = try rt.internAtom("qjs-ordered-global-decl-slots");
    defer rt.atoms.free(binding_name);
    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    defer function.deinit(rt);
    function.closure_var = try rt.memory.alloc(bytecode.function_bytecode.BytecodeClosureVar, 2);
    for (function.closure_var, 0..) |*cv, idx| {
        cv.* = bytecode.function_bytecode.BytecodeClosureVar.init(.{
            .closure_type = .global_decl,
            .var_idx = @intCast(idx),
            .var_name = rt.atoms.dup(binding_name),
        });
    }

    var refs = [_]*core.VarRef{
        try core.VarRef.createClosed(rt, core.JSValue.uninitialized()),
        try core.VarRef.createClosed(rt, core.JSValue.uninitialized()),
    };
    defer {
        refs[0].freeCell(rt);
        refs[1].freeCell(rt);
    }
    const second_placeholder = refs[1];
    var execution_adapter: bytecode.LegacyExecutionAdapter = undefined;
    const execution_function = execution_adapter.init(&function);
    var frame = frame_mod.Frame.init(execution_function);
    defer frame.deinit(&rt.memory, rt);
    frame.var_refs = &refs;
    frame.ownership.var_refs = .borrowed;

    try std.testing.expect(try engine.exec.call_runtime.defineGlobalDeclVarCell(
        ctx,
        global,
        execution_function,
        &frame,
        0,
        binding_name,
        false,
        false,
    ));
    try std.testing.expect(refs[0] != refs[1]);
    try std.testing.expectEqual(second_placeholder, refs[1]);

    try std.testing.expect(try engine.exec.call_runtime.defineGlobalDeclVarCell(
        ctx,
        global,
        execution_function,
        &frame,
        1,
        binding_name,
        false,
        false,
    ));
    try std.testing.expectEqual(refs[0], refs[1]);
}

test "ordinary global closure selector preserves QuickJS cell waterfall and owner metadata" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    try js.ensureTest262GlobalsInstalled();
    const rt = js.runtime;
    const ctx = js.context;
    const global = try engine.exec.zjs_vm.contextGlobal(ctx);

    const lexical_name = try rt.internAtom("__selectorLexicalWins");
    defer rt.atoms.free(lexical_name);
    const lexical_value = try engine.exec.call_runtime.ensureGlobalLexicalCell(ctx, global, lexical_name, false);
    defer lexical_value.free(rt);
    const object_value = (try engine.exec.call_runtime.ensureGlobalObjectVarRefCell(
        ctx,
        global,
        lexical_name,
        false,
        false,
    )) orelse return error.TestExpectedEqual;
    defer object_value.free(rt);
    const lexical_selected = try engine.exec.call_runtime.selectOrdinaryGlobalClosureCell(ctx, global, lexical_name);
    defer lexical_selected.free(rt);
    try std.testing.expectEqual(core.VarRef.fromValue(lexical_value).?, core.VarRef.fromValue(lexical_selected).?);
    try std.testing.expect(core.VarRef.fromValue(object_value).? != core.VarRef.fromValue(lexical_selected).?);

    const varref_name = try rt.internAtom("__selectorGlobalVarRef");
    defer rt.atoms.free(varref_name);
    const global_varref = (try engine.exec.call_runtime.ensureGlobalObjectVarRefCell(
        ctx,
        global,
        varref_name,
        false,
        false,
    )) orelse return error.TestExpectedEqual;
    defer global_varref.free(rt);
    const global_selected = try engine.exec.call_runtime.selectOrdinaryGlobalClosureCell(ctx, global, varref_name);
    defer global_selected.free(rt);
    try std.testing.expectEqual(core.VarRef.fromValue(global_varref).?, core.VarRef.fromValue(global_selected).?);

    const data_name = try rt.internAtom("__selectorDataParks");
    defer rt.atoms.free(data_name);
    try global.defineOwnProperty(rt, data_name, core.Descriptor.data(core.JSValue.int32(41), true, true, true));
    const parked_first = try engine.exec.call_runtime.selectOrdinaryGlobalClosureCell(ctx, global, data_name);
    defer parked_first.free(rt);
    const parked_cell = core.VarRef.fromValue(parked_first) orelse return error.TestExpectedEqual;
    try std.testing.expect(parked_cell.varRefValue().isUninitialized());
    parked_cell.is_lexical = true;
    parked_cell.varRefIsConstSlot().* = true;
    parked_cell.varRefIsFunctionNameSlot().* = true;
    const parked_second = try engine.exec.call_runtime.selectOrdinaryGlobalClosureCell(ctx, global, data_name);
    defer parked_second.free(rt);
    try std.testing.expectEqual(parked_cell, core.VarRef.fromValue(parked_second).?);
    try std.testing.expect(parked_cell.is_lexical);
    try std.testing.expect(parked_cell.varRefIsConstSlot().*);
    try std.testing.expect(parked_cell.varRefIsFunctionNameSlot().*);

    const accessor_setup = try js.eval(
        \\globalThis.__selectorAccessorReads = 0;
        \\Object.defineProperty(globalThis, "__selectorAccessor", {
        \\    configurable: true,
        \\    get: function () { __selectorAccessorReads++; return 1; }
        \\});
    );
    defer accessor_setup.free(rt);
    const accessor_name = try rt.internAtom("__selectorAccessor");
    defer rt.atoms.free(accessor_name);
    const accessor_selected = try engine.exec.call_runtime.selectOrdinaryGlobalClosureCell(ctx, global, accessor_name);
    defer accessor_selected.free(rt);
    const accessor_check = try js.eval("assert.sameValue(__selectorAccessorReads, 0);");
    defer accessor_check.free(rt);

    const auto_name = try rt.internAtom("__selectorAutoInit");
    defer rt.atoms.free(auto_name);
    try global.definePerformanceAutoInitProperty(
        rt,
        auto_name,
        core.property.Flags.data(true, false, true),
        global,
    );
    const auto_index = global.findProperty(auto_name) orelse return error.TestExpectedEqual;
    try std.testing.expect(global.propFlagsAt(auto_index).isAutoInit());
    const auto_selected = try engine.exec.call_runtime.selectOrdinaryGlobalClosureCell(ctx, global, auto_name);
    defer auto_selected.free(rt);
    const materialized_index = global.findProperty(auto_name) orelse return error.TestExpectedEqual;
    try std.testing.expect(!global.propFlagsAt(materialized_index).isAutoInit());
    const auto_again = try engine.exec.call_runtime.selectOrdinaryGlobalClosureCell(ctx, global, auto_name);
    defer auto_again.free(rt);
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
    defer for (names[0..initialized]) |name| rt.atoms.free(name);
    for (&names, 0..) |*name, index| {
        var buffer: [48]u8 = undefined;
        name.* = try rt.internAtom(try std.fmt.bufPrint(&buffer, "__compact_hidden_{d}", .{index}));
        initialized += 1;
        const cell = try engine.exec.call_runtime.globalObjectGetUninitializedVar(ctx, global, name.*);
        cell.free(rt);
    }

    const hidden = global.globalUninitializedVars() orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u32, 78), hidden.shape_ref.prop_count);
    try std.testing.expectEqual(@as(u32, 0), hidden.shape_ref.deleted_prop_count);

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
            const parked = engine.exec.call_runtime.globalObjectFindUninitializedVar(ctx, global, name, false) orelse
                return error.TestExpectedEqual;
            parked.free(rt);
            const deleted = hidden.shape_ref.deleted_prop_count;
            const live = hidden.shape_ref.prop_count - deleted;
            try std.testing.expect(deleted < @max(@as(u32, 8), live + 1));
            if (deleted == 0) saw_compaction = true;
            peak_deleted = @max(peak_deleted, deleted);

            const replacement = try engine.exec.call_runtime.globalObjectGetUninitializedVar(ctx, global, name);
            replacement.free(rt);
        }
        try std.testing.expectEqual(expected.props, hidden.shape_ref.prop_count);
        try std.testing.expectEqual(expected.deleted, hidden.shape_ref.deleted_prop_count);
    }

    try std.testing.expect(saw_compaction);
    try std.testing.expectEqual(@as(u32, 75), peak_deleted);
    try std.testing.expectEqual(@as(u32, live_count), hidden.shape_ref.prop_count - hidden.shape_ref.deleted_prop_count);
    for (names) |name| try std.testing.expect(hidden.hasOwnProperty(name));
}

test "runtime-strict script still constructs its global function declaration" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [8]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileWithOutputModeStrict(
        \\function __qjsRuntimeStrictGlobalFunction() {}
        \\print(Object.prototype.hasOwnProperty.call(globalThis, "__qjsRuntimeStrictGlobalFunction"));
    , &output, .script, "runtime-strict-global-function.js", true);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\n", output.buffered());
}

test "var-ref growth rejects an owned composite frame slab" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const name = try rt.internAtom("frame-composite-var-ref-growth-test");
    defer rt.atoms.free(name);
    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    const slab = try frame_mod.FrameSlab.allocHeap(&rt.memory, 0, 0, 0, 1, 1, 0);
    slab.stack[0] = core.JSValue.undefinedValue();
    slab.var_refs[0] = try core.VarRef.createClosed(rt, core.JSValue.int32(7));
    var execution_adapter: bytecode.LegacyExecutionAdapter = undefined;
    const execution_function = execution_adapter.init(&function);
    var exec_frame = frame_mod.Frame.init(execution_function);
    defer exec_frame.deinit(&rt.memory, rt);
    exec_frame.installOwnedStorage(slab.storage);
    exec_frame.var_refs = slab.var_refs;

    const storage_ptr = exec_frame.storage_values.ptr;
    const var_refs_ptr = exec_frame.var_refs.ptr;
    try std.testing.expectError(error.InvalidBytecode, frame_mod.ensureVarRefsCapacity(ctx, &exec_frame, 1));
    try std.testing.expectEqual(storage_ptr, exec_frame.storage_values.ptr);
    try std.testing.expectEqual(var_refs_ptr, exec_frame.var_refs.ptr);
}

test "local growth rejects an owned composite frame slab" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("frame-composite-local-growth-test");
    defer rt.atoms.free(name);
    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    const slab = try frame_mod.FrameSlab.allocHeap(&rt.memory, 0, 0, 1, 1, 0, 0);
    slab.locals[0] = core.JSValue.int32(3);
    slab.stack[0] = core.JSValue.undefinedValue();
    var execution_adapter: bytecode.LegacyExecutionAdapter = undefined;
    const execution_function = execution_adapter.init(&function);
    var exec_frame = frame_mod.Frame.init(execution_function);
    defer exec_frame.deinit(&rt.memory, rt);
    exec_frame.installOwnedStorage(slab.storage);
    exec_frame.locals = slab.locals;

    const storage_ptr = exec_frame.storage_values.ptr;
    const locals_ptr = exec_frame.locals.ptr;
    try std.testing.expectError(error.InvalidBytecode, exec_frame.setLocal(&rt.memory, rt, 1, core.JSValue.int32(4)));
    try std.testing.expectEqual(storage_ptr, exec_frame.storage_values.ptr);
    try std.testing.expectEqual(locals_ptr, exec_frame.locals.ptr);
}

test "arg aliases reject missing open-ref storage without cellifying the slot" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const name = try js.runtime.internAtom("frame-arg-open-ref-capacity-test");
    defer js.runtime.atoms.free(name);
    var function = bytecode.Bytecode.init(&js.runtime.memory, &js.runtime.atoms, name);
    defer function.deinit(js.runtime);
    function.flags.has_simple_parameter_list = true;
    function.flags.has_mapped_arguments = true;
    function.arg_count = 1;
    function.open_var_ref_count = 1;
    function.argdefs = try js.runtime.memory.alloc(bytecode.function_bytecode.BytecodeVarDef, 1);
    function.argdefs[0] = bytecode.function_bytecode.BytecodeVarDef.init(.{ .var_name = core.atom.null_atom, .is_captured = true, .var_ref_idx = 0 });

    var args = [_]core.JSValue{core.JSValue.int32(41)};
    var no_open_refs = [_]?*core.VarRef{};
    var execution_adapter: bytecode.LegacyExecutionAdapter = undefined;
    const execution_function = execution_adapter.init(&function);
    var exec_frame = frame_mod.Frame.init(execution_function);
    defer exec_frame.deinit(&js.runtime.memory, js.runtime);
    exec_frame.args = &args;
    exec_frame.actual_arg_count = args.len;
    exec_frame.open_var_refs = &no_open_refs;
    exec_frame.ownership.storage = .borrowed;

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    var rejected = false;
    if (object_ops.createArgumentsObject(js.context, global, &exec_frame, true)) |unexpected| {
        unexpected.free(js.runtime);
        args[0].free(js.runtime);
        args[0] = core.JSValue.int32(41);
    } else |err| {
        try std.testing.expectEqual(error.InvalidBytecode, err);
        rejected = true;
    }
    try std.testing.expect(rejected);
    try std.testing.expectEqual(@as(?i32, 41), args[0].asInt32());
    try std.testing.expect(core.VarRef.fromValue(args[0]) == null);

    var occupied_value = core.JSValue.int32(7);
    const occupied_ref = try core.VarRef.createOpen(js.runtime, &occupied_value);
    var full_open_refs = [_]?*core.VarRef{occupied_ref};
    exec_frame.open_var_refs = &full_open_refs;
    rejected = false;
    if (object_ops.createArgumentsObject(js.context, global, &exec_frame, true)) |unexpected| {
        unexpected.free(js.runtime);
    } else |err| {
        try std.testing.expectEqual(error.InvalidBytecode, err);
        rejected = true;
    }
    try std.testing.expect(rejected);
    try std.testing.expectEqual(@as(?i32, 41), args[0].asInt32());
    try std.testing.expect(core.VarRef.fromValue(args[0]) == null);
    try std.testing.expectEqual(occupied_ref, full_open_refs[0].?);

    const malformed_cell = try core.VarRef.createClosed(js.runtime, args[0]);
    args[0] = malformed_cell.valueRef();
    rejected = false;
    if (object_ops.createArgumentsObject(js.context, global, &exec_frame, true)) |unexpected| {
        unexpected.free(js.runtime);
    } else |err| {
        try std.testing.expectEqual(error.InvalidBytecode, err);
        rejected = true;
    }
    try std.testing.expect(rejected);
    try std.testing.expectEqual(malformed_cell, core.VarRef.fromValue(args[0]).?);
    args[0].free(js.runtime);
    args[0] = core.JSValue.int32(41);
}

test "local growth rejects moving storage after an open binding is published" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("frame-open-local-growth-test");
    defer rt.atoms.free(name);
    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    var locals = [_]core.JSValue{core.JSValue.int32(7)};
    const open_ref = try core.VarRef.createOpen(rt, &locals[0]);
    var open_refs = [_]?*core.VarRef{open_ref};
    var execution_adapter: bytecode.LegacyExecutionAdapter = undefined;
    const execution_function = execution_adapter.init(&function);
    var exec_frame = frame_mod.Frame.init(execution_function);
    defer exec_frame.deinit(&rt.memory, rt);
    exec_frame.locals = &locals;
    exec_frame.open_var_refs = &open_refs;
    exec_frame.ownership.storage = .borrowed;

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    try std.testing.expectError(error.InvalidBytecode, exec_frame.setLocal(&rt.memory, rt, 1, core.JSValue.int32(8)));
    rt.setMemoryLimit(null);
    try exec_frame.setLocal(&rt.memory, rt, 0, core.JSValue.int32(9));
    try std.testing.expectEqual(@as(?i32, 9), open_ref.varRefValue().asInt32());
}

test "call-binding OOM leaves input references with the caller" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("frame-call-binding-oom-test");
    defer rt.atoms.free(name);
    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    const held = try core.Object.create(rt, core.class.ids.object, null);
    defer held.value().free(rt);
    var execution_adapter: bytecode.LegacyExecutionAdapter = undefined;
    const execution_function = execution_adapter.init(&function);
    var exec_frame = frame_mod.Frame.init(execution_function);
    defer exec_frame.deinit(&rt.memory, rt);
    const initial_refs = held.header.meta().rc;

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    const result = exec_frame.initCallBindings(rt, .{
        .initial_this_value = held.value(),
        .current_function_value = held.value(),
        .new_target_value = held.value(),
    });
    rt.setMemoryLimit(null);

    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expectEqual(initial_refs, held.header.meta().rc);
}

test "original-args cold-state OOM does not retain copied references" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("frame-original-args-oom-test");
    defer rt.atoms.free(name);
    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    const held = try core.Object.create(rt, core.class.ids.object, null);
    defer held.value().free(rt);
    var source_args = [_]core.JSValue{held.value().dup()};
    defer source_args[0].free(rt);
    var original_args = [_]core.JSValue{core.JSValue.undefinedValue()};
    defer original_args[0].free(rt);
    var execution_adapter: bytecode.LegacyExecutionAdapter = undefined;
    const execution_function = execution_adapter.init(&function);
    var exec_frame = frame_mod.Frame.init(execution_function);
    defer exec_frame.deinit(&rt.memory, rt);
    const initial_refs = held.header.meta().rc;

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    const result = exec_frame.initArgumentsBorrowedSlots(
        &rt.memory,
        &source_args,
        false,
        true,
        .{ .original_args = &original_args },
    );
    rt.setMemoryLimit(null);

    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expectEqual(initial_refs, held.header.meta().rc);
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

pub const helpers = @import("helpers.zig");
pub const vm_helpers = helpers.vm_helpers;

// ================== core_native.zig ==================

test "vm executes push constants arithmetic comparisons and return" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    var function = try makeFunction(rt, &.{
        op.push_i32, 2,           0,            0, 0,
        op.push_i32, 3,           0,            0, 0,
        op.add,      op.push_i32, 6,            0, 0,
        0,           op.lt,       op.@"return",
    });
    defer function.deinit(rt);

    const result = try runFunction(rt, ctx, &function);
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "Engine executes both paths of a threaded with atom-label destructuring probe" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function withThread(obj, y) {
        \\  with (obj) { [x] = y; }
        \\  return obj.x;
        \\}
        \\var threadedTotal = withThread({ x: 0, y: [4] }, [9]) * 10 +
        \\  withThread({ x: 0 }, [2]);
        \\assert.sameValue(threadedTotal, 42);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "signed bigint-i32 neg preserves inline and generic BigInt semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(-(0n), 0n);
        \\assert.sameValue(-1n, -1n);
        \\assert.sameValue(-(1n), -1n);
        \\assert.sameValue(-(2147483647n), -2147483647n);
        \\assert.sameValue(-(2147483648n), -2147483648n);
        \\assert.sameValue(-(2147483649n), -2147483649n);
        \\assert.sameValue(1n, 1n);
        \\assert.sameValue(-(1), -1);
        \\assert.sameValue(Object.is(-(0), -0), true);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "heap bigint multiplication still compacts a short-representable product" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Heap representation does not imply a magnitude above the short-BigInt
    // range: the parser only folds literals inside the i32 range while short
    // BigInts cover all of i64, so both operands below are one-limb heap
    // BigInts whose product still fits a short. qjs compacts every
    // multiplication result (JS_CompactBigInt, quickjs.c:15054), so the
    // single-allocation FAM path -- which does not collapse -- must decline
    // this shape. This is the regression guard for that gate: if a future
    // parser or literal-folding change makes the eligibility predicate
    // unsound, the representation silently diverges from qjs, and only a
    // direct check like this one catches it.
    const result = try js.eval(
        \\assert.sameValue(3000000000n * 3000000000n, 9000000000000000000n);
        \\assert.sameValue(String(3000000000n * 3000000000n), "9000000000000000000");
        \\assert.sameValue(typeof (3000000000n * 3000000000n), "bigint");
        \\assert.sameValue((3000000000n * 3000000000n) === 9000000000000000000n, true);
        \\// One limb short of the boundary on either side is still excluded.
        \\assert.sameValue(2147483648n * 2147483648n, 4611686018427387904n);
        \\assert.sameValue(-3000000000n * 3000000000n, -9000000000000000000n);
        \\// Just past it the FAM path takes over and must agree.
        \\assert.sameValue(4000000000n * 4000000000n, 16000000000000000000n);
        \\assert.sameValue(String(4000000000n * 4000000000n), "16000000000000000000");
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "numeric discarded immediates preserve comma control and completion semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function numericDiscardTail() { (1); }
        \\function numericDiscardComma(value) { return (1, value); }
        \\function numericDiscardControl(flag) { if (flag) (1); return flag ? 2 : 3; }
        \\function numericDiscardUpdate() {
        \\  let count = 0;
        \\  for (; count < 2; (1), count++) {}
        \\  return count;
        \\}
        \\assert.sameValue(numericDiscardTail(), undefined);
        \\assert.sameValue(numericDiscardComma(42), 42);
        \\assert.sameValue(numericDiscardControl(true), 2);
        \\assert.sameValue(numericDiscardControl(false), 3);
        \\assert.sameValue(numericDiscardUpdate(), 2);
        \\assert.sameValue(void 0, undefined);
        \\assert.sameValue(eval("1"), 1);
        \\assert.sameValue(eval("-1"), -1);
        \\assert.sameValue(Object.is(eval("-0"), -0), true);
        \\assert.sameValue(eval("+1"), 1);
        \\assert.sameValue(eval("-2147483648"), -2147483648);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());

    const repl = try js.evalWithOptions("1", .{ .filename = "<repl>" });
    defer repl.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 1), repl.asInt32());

    const module = try js.evalModule("1; export const numericDiscardModule = 1;");
    defer module.free(js.runtime);
    try std.testing.expect(module.isUndefined());
}

test "vm executes stack constants source locations and return_undef" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    var function = try makeFunction(rt, &.{
        op.undefined, op.null, op.push_true, op.push_false, op.drop, op.return_undef,
    });
    defer function.deinit(rt);

    const result = try runFunction(rt, ctx, &function);
    defer result.free(rt);
    try std.testing.expect(result.isUndefined());
    try std.testing.expect(result.isUndefined());
}

test "frame setLocal handles self-assignment without dropping object" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    defer function.deinit(rt);
    var execution_adapter: bytecode.LegacyExecutionAdapter = undefined;
    const execution_function = execution_adapter.init(&function);
    var frame = frame_mod.Frame.init(execution_function);
    defer frame.deinit(&rt.memory, rt);

    const object = try core.Object.create(rt, core.class.ids.object, null);
    try frame.setLocal(&rt.memory, rt, 0, object.value());
    object.value().free(rt);

    try std.testing.expectEqual(@as(i32, 1), object.header.meta().rc);
    const current = frame.locals[0];
    try frame.setLocal(&rt.memory, rt, 0, current);

    try std.testing.expectEqual(@as(i32, 1), object.header.meta().rc);
    try std.testing.expectEqual(&object.header, frame.locals[0].refHeader().?);
}

test "lookupFrameVarRef tolerates synthetic var-ref name mirrors" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);

    const binding_name = try rt.internAtom("synthetic-var-ref");
    defer rt.atoms.free(binding_name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    defer function.deinit(rt);
    function.var_ref_names = try rt.memory.alloc(core.Atom, 1);
    function.var_ref_names[0] = rt.atoms.dup(binding_name);

    const cell = try core.VarRef.createClosed(rt, core.JSValue.uninitialized());
    var var_refs = [_]*core.VarRef{cell};
    var execution_adapter: bytecode.LegacyExecutionAdapter = undefined;
    const execution_function = execution_adapter.init(&function);
    var frame = frame_mod.Frame.init(execution_function);
    frame.var_refs = &var_refs;
    defer frame.deinit(&rt.memory, rt);

    const result = engine.exec.call_runtime.lookupFrameVarRef(ctx, global, execution_function, &frame, binding_name);
    defer if (result) |value| value.free(rt);
    try std.testing.expect(result == null);
}

test "derived constructor without nested this references has no owner cell" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\globalThis.__derivedNoCapture = class DerivedNoCapture extends Object {
        \\  constructor() { super(); }
        \\};
        \\new globalThis.__derivedNoCapture();
    );
    defer result.free(js.runtime);

    const constructor = try globalFunctionBytecode(&js, "__derivedNoCapture");
    try std.testing.expect(constructor.isDerivedClassConstructor());
    try std.testing.expectEqual(@as(u16, 0), constructor.openVarRefCount());
    const this_idx = derivedThisLocalIndex(constructor) orelse return error.InvalidFunctionBytecode;
    try std.testing.expect(!constructor.varDefs()[this_idx].isCaptured());
    try std.testing.expectEqual(@as(usize, 0), try finalOpcodeCount(constructor.byteCode(), op.close_loc));
}

test "derived constructor arrow creates exactly one owner this cell" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\globalThis.__derivedArrowCapture = class DerivedArrowCapture extends Object {
        \\  constructor() { const read = () => this; super(); if (read() !== this) throw new Error("this mismatch"); }
        \\};
        \\new globalThis.__derivedArrowCapture();
    );
    defer result.free(js.runtime);

    try expectSingleDerivedThisClosureCapture(try globalFunctionBytecode(&js, "__derivedArrowCapture"));
}

test "derived constructor parameter default arrow captures this by binding identity" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\globalThis.__derivedParameterArrow = class DerivedParameterArrow extends Object {
        \\  constructor({ read = () => this } = {}) { super(); if (read() !== this) throw new Error("this mismatch"); }
        \\};
        \\new globalThis.__derivedParameterArrow();
    );
    defer result.free(js.runtime);

    try expectSingleDerivedThisClosureCapture(try globalFunctionBytecode(&js, "__derivedParameterArrow"));
}

test "direct eval captures derived this while indirect eval does not" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\globalThis.__derivedDirectEval = class DerivedDirectEval extends Object {
        \\  constructor() { super(); if (eval("this") !== this) throw new Error("this mismatch"); }
        \\};
        \\globalThis.__derivedIndirectEval = class DerivedIndirectEval extends Object {
        \\  constructor() { (0, eval)("this"); super(); }
        \\};
        \\new globalThis.__derivedDirectEval();
        \\new globalThis.__derivedIndirectEval();
    );
    defer result.free(js.runtime);

    const direct = try globalFunctionBytecode(&js, "__derivedDirectEval");
    const direct_this_idx = derivedThisLocalIndex(direct) orelse return error.InvalidFunctionBytecode;
    const direct_this = direct.varDefs()[direct_this_idx];
    try std.testing.expect(direct_this.isCaptured());
    try std.testing.expect(direct_this.var_ref_idx < direct.openVarRefCount());
    try std.testing.expectEqual(@as(usize, 0), try finalOpcodeCount(direct.byteCode(), op.close_loc));

    const indirect = try globalFunctionBytecode(&js, "__derivedIndirectEval");
    const indirect_this_idx = derivedThisLocalIndex(indirect) orelse return error.InvalidFunctionBytecode;
    try std.testing.expect(!indirect.varDefs()[indirect_this_idx].isCaptured());
    try std.testing.expectEqual(@as(u16, 0), indirect.openVarRefCount());
    try std.testing.expectEqual(@as(usize, 0), try finalOpcodeCount(indirect.byteCode(), op.close_loc));
}

test "ordinary calls to the current superclass do not initialize derived this" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\class OrdinaryCallBase {}
        \\class OrdinaryCallDerived extends OrdinaryCallBase {
        \\  constructor(spread) {
        \\    let caught;
        \\    try { if (spread) OrdinaryCallBase(...[]); else OrdinaryCallBase(); }
        \\    catch (error) { caught = error; }
        \\    if (!(caught instanceof TypeError)) throw new Error("ordinary call became super");
        \\    super();
        \\  }
        \\}
        \\new OrdinaryCallDerived(false);
        \\new OrdinaryCallDerived(true);
    );
    defer result.free(js.runtime);
}

test "class entry and construction use bytecode gates without a class behavior flag" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\let ordinaryNewTarget = null;
        \\function Ordinary(value) {
        \\  ordinaryNewTarget = new.target;
        \\  this.value = value;
        \\  return 7;
        \\}
        \\const receiver = {};
        \\assert.sameValue(Ordinary.call(receiver, 1), 7);
        \\assert.sameValue(receiver.value, 1);
        \\assert.sameValue(ordinaryNewTarget, undefined);
        \\
        \\let baseNewTarget;
        \\let derivedNewTarget;
        \\class Base {
        \\  constructor(value) {
        \\    baseNewTarget = new.target;
        \\    this.value = value;
        \\    return 7;
        \\  }
        \\}
        \\class Derived extends Base {
        \\  constructor(value) {
        \\    derivedNewTarget = new.target;
        \\    super(value);
        \\  }
        \\}
        \\assert.throws(TypeError, function () { Base(2); });
        \\assert.throws(TypeError, function () { Derived(2); });
        \\
        \\function Replacement() {}
        \\const ordinary = Reflect.construct(Ordinary, [3], Replacement);
        \\assert.sameValue(ordinaryNewTarget, Replacement);
        \\assert.sameValue(ordinary.value, 3);
        \\assert.sameValue(Object.getPrototypeOf(ordinary), Replacement.prototype);
        \\
        \\const base = Reflect.construct(Base, [4], Replacement);
        \\assert.sameValue(baseNewTarget, Replacement);
        \\assert.sameValue(base.value, 4);
        \\assert.sameValue(Object.getPrototypeOf(base), Replacement.prototype);
        \\
        \\const derived = Reflect.construct(Derived, [5], Replacement);
        \\assert.sameValue(derivedNewTarget, Replacement);
        \\assert.sameValue(baseNewTarget, Replacement);
        \\assert.sameValue(derived.value, 5);
        \\assert.sameValue(Object.getPrototypeOf(derived), Replacement.prototype);
        \\
        \\const key = "ComputedClass";
        \\let computedNewTarget;
        \\const holder = {
        \\  [key]: class {
        \\    constructor() { computedNewTarget = new.target; }
        \\  },
        \\};
        \\assert.sameValue(holder[key].name, key);
        \\assert.throws(TypeError, function () { holder[key](); });
        \\const computed = Reflect.construct(holder[key], [], Replacement);
        \\assert.sameValue(computedNewTarget, Replacement);
        \\assert.sameValue(Object.getPrototypeOf(computed), Replacement.prototype);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "ordinary constructor Machine completion preserves bindings eval recursion and abrupt teardown" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const baseline_call_depth = js.runtime.hot.call_depth;
    const baseline_stack_bytes = js.runtime.hot.active_bytecode_stack_bytes;
    const baseline_arena_mark = js.runtime.vm_stack.mark();
    const result = try js.eval(
        \\let observed;
        \\let evalThis;
        \\let evalNewTarget;
        \\function Ordinary(value, mode) {
        \\  const arrow = () => [this, new.target, arguments[0]];
        \\  observed = arrow();
        \\  eval("evalThis = this; evalNewTarget = new.target");
        \\  this.value = value;
        \\  if (mode === "object") return { replacement: value + 1 };
        \\  if (mode === "throw") throw value;
        \\  return 17;
        \\}
        \\const primitive = new Ordinary(3, "primitive");
        \\assert.sameValue(primitive.value, 3);
        \\assert.sameValue(observed[0], primitive);
        \\assert.sameValue(observed[1], Ordinary);
        \\assert.sameValue(observed[2], 3);
        \\assert.sameValue(evalThis, primitive);
        \\assert.sameValue(evalNewTarget, Ordinary);
        \\const replacement = new Ordinary(4, "object");
        \\assert.sameValue(replacement.replacement, 5);
        \\assert.sameValue(replacement.value, undefined);
        \\let caught;
        \\try { new Ordinary(6, "throw"); } catch (error) { caught = error; }
        \\assert.sameValue(caught, 6);
        \\
        \\function Recursive(depth) {
        \\  this.depth = depth;
        \\  if (depth !== 0) this.child = new Recursive(depth - 1);
        \\}
        \\const recursive = new Recursive(32);
        \\let count = 0;
        \\for (let cursor = recursive; cursor; cursor = cursor.child) count++;
        \\assert.sameValue(count, 33);
        \\
        \\function EvalTail(value) {
        \\  eval("this.value = value");
        \\}
        \\const evalTail = new EvalTail(9);
        \\assert.sameValue(evalTail.value, 9);
        \\
        \\function GcConstructor(value) {
        \\  this.value = value;
        \\  $262.gc();
        \\  return null;
        \\}
        \\const gcValue = new GcConstructor(11);
        \\assert.sameValue(gcValue.value, 11);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqual(baseline_call_depth, js.runtime.hot.call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.hot.active_bytecode_stack_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
}

test "derived constructor Machine completion preserves inherited new target and teardown" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const baseline_call_depth = js.runtime.hot.call_depth;
    const baseline_stack_bytes = js.runtime.hot.active_bytecode_stack_bytes;
    const baseline_arena_mark = js.runtime.vm_stack.mark();
    const result = try js.eval(
        \\let baseNewTarget;
        \\function OrdinaryBase(value) { this.value = value; }
        \\class Base {
        \\  constructor(value, mode) {
        \\    baseNewTarget = new.target;
        \\    this.value = value;
        \\    if (mode === "object") return { replacement: value + 1 };
        \\    if (mode === "throw") throw value;
        \\  }
        \\}
        \\class Derived extends Base {
        \\  constructor(value, mode) {
        \\    super(value, mode);
        \\    this.derived = true;
        \\  }
        \\}
        \\class FromOrdinary extends OrdinaryBase {
        \\  constructor(value) { super(value); }
        \\}
        \\
        \\const direct = new Derived(3);
        \\assert.sameValue(direct.value, 3);
        \\assert.sameValue(direct.derived, true);
        \\assert.sameValue(baseNewTarget, Derived);
        \\assert.sameValue(Object.getPrototypeOf(direct), Derived.prototype);
        \\const fromOrdinary = new FromOrdinary(5);
        \\assert.sameValue(fromOrdinary.value, 5);
        \\assert.sameValue(Object.getPrototypeOf(fromOrdinary), FromOrdinary.prototype);
        \\
        \\function Replacement() {}
        \\Replacement.prototype = { marker: 7 };
        \\const reflected = Reflect.construct(Derived, [11], Replacement);
        \\assert.sameValue(reflected.value, 11);
        \\assert.sameValue(reflected.derived, true);
        \\assert.sameValue(baseNewTarget, Replacement);
        \\assert.sameValue(Object.getPrototypeOf(reflected), Replacement.prototype);
        \\const reflectedOrdinary = Reflect.construct(FromOrdinary, [13], Replacement);
        \\assert.sameValue(reflectedOrdinary.value, 13);
        \\assert.sameValue(Object.getPrototypeOf(reflectedOrdinary), Replacement.prototype);
        \\
        \\const replacement = new Derived(17, "object");
        \\assert.sameValue(replacement.replacement, 18);
        \\assert.sameValue(replacement.derived, true);
        \\let caught;
        \\try { new Derived(19, "throw"); } catch (error) { caught = error; }
        \\assert.sameValue(caught, 19);
        \\
        \\class ReturnsObject extends Base {
        \\  constructor() { return { selected: 23 }; }
        \\}
        \\class ReturnsPrimitive extends Base {
        \\  constructor() { return 29; }
        \\}
        \\assert.sameValue(new ReturnsObject().selected, 23);
        \\assert.throws(TypeError, function () { new ReturnsPrimitive(); });
        \\
        \\class Recursive extends Base {
        \\  constructor(depth) {
        \\    super(depth);
        \\    if (depth !== 0) this.child = new Recursive(depth - 1);
        \\  }
        \\}
        \\const recursive = new Recursive(24);
        \\let count = 0;
        \\for (let cursor = recursive; cursor; cursor = cursor.child) count++;
        \\assert.sameValue(count, 25);
        \\$262.gc();
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqual(baseline_call_depth, js.runtime.hot.call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.hot.active_bytecode_stack_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
}

test "Reflect.construct keeps a fresh prototype getter result alive through instance allocation" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\let prototypeGets = 0;
        \\let receiverIsNewTarget = true;
        \\function Target() {}
        \\let NewTarget;
        \\NewTarget = new Proxy(function () {}, {
        \\  get(target, key, receiver) {
        \\    if (key === "prototype") {
        \\      receiverIsNewTarget = receiverIsNewTarget && receiver === NewTarget;
        \\      return { marker: ++prototypeGets };
        \\    }
        \\    return Reflect.get(target, key, receiver);
        \\  },
        \\});
        \\for (let expected = 1; expected <= 256; expected++) {
        \\  const instance = Reflect.construct(Target, [], NewTarget);
        \\  if ((expected & 15) === 0) $262.gc();
        \\  assert.sameValue(Object.getPrototypeOf(instance).marker, expected);
        \\}
        \\assert.sameValue(prototypeGets, 256);
        \\assert.sameValue(receiverIsNewTarget, true);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Proxy wrapping a class named Array never enters the native Array construct record" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\let caught;
        \\try {
        \\  new (new Proxy(class Array {
        \\    constructor() { throw 1; }
        \\  }, {}))();
        \\} catch (error) {
        \\  caught = error;
        \\}
        \\assert.sameValue(caught, 1);
        \\
        \\const ProxyArray = new Proxy(Array, {});
        \\class DerivedArray extends ProxyArray {}
        \\const array = new DerivedArray(1, 2);
        \\assert.sameValue(Array.isArray(array), true);
        \\assert.sameValue(array instanceof DerivedArray, true);
        \\assert.sameValue(Object.getPrototypeOf(array), DerivedArray.prototype);
        \\assert.sameValue(array.length, 2);
        \\assert.sameValue(array[0], 1);
        \\assert.sameValue(array[1], 2);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Proxy native constructor forwarding resolves new target prototype before coercion" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\let order = 0;
        \\let prototypeGets = 0;
        \\let forwardedPrototype;
        \\const ErrorProxy = new Proxy(Error, {
        \\  get(target, key, receiver) {
        \\    assert.sameValue(key, "prototype");
        \\    assert.sameValue(receiver, ErrorProxy);
        \\    assert.sameValue(order++, 0);
        \\    prototypeGets++;
        \\    forwardedPrototype = Reflect.get(target, key, receiver);
        \\    return forwardedPrototype;
        \\  },
        \\});
        \\const message = {
        \\  toString() {
        \\    assert.sameValue(order++, 1);
        \\    return "message";
        \\  },
        \\};
        \\const error = new ErrorProxy(message);
        \\assert.sameValue(order, 2);
        \\assert.sameValue(prototypeGets, 1);
        \\assert.sameValue(Object.getPrototypeOf(error), forwardedPrototype);
        \\assert.sameValue(error.message, "message");
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "default derived constructor follows the live constructor prototype" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\let oldBaseCalls = 0;
        \\let seenNewTarget;
        \\class OldBase {
        \\  constructor() {
        \\    oldBaseCalls++;
        \\    this.kind = "old";
        \\  }
        \\}
        \\class NewBase {
        \\  constructor() {
        \\    seenNewTarget = new.target;
        \\    this.kind = "new";
        \\  }
        \\}
        \\class DefaultDerived extends OldBase {}
        \\Object.setPrototypeOf(DefaultDerived, NewBase);
        \\const derived = new DefaultDerived();
        \\assert.sameValue(oldBaseCalls, 0);
        \\assert.sameValue(seenNewTarget, DefaultDerived);
        \\assert.sameValue(derived.kind, "new");
        \\assert.sameValue(Object.getPrototypeOf(derived), DefaultDerived.prototype);
        \\
        \\Object.setPrototypeOf(DefaultDerived, null);
        \\let nullSuperError;
        \\try { new DefaultDerived(); } catch (error) { nullSuperError = error; }
        \\assert.sameValue(nullSuperError.constructor, TypeError);
        \\assert.sameValue(nullSuperError.message, "not a function");
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "class constructor opcode errors preserve QuickJS messages and realms" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\const other = $262.createRealm().global;
        \\other.eval("globalThis.ForeignBase = class ForeignBase {}; globalThis.ForeignDerived = class ForeignDerived extends ForeignBase {}; globalThis.ForeignBadReturn = class ForeignBadReturn extends Object { constructor() { return 1; } }; globalThis.ForeignNoSuper = class ForeignNoSuper extends Object { constructor() { return undefined; } }; globalThis.ForeignCaughtThis = class ForeignCaughtThis extends Object { constructor() { try { this; } catch (error) { globalThis.directThisError = error; } try { (() => this)(); } catch (error) { globalThis.capturedThisError = error; } return {}; } };");
        \\function capture(thunk) {
        \\  try { thunk(); } catch (error) { return error; }
        \\  throw new Error("expected constructor TypeError");
        \\}
        \\
        \\const baseCallError = capture(function () { other.ForeignBase(); });
        \\assert.sameValue(baseCallError.constructor, other.TypeError);
        \\assert.sameValue(baseCallError.message, "class constructors must be invoked with 'new'");
        \\
        \\const derivedCallError = capture(function () { other.ForeignDerived(); });
        \\assert.sameValue(derivedCallError.constructor, other.TypeError);
        \\assert.sameValue(derivedCallError.message, "class constructors must be invoked with 'new'");
        \\
        \\const returnError = capture(function () { new other.ForeignBadReturn(); });
        \\assert.sameValue(returnError.constructor, TypeError);
        \\assert.sameValue(returnError.message, "derived class constructor must return an object or undefined");
        \\
        \\const noSuperError = capture(function () { new other.ForeignNoSuper(); });
        \\assert.sameValue(noSuperError.constructor, ReferenceError);
        \\assert.sameValue(noSuperError.message, "this is not initialized");
        \\
        \\new other.ForeignCaughtThis();
        \\assert.sameValue(other.directThisError.constructor, other.ReferenceError);
        \\assert.sameValue(other.directThisError.message, "this is not initialized");
        \\assert.sameValue(other.capturedThisError.constructor, other.ReferenceError);
        \\assert.sameValue(other.capturedThisError.message, "this is not initialized");
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "direct spread and arrow super follow the live derived constructor prototype" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\let directNewTarget;
        \\let spreadNewTarget;
        \\let arrowDirectNewTarget;
        \\let arrowSpreadNewTarget;
        \\class OldBase {}
        \\class NewBase {
        \\  constructor(kind) {
        \\    if (kind === "direct") directNewTarget = new.target;
        \\    else if (kind === "spread") spreadNewTarget = new.target;
        \\    else if (kind === "arrow-direct") arrowDirectNewTarget = new.target;
        \\    else arrowSpreadNewTarget = new.target;
        \\  }
        \\}
        \\class DirectDerived extends OldBase {
        \\  constructor() { super("direct"); }
        \\}
        \\class SpreadDerived extends OldBase {
        \\  constructor() { super(...["spread"]); }
        \\}
        \\class ArrowDirectDerived extends OldBase {
        \\  constructor() { (() => super("arrow-direct"))(); }
        \\}
        \\class ArrowSpreadDerived extends OldBase {
        \\  constructor() { (() => super(...["arrow-spread"]))(); }
        \\}
        \\Object.setPrototypeOf(DirectDerived, NewBase);
        \\Object.setPrototypeOf(SpreadDerived, NewBase);
        \\Object.setPrototypeOf(ArrowDirectDerived, NewBase);
        \\Object.setPrototypeOf(ArrowSpreadDerived, NewBase);
        \\const direct = new DirectDerived();
        \\const spread = new SpreadDerived();
        \\const arrowDirect = new ArrowDirectDerived();
        \\const arrowSpread = new ArrowSpreadDerived();
        \\assert.sameValue(directNewTarget, DirectDerived);
        \\assert.sameValue(spreadNewTarget, SpreadDerived);
        \\assert.sameValue(arrowDirectNewTarget, ArrowDirectDerived);
        \\assert.sameValue(arrowSpreadNewTarget, ArrowSpreadDerived);
        \\assert.sameValue(Object.getPrototypeOf(direct), DirectDerived.prototype);
        \\assert.sameValue(Object.getPrototypeOf(spread), SpreadDerived.prototype);
        \\assert.sameValue(Object.getPrototypeOf(arrowDirect), ArrowDirectDerived.prototype);
        \\assert.sameValue(Object.getPrototypeOf(arrowSpread), ArrowSpreadDerived.prototype);
    );
    defer result.free(js.runtime);
}

test "super call paths reject null live parents and do not authorize ordinary class calls" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function capture(thunk) {
        \\  try { thunk(); } catch (error) { return error; }
        \\  throw new Error("expected constructor error");
        \\}
        \\function expectNotFunction(thunk) {
        \\  const error = capture(thunk);
        \\  assert.sameValue(error.constructor, TypeError);
        \\  assert.sameValue(error.message, "not a function");
        \\}
        \\function expectClassCallError(error) {
        \\  assert.sameValue(error.constructor, TypeError);
        \\  assert.sameValue(error.message, "class constructors must be invoked with 'new'");
        \\}
        \\class Base {}
        \\
        \\class ExternalDirect extends Base {
        \\  constructor() { super(); }
        \\}
        \\class ExternalSpread extends Base {
        \\  constructor() { super(...[]); }
        \\}
        \\class ExternalArrow extends Base {
        \\  constructor() { (() => super("direct"))(); }
        \\}
        \\Object.setPrototypeOf(ExternalDirect, null);
        \\Object.setPrototypeOf(ExternalSpread, null);
        \\Object.setPrototypeOf(ExternalArrow, null);
        \\expectNotFunction(() => new ExternalDirect());
        \\expectNotFunction(() => new ExternalSpread());
        \\expectNotFunction(() => new ExternalArrow());
        \\
        \\class InternalDirect extends Base {
        \\  constructor() {
        \\    Object.setPrototypeOf(InternalDirect, null);
        \\    super();
        \\  }
        \\}
        \\class InternalSpread extends Base {
        \\  constructor() {
        \\    Object.setPrototypeOf(InternalSpread, null);
        \\    super(...[]);
        \\  }
        \\}
        \\class InternalArrow extends Base {
        \\  constructor() {
        \\    Object.setPrototypeOf(InternalArrow, null);
        \\    (() => super())();
        \\  }
        \\}
        \\expectNotFunction(() => new InternalDirect());
        \\expectNotFunction(() => new InternalSpread());
        \\expectNotFunction(() => new InternalArrow());
        \\
        \\class OrdinaryDirect extends Base {
        \\  constructor() {
        \\    const parent = Object.getPrototypeOf(OrdinaryDirect);
        \\    expectClassCallError(capture(() => parent()));
        \\    super();
        \\  }
        \\}
        \\class OrdinarySpread extends Base {
        \\  constructor() {
        \\    const parent = Object.getPrototypeOf(OrdinarySpread);
        \\    expectClassCallError(capture(() => parent(...[])));
        \\    super(...[]);
        \\  }
        \\}
        \\assert.sameValue(new OrdinaryDirect() instanceof OrdinaryDirect, true);
        \\assert.sameValue(new OrdinarySpread() instanceof OrdinarySpread, true);
    );
    defer result.free(js.runtime);
}

test "derived constructor arrow and direct eval observe the same this value" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [32]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\new class extends class {} {
        \\  constructor() {
        \\    super();
        \\    print(this === (() => this)(), this === eval("this"));
        \\  }
        \\}();
    , &output);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true true\n", output.buffered());
}

test "derived constructor direct eval this shortcut preserves TDZ" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [96]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\new class extends Object {
        \\  constructor() {
        \\    let shortcut = "no", full = "no";
        \\    try { eval("this"); } catch (error) { shortcut = error.name; }
        \\    try { eval("this;"); } catch (error) { full = error.name; }
        \\    print(shortcut, full);
        \\    super();
        \\  }
        \\}();
    , &output);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("ReferenceError ReferenceError\n", output.buffered());
}

test "bound function call skips zero-length combined args allocation" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const target = try engine.exec.closure.create(rt, 13, 0, 0, 0);
    defer target.free(rt);
    const bound = try core.Object.create(rt, core.class.ids.bound_function, null);
    defer bound.value().free(rt);
    bound.boundTargetSlot().* = target.dup();
    bound.boundThisSlot().* = core.JSValue.undefinedValue();

    const base_bytes = rt.memory.allocated_bytes;
    const base_allocations = rt.memory.allocation_count;

    const result = try engine.exec.call.callValue(ctx, null, bound.value(), &.{});
    defer result.free(rt);
    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqual(base_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(base_allocations, rt.memory.allocation_count);
}

test "constant pool execution retains returned constants" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const name = try rt.internAtom("const-return");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    const str = try core.string.String.createAscii(rt, "hello");
    const value = str.value();
    _ = try function.addConstant(value);
    value.free(rt);
    try helpers.setCodeAndStackSize(&function, &.{ op.push_const, 0, 0, 0, 0, op.@"return" });

    const result = try runFunction(rt, ctx, &function);
    defer result.free(rt);
    try std.testing.expect(result.isString());
}

test "property ops use shared object semantics" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const obj = try core.Object.create(rt, core.class.ids.object, null);
    defer obj.value().free(rt);
    const key = try rt.internAtom("x");
    defer rt.atoms.free(key);

    try engine.exec.property_ops.defineDataProperty(rt, obj, key, core.JSValue.int32(9));
    try engine.exec.property_ops.setProperty(rt, obj, key, core.JSValue.int32(10));
    const value = try engine.exec.property_ops.getProperty(rt, obj, key);
    try std.testing.expectEqual(@as(?i32, 10), value.asInt32());

    const direct_value = try engine.exec.property_ops.getPropertyValue(rt, obj.value(), key);
    defer direct_value.free(rt);
    try std.testing.expectEqual(@as(?i32, 10), direct_value.asInt32());

    const key_string_obj = try core.string.String.createUtf8(rt, "x");
    const key_string = key_string_obj.value();
    defer key_string.free(rt);
    const in_result = try engine.exec.property_ops.propertyIn(rt, obj.value(), key_string);
    try std.testing.expectEqual(true, in_result.asBool().?);

    const optional_result = try engine.exec.property_ops.optionalGetPropertyValue(rt, core.JSValue.nullValue(), key);
    try std.testing.expect(optional_result.isUndefined());

    try std.testing.expect(engine.exec.property_ops.deleteProperty(rt, obj, key));
}

test "value ops own primitive VM semantics" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const sum = try engine.exec.value_ops.binary(rt, op.add, core.JSValue.int32(2), core.JSValue.int32(3));
    defer sum.free(rt);
    try std.testing.expectEqual(@as(?i32, 5), sum.asInt32());

    const suffix_obj = try core.string.String.createUtf8(rt, "px");
    const suffix = suffix_obj.value();
    defer suffix.free(rt);
    const joined = try engine.exec.value_ops.binary(rt, op.add, core.JSValue.int32(2), suffix);
    defer joined.free(rt);

    var joined_text = std.ArrayList(u8).empty;
    defer joined_text.deinit(rt.memory.allocator);
    try engine.exec.value_ops.appendRawString(rt, &joined_text, joined);
    try std.testing.expectEqualStrings("2px", joined_text.items);

    const int_string = try engine.exec.value_ops.toStringValue(rt, core.JSValue.int32(7));
    defer int_string.free(rt);
    var int_string_text = std.ArrayList(u8).empty;
    defer int_string_text.deinit(rt.memory.allocator);
    try engine.exec.value_ops.appendRawString(rt, &int_string_text, int_string);
    try std.testing.expectEqualStrings("7", int_string_text.items);

    const empty_obj = try core.string.String.createUtf8(rt, "");
    const empty = empty_obj.value();
    defer empty.free(rt);

    const empty_suffix = try engine.exec.value_ops.binary(rt, op.add, empty, core.JSValue.int32(7));
    defer empty_suffix.free(rt);
    var empty_suffix_text = std.ArrayList(u8).empty;
    defer empty_suffix_text.deinit(rt.memory.allocator);
    try engine.exec.value_ops.appendRawString(rt, &empty_suffix_text, empty_suffix);
    try std.testing.expectEqualStrings("7", empty_suffix_text.items);

    const empty_prefix = try engine.exec.value_ops.binary(rt, op.add, core.JSValue.int32(7), empty);
    defer empty_prefix.free(rt);
    var empty_prefix_text = std.ArrayList(u8).empty;
    defer empty_prefix_text.deinit(rt.memory.allocator);
    try engine.exec.value_ops.appendRawString(rt, &empty_prefix_text, empty_prefix);
    try std.testing.expectEqualStrings("7", empty_prefix_text.items);

    const one_obj = try core.string.String.createUtf8(rt, "1");
    const one_string = one_obj.value();
    defer one_string.free(rt);

    const same_string = try engine.exec.value_ops.toStringValue(rt, one_string);
    defer same_string.free(rt);
    try std.testing.expect(same_string.same(one_string));

    const boxed_one = try engine.exec.string_builtin_ops.constructWithPrototype(rt, &.{one_string}, null);
    defer boxed_one.free(rt);
    const boxed_one_object: *core.Object = @fieldParentPtr("header", boxed_one.refHeader().?);
    const boxed_one_data = boxed_one_object.objectData() orelse return error.TypeError;
    try std.testing.expect(boxed_one_data.same(one_string));

    const symbol_atom = try rt.atoms.newSymbol("boxed", .symbol);
    defer rt.atoms.free(symbol_atom);
    try std.testing.expectError(error.TypeError, engine.exec.string_builtin_ops.constructWithPrototype(rt, &.{try rt.symbolValue(symbol_atom)}, null));

    const name = try rt.internAtom("loose-eq");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    _ = try function.addConstant(one_string);
    try helpers.setCodeAndStackSize(&function, &.{
        op.push_i32,   1,            0, 0, 0,
        op.push_const, 0,            0, 0, 0,
        op.eq,         op.@"return",
    });
    const eq_result = try runFunction(rt, ctx, &function);
    defer eq_result.free(rt);
    try std.testing.expectEqual(true, eq_result.asBool().?);

    try std.testing.expectEqual(false, engine.exec.value_ops.toBooleanValue(core.JSValue.int32(0)).asBool().?);
}

test "closure helper stores closure state outside the VM" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const closure_value = try engine.exec.closure.create(rt, 2, 0, 0, 0);
    defer closure_value.free(rt);
    const first = try engine.exec.closure.call(rt, closure_value, &.{}, &.{});
    defer first.free(rt);
    const second = try engine.exec.closure.call(rt, closure_value, &.{}, &.{});
    defer second.free(rt);

    try std.testing.expectEqual(@as(?i32, 1), first.asInt32());
    try std.testing.expectEqual(@as(?i32, 2), second.asInt32());
}

test "M1.3: returned closure can update and return captured counter" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try vm_helpers.parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  function counter() {
        \\    let n = 0;
        \\    return function next() { n++; return n; };
        \\  }
        \\  var next = counter();
        \\  return next() * 100 + next() * 10 + next();
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 123), result.asInt32().?);
}

test "resident set_var_ref preserves assignment results and refcounted self-assignment" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function __buildResidentSetVarRefProbes() {
        \\  var shortTarget = 0;
        \\  globalThis.__residentSetVarRefShort = function (next) {
        \\    return shortTarget = next;
        \\  };
        \\  globalThis.__residentSetVarRefSelf = function () {
        \\    return shortTarget = shortTarget;
        \\  };
        \\
        \\  var capture0 = 0;
        \\  var capture1 = 1;
        \\  var capture2 = 2;
        \\  var capture3 = 3;
        \\  var genericTarget = 4;
        \\  globalThis.__residentSetVarRefGeneric = function (next) {
        \\    if (capture0 + capture1 + capture2 + capture3 !== 6) throw new Error("capture mismatch");
        \\    return genericTarget = next;
        \\  };
        \\}
        \\__buildResidentSetVarRefProbes();
        \\
        \\assert.sameValue(__residentSetVarRefShort(42), 42);
        \\const shortObject = { marker: 1 };
        \\assert.sameValue(__residentSetVarRefShort(shortObject), shortObject);
        \\assert.sameValue(__residentSetVarRefSelf(), shortObject);
        \\assert.sameValue(__residentSetVarRefSelf().marker, 1);
        \\
        \\const genericObject = { marker: 2 };
        \\assert.sameValue(__residentSetVarRefGeneric(genericObject), genericObject);
        \\assert.sameValue(__residentSetVarRefGeneric(43), 43);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());

    const short = try globalFunctionBytecode(&js, "__residentSetVarRefShort");
    const short_set = try finalSetVarRefStats(short.byteCode());
    try std.testing.expectEqual(@as(usize, 1), short_set.count);
    try std.testing.expectEqual(@as(?u16, 0), short_set.first_idx);

    const self_assign = try globalFunctionBytecode(&js, "__residentSetVarRefSelf");
    const self_set = try finalSetVarRefStats(self_assign.byteCode());
    try std.testing.expectEqual(@as(usize, 1), self_set.count);
    try std.testing.expectEqual(@as(?u16, 0), self_set.first_idx);

    const generic = try globalFunctionBytecode(&js, "__residentSetVarRefGeneric");
    var generic_set_idx: ?u16 = null;
    var pc: usize = 0;
    while (pc < generic.byteCode().len) {
        const opcode_id = generic.byteCode()[pc];
        const size = bytecode.opcode.sizeOf(opcode_id);
        if (size == 0 or pc + size > generic.byteCode().len) return error.InvalidFunctionBytecode;
        if (opcode_id == op.set_var_ref) {
            generic_set_idx = std.mem.readInt(u16, generic.byteCode()[pc + 1 ..][0..2], .little);
            break;
        }
        pc += size;
    }
    try std.testing.expect(generic_set_idx != null);
    try std.testing.expect(generic_set_idx.? >= 4);
}

test "resident stack permutations preserve assignment values and ownership" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\globalThis.__residentInsert2 = function (object, value) {
        \\  return object.field = value;
        \\};
        \\globalThis.__residentInsert3 = function (object, key, value) {
        \\  return object[key] = value;
        \\};
        \\globalThis.__residentPerm3 = function (object) {
        \\  return object.count++;
        \\};
        \\const marker = { alive: true };
        \\const target = { count: 4 };
        \\assert.sameValue(__residentInsert2(target, marker), marker);
        \\assert.sameValue(target.field, marker);
        \\assert.sameValue(__residentInsert3(target, "indexed", marker), marker);
        \\assert.sameValue(target.indexed, marker);
        \\target.count = 12345678901234567890n;
        \\assert.sameValue(__residentPerm3(target), 12345678901234567890n);
        \\assert.sameValue(target.count, 12345678901234567891n);
        \\assert.sameValue(marker.alive, true);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());

    const insert2 = try globalFunctionBytecode(&js, "__residentInsert2");
    try std.testing.expectEqual(@as(usize, 1), try finalOpcodeCount(insert2.byteCode(), op.insert2));
    const insert3 = try globalFunctionBytecode(&js, "__residentInsert3");
    try std.testing.expectEqual(@as(usize, 1), try finalOpcodeCount(insert3.byteCode(), op.insert3));
    const perm3 = try globalFunctionBytecode(&js, "__residentPerm3");
    try std.testing.expectEqual(@as(usize, 1), try finalOpcodeCount(perm3.byteCode(), op.perm3));
}

test "empty object named field miss is undefined and own hit stores" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\const o = {};
        \\assert.sameValue(o.missing, undefined);
        \\assert.sameValue(o.x = 1, 1);
        \\assert.sameValue(o.x, 1);
        \\assert.sameValue(({}).y, undefined);
    );
    _ = result;
}

test "mapped arguments named field skips binding alias; computed index stays aliased" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function f(a) {
        \\  assert.sameValue(arguments[0], 7);
        \\  assert.sameValue(arguments.foo, undefined);
        \\  arguments.foo = 1;
        \\  assert.sameValue(arguments.foo, 1);
        \\  assert.sameValue(a, 7);
        \\  arguments[0] = 8;
        \\  assert.sameValue(a, 8);
        \\  assert.sameValue(arguments[0], 8);
        \\}
        \\f(7);
    );
    _ = result;
}

test "mapped arguments rest-style 0-formal length and index (sc_list)" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function sc_list() {
        \\  var a = arguments;
        \\  assert.sameValue(a.length, 2);
        \\  assert.sameValue(a[0], "x");
        \\  assert.sameValue(a[1], 9);
        \\  a[0] = "y";
        \\  assert.sameValue(a[0], "y");
        \\  assert.sameValue(a[2], undefined);
        \\  return a.length + a[1];
        \\}
        \\assert.sameValue(sc_list("x", 9), 11);
        \\function g(a, b) {
        \\  assert.sameValue(arguments[0], 1);
        \\  assert.sameValue(arguments[1], 2);
        \\  arguments[0] = 3;
        \\  assert.sameValue(a, 3);
        \\  a = 4;
        \\  assert.sameValue(arguments[0], 4);
        \\  delete arguments[1];
        \\  assert.sameValue(arguments[1], undefined);
        \\  assert.sameValue(b, 2);
        \\}
        \\g(1, 2);
    );
    _ = result;
}

test "typed array integer get uses class-id arm and qjs tag shape" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\const u8 = new Uint8Array([255, 1]);
        \\assert.sameValue(u8[0], 255);
        \\assert.sameValue(u8[1], 1);
        \\assert.sameValue(u8[2], undefined);
        \\assert.sameValue(u8[-1], undefined);
        \\const i32 = new Int32Array([-1, 2147483647]);
        \\assert.sameValue(i32[0], -1);
        \\assert.sameValue(i32[1], 2147483647);
        \\const u32 = new Uint32Array([2147483648, 1]);
        \\assert.sameValue(u32[0], 2147483648);
        \\assert.sameValue(u32[1], 1);
        \\const f64 = new Float64Array([1, -0]);
        \\assert.sameValue(f64[0], 1);
        \\assert.sameValue(Object.is(f64[1], -0), true);
        \\const dense = [9, 8, 7];
        \\assert.sameValue(dense[1], 8);
        \\const buf = new ArrayBuffer(4);
        \\const view = new Uint8Array(buf);
        \\view[0] = 3;
        \\assert.sameValue(view[0], 3);
        \\const detached = new Uint8Array(new ArrayBuffer(2));
        \\detached[0] = 9;
        \\detached.buffer.transfer();
        \\assert.sameValue(detached[0], undefined);
    );
    _ = result;
}

test "typed array prototype chain get reads canonical numeric indices" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    // S1: TA-as-proto [[Get]] (PROTO-WALK-EXOTIC-AUDIT). qjs
    // JS_GetPropertyInternal (quickjs.c:8296-8303) consults is_exotic+fast_array
    // at every proto link, not only when the receiver is the TypedArray.
    const result = try js.eval(
        \\const ta = new Uint8Array([7, 8]);
        \\const o = Object.create(ta);
        \\assert.sameValue(o[0], 7);
        \\assert.sameValue(o["0"], 7);
        \\assert.sameValue(o[1], 8);
        \\assert.sameValue(o[2], undefined);
        \\assert.sameValue(0 in o, true);
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(o, "0"), false);
        \\assert.sameValue([7, 8][0], 7);
        \\const fromArray = Object.create([7, 8]);
        \\assert.sameValue(fromArray[0], 7);
    );
    _ = result;
}

test "typed array integer put uses class-id arm" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\const u8 = new Uint8Array(3);
        \\assert.sameValue(u8[0] = 255, 255);
        \\assert.sameValue(u8[0], 255);
        \\assert.sameValue(u8[1] = -1, -1);
        \\assert.sameValue(u8[1], 255);
        \\assert.sameValue(u8[2] = 300, 300);
        \\assert.sameValue(u8[2], 44);
        \\assert.sameValue(u8[3] = 7, 7);
        \\assert.sameValue(u8[3], undefined);
        \\const i32 = new Int32Array(1);
        \\assert.sameValue(i32[0] = -2147483648, -2147483648);
        \\assert.sameValue(i32[0], -2147483648);
        \\const f64 = new Float64Array(1);
        \\assert.sameValue(f64[0] = 42, 42);
        \\assert.sameValue(f64[0], 42);
        \\const dense = [0, 0];
        \\assert.sameValue(dense[1] = 8, 8);
        \\assert.sameValue(dense[1], 8);
        \\const detached = new Uint8Array(new ArrayBuffer(2));
        \\detached[0] = 9;
        \\detached.buffer.transfer();
        \\assert.sameValue(detached[0] = 1, 1);
        \\assert.sameValue(detached[0], undefined);
    );
    _ = result;
}

test "typed array int32 store fast arm preserves conversion and assignment semantics" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\globalThis.__typedIntStore = function (array, index, value) {
        \\  return array[index] = value;
        \\};
        \\const i8 = new Int8Array(1);
        \\assert.sameValue(__typedIntStore(i8, 0, 255), 255);
        \\assert.sameValue(i8[0], -1);
        \\const u8 = new Uint8Array(1);
        \\assert.sameValue(__typedIntStore(u8, 0, -1), -1);
        \\assert.sameValue(u8[0], 255);
        \\const u8c = new Uint8ClampedArray(2);
        \\__typedIntStore(u8c, 0, -1);
        \\__typedIntStore(u8c, 1, 300);
        \\assert.sameValue(u8c[0], 0);
        \\assert.sameValue(u8c[1], 255);
        \\const i16 = new Int16Array(1);
        \\__typedIntStore(i16, 0, 65535);
        \\assert.sameValue(i16[0], -1);
        \\const u16 = new Uint16Array(1);
        \\__typedIntStore(u16, 0, -1);
        \\assert.sameValue(u16[0], 65535);
        \\const i32 = new Int32Array(1);
        \\__typedIntStore(i32, 0, -2147483648);
        \\assert.sameValue(i32[0], -2147483648);
        \\const u32 = new Uint32Array(1);
        \\__typedIntStore(u32, 0, -1);
        \\assert.sameValue(u32[0], 4294967295);
        \\const empty = new Uint8Array(0);
        \\assert.sameValue(__typedIntStore(empty, 0, 7), 7);
        \\assert.sameValue(empty[0], undefined);
        \\const f64 = new Float64Array(1);
        \\__typedIntStore(f64, 0, 42);
        \\assert.sameValue(f64[0], 42);
        \\let coercions = 0;
        \\__typedIntStore(u8, 0, { valueOf() { coercions++; return 258; } });
        \\assert.sameValue(u8[0], 2);
        \\assert.sameValue(coercions, 1);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());

    const store = try globalFunctionBytecode(&js, "__typedIntStore");
    try std.testing.expectEqual(@as(usize, 1), try finalOpcodeCount(store.byteCode(), op.put_array_el));
}

test "checked local replacement preserves int fast moves and refcounted fallbacks" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try vm_helpers.parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function () {
        \\  let value = 1;
        \\  value = 2;
        \\  value = "left";
        \\  value = "right";
        \\  value = 3;
        \\  return value;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(?i32, 3), result.asInt32());
}

test "an expression helper emits an explicit return after a bytecode call" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try vm_helpers.parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function identity(value) { return value; })(42)
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(?i32, 42), result.asInt32());
}

test "TDZ: closure update and return of captured const throws TypeError" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    try std.testing.expectError(error.TypeError, vm_helpers.parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\const k = 11;
        \\function f() { k++; return k; }
        \\f();
    ));
}

test "forward-ref top-level lexical captured through a nested closure resolves after init" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    // `mk` is declared textually before `const G`, and only the inner closure
    // names G. The forward-capture retrofit must thread a closure-var chain
    // through `mk` (which never names G itself) down to the inner function;
    // otherwise the reference falls back to a global lookup and reads
    // undefined. Mirrors QuickJS, which resolves the whole tree post-parse.
    const result = try vm_helpers.parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\function mk() { return function inner() { return G; }; }
        \\const G = 42;
        \\mk()();
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "forward-ref lexical captured through nested closure still honors TDZ before init" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    // The retrofitted chain must capture the binding's cell (not a snapshot):
    // calling the closure before `const G` is initialized throws ReferenceError
    // (TDZ), and the same closure reads 42 once initialized. Result encodes
    // 2 = ReferenceError thrown pre-init.
    const result = try vm_helpers.parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\function mk() { return function inner() { return G; }; }
        \\const early = mk();
        \\let code = 0;
        \\try { early(); code = 1; } catch (e) { code = (e instanceof ReferenceError) ? 2 : 3; }
        \\const G = 42;
        \\code;
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 2), result.asInt32().?);
}

test "global closure get before top-level lexical initialization honors TDZ" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var let_output_buffer: [64]u8 = undefined;
    var let_output = std.Io.Writer.fixed(&let_output_buffer);
    const let_result = try js.evalWithOutput(
        \\function f() { return x + 1; }
        \\try { f(); print("no"); } catch (e) { print(e.name); }
        \\let x;
    , &let_output);
    defer let_result.free(js.runtime);
    try std.testing.expect(let_result.isUndefined());
    try std.testing.expectEqualStrings("ReferenceError\n", let_output.buffered());

    var const_output_buffer: [64]u8 = undefined;
    var const_output = std.Io.Writer.fixed(&const_output_buffer);
    const const_result = try js.evalWithOutput(
        \\function f() { return y + 1; }
        \\try { f(); print("no"); } catch (e) { print(e.name); }
        \\const y = 1;
    , &const_output);
    defer const_result.free(js.runtime);
    try std.testing.expect(const_result.isUndefined());
    try std.testing.expectEqualStrings("ReferenceError\n", const_output.buffered());
}

test "global closure set before top-level lexical initialization honors TDZ" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function f() { x = 1; }
        \\try { f(); print("no"); } catch (e) { print(e.name); }
        \\let x;
    , &output);
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("ReferenceError\n", output.buffered());
}

test "global closure update before top-level lexical initialization honors TDZ" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function f() { x++; }
        \\try { f(); print("no"); } catch (e) { print(e.name); }
        \\let x;
    , &output);
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("ReferenceError\n", output.buffered());
}

test "Annex B block function updates existing global function binding" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\{
        \\  function f() { return "inner declaration"; }
        \\}
        \\function f() {
        \\  return "outer declaration";
        \\}
        \\print(f());
    , &output);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("inner declaration\n", output.buffered());
}

test "block function declarations instantiate at scope entry" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function strictProbe() {
        \\  "use strict";
        \\  {
        \\    print(typeof strictScoped);
        \\    function strictScoped() {}
        \\    print(typeof strictScoped);
        \\  }
        \\}
        \\strictProbe();
        \\{
        \\  print(typeof annexScoped);
        \\  function annexScoped() {}
        \\}
        \\print(typeof annexScoped);
    , &output);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("function\nfunction\nfunction\nfunction\n", output.buffered());
}

test "Annex B eval block function updates global function binding mirrors" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var direct_output_buffer: [64]u8 = undefined;
    var direct_output = std.Io.Writer.fixed(&direct_output_buffer);
    const direct_result = try js.evalWithOutput(
        \\{
        \\  function f() { return "first declaration"; }
        \\}
        \\eval('{ function f() { return "second declaration"; } }');
        \\print(f());
    , &direct_output);
    defer direct_result.free(js.runtime);
    try std.testing.expect(direct_result.isUndefined());
    try std.testing.expectEqualStrings("second declaration\n", direct_output.buffered());

    var indirect_output_buffer: [64]u8 = undefined;
    var indirect_output = std.Io.Writer.fixed(&indirect_output_buffer);
    const indirect_result = try js.evalWithOutput(
        \\(0, eval)('{ function g() { return "inner declaration"; } } print(g()); function g() { return "outer declaration"; }');
    , &indirect_output);
    defer indirect_result.free(js.runtime);
    try std.testing.expect(indirect_result.isUndefined());
    try std.testing.expectEqualStrings("inner declaration\n", indirect_output.buffered());
}

test "Annex B direct eval global function does not block later script lexical declaration" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const eval_result = try js.eval(
        \\eval('if (true) { function test262Fn() {} }');
    );
    defer eval_result.free(js.runtime);
    try std.testing.expect(eval_result.isUndefined());

    const lexical_result = try js.eval(
        \\let test262Fn = 1;
    );
    defer lexical_result.free(js.runtime);
    try std.testing.expect(lexical_result.isUndefined());

    var output_buffer: [16]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const read_result = try js.evalWithOutput(
        \\print(test262Fn);
    , &output);
    defer read_result.free(js.runtime);
    try std.testing.expect(read_result.isUndefined());
    try std.testing.expectEqualStrings("1\n", output.buffered());
}

test "sloppy global assignment creates deletable object property" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var this_output_buffer: [64]u8 = undefined;
    var this_output = std.Io.Writer.fixed(&this_output_buffer);
    const this_result = try js.evalWithOutput(
        \\x = 1;
        \\print(delete this.x);
        \\print(Object.prototype.hasOwnProperty.call(this, "x"));
    , &this_output);
    defer this_result.free(js.runtime);
    try std.testing.expect(this_result.isUndefined());
    try std.testing.expectEqualStrings("true\nfalse\n", this_output.buffered());

    var global_output_buffer: [64]u8 = undefined;
    var global_output = std.Io.Writer.fixed(&global_output_buffer);
    const global_result = try js.evalWithOutput(
        \\y = 1;
        \\print(delete globalThis.y);
        \\print(Object.prototype.hasOwnProperty.call(globalThis, "y"));
    , &global_output);
    defer global_result.free(js.runtime);
    try std.testing.expect(global_result.isUndefined());
    try std.testing.expectEqualStrings("true\nfalse\n", global_output.buffered());
}

test "forward-ref top-level lexical threads through three closure levels" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    // Two intermediate functions, neither naming G, must each receive a
    // propagated closure-var link so the innermost arrow resolves G.
    const result = try vm_helpers.parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\function a() { return function b() { return () => G; }; }
        \\const G = 7;
        \\a()()();
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 7), result.asInt32().?);
}

test "top-level function declarations use wide closure operands past 255 constants" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    var source = std.ArrayList(u8).empty;
    defer source.deinit(std.testing.allocator);
    for (0..260) |index| {
        var line_buf: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "function f{d}() {{ return {d}; }}\n", .{ index, index });
        try source.appendSlice(std.testing.allocator, line);
    }
    try source.appendSlice(std.testing.allocator, "f259();");

    const result = try vm_helpers.parseStmtAndRunWithTopLevelChildren(rt, ctx, source.items);
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 259), result.asInt32().?);
}

test "function expressions execute wide closure operands past 255 constants" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "const functions = [");
    for (0..257) |index| {
        if (index != 0) try source.append(std.testing.allocator, ',');
        var expression_buffer: [32]u8 = undefined;
        const expression = try std.fmt.bufPrint(&expression_buffer, "() => {d}", .{index});
        try source.appendSlice(std.testing.allocator, expression);
    }
    try source.appendSlice(std.testing.allocator, "]; functions[256]();");

    const result = try vm_helpers.parseStmtAndRunWithTopLevelChildren(rt, ctx, source.items);
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 256), result.asInt32().?);
}

test "test262 helpers own SameValue assertions" {
    const run_test262 = @import("../cli/run_test262.zig");
    const same_nan = try run_test262.assertSameValue(core.JSValue.float64(std.math.nan(f64)), core.JSValue.float64(std.math.nan(f64)));
    try std.testing.expect(same_nan.isUndefined());
    try std.testing.expectError(error.JSException, run_test262.assertSameValue(core.JSValue.int32(1), core.JSValue.int32(2)));
}

test "call subsystem installs and invokes host globals" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);
    const run_test262 = @import("../cli/run_test262.zig");
    var wrapper = zjs.JSContext.borrowCore(ctx);
    try run_test262.installTest262Globals(rt, &wrapper, global);

    const print_key = try rt.internAtom("print");
    defer rt.atoms.free(print_key);
    const print = try global.getProperty(print_key);
    defer print.free(rt);
    const print_object: *core.Object = @fieldParentPtr("header", print.refHeader().?);
    const host_function_key = try rt.internAtom("__host_function");
    defer rt.atoms.free(host_function_key);
    try std.testing.expect((try print_object.getOwnProperty(rt, host_function_key)) == null);
    try std.testing.expectEqual(core.host_function.ids.external_host, print_object.hostFunctionKindSlot().*);
    try std.testing.expect(print_object.externalHostFunctionId() != 0);

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const args = [_]core.JSValue{ core.JSValue.int32(1), core.JSValue.boolean(true) };
    const result = try engine.exec.call.callValue(ctx, &stream, print, &args);
    defer result.free(rt);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1 true\n", stream.buffered());

    const console_key = try rt.internAtom("console");
    defer rt.atoms.free(console_key);
    const log_key = try rt.internAtom("log");
    defer rt.atoms.free(log_key);
    const console_value = try global.getProperty(console_key);
    defer console_value.free(rt);
    const console_object: *core.Object = @fieldParentPtr("header", console_value.refHeader().?);
    const log = try console_object.getProperty(log_key);
    defer log.free(rt);
    const log_object: *core.Object = @fieldParentPtr("header", log.refHeader().?);
    try std.testing.expectEqual(core.host_function.ids.external_host, log_object.hostFunctionKindSlot().*);
    try std.testing.expectEqual(print_object.externalHostFunctionId(), log_object.externalHostFunctionId());

    const log_args = [_]core.JSValue{ core.JSValue.int32(2), core.JSValue.boolean(false) };
    const log_result = try engine.exec.call.callValue(ctx, &stream, log, &log_args);
    defer log_result.free(rt);
    try std.testing.expect(log_result.isUndefined());
    try std.testing.expectEqualStrings("1 true\n2 false\n", stream.buffered());

    const assert_key = try rt.internAtom("assert");
    defer rt.atoms.free(assert_key);
    const same_value_key = try rt.internAtom("sameValue");
    defer rt.atoms.free(same_value_key);
    const assert_object_value = try global.getProperty(assert_key);
    defer assert_object_value.free(rt);
    const assert_object_header = assert_object_value.refHeader().?;
    const assert_object: *core.Object = @fieldParentPtr("header", assert_object_header);
    const same_value = try assert_object.getProperty(same_value_key);
    defer same_value.free(rt);

    const same_args = [_]core.JSValue{ core.JSValue.float64(std.math.nan(f64)), core.JSValue.float64(std.math.nan(f64)) };
    const same_result = try engine.exec.call.callValue(ctx, null, same_value, &same_args);
    defer same_result.free(rt);
    try std.testing.expect(same_result.isUndefined());
    const mismatch_args = [_]core.JSValue{ core.JSValue.int32(1), core.JSValue.int32(2) };
    try std.testing.expectError(error.JSException, engine.exec.call.callValue(ctx, null, same_value, &mismatch_args));

    const test262_key = try rt.internAtom("Test262Error");
    defer rt.atoms.free(test262_key);
    const test262_ctor = try global.getProperty(test262_key);
    defer test262_ctor.free(rt);
    const test262_error = try engine.exec.call.callValue(ctx, null, test262_ctor, &.{});
    defer test262_error.free(rt);
    try std.testing.expect(test262_error.isObject());

    const map_value = try engine.exec.collection_ops.construct(ctx, 1);
    defer map_value.free(rt);
    const map_object: *core.Object = @fieldParentPtr("header", map_value.refHeader().?);
    const set_key = try rt.internAtom("set");
    defer rt.atoms.free(set_key);
    const get_key = try rt.internAtom("get");
    defer rt.atoms.free(get_key);
    const map_set = try map_object.getProperty(set_key);
    defer map_set.free(rt);
    const map_get = try map_object.getProperty(get_key);
    defer map_get.free(rt);
    const stored_key_obj = try core.string.String.createUtf8(rt, "key");
    const stored_key = stored_key_obj.value();
    defer stored_key.free(rt);
    const stored_value_obj = try core.string.String.createUtf8(rt, "value");
    const stored_value = stored_value_obj.value();
    defer stored_value.free(rt);
    const set_args = [_]core.JSValue{ stored_key, stored_value };
    const set_result = try engine.exec.call.callValueWithThis(ctx, null, map_value, map_set, &set_args);
    defer set_result.free(rt);
    try std.testing.expect(set_result.same(map_value));
    try std.testing.expectError(error.TypeError, engine.exec.call.callValue(ctx, null, map_set, &set_args));
    const get_result = try engine.exec.call.callValueWithThis(ctx, null, map_value, map_get, &.{stored_key});
    defer get_result.free(rt);
    var get_text = std.ArrayList(u8).empty;
    defer get_text.deinit(rt.memory.allocator);
    try engine.exec.value_ops.appendRawString(rt, &get_text, get_result);
    try std.testing.expectEqualStrings("value", get_text.items);
}

test "native builtin record dispatch is independent from dispatch-name strings" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const math_key = try rt.internAtom("Math");
    defer rt.atoms.free(math_key);
    const abs_key = try rt.internAtom("abs");
    defer rt.atoms.free(abs_key);
    const math_value = try global.getProperty(math_key);
    defer math_value.free(rt);
    const math_object: *core.Object = @fieldParentPtr("header", math_value.refHeader().?);
    const abs_value = try math_object.getProperty(abs_key);
    defer abs_value.free(rt);
    const abs_object: *core.Object = @fieldParentPtr("header", abs_value.refHeader().?);
    try std.testing.expect(abs_object.nativeFunctionIdSlot().* != 0);
    const abs_record = abs_object.nativeRecord() orelse return error.InvalidBuiltinRegistry;
    try std.testing.expectEqual(core.host_function.NativeCProto.f_f, abs_record.cproto);
    try std.testing.expect(abs_record.native_function != null);

    const atan2_key = try rt.internAtom("atan2");
    defer rt.atoms.free(atan2_key);
    const atan2_value = try math_object.getProperty(atan2_key);
    defer atan2_value.free(rt);
    const atan2_object: *core.Object = @fieldParentPtr("header", atan2_value.refHeader().?);
    const atan2_record = atan2_object.nativeRecord() orelse return error.InvalidBuiltinRegistry;
    try std.testing.expectEqual(core.host_function.NativeCProto.f_f_f, atan2_record.cproto);
    try std.testing.expect(atan2_record.native_function != null);

    const fake = try engine.core.function.nativeFunction(ctx, "notMathAbs", 1);
    defer fake.free(rt);
    const fake_object: *core.Object = @fieldParentPtr("header", fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = abs_object.nativeFunctionIdSlot().*;

    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notMathAbs", dispatch_name);

    const args = [_]core.JSValue{core.JSValue.int32(-8)};
    const result = try engine.exec.call.callValue(ctx, null, fake, &args);
    defer result.free(rt);
    try std.testing.expectEqual(@as(f64, 8.0), engine.exec.value_ops.numberValue(result).?);

    // Plain op_call must prefer the resolved record memo. The encoded id is a
    // bootstrap key, not work to repeat after the function object is bound.
    fake_object.nativeRecordSlot().* = abs_record;
    fake_object.nativeFunctionIdSlot().* = 0;
    const memo_result = try engine.exec.call.callValue(ctx, null, fake, &args);
    defer memo_result.free(rt);
    try std.testing.expectEqual(@as(f64, 8.0), engine.exec.value_ops.numberValue(memo_result).?);

    const fake_key = try rt.internAtom("fake");
    defer rt.atoms.free(fake_key);
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, true, false, true));

    var parsed = try engine.parser.compile(.{ .realm = ctx }, "print(fake(-8));", .{ .mode = .script, .filename = "native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stackLimit());
    defer stack.deinit(rt);
    var output_buffer: [16]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("8\n", output.buffered());
}

test "bytecode calls execute directly from the shared function bytecode" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const definition = try js.eval(
        \\function directFunctionBytecode(value) {
        \\    return value + 1;
        \\}
        \\undefined;
    );
    defer definition.free(js.runtime);
    try std.testing.expect(definition.isUndefined());

    const global = js.context.global.?;
    const name = try js.runtime.internAtom("directFunctionBytecode");
    defer js.runtime.atoms.free(name);
    const function_value = try global.getProperty(name);
    defer function_value.free(js.runtime);
    const function_object = engine.exec.object_ops.functionObjectFromValue(function_value) orelse
        return error.InvalidFunctionBytecode;
    const fb = function_object.bytecodeFunctionStoragePtr().function_bytecode orelse
        return error.InvalidFunctionBytecode;
    try std.testing.expect(!@hasField(bytecode.FunctionBytecode, "cached_view"));
    try std.testing.expect(fb.byteCode().len != 0);
    const function_bytecode_refs = fb.header.meta().rc;

    const first_args = [_]core.JSValue{core.JSValue.int32(1)};
    const first = try engine.exec.call.callValueWithThisGlobalsAndGlobal(
        js.context,
        null,
        global,
        &.{},
        core.JSValue.undefinedValue(),
        function_value,
        &first_args,
    );
    defer first.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 2), first.asInt32());
    try std.testing.expectEqual(function_bytecode_refs, fb.header.meta().rc);

    const second_args = [_]core.JSValue{core.JSValue.int32(2)};
    const second = try engine.exec.call.callValueWithThisGlobalsAndGlobal(
        js.context,
        null,
        global,
        &.{},
        core.JSValue.undefinedValue(),
        function_value,
        &second_args,
    );
    defer second.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 3), second.asInt32());
    try std.testing.expectEqual(function_bytecode_refs, fb.header.meta().rc);

    const rerun = try js.eval(
        \\assert.sameValue(directFunctionBytecode(3), 4);
        \\Promise.resolve(4)
        \\    .then(function(value) {
        \\        var holder = { method: directFunctionBytecode };
        \\        return holder.method(value);
        \\    })
        \\    .then(function(value) {
        \\        assert.sameValue(value, 5);
        \\    });
        \\undefined;
    );
    defer rerun.free(js.runtime);
    try std.testing.expect(rerun.isUndefined());
}

test "Math cproto dispatch preserves observable ToNumber semantics" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var log = "";
        \\var lhs = { valueOf() { log += "l"; return -3; } };
        \\var rhs = { valueOf() { log += "r"; return 4; } };
        \\print(Math.abs(lhs));
        \\print(Math.atan2(lhs, rhs) === Math.atan2(-3, 4));
        \\print(log);
        \\print(Number.isNaN(Math.abs()));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("3\ntrue\nllr\ntrue\n", stream.buffered());
}

test "local add_loc retains string snapshots while using a rope tail" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function build() {
        \\  var text = "";
        \\  for (var i = 0; i < 4096; i++) text += "ab";
        \\  return text;
        \\}
        \\function verifySnapshot() {
        \\  var text = "";
        \\  var snapshot;
        \\  for (var i = 0; i < 4096; i++) {
        \\    if (i === 2048) snapshot = text;
        \\    text += "ab";
        \\  }
        \\  return snapshot.length;
        \\}
        \\if (verifySnapshot() !== 4096) throw new Error("snapshot mutated");
        \\globalThis.__rope_tail_probe = build();
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());

    const global = js.context.global orelse return error.TypeError;
    const probe_atom = try js.runtime.internAtom("__rope_tail_probe");
    defer js.runtime.atoms.free(probe_atom);
    const text = try global.getProperty(probe_atom);
    defer text.free(js.runtime);
    const rope = text.ropeBody() orelse return error.TypeError;
    try std.testing.expectEqual(@as(usize, 8192), rope.len_());
    try std.testing.expect(rope.tailLen() >= 2048);
    var chain_depth: usize = 1;
    var cursor = rope;
    while (cursor.left.ropeBody()) |left| {
        chain_depth += 1;
        if (chain_depth > 8) break;
        cursor = left;
    }
    try std.testing.expect(chain_depth <= 4);
}

test "add_loc string+object goes through slow add after toPrimitive (qjs OP_add_loc)" {
    // X-03: qjs:19766-19767 requires both operands already JS_TAG_STRING
    // before in-place concat. An object RHS must take js_add_slow so a
    // toString that reassigns the accumulator cannot mutate a stale rope.

    try helpers.expectPrints(
        \\function f(){
        \\  var s = "abc";
        \\  var stash = null;
        \\  s = s + "d";
        \\  var o = { toString: function(){ stash = s; s = "ZZZ"; return "Q"; } };
        \\  s = s + o;
        \\  return "s=" + s + " stash=" + stash;
        \\}
        \\print(f());
        \\function plusEq(){
        \\  var s = "abc";
        \\  var stash = null;
        \\  s = s + "d";
        \\  var o = { toString: function(){ stash = s; s = "ZZZ"; return "Q"; } };
        \\  s += o;
        \\  return "s=" + s + " stash=" + stash;
        \\}
        \\print(plusEq());
        \\function viaValueOf(){
        \\  var s = "abc";
        \\  var stash = null;
        \\  s = s + "d";
        \\  var o = { valueOf: function(){ stash = s; s = "ZZZ"; return "Q"; } };
        \\  s = s + o;
        \\  return "s=" + s + " stash=" + stash;
        \\}
        \\print(viaValueOf());
        \\function viaToPrim(){
        \\  var s = "abc";
        \\  var stash = null;
        \\  s = s + "d";
        \\  var o = { [Symbol.toPrimitive]: function(){ stash = s; s = "ZZZ"; return "Q"; } };
        \\  s = s + o;
        \\  return "s=" + s + " stash=" + stash;
        \\}
        \\print(viaToPrim());
        \\function viaClosure(){
        \\  var s = "abc";
        \\  var stash = null;
        \\  s = s + "d";
        \\  function cap(){ return s; }
        \\  var o = { toString: function(){ stash = s; s = "ZZZ"; return "Q"; } };
        \\  s = s + o;
        \\  return "s=" + s + " stash=" + stash + " cap=" + cap();
        \\}
        \\print(viaClosure());
        \\function longRope(){
        \\  var s = "";
        \\  for (var i = 0; i < 9000; i++) s += "a";
        \\  var stash = null;
        \\  s = s + "d";
        \\  var o = { toString: function(){ stash = s; s = "ZZZ"; return "Q"; } };
        \\  s = s + o;
        \\  return "s_len=" + s.length + " s_is_ZZZ=" + (s === "ZZZ") + " stash_len=" + stash.length;
        \\}
        \\print(longRope());
        \\function noTailSidecar(){
        \\  var base = "abc";
        \\  var t = base + "y";
        \\  var stash = null;
        \\  var o = { toString: function(){ stash = t; t = "ZZZ"; return "Q"; } };
        \\  t = t + o;
        \\  return "t=" + t + " stash=" + stash;
        \\}
        \\print(noTailSidecar());
        \\function toStringNumber(){
        \\  var s = "abc";
        \\  var stash = null;
        \\  s = s + "d";
        \\  var o = { toString: function(){ stash = s; s = "ZZZ"; return 1; } };
        \\  s = s + o;
        \\  return "s=" + s + " stash=" + stash;
        \\}
        \\print(toStringNumber());
        \\function notAddLoc(){
        \\  var s = "abc";
        \\  var stash = null;
        \\  s = s + "d";
        \\  var o = { toString: function(){ stash = s; s = "ZZZ"; return "Q"; } };
        \\  var r = s + o;
        \\  return "s=" + s + " r=" + r + " stash=" + stash;
        \\}
        \\print(notAddLoc());
    , "s=abcdQ stash=abcd\n" ++
        "s=abcdQ stash=abcd\n" ++
        "s=abcdQ stash=abcd\n" ++
        "s=abcdQ stash=abcd\n" ++
        "s=abcdQ stash=abcd cap=abcdQ\n" ++
        "s_len=9002 s_is_ZZZ=false stash_len=9001\n" ++
        "t=abcyQ stash=abcy\n" ++
        "s=abcd1 stash=abcd\n" ++
        "s=ZZZ r=abcdQ stash=abcd\n");
}

test "checked lexical string accumulation keeps rope depth bounded" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function build() {
        \\  let text = "";
        \\  let snapshot;
        \\  for (var i = 0; i < 8192; i++) {
        \\    if (i === 4096) snapshot = text;
        \\    text += "ab";
        \\  }
        \\  if (snapshot.length !== 8192) throw new Error("snapshot mutated");
        \\  return text;
        \\}
        \\globalThis.__checked_lexical_rope_probe = build();
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());

    const global = js.context.global orelse return error.TypeError;
    const probe_atom = try js.runtime.internAtom("__checked_lexical_rope_probe");
    defer js.runtime.atoms.free(probe_atom);
    const text = try global.getProperty(probe_atom);
    defer text.free(js.runtime);
    const rope = text.ropeBody() orelse return error.TypeError;
    try std.testing.expectEqual(@as(usize, 16384), rope.len_());

    // QJS caps rope depth and rebalances; zjs may use its private growable tail,
    // but must likewise avoid retaining one wrapper node per `+=` iteration.
    var left_depth: usize = 1;
    var cursor = rope;
    while (cursor.left.ropeBody()) |left| {
        left_depth += 1;
        if (left_depth > 64) break;
        cursor = left;
    }
    try std.testing.expect(left_depth <= 64);
}

test "computed reads with cached string atoms preserve exotic and prototype semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const proto = { get hot() { return 7; } };
        \\const object = Object.create(proto);
        \\assert.sameValue(object["hot"], 7);
        \\let trapCalls = 0;
        \\const proxy = new Proxy(object, {
        \\  get(target, key, receiver) {
        \\    trapCalls++;
        \\    return Reflect.get(target, key, receiver);
        \\  }
        \\});
        \\assert.sameValue(proxy["hot"], 7);
        \\assert.sameValue(trapCalls, 1);
        \\assert.sameValue([11]["0"], 11);
        \\assert.sameValue("ab"["1"], "b");
        \\assert.sameValue(new Uint8Array([9])["0"], 9);
        \\const dynamic = "dynamic" + "Key";
        \\const keyed = { dynamicKey: 13 };
        \\assert.sameValue(keyed[dynamic], 13);
        \\assert.sameValue(keyed[dynamic], 13);
        \\let holder;
        \\const recycledKey = "recycled_key_" + 12345;
        \\holder = {};
        \\holder[recycledKey] = 1;
        \\const invariantTarget = {};
        \\const recyclingProxy = new Proxy(invariantTarget, {
        \\  get(target, key) {
        \\    delete holder[recycledKey];
        \\    holder = null;
        \\    const replacementKey = "replacement_key_" + 67890;
        \\    Object.defineProperty(target, replacementKey, {
        \\      value: 123,
        \\      configurable: false,
        \\      writable: false
        \\    });
        \\    return 456;
        \\  }
        \\});
        \\assert.sameValue(recyclingProxy[recycledKey], 456);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "native dispatch metadata is internal and ignores user properties" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var f = Object.prototype.isPrototypeOf;
        \\print("__zjs_native_name" in f);
        \\print(Object.getOwnPropertyDescriptor(f, "__zjs_native_name") === undefined);
        \\f.__zjs_native_name = "notIsPrototypeOf";
        \\print(f.call(Object.prototype, {}));
        \\print(delete f.__zjs_native_name);
        \\print(f.call(Object.prototype, {}));
        \\var a = [];
        \\Array.prototype.push.__zjs_native_name = "notPush";
        \\print(Array.prototype.push.call(a, 1));
        \\print(delete Array.prototype.push.__zjs_native_name);
        \\print(Array.prototype.push.call(a, 2));
        \\print(a.length);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false\ntrue\ntrue\ntrue\ntrue\n1\ntrue\n2\n2\n", stream.buffered());
}

test "scope resolver skips popped lexical shadow for destructured parameter" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function f({ comment, items }) {
        \\  { let comment = null; }
        \\  for (let i = 0; i < items.length; ++i) {
        \\    let comment = "inner";
        \\  }
        \\  return comment;
        \\}
        \\assert.sameValue(f({ comment: "ok", items: [1] }), "ok");
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "__zjs-prefixed user properties are ordinary own properties" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var o = {};
        \\o.__zjs_user = 1;
        \\Object.defineProperty(o, "__zjs_non_enum", { value: 2, enumerable: false, configurable: true });
        \\print(Object.getOwnPropertyNames(o).join("|"));
        \\print(Object.getOwnPropertyDescriptors(o).__zjs_user.value);
        \\print(Object.getOwnPropertyDescriptor(o, "__zjs_non_enum").value);
        \\print(Reflect.ownKeys(o).join("|"));
        \\print(Object.keys(o).join("|"));
        \\print("__zjs_user" in o);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("__zjs_user|__zjs_non_enum\n1\n2\n__zjs_user|__zjs_non_enum\n__zjs_user\ntrue\n", stream.buffered());
}

test "array species fast path markers are internal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var getter = Object.getOwnPropertyDescriptor(Array, Symbol.species).get;
        \\print("__zjs_array_constructor" in Array);
        \\print(Object.getOwnPropertyDescriptor(Array, "__zjs_array_constructor") === undefined);
        \\print("__zjs_array_species_getter" in getter);
        \\print(Object.getOwnPropertyDescriptor(getter, "__zjs_array_species_getter") === undefined);
        \\Array.__zjs_array_constructor = 0;
        \\getter.__zjs_array_species_getter = 0;
        \\var mapped = [1, 2].map(function(value) { return value + 1; });
        \\print(mapped instanceof Array);
        \\print(mapped.join(","));
        \\print(delete Array.__zjs_array_constructor);
        \\print(delete getter.__zjs_array_species_getter);
        \\print([3].filter(function() { return true; }).join(","));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false\ntrue\nfalse\ntrue\ntrue\n2,3\ntrue\ntrue\n3\n", stream.buffered());
}

test "auto-init builtin markers are internal and ignore user properties" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function check(fn, marker, run) {
        \\  print(marker in fn);
        \\  print(Object.getOwnPropertyDescriptor(fn, marker) === undefined);
        \\  fn[marker] = 0;
        \\  print(run());
        \\  print(delete fn[marker]);
        \\  print(run());
        \\}
        \\check(Object.assign, "__zjs_object_static", function() {
        \\  var target = {};
        \\  Object.assign(target, { x: 1 });
        \\  return target.x;
        \\});
        \\check(Object.defineProperty, "__zjs_define_property_kind", function() {
        \\  var object = {};
        \\  Object.defineProperty(object, "x", { value: 1 });
        \\  return object.x;
        \\});
        \\check(Object.prototype.hasOwnProperty, "__zjs_object_method", function() {
        \\  return Object.prototype.hasOwnProperty.call({ x: 1 }, "x");
        \\});
        \\check(String.prototype.includes, "__zjs_string_method", function() {
        \\  return "abc".includes("b");
        \\});
        \\check(Number.prototype.toFixed, "__zjs_number_method", function() {
        \\  return (7).toFixed(0);
        \\});
        \\check(RegExp.prototype.test, "__zjs_regexp_method", function() {
        \\  return /a/.test("a");
        \\});
        \\check(RegExp.escape, "__zjs_regexp_escape", function() {
        \\  return RegExp.escape("a+b") === "\\x61\\+b";
        \\});
        \\check(JSON.parse, "__zjs_json_static", function() {
        \\  return JSON.parse("{\"x\":1}").x;
        \\});
        \\check(JSON.stringify, "__zjs_json_static", function() {
        \\  return JSON.stringify({ x: 1 });
        \\});
        \\check(Reflect.apply, "__zjs_reflect_static", function() {
        \\  return Reflect.apply(function(x) { return x + 1; }, null, [2]);
        \\});
        \\check(Reflect.setPrototypeOf, "__zjs_reflect_set_prototype_of", function() {
        \\  var proto = { x: 1 };
        \\  var object = {};
        \\  return Reflect.setPrototypeOf(object, proto) && object.x;
        \\});
        \\check(Reflect.defineProperty, "__zjs_define_property_kind", function() {
        \\  var object = {};
        \\  return Reflect.defineProperty(object, "x", { value: 1 }) && object.x;
        \\});
        \\check(Atomics.isLockFree, "__zjs_atomics_static", function() {
        \\  return Atomics.isLockFree(4);
        \\});
        \\check(Array.prototype.concat, "__zjs_array_concat", function() {
        \\  return [1].concat([2]).join(",");
        \\});
        \\check(ArrayBuffer.prototype.slice, "__zjs_buffer_method_kind", function() {
        \\  return new ArrayBuffer(4).slice(1).byteLength;
        \\});
        \\check(SharedArrayBuffer.prototype.slice, "__zjs_buffer_method_kind", function() {
        \\  return new SharedArrayBuffer(4).slice(1).byteLength;
        \\});
        \\check(Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, "byteLength").get, "__zjs_buffer_accessor_kind", function() {
        \\  return new ArrayBuffer(4).byteLength;
        \\});
        \\check(Object.getOwnPropertyDescriptor(SharedArrayBuffer.prototype, "byteLength").get, "__zjs_buffer_accessor_kind", function() {
        \\  return new SharedArrayBuffer(4).byteLength;
        \\});
        \\check(Object.getOwnPropertyDescriptor(DataView.prototype, "byteLength").get, "__zjs_dataview_accessor", function() {
        \\  return new DataView(new ArrayBuffer(6), 1, 3).byteLength;
        \\});
        \\check(Object.getOwnPropertyDescriptor(Object.getPrototypeOf(Uint8Array.prototype), "length").get, "__zjs_typedarray_accessor", function() {
        \\  return new Uint8Array(5).length;
        \\});
        \\check(Uint8Array.prototype.slice, "__zjs_typedarray_method", function() {
        \\  return new Uint8Array([1, 2]).slice(1)[0];
        \\});
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "false\ntrue\n1\ntrue\n1\n" ++
            "false\ntrue\n1\ntrue\n1\n" ++
            "false\ntrue\ntrue\ntrue\ntrue\n" ++
            "false\ntrue\ntrue\ntrue\ntrue\n" ++
            "false\ntrue\n7\ntrue\n7\n" ++
            "false\ntrue\ntrue\ntrue\ntrue\n" ++
            "false\ntrue\ntrue\ntrue\ntrue\n" ++
            "false\ntrue\n1\ntrue\n1\n" ++
            "false\ntrue\n{\"x\":1}\ntrue\n{\"x\":1}\n" ++
            "false\ntrue\n3\ntrue\n3\n" ++
            "false\ntrue\n1\ntrue\n1\n" ++
            "false\ntrue\n1\ntrue\n1\n" ++
            "false\ntrue\ntrue\ntrue\ntrue\n" ++
            "false\ntrue\n1,2\ntrue\n1,2\n" ++
            "false\ntrue\n3\ntrue\n3\n" ++
            "false\ntrue\n3\ntrue\n3\n" ++
            "false\ntrue\n4\ntrue\n4\n" ++
            "false\ntrue\n4\ntrue\n4\n" ++
            "false\ntrue\n3\ntrue\n3\n" ++
            "false\ntrue\n5\ntrue\n5\n" ++
            "false\ntrue\n2\ntrue\n2\n",
        stream.buffered(),
    );
}

test "immutable prototype marker is internal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print("__zjs_immutable_prototype" in Object.prototype);
        \\print(Object.getOwnPropertyDescriptor(Object.prototype, "__zjs_immutable_prototype") === undefined);
        \\Object.prototype.__zjs_immutable_prototype = false;
        \\print(Reflect.setPrototypeOf(Object.prototype, {}));
        \\try { Object.setPrototypeOf(Object.prototype, {}); print("no throw"); } catch (e) { print(e.name); }
        \\print(delete Object.prototype.__zjs_immutable_prototype);
        \\print(Reflect.setPrototypeOf(Object.prototype, null));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false\ntrue\nfalse\nTypeError\ntrue\ntrue\n", stream.buffered());
}

test "builtin dispatch function markers are internal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function check(fn, marker, run) {
        \\  print(marker in fn);
        \\  print(Object.getOwnPropertyDescriptor(fn, marker) === undefined);
        \\  fn[marker] = 0;
        \\  print(run());
        \\  print(delete fn[marker]);
        \\  print(run());
        \\}
        \\check(Function.prototype.toString, "__zjs_function_to_string", function() {
        \\  return typeof Function.prototype.toString.call(Array.prototype.push);
        \\});
        \\check(Error.prototype.toString, "__zjs_error_to_string", function() {
        \\  return Error.prototype.toString.call({ name: "E", message: "m" });
        \\});
        \\var constructorDesc = Object.getOwnPropertyDescriptor(Iterator.prototype, "constructor");
        \\var tagDesc = Object.getOwnPropertyDescriptor(Iterator.prototype, Symbol.toStringTag);
        \\check(constructorDesc.get, "__zjs_iterator_accessor", function() {
        \\  return constructorDesc.get.call(Iterator.prototype) === Iterator;
        \\});
        \\check(tagDesc.get, "__zjs_iterator_accessor", function() {
        \\  return tagDesc.get.call(Iterator.prototype);
        \\});
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "false\ntrue\nstring\ntrue\nstring\n" ++
            "false\ntrue\nE: m\ntrue\nE: m\n" ++
            "false\ntrue\ntrue\ntrue\ntrue\n" ++
            "false\ntrue\nIterator\ntrue\nIterator\n",
        stream.buffered(),
    );
}

test "proxy revocation target is internal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var r = Proxy.revocable({ x: 1 }, {});
        \\var revoke = r.revoke;
        \\print("__zjs_revoke_proxy" in revoke);
        \\print(Object.getOwnPropertyDescriptor(revoke, "__zjs_revoke_proxy") === undefined);
        \\revoke.__zjs_revoke_proxy = null;
        \\print(revoke.__zjs_revoke_proxy === null);
        \\revoke();
        \\var threw = false;
        \\try {
        \\  r.proxy.x;
        \\} catch (e) {
        \\  threw = e instanceof TypeError;
        \\}
        \\print(threw);
        \\print(delete revoke.__zjs_revoke_proxy);
        \\print("__zjs_revoke_proxy" in revoke);
        \\var r2 = Proxy.revocable({ y: 2 }, {});
        \\print(delete r2.revoke.__zjs_revoke_proxy);
        \\r2.revoke();
        \\var threw2 = false;
        \\try {
        \\  r2.proxy.y;
        \\} catch (e) {
        \\  threw2 = e instanceof TypeError;
        \\}
        \\print(threw2);
        \\r2.revoke();
        \\print("done");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false\ntrue\ntrue\ntrue\ntrue\nfalse\ntrue\ntrue\ndone\n", stream.buffered());
}

test "regexp accessor realm TypeError constructor is internal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var getter = Object.getOwnPropertyDescriptor(RegExp.prototype, "source").get;
        \\print("__zjs_realm_TypeError" in getter);
        \\print(Object.getOwnPropertyDescriptor(getter, "__zjs_realm_TypeError") === undefined);
        \\function Fake(message) {
        \\  this.message = message;
        \\}
        \\Fake.prototype = Object.create(Error.prototype);
        \\Fake.prototype.constructor = Fake;
        \\getter.__zjs_realm_TypeError = Fake;
        \\try {
        \\  getter.call({});
        \\} catch (e) {
        \\  print(e.constructor === Fake);
        \\  print(e instanceof TypeError);
        \\}
        \\print(delete getter.__zjs_realm_TypeError);
        \\try {
        \\  getter.call({});
        \\} catch (e) {
        \\  print(e instanceof TypeError);
        \\}
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false\ntrue\nfalse\ntrue\ntrue\ntrue\n", stream.buffered());
}

test "throw type error intrinsic marker is internal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\"use strict";
        \\print("__zjs_throw_type_error_intrinsic" in globalThis);
        \\print(Object.getOwnPropertyDescriptor(globalThis, "__zjs_throw_type_error_intrinsic") === undefined);
        \\globalThis.__zjs_throw_type_error_intrinsic = function() { return 1; };
        \\print("__zjs_throw_type_error_intrinsic" in globalThis);
        \\print(delete globalThis.__zjs_throw_type_error_intrinsic);
        \\print("__zjs_throw_type_error_intrinsic" in globalThis);
        \\var thrower = Object.getOwnPropertyDescriptor(Function.prototype, "arguments").get;
        \\print(typeof thrower);
        \\print("__zjs_throw_type_error_function_proto" in thrower);
        \\print(Object.getOwnPropertyDescriptor(thrower, "__zjs_throw_type_error_function_proto") === undefined);
        \\var assignType = "none";
        \\try {
        \\  thrower.__zjs_throw_type_error_function_proto = false;
        \\} catch (e) {
        \\  assignType = e.name;
        \\}
        \\print(assignType);
        \\print("__zjs_throw_type_error_function_proto" in thrower);
        \\print(delete thrower.__zjs_throw_type_error_function_proto);
        \\var threw = false;
        \\try {
        \\  thrower();
        \\} catch (e) {
        \\  threw = e instanceof TypeError;
        \\}
        \\print(threw);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false\ntrue\ntrue\ntrue\nfalse\nfunction\nfalse\ntrue\nTypeError\nfalse\ntrue\ntrue\n", stream.buffered());

    const probe_result = try js.eval("globalThis.__thrower_probe = Object.getOwnPropertyDescriptor(Function.prototype, \"arguments\").get;");
    defer probe_result.free(js.runtime);
    try std.testing.expect(js.context.global != null);
    const global = js.context.global.?;
    const probe_key = try js.runtime.internAtom("__thrower_probe");
    defer js.runtime.atoms.free(probe_key);
    const thrower_value = try global.getProperty(probe_key);
    defer thrower_value.free(js.runtime);
    const thrower_object = try property_ops.expectObject(thrower_value);
    const dispatch_atom = thrower_object.nativeDispatchName();
    try std.testing.expect(dispatch_atom != core.atom.null_atom);
    const dispatch_name = js.runtime.atoms.name(dispatch_atom);
    try std.testing.expect(dispatch_name != null);
    try std.testing.expectEqualStrings("", dispatch_name.?);
}

test "async generator prototype method marker is internal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\async function* g() {}
        \\var AsyncGeneratorPrototype = Object.getPrototypeOf(g.prototype);
        \\var next = AsyncGeneratorPrototype.next;
        \\print("__zjs_async_generator_method" in next);
        \\print(Object.getOwnPropertyDescriptor(next, "__zjs_async_generator_method") === undefined);
        \\next.__zjs_async_generator_method = 0;
        \\print("__zjs_async_generator_method" in next);
        \\print(delete next.__zjs_async_generator_method);
        \\print("__zjs_async_generator_method" in next);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false\ntrue\ntrue\ntrue\nfalse\n", stream.buffered());
}

test "generator instances inherit shared prototype methods" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function* syncGenerator() { yield 1; }
        \\var syncA = syncGenerator();
        \\var syncB = syncGenerator();
        \\var GeneratorPrototype = Object.getPrototypeOf(syncGenerator.prototype);
        \\var arrayIteratorForNativeRecord = [][Symbol.iterator]();
        \\print(Object.getOwnPropertyNames(syncA).length);
        \\print(syncA.next === GeneratorPrototype.next);
        \\print(syncA.return === GeneratorPrototype.return);
        \\print(syncA.throw === GeneratorPrototype.throw);
        \\print(syncA.next === syncB.next);
        \\print(syncA.next.length);
        \\print(typeof syncA.slice);
        \\var calls = 0;
        \\var overridden = syncGenerator();
        \\var builtinNext = overridden.next;
        \\overridden.next = function() {
        \\  calls++;
        \\  return builtinNext.call(this);
        \\};
        \\var values = [];
        \\for (var value of overridden) values.push(value);
        \\print(calls + ":" + values.join(","));
        \\var customGeneratorPrototype = Object.create(GeneratorPrototype);
        \\syncGenerator.prototype = customGeneratorPrototype;
        \\var customSync = syncGenerator();
        \\print(Object.getPrototypeOf(customSync) === customGeneratorPrototype);
        \\print(customSync.next === GeneratorPrototype.next);
        \\syncGenerator.prototype = 1;
        \\print(Object.getPrototypeOf(syncGenerator()) === GeneratorPrototype);
        \\async function* asyncGenerator() { yield 1; }
        \\var asyncA = asyncGenerator();
        \\var asyncB = asyncGenerator();
        \\var AsyncGeneratorPrototype = Object.getPrototypeOf(asyncGenerator.prototype);
        \\print(Object.getOwnPropertyNames(asyncA).length);
        \\print(asyncA.next === AsyncGeneratorPrototype.next);
        \\print(asyncA.return === AsyncGeneratorPrototype.return);
        \\print(asyncA.throw === AsyncGeneratorPrototype.throw);
        \\print(asyncA.next === asyncB.next);
        \\print(asyncA.next.length);
        \\print(typeof asyncA.slice);
        \\var customAsyncGeneratorPrototype = Object.create(AsyncGeneratorPrototype);
        \\asyncGenerator.prototype = customAsyncGeneratorPrototype;
        \\print(Object.getPrototypeOf(asyncGenerator()) === customAsyncGeneratorPrototype);
        \\asyncGenerator.prototype = null;
        \\print(Object.getPrototypeOf(asyncGenerator()) === AsyncGeneratorPrototype);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "0\ntrue\ntrue\ntrue\ntrue\n1\nundefined\n2:1\ntrue\ntrue\ntrue\n0\ntrue\ntrue\ntrue\ntrue\n1\nundefined\ntrue\ntrue\n",
        stream.buffered(),
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const sync_key = try js.runtime.internAtom("syncA");
    defer js.runtime.atoms.free(sync_key);
    const sync_value = try global.getProperty(sync_key);
    defer sync_value.free(js.runtime);
    const sync_object = try property_ops.expectObject(sync_value);
    try std.testing.expect(!js.runtime.borrowedReferenceHolderRegistered(sync_object));
    try std.testing.expectEqual(global, engine.exec.object_ops.objectRealmGlobal(sync_object).?);

    const generator_prototype_key = try js.runtime.internAtom("GeneratorPrototype");
    defer js.runtime.atoms.free(generator_prototype_key);
    const generator_prototype_value = try global.getProperty(generator_prototype_key);
    defer generator_prototype_value.free(js.runtime);
    const generator_prototype = try property_ops.expectObject(generator_prototype_value);
    const IntrinsicMethod = core.host_function.builtin_method_ids.iterator.IntrinsicMethod;
    const generator_methods = [_]struct { name: []const u8, id: u32 }{
        .{ .name = "next", .id = @intFromEnum(IntrinsicMethod.generator_next) },
        .{ .name = "return", .id = @intFromEnum(IntrinsicMethod.generator_return) },
        .{ .name = "throw", .id = @intFromEnum(IntrinsicMethod.generator_throw) },
    };
    for (generator_methods) |method| {
        const key = try js.runtime.internAtom(method.name);
        defer js.runtime.atoms.free(key);
        const value = try generator_prototype.getProperty(key);
        defer value.free(js.runtime);
        const function_object = try property_ops.expectObject(value);
        const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionIdSlot().*) orelse return error.InvalidBuiltinRegistry;
        try std.testing.expectEqual(core.function.NativeBuiltinDomain.iterator, native_ref.domain);
        try std.testing.expectEqual(method.id, native_ref.id);
        try std.testing.expect(function_object.nativeRecord() != null);
    }

    const array_iterator_key = try js.runtime.internAtom("arrayIteratorForNativeRecord");
    defer js.runtime.atoms.free(array_iterator_key);
    const array_iterator_value = try global.getProperty(array_iterator_key);
    defer array_iterator_value.free(js.runtime);
    const array_iterator = try property_ops.expectObject(array_iterator_value);
    const next_key = try js.runtime.internAtom("next");
    defer js.runtime.atoms.free(next_key);
    const next_value = try array_iterator.getProperty(next_key);
    defer next_value.free(js.runtime);
    const next_function = try property_ops.expectObject(next_value);
    const next_ref = core.function.decodeNativeBuiltinId(next_function.nativeFunctionIdSlot().*) orelse return error.InvalidBuiltinRegistry;
    try std.testing.expectEqual(core.function.NativeBuiltinDomain.iterator, next_ref.domain);
    try std.testing.expectEqual(@intFromEnum(IntrinsicMethod.array_iterator_next), next_ref.id);
    try std.testing.expect(next_function.nativeRecord() != null);
}

test "generator object uses the prototype selected after parameter initialization" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\var GeneratorPrototype = Object.getPrototypeOf(function* () {}.prototype);
        \\var syncPrototype = Object.create(GeneratorPrototype);
        \\function* syncGenerator(value = (syncGenerator.prototype = syncPrototype)) {}
        \\if (Object.getPrototypeOf(syncGenerator()) !== syncPrototype) throw new Error("sync prototype order");
        \\var AsyncGeneratorPrototype = Object.getPrototypeOf(async function* () {}.prototype);
        \\var asyncPrototype = Object.create(AsyncGeneratorPrototype);
        \\async function* asyncGenerator(value = (asyncGenerator.prototype = asyncPrototype)) {}
        \\if (Object.getPrototypeOf(asyncGenerator()) !== asyncPrototype) throw new Error("async prototype order");
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "closure-env var_ref hitting rc zero during remove_cycles stays a batch no-op" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const body =
        \\(function () {
        \\  let cycleSelf = null;
        \\  function cycleInner() { return cycleSelf; }
        \\  cycleSelf = { fn: cycleInner };
        \\  if (cycleSelf.fn() !== cycleSelf) throw new Error("capture wiring");
        \\})();
        \\"collected";
    ;

    // First round reaches the engine's steady state (repl bootstrap pins a
    // few permanent cells). forceGC must run from outside any active frame:
    // an in-eval $262.gc() still sees stale VM-stack slots of the running
    // script as conservative roots and would keep the dead ring alive.
    const warm = try js.evalWithOptions(body, .{ .filename = "<repl>" });
    warm.free(js.runtime);
    _ = try js.runtime.forceGC(null);
    const cell_steady = js.runtime.gc.liveCountKind(.var_ref);
    const object_steady = js.runtime.gc.liveCountKind(.object);

    // Each round strands one {closure -> cell -> object -> closure} ring that
    // only the cycle batch can reclaim. destroyZeroRef's remove_cycles gate
    // must keep the cell's mid-batch rc==0 a pure no-op (never the synchronous
    // free_var_ref tail), so the garbage_var_refs loop frees it exactly once
    // and the live census cannot grow across rounds.
    var round: usize = 0;
    while (round < 4) : (round += 1) {
        const result = try js.evalWithOptions(body, .{ .filename = "<repl>" });
        defer result.free(js.runtime);
        try helpers.expectStringValueBytes(result, "collected");
        _ = try js.runtime.forceGC(null);
        try std.testing.expectEqual(cell_steady, js.runtime.gc.liveCountKind(.var_ref));
        try std.testing.expectEqual(object_steady, js.runtime.gc.liveCountKind(.object));
    }
}

test "parked generator open cell death path reclaims cell and generator together" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const body =
        \\var parkedProbe = (function () {
        \\  function* parkedGen() {
        \\    let captured = 1;
        \\    const bump = () => ++captured;
        \\    yield bump;
        \\    yield captured;
        \\  }
        \\  const it = parkedGen();
        \\  const bump = it.next().value;
        \\  // Frame now parked: `captured`'s open cell owns the generator
        \\  // (attachOpenOwner) while the parked frame owns the cell.
        \\  return "" + bump() + bump();
        \\})();
        \\parkedProbe;
    ;

    // First round reaches steady state (repl bootstrap + lazy generator
    // machinery pin some permanent nodes); later rounds must not grow the
    // live census. See the remove_cycles no-op test above for why forceGC
    // runs from Zig instead of an in-eval $262.gc().
    const warm = try js.evalWithOptions(body, .{ .filename = "<repl>" });
    warm.free(js.runtime);
    _ = try js.runtime.forceGC(null);
    const cell_steady = js.runtime.gc.liveCountKind(.var_ref);
    const object_steady = js.runtime.gc.liveCountKind(.object);

    // Each round strands a {parked frame -> open cell -> generator owner}
    // ring that dies only via cycle collection: teardown close()s the cell
    // mid-batch and its rc==0 must stay gated (no synchronous destroy of a
    // cycle-owned cell), then the batch frees cell + generator exactly once.
    var round: usize = 0;
    while (round < 4) : (round += 1) {
        const result = try js.evalWithOptions(body, .{ .filename = "<repl>" });
        defer result.free(js.runtime);
        // Writes through the escaped closure stay visible through the open alias.
        try helpers.expectStringValueBytes(result, "23");
        _ = try js.runtime.forceGC(null);
        try std.testing.expectEqual(cell_steady, js.runtime.gc.liveCountKind(.var_ref));
        try std.testing.expectEqual(object_steady, js.runtime.gc.liveCountKind(.object));
    }
}

test "cycle drain frees leftover-rc rings under repeated forceGC" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const body =
        \\(function () {
        \\  const rings = [];
        \\  for (let i = 0; i < 32; i++) {
        \\    let a = { n: i };
        \\    let b = { peer: a };
        \\    a.peer = b;
        \\    a.self = function () { return a; };
        \\    rings.push(a.self());
        \\  }
        \\  return rings.length;
        \\})();
    ;

    const warm = try js.evalWithOptions(body, .{ .filename = "<repl>" });
    warm.free(js.runtime);
    _ = try js.runtime.forceGC(null);
    const cell_steady = js.runtime.gc.liveCountKind(.var_ref);
    const object_steady = js.runtime.gc.liveCountKind(.object);
    const fb_steady = js.runtime.gc.liveCountKind(.function_bytecode);

    var round: usize = 0;
    while (round < 8) : (round += 1) {
        const result = try js.evalWithOptions(body, .{ .filename = "<repl>" });
        defer result.free(js.runtime);
        try std.testing.expectEqual(@as(?i32, 32), result.asInt32());
        _ = try js.runtime.forceGC(null);
        try std.testing.expectEqual(cell_steady, js.runtime.gc.liveCountKind(.var_ref));
        try std.testing.expectEqual(object_steady, js.runtime.gc.liveCountKind(.object));
        try std.testing.expectEqual(fb_steady, js.runtime.gc.liveCountKind(.function_bytecode));
    }
}

test "cycle scan restores a heap BigInt without list_del on an unlinked header" {
    // Heap BigInt is a refCountHeader() target but not a cycle-list member.
    // gc_scan_incref_child must restore its trial rc and must not list_del a
    // null prev (the in_cycle_list replacement). Short 1n is not enough —
    // only a heap bigint exercises the header.
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\var live = { x: 0x10000000000000000n };
        \\$262.gc();
        \\assert.sameValue(live.x === 0x10000000000000000n, true);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "generator continuation keeps its FunctionBytecode alive after every source binding is dropped" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.evalWithOptions(
        \\function* escapeAuditGen() { var a = 10; yield a; yield a + 1; }
        \\async function escapeAuditAsync(x) { return (await x) + 5; }
        \\var it = escapeAuditGen();
        \\var first = it.next().value;
        \\var p = escapeAuditAsync(100);
        \\var escapeAuditAsyncResult;
        \\p.then(function (value) { escapeAuditAsyncResult = value; });
        \\escapeAuditGen = undefined;
        \\escapeAuditAsync = undefined;
        \\$262.gc();
        \\var second = it.next().value;
        \\first * 100 + second;
    , .{ .filename = "<repl>" });
    defer result.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 1011), result.asInt32());

    // The async frame was also suspended across the forced collection after
    // its only source-level function binding was cleared. Drain through the
    // existing harness API, then verify its continuation in a second eval.
    try js.runJobs();
    const async_check = try js.eval(
        \\assert.sameValue(escapeAuditAsyncResult, 105);
    );
    defer async_check.free(js.runtime);
    try std.testing.expect(async_check.isUndefined());
}

test "initial_yield keeps sync generators in suspended-start after parameter initialization" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const initialYieldEvents = [];
        \\function* initialYieldGenerator(
        \\  factory = (initialYieldEvents.push("param"), function* () { yield 1; })
        \\) {
        \\  initialYieldEvents.push("body");
        \\  yield factory().next().value;
        \\}
        \\const first = initialYieldGenerator();
        \\assert.sameValue(initialYieldEvents.join(","), "param");
        \\let step = first.next(99);
        \\assert.sameValue(step.value, 1);
        \\assert.sameValue(step.done, false);
        \\assert.sameValue(initialYieldEvents.join(","), "param,body");
        \\assert.sameValue(first.next().done, true);
        \\const returned = initialYieldGenerator();
        \\step = returned.return(9);
        \\assert.sameValue(step.value, 9);
        \\assert.sameValue(step.done, true);
        \\const thrown = initialYieldGenerator();
        \\let caught;
        \\try { thrown.throw(11); } catch (error) { caught = error; }
        \\assert.sameValue(caught, 11);
        \\assert.sameValue(initialYieldEvents.join(","), "param,body,param,param");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "initial_yield keeps async generators in suspended-start" {
    try helpers.expectPrints(
        \\const asyncInitialYieldEvents = [];
        \\async function* asyncInitialYieldGenerator(
        \\  value = (asyncInitialYieldEvents.push("param"), 3)
        \\) {
        \\  asyncInitialYieldEvents.push("body");
        \\  yield value;
        \\}
        \\const first = asyncInitialYieldGenerator();
        \\print("create", asyncInitialYieldEvents.join(","));
        \\first.next(99).then(function(step) {
        \\  print("next", step.value, step.done, asyncInitialYieldEvents.join(","));
        \\  const returned = asyncInitialYieldGenerator();
        \\  return returned.return(9);
        \\}).then(function(step) {
        \\  print("return", step.value, step.done, asyncInitialYieldEvents.join(","));
        \\  const thrown = asyncInitialYieldGenerator();
        \\  return thrown.throw(11).then(function() {
        \\    print("throw resolved");
        \\  }, function(reason) {
        \\    print("throw", reason, asyncInitialYieldEvents.join(","));
        \\  });
        \\});
    , "create param\n" ++
        "next 3 false param,body\n" ++
        "return 9 true param,body,param\n" ++
        "throw 11 param,body,param,param\n");
}

test "initial_yield executes exported generator bytecode in module mode" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalModule(
        \\const moduleInitialYieldEvents = [];
        \\export function* moduleInitialYieldGenerator(
        \\  value = (moduleInitialYieldEvents.push("param"), 4)
        \\) {
        \\  moduleInitialYieldEvents.push("body");
        \\  yield value;
        \\}
        \\const iterator = moduleInitialYieldGenerator();
        \\assert.sameValue(moduleInitialYieldEvents.join(","), "param");
        \\const step = iterator.next();
        \\assert.sameValue(step.value, 4);
        \\assert.sameValue(step.done, false);
        \\assert.sameValue(moduleInitialYieldEvents.join(","), "param,body");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "generator completion resumes keep the original function home object" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\class Base {
        \\  get marker() { return 41; }
        \\}
        \\class Derived extends Base {
        \\  *viaReturn() {
        \\    try { yield 0; }
        \\    finally { yield super.marker; }
        \\  }
        \\  *viaThrow() {
        \\    try { yield 0; }
        \\    catch (value) { yield super.marker + value; }
        \\  }
        \\  *viaYieldStar() {
        \\    yield* [0];
        \\    return super.marker;
        \\  }
        \\}
        \\const instance = new Derived();
        \\const returned = instance.viaReturn();
        \\assert.sameValue(returned.next().value, 0);
        \\let step = returned.return(99);
        \\assert.sameValue(step.value, 41);
        \\assert.sameValue(step.done, false);
        \\step = returned.next();
        \\assert.sameValue(step.value, 99);
        \\assert.sameValue(step.done, true);
        \\const thrown = instance.viaThrow();
        \\assert.sameValue(thrown.next().value, 0);
        \\step = thrown.throw(1);
        \\assert.sameValue(step.value, 42);
        \\assert.sameValue(step.done, false);
        \\assert.sameValue(thrown.next().done, true);
        \\const delegated = instance.viaYieldStar();
        \\assert.sameValue(delegated.next().value, 0);
        \\step = delegated.next();
        \\assert.sameValue(step.value, 41);
        \\assert.sameValue(step.done, true);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "resident generator resumes preserve nested catch and finally targets" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function* afterNested() {
        \\  try {
        \\    yield 1;
        \\    try { yield 2; throw 3; } catch (error) { yield error; }
        \\    yield 4;
        \\  } finally { yield 5; }
        \\}
        \\let iterator = afterNested();
        \\assert.sameValue(iterator.next().value, 1);
        \\assert.sameValue(iterator.next().value, 2);
        \\assert.sameValue(iterator.next().value, 3);
        \\assert.sameValue(iterator.next().value, 4);
        \\assert.sameValue(iterator.throw(6).value, 5);
        \\let caught;
        \\try { iterator.next(); } catch (error) { caught = error; }
        \\assert.sameValue(caught, 6);
        \\function* beforeNested() {
        \\  try {
        \\    yield 1;
        \\    try { yield 2; } catch (error) { yield error; }
        \\  } finally { yield 3; }
        \\}
        \\iterator = beforeNested();
        \\assert.sameValue(iterator.next().value, 1);
        \\assert.sameValue(iterator.throw(7).value, 3);
        \\try { iterator.next(); } catch (error) { caught = error; }
        \\assert.sameValue(caught, 7);
        \\function* plainFinally() {
        \\  try { yield 1; } finally { yield 2; }
        \\}
        \\iterator = plainFinally();
        \\assert.sameValue(iterator.next().value, 1);
        \\assert.sameValue(iterator.throw(8).value, 2);
        \\try { iterator.next(); } catch (error) { caught = error; }
        \\assert.sameValue(caught, 8);
        \\function* inner() { return yield 1; }
        \\function* delegate(iterable) { return yield* iterable; }
        \\iterator = delegate(inner());
        \\assert.sameValue(iterator.next().value, 1);
        \\try { iterator.throw(9); } catch (error) { caught = error; }
        \\assert.sameValue(caught, 9);
        \\let delegateReturnCount = 0;
        \\const missingThrow = {
        \\  [Symbol.iterator]() { return this; },
        \\  next() { return { value: 10, done: false }; },
        \\  return() { delegateReturnCount++; return { done: true }; },
        \\};
        \\function* catchYieldStarHostError() {
        \\  try { yield* missingThrow; }
        \\  catch (error) { yield error instanceof TypeError; }
        \\}
        \\iterator = catchYieldStarHostError();
        \\assert.sameValue(iterator.next().value, 10);
        \\assert.sameValue(iterator.throw(11).value, true);
        \\assert.sameValue(delegateReturnCount, 1);
        \\assert.sameValue(iterator.next().done, true);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "surviving var references keep resident local slots bare" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function* referenceStorage(scope) {
        \\  var target;
        \\  with (scope) { target = 41; }
        \\  yield target;
        \\  target += 1;
        \\  return target;
        \\}
        \\globalThis.__referenceStorage = referenceStorage({});
        \\__referenceStorage.next();
    );
    defer result.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const key = try js.runtime.internAtom("__referenceStorage");
    defer js.runtime.atoms.free(key);
    const value = try global.getProperty(key);
    defer value.free(js.runtime);
    const generator = try property_ops.expectObject(value);
    const function_value = generator.generatorFunctionBytecode() orelse return error.TypeError;
    const function = engine.exec.call_runtime.functionBytecodeFromValue(function_value) orelse return error.TypeError;
    const target_idx = localIndexNamed(js.runtime, function, "target") orelse return error.TypeError;
    const state = generator.generatorExecutionState();

    try std.testing.expect(function.openVarRefCount() > 0);
    try std.testing.expect(function.varDefs()[target_idx].isCaptured());
    try std.testing.expect(!function.varDefs()[target_idx].isLexical());
    try std.testing.expectEqual(@as(?i32, 41), state.storage.frame.locals[target_idx].asInt32());
    try std.testing.expect(core.VarRef.fromValue(state.storage.frame.locals[target_idx]) == null);
    var found_open_alias = false;
    for (state.storage.frame.open_var_refs) |maybe_ref| {
        const ref = maybe_ref orelse continue;
        if (ref.is_open and ref.pvalue == &state.storage.frame.locals[target_idx]) found_open_alias = true;
    }
    try std.testing.expect(found_open_alias);

    const completion = try js.eval(
        \\const step = __referenceStorage.next();
        \\assert.sameValue(step.value, 42);
        \\assert.sameValue(step.done, true);
    );
    defer completion.free(js.runtime);
    try std.testing.expect(completion.isUndefined());
}

test "direct eval captures only bindings visible at its call scope" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function* scopedEvalStorage() {
        \\  { let sibling = 10; globalThis.__siblingValue = sibling; }
        \\  var visible = 1;
        \\  { let active = 2; eval("visible = active"); yield visible; }
        \\}
        \\globalThis.__scopedEvalStorage = scopedEvalStorage();
    );
    defer result.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const key = try js.runtime.internAtom("__scopedEvalStorage");
    defer js.runtime.atoms.free(key);
    const value = try global.getProperty(key);
    defer value.free(js.runtime);
    const generator = try property_ops.expectObject(value);
    const function_value = generator.generatorFunctionBytecode() orelse return error.TypeError;
    const function = engine.exec.call_runtime.functionBytecodeFromValue(function_value) orelse return error.TypeError;
    const sibling_idx = localIndexNamed(js.runtime, function, "sibling") orelse return error.TypeError;
    const visible_idx = localIndexNamed(js.runtime, function, "visible") orelse return error.TypeError;
    const active_idx = localIndexNamed(js.runtime, function, "active") orelse return error.TypeError;

    try std.testing.expect(!function.varDefs()[sibling_idx].isCaptured());
    try std.testing.expect(function.varDefs()[visible_idx].isCaptured());
    try std.testing.expect(function.varDefs()[active_idx].isCaptured());
    try std.testing.expect(function.localOpenBindingIndex(sibling_idx) == null);
    try std.testing.expect(function.localOpenBindingIndex(visible_idx) != null);
    try std.testing.expect(function.localOpenBindingIndex(active_idx) != null);
}

test "suspended generators retain one resident execution owner across resumes" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function* residentGenerator(argument) {
        \\  let local = { local: true };
        \\  try {
        \\    yield local;
        \\    yield argument;
        \\  } catch (error) {
        \\    yield error;
        \\  }
        \\}
        \\globalThis.__residentGenerator = residentGenerator({ argument: true });
        \\let first = __residentGenerator.next();
        \\assert.sameValue(first.value.local, true);
        \\assert.sameValue(first.done, false);
        \\let second = __residentGenerator.next();
        \\assert.sameValue(second.value.argument, true);
        \\assert.sameValue(second.done, false);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const key = try js.runtime.internAtom("__residentGenerator");
    defer js.runtime.atoms.free(key);
    const value = try global.getProperty(key);
    defer value.free(js.runtime);
    const generator = try property_ops.expectObject(value);
    const generator_function = generator.generatorFunctionBytecode() orelse return error.TypeError;
    try std.testing.expect(inline_calls.resolveInlineTarget(
        js.context,
        global,
        core.JSValue.undefinedValue(),
        generator_function,
    ) == null);
    const state = generator.generatorExecutionState();
    try std.testing.expect(!generator.generatorDone());
    try std.testing.expect(state.has_frame);
    try std.testing.expect(!state.running_aliases);
    try std.testing.expect(state.resident_storage_owner);
    try std.testing.expect(state.catchTarget() != null);
    try std.testing.expect(generator.generatorStackUsesCombinedStorage());
    try std.testing.expect(generator.generatorFrameUsesCombinedStorage());
    try std.testing.expect(state.storage.frame.args.len != 0);
    try std.testing.expect(state.storage.frame.locals.len != 0);
    const completion = try js.eval(
        \\let finalStep = __residentGenerator.next();
        \\assert.sameValue(finalStep.value, undefined);
        \\assert.sameValue(finalStep.done, true);
    );
    defer completion.free(js.runtime);
    try std.testing.expect(completion.isUndefined());
    try std.testing.expect(generator.generatorDone());
    try std.testing.expect(!generator.generatorExecutionState().has_frame);
    try std.testing.expect(generator.generatorExecutionState().storage.isEmpty());
}

test "completed generators eagerly release their resident execution state" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function make(captured) {
        \\  return function* generator(argument) { yield captured; return argument; };
        \\}
        \\const generator = make({ captured: true });
        \\globalThis.__returnedGenerator = generator.call({ receiver: true }, { argument: true });
        \\let step = __returnedGenerator.return(7);
        \\assert.sameValue(step.value, 7);
        \\assert.sameValue(step.done, true);
        \\step = __returnedGenerator.next();
        \\assert.sameValue(step.value, undefined);
        \\assert.sameValue(step.done, true);
        \\step = __returnedGenerator.return(8);
        \\assert.sameValue(step.value, 8);
        \\assert.sameValue(step.done, true);
        \\let thrown;
        \\try { __returnedGenerator.throw(9); } catch (value) { thrown = value; }
        \\assert.sameValue(thrown, 9);
        \\globalThis.__normallyCompletedGenerator = generator({ argument: true });
        \\__normallyCompletedGenerator.next();
        \\step = __normallyCompletedGenerator.next();
        \\assert.sameValue(step.done, true);
        \\globalThis.__thrownGenerator = generator({ argument: true });
        \\try { __thrownGenerator.throw(10); } catch (value) { thrown = value; }
        \\assert.sameValue(thrown, 10);
    );
    defer result.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const names = [_][]const u8{
        "__returnedGenerator",
        "__normallyCompletedGenerator",
        "__thrownGenerator",
    };
    for (names) |name| {
        const key = try js.runtime.internAtom(name);
        defer js.runtime.atoms.free(key);
        const value = try global.getProperty(key);
        defer value.free(js.runtime);
        const generator_object = try property_ops.expectObject(value);
        try std.testing.expect(generator_object.generatorDone());
        try std.testing.expect(!generator_object.generatorExecutionState().has_frame);
        try std.testing.expect(generator_object.generatorExecutionState().storage.isEmpty());
        try std.testing.expectEqual(@as(usize, 0), generator_object.generatorPc());
        try std.testing.expectEqual(@as(usize, 0), generator_object.generatorArgs().len);
        try std.testing.expectEqual(@as(usize, 0), generator_object.generatorCaptures().len);
        try std.testing.expect(generator_object.generatorThis() == null);
        try std.testing.expect(generator_object.generatorCurrentFunction() == null);
    }
}

test "iterator helper method marker is internal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function printLayout(label, helper) {
        \\  var proto = Object.getPrototypeOf(helper);
        \\  print(label);
        \\  print(Object.prototype.toString.call(helper));
        \\  print("own:" + Object.getOwnPropertyNames(helper).join(","));
        \\  print("proto:" + Object.getOwnPropertyNames(proto).join(","));
        \\  print(helper.hasOwnProperty("next"));
        \\  print(typeof proto.next);
        \\  print(helper.next === proto.next);
        \\}
        \\function check(fn, marker, run) {
        \\  print(marker in fn);
        \\  print(Object.getOwnPropertyDescriptor(fn, marker) === undefined);
        \\  fn[marker] = 0;
        \\  print(marker in fn);
        \\  print(run());
        \\  print(delete fn[marker]);
        \\  print(marker in fn);
        \\  print(run());
        \\}
        \\var helper = Iterator.from([1]).map(function(x) { return x + 1; });
        \\printLayout("map", helper);
        \\printLayout("concat", Iterator.concat([1]));
        \\printLayout("zip", Iterator.zip([[1], [2]]));
        \\var next = helper.next;
        \\check(next, "__zjs_iterator_helper_method", function() {
        \\  var h = Iterator.from([1]).map(function(x) { return x + 1; });
        \\  return next.call(h).value;
        \\});
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "map\n[object Iterator Helper]\nown:\nproto:next,return\nfalse\nfunction\ntrue\n" ++
            "concat\n[object Iterator Concat]\nown:\nproto:next,return\nfalse\nfunction\ntrue\n" ++
            "zip\n[object Iterator Helper]\nown:next,return\nproto:next,return\ntrue\nfunction\nfalse\n" ++
            "false\ntrue\ntrue\n2\ntrue\nfalse\n2\n",
        stream.buffered(),
    );
}

test "Iterator.from follows QuickJS wrapper selection" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var count = 0;
        \\var iterable = {
        \\  [Symbol.iterator]: function() { return this; },
        \\  get next() {
        \\    count++;
        \\    return function() { return { done: true, value: 1 }; };
        \\  },
        \\};
        \\var fromIterable = Iterator.from(iterable);
        \\print(fromIterable === iterable);
        \\print(count);
        \\fromIterable.next();
        \\print(count);
        \\print(typeof fromIterable.map);
        \\var sealed = Object.preventExtensions({
        \\  next: function() { return { done: true }; },
        \\});
        \\var wrapped = Iterator.from(sealed);
        \\print(wrapped === sealed);
        \\var wrapProto = Object.getPrototypeOf(wrapped);
        \\print("__zjs_iterator_wrap_method" in wrapProto.next);
        \\print(Object.getOwnPropertyDescriptor(wrapProto.next, "__zjs_iterator_wrap_method") === undefined);
        \\print("__zjs_iterator_wrap_method" in wrapProto.return);
        \\print(Object.getOwnPropertyDescriptor(wrapProto.return, "__zjs_iterator_wrap_method") === undefined);
        \\wrapProto.next.__zjs_iterator_wrap_method = 2;
        \\print(wrapped.next().done);
        \\print(wrapped.next().value);
        \\print(delete wrapProto.next.__zjs_iterator_wrap_method);
        \\print(wrapped.next().value);
        \\wrapProto.return.__zjs_iterator_wrap_method = 1;
        \\print(wrapped.return().done);
        \\print(delete wrapProto.return.__zjs_iterator_wrap_method);
        \\print(wrapped.return().done);
        \\print("__zjs_iterator_next" in wrapped);
        \\print(Object.getOwnPropertyDescriptor(wrapped, "__zjs_iterator_next") === undefined);
        \\wrapped.__zjs_iterator_next = function() { return { done: false, value: 99 }; };
        \\print(wrapped.next().value);
        \\print(delete wrapped.__zjs_iterator_next);
        \\print("__zjs_iterator_next" in wrapped);
        \\var bad = Iterator.from({ next: 1 });
        \\print(typeof bad);
        \\try {
        \\  bad.next();
        \\} catch (e) {
        \\  print(e.name);
        \\}
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    // The first four values changed on 2026-08-21. They used to read
    // "true, 0, undefined" — the source returned unwrapped, its `next` getter
    // never read, and no iterator helpers on the result — and this test pinned
    // that as QuickJS parity. It was not: the pinned QuickJS prints
    // "false, 1, 1, function" for this exact snippet, and so does the spec.
    // Iterator.from must test %Iterator%-instance-hood on the RESOLVED
    // iterator, which this shape fails, so it gets a wrapper.
    try std.testing.expectEqualStrings("false\n1\n1\nfunction\nfalse\nfalse\ntrue\nfalse\ntrue\ntrue\nundefined\ntrue\nundefined\ntrue\ntrue\ntrue\nfalse\ntrue\nundefined\ntrue\nfalse\nobject\nTypeError\n", stream.buffered());
}

test "number native builtin records cover static and prototype dispatch" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const number_key = try rt.internAtom("Number");
    defer rt.atoms.free(number_key);
    const is_integer_key = try rt.internAtom("isInteger");
    defer rt.atoms.free(is_integer_key);
    const prototype_key = core.atom.ids.prototype;
    const to_fixed_key = try rt.internAtom("toFixed");
    defer rt.atoms.free(to_fixed_key);

    const number_value = try global.getProperty(number_key);
    defer number_value.free(rt);
    const number_object: *core.Object = @fieldParentPtr("header", number_value.refHeader().?);

    const is_integer_value = try number_object.getProperty(is_integer_key);
    defer is_integer_value.free(rt);
    const is_integer_object: *core.Object = @fieldParentPtr("header", is_integer_value.refHeader().?);
    try std.testing.expect(is_integer_object.nativeFunctionIdSlot().* != 0);

    const fake_static = try engine.core.function.nativeFunction(ctx, "notNumberIsInteger", 1);
    defer fake_static.free(rt);
    const fake_static_object: *core.Object = @fieldParentPtr("header", fake_static.refHeader().?);
    fake_static_object.nativeFunctionIdSlot().* = is_integer_object.nativeFunctionIdSlot().*;
    const static_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_static_object);
    defer rt.memory.allocator.free(static_dispatch_name);
    try std.testing.expectEqualStrings("notNumberIsInteger", static_dispatch_name);
    const static_args = [_]core.JSValue{core.JSValue.float64(3.5)};
    const static_result = try engine.exec.call.callValue(ctx, null, fake_static, &static_args);
    defer static_result.free(rt);
    try std.testing.expectEqual(false, static_result.asBool().?);

    const prototype_value = try number_object.getProperty(prototype_key);
    defer prototype_value.free(rt);
    const prototype_object: *core.Object = @fieldParentPtr("header", prototype_value.refHeader().?);
    const to_fixed_value = try prototype_object.getProperty(to_fixed_key);
    defer to_fixed_value.free(rt);
    const to_fixed_object: *core.Object = @fieldParentPtr("header", to_fixed_value.refHeader().?);
    try std.testing.expect(to_fixed_object.nativeFunctionIdSlot().* != 0);

    const fake_proto = try engine.core.function.nativeFunction(ctx, "notNumberToFixed", 1);
    defer fake_proto.free(rt);
    const fake_proto_object: *core.Object = @fieldParentPtr("header", fake_proto.refHeader().?);
    fake_proto_object.nativeFunctionIdSlot().* = to_fixed_object.nativeFunctionIdSlot().*;
    const proto_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_proto_object);
    defer rt.memory.allocator.free(proto_dispatch_name);
    try std.testing.expectEqualStrings("notNumberToFixed", proto_dispatch_name);
    const fixed_args = [_]core.JSValue{core.JSValue.int32(2)};
    const proto_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, core.JSValue.float64(1.25), fake_proto, &fixed_args);
    defer proto_result.free(rt);
    const proto_string = proto_result.asStringBody().?;
    try std.testing.expect(proto_string.eqlBytes("1.25"));

    const fake_static_key = try rt.internAtom("fakeStatic");
    defer rt.atoms.free(fake_static_key);
    try global.defineOwnProperty(rt, fake_static_key, core.Descriptor.data(fake_static, true, false, true));
    const fake_proto_key = try rt.internAtom("fakeProto");
    defer rt.atoms.free(fake_proto_key);
    try global.defineOwnProperty(rt, fake_proto_key, core.Descriptor.data(fake_proto, true, false, true));

    var parsed = try engine.parser.compile(.{ .realm = ctx }, "print(fakeStatic(3.5)); print(fakeProto.call(1.25, 2));", .{ .mode = .script, .filename = "number-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stackLimit());
    defer stack.deinit(rt);
    var output_buffer: [32]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("false\n1.25\n", output.buffered());
}

test "class extends Number ToPrimitive matches JS_ToNumeric" {
    // X-37: qjs js_number_constructor (qjs:44822) uses JS_ToNumeric
    // (qjs:13030) so object arguments run valueOf/toString. The subclass
    // super path must not skip that via toNumberValue's missing object arm.

    try helpers.expectPrints(
        \\class MyNum extends Number {}
        \\function t(n,f){ try{ print(n+" => "+f()); }catch(e){ print(n+" => THROW "+e.name+": "+e.message); } }
        \\t("new MyNum({valueOf:42})", ()=> new MyNum({valueOf(){return 42}}).valueOf());
        \\t("new MyNum([5])", ()=> new MyNum([5]).valueOf());
        \\t("new MyNum({toString:'7'})", ()=> new MyNum({toString(){return "7"}}).valueOf());
        \\t("Reflect.construct", ()=> Reflect.construct(Number,[{valueOf(){return 42}}],MyNum).valueOf());
        \\t("new Number(obj) plain", ()=> new Number({valueOf(){return 42}}).valueOf());
        \\t("new MyNum(new Date(1000))", ()=> new MyNum(new Date(1000)).valueOf());
        \\t("new MyNum(SymToPrim)", ()=> new MyNum({[Symbol.toPrimitive](){return 9}}).valueOf());
        \\t("throwing valueOf", ()=> new MyNum({valueOf(){throw new Error("boom")}}).valueOf());
        \\var log=[]; try{ new MyNum({valueOf(){log.push("v");return 1}}); }catch(e){}
        \\print("sideeffect log=["+log+"]");
    , "new MyNum({valueOf:42}) => 42\n" ++
        "new MyNum([5]) => 5\n" ++
        "new MyNum({toString:'7'}) => 7\n" ++
        "Reflect.construct => 42\n" ++
        "new Number(obj) plain => 42\n" ++
        "new MyNum(new Date(1000)) => 1000\n" ++
        "new MyNum(SymToPrim) => 9\n" ++
        "throwing valueOf => THROW Error: boom\n" ++
        "sideeffect log=[v]\n");
}

test "Number.prototype.toString saturates out-of-i32 radix before intFromFloat" {
    // X-12: qjs js_get_radix (qjs:44953) uses JS_ToInt32Sat (qjs:13125)
    // before the 2..36 check. `@intFromFloat(Infinity)` panics in Debug.

    try helpers.expectPrints(
        \\try { print((5).toString(Infinity)); } catch(e){ print("Inf:", e.name, e.message); }
        \\try { print((5).toString(-Infinity)); } catch(e){ print("-Inf:", e.name, e.message); }
        \\try { print((5).toString(1e30)); } catch(e){ print("1e30:", e.name, e.message); }
        \\try { print((5).toString(-1e30)); } catch(e){ print("-1e30:", e.name, e.message); }
        \\try { print((5).toString({valueOf:()=>Infinity})); } catch(e){ print("objInf:", e.name, e.message); }
        \\try { print((5).toString(2**31)); } catch(e){ print("2**31:", e.name, e.message); }
        \\try { print((5).toString(NaN)); } catch(e){ print("NaN:", e.name, e.message); }
        \\try { print((5).toString({valueOf:()=>NaN})); } catch(e){ print("objNaN:", e.name, e.message); }
        \\try { print((5).toString(-0)); } catch(e){ print("-0:", e.name, e.message); }
        \\try { print((5).toString(16)); } catch(e){ print("16:", e); }
    , "Inf: RangeError radix must be between 2 and 36\n" ++
        "-Inf: RangeError radix must be between 2 and 36\n" ++
        "1e30: RangeError radix must be between 2 and 36\n" ++
        "-1e30: RangeError radix must be between 2 and 36\n" ++
        "objInf: RangeError radix must be between 2 and 36\n" ++
        "2**31: RangeError radix must be between 2 and 36\n" ++
        "NaN: RangeError radix must be between 2 and 36\n" ++
        "objNaN: RangeError radix must be between 2 and 36\n" ++
        "-0: RangeError radix must be between 2 and 36\n" ++
        "5\n");
}

test "string static native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const string_key = try rt.internAtom("String");
    defer rt.atoms.free(string_key);
    const from_code_point_key = try rt.internAtom("fromCodePoint");
    defer rt.atoms.free(from_code_point_key);
    const string_value = try global.getProperty(string_key);
    defer string_value.free(rt);
    const string_object: *core.Object = @fieldParentPtr("header", string_value.refHeader().?);
    const from_code_point_value = try string_object.getProperty(from_code_point_key);
    defer from_code_point_value.free(rt);
    const from_code_point_object: *core.Object = @fieldParentPtr("header", from_code_point_value.refHeader().?);
    try std.testing.expect(from_code_point_object.nativeFunctionIdSlot().* != 0);

    const fake = try engine.core.function.nativeFunction(ctx, "notStringFromCodePoint", 1);
    defer fake.free(rt);
    const fake_object: *core.Object = @fieldParentPtr("header", fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = from_code_point_object.nativeFunctionIdSlot().*;
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notStringFromCodePoint", dispatch_name);

    const args = [_]core.JSValue{core.JSValue.int32(0x41)};
    const result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, core.JSValue.undefinedValue(), fake, &args);
    defer result.free(rt);
    const result_string = result.asStringBody().?;
    try std.testing.expect(result_string.eqlBytes("A"));

    const fake_key = try rt.internAtom("fakeStringStatic");
    defer rt.atoms.free(fake_key);
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, true, false, true));

    var parsed = try engine.parser.compile(.{ .realm = ctx }, "print(fakeStringStatic({ valueOf: function(){ return 0x42; } }));", .{ .mode = .script, .filename = "string-static-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stackLimit());
    defer stack.deinit(rt);
    var output_buffer: [8]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("B\n", output.buffered());
}

test "string prototype native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const string_key = try rt.internAtom("String");
    defer rt.atoms.free(string_key);
    const index_of_key = try rt.internAtom("indexOf");
    defer rt.atoms.free(index_of_key);
    const string_value = try global.getProperty(string_key);
    defer string_value.free(rt);
    const string_object: *core.Object = @fieldParentPtr("header", string_value.refHeader().?);
    const prototype_value = try string_object.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    const prototype_object: *core.Object = @fieldParentPtr("header", prototype_value.refHeader().?);
    const index_of_value = try prototype_object.getProperty(index_of_key);
    defer index_of_value.free(rt);
    const index_of_object: *core.Object = @fieldParentPtr("header", index_of_value.refHeader().?);
    try std.testing.expect(index_of_object.nativeFunctionIdSlot().* != 0);

    const fake = try engine.core.function.nativeFunction(ctx, "notStringIndexOf", 1);
    defer fake.free(rt);
    const fake_object: *core.Object = @fieldParentPtr("header", fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = index_of_object.nativeFunctionIdSlot().*;
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notStringIndexOf", dispatch_name);

    const needle_string = try core.string.String.createUtf8(rt, "n");
    defer needle_string.value().free(rt);
    const receiver_string = try core.string.String.createUtf8(rt, "banana");
    defer receiver_string.value().free(rt);
    const direct_args = [_]core.JSValue{ needle_string.value(), core.JSValue.int32(3) };
    const direct_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver_string.value(), fake, &direct_args);
    defer direct_result.free(rt);
    try std.testing.expectEqual(@as(i32, 4), direct_result.asInt32().?);

    const fake_key = try rt.internAtom("fakeStringIndexOf");
    defer rt.atoms.free(fake_key);
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, true, false, true));

    var parsed = try engine.parser.compile(.{ .realm = ctx }, "print(fakeStringIndexOf.call('banana', 'n', { valueOf: function(){ return 3; } }));", .{ .mode = .script, .filename = "string-prototype-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stackLimit());
    defer stack.deinit(rt);
    var output_buffer: [8]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("4\n", output.buffered());
}

test "String case conversion records preserve coercion and Unicode semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var hints = [];
        \\var receiver = {};
        \\receiver[Symbol.toPrimitive] = function(hint) {
        \\    hints.push(hint);
        \\    return "aßΣ";
        \\};
        \\assert.sameValue(String.prototype.toUpperCase.call(receiver), "ASSΣ");
        \\assert.sameValue(hints.join(","), "string");
        \\assert.sameValue("AΣ".toLowerCase(), "aς");
        \\assert.sameValue("AΣA".toLowerCase(), "aσa");
        \\assert.sameValue("\uD801\uDC28".toUpperCase(), "\uD801\uDC00");
        \\assert.sameValue(String.prototype.toLowerCase.call(new String("ABC")), "abc");
        \\var upper = String.prototype.toUpperCase;
        \\Object.defineProperty(upper, "name", { value: "renamed" });
        \\assert.sameValue(upper.call("ab"), "AB");
        \\assert.throws(TypeError, function() {
        \\    String.prototype.toUpperCase.call(Symbol("x"));
        \\});
        \\var other = $262.createRealm().global;
        \\assert.throws(other.TypeError, function() {
        \\    other.String.prototype.toUpperCase.call(Symbol("x"));
        \\});
    );
    defer result.free(js.runtime);

    const pure_source = try core.string.String.createUtf8(js.runtime, "ABC");
    defer pure_source.value().free(js.runtime);
    const pure_result = try engine.exec.string_ops.callStringBody(js.context, pure_source.value(), 3, &.{});
    defer pure_result.free(js.runtime);
    try std.testing.expect((pure_result.asStringBody() orelse return error.TestUnexpectedResult).eqlBytes("abc"));

    try std.testing.expect(result.isUndefined());
}

test "date static native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const date_key = try rt.internAtom("Date");
    defer rt.atoms.free(date_key);
    const utc_key = try rt.internAtom("UTC");
    defer rt.atoms.free(utc_key);
    const date_value = try global.getProperty(date_key);
    defer date_value.free(rt);
    const date_object: *core.Object = @fieldParentPtr("header", date_value.refHeader().?);
    const utc_value = try date_object.getProperty(utc_key);
    defer utc_value.free(rt);
    const utc_object: *core.Object = @fieldParentPtr("header", utc_value.refHeader().?);
    try std.testing.expect(utc_object.nativeFunctionIdSlot().* != 0);

    const fake = try engine.core.function.nativeFunction(ctx, "notDateUTC", 7);
    defer fake.free(rt);
    const fake_object: *core.Object = @fieldParentPtr("header", fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = utc_object.nativeFunctionIdSlot().*;
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notDateUTC", dispatch_name);

    const args = [_]core.JSValue{ core.JSValue.int32(2024), core.JSValue.int32(0), core.JSValue.int32(1) };
    const result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, core.JSValue.undefinedValue(), fake, &args);
    defer result.free(rt);
    try std.testing.expectEqual(@as(f64, 1704067200000), engine.exec.value_ops.numberValue(result).?);

    const fake_key = try rt.internAtom("fakeDateUTC");
    defer rt.atoms.free(fake_key);
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, true, false, true));

    var parsed = try engine.parser.compile(.{ .realm = ctx }, "print(fakeDateUTC({ valueOf: function(){ return 2024; } }, 0, 1));", .{ .mode = .script, .filename = "date-static-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stackLimit());
    defer stack.deinit(rt);
    var output_buffer: [24]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("1704067200000\n", output.buffered());
}

test "date constructor native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const date_key = try rt.internAtom("Date");
    defer rt.atoms.free(date_key);
    const date_value = try global.getProperty(date_key);
    defer date_value.free(rt);
    const date_object: *core.Object = @fieldParentPtr("header", date_value.refHeader().?);
    try std.testing.expect(date_object.nativeFunctionIdSlot().* != 0);

    const fake = try engine.core.function.nativeFunction(ctx, "notDateConstructor", 7);
    defer fake.free(rt);
    const fake_object: *core.Object = @fieldParentPtr("header", fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = date_object.nativeFunctionIdSlot().*;
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notDateConstructor", dispatch_name);

    const prototype_value = try date_object.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    try fake_object.defineOwnProperty(rt, core.atom.ids.prototype, core.Descriptor.data(prototype_value, true, false, true));

    const call_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, core.JSValue.undefinedValue(), fake, &.{});
    defer call_result.free(rt);
    var call_buffer = std.ArrayList(u8).empty;
    defer call_buffer.deinit(rt.memory.allocator);
    try engine.exec.value_ops.appendRawString(rt, &call_buffer, call_result);
    // Local-time toString shape (offset varies with the host timezone).
    try std.testing.expect(std.mem.indexOf(u8, call_buffer.items, "GMT+") != null or
        std.mem.indexOf(u8, call_buffer.items, "GMT-") != null);

    const construct_result = try engine.exec.construct.constructValue(ctx, fake, &.{core.JSValue.int32(1)}, &.{});
    defer construct_result.free(rt);
    const construct_ms = try engine.exec.date_ops.methodCall(rt, construct_result, 1);
    defer construct_ms.free(rt);
    try std.testing.expectEqual(@as(f64, 1), engine.exec.value_ops.numberValue(construct_ms).?);

    const fake_key = try rt.internAtom("fakeDateConstructor");
    defer rt.atoms.free(fake_key);
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, true, false, true));

    var parsed = try engine.parser.compile(.{ .realm = ctx },
        \\const d = new fakeDateConstructor({ valueOf: function(){ return 2; } });
        \\print(d instanceof Date);
        \\print(d.getTime());
        \\print(fakeDateConstructor().indexOf('GMT') >= 0);
        \\print(Reflect.construct(fakeDateConstructor, [3], Date).getTime());
    , .{ .mode = .script, .filename = "date-constructor-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stackLimit());
    defer stack.deinit(rt);
    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("true\n2\ntrue\n3\n", output.buffered());
}

test "constructValue AggregateError releases copied errors array owner" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;
    const function_proto = try core.Object.create(rt, core.class.ids.object, null);
    ctx.cached_function_proto = function_proto;
    const object_proto = try core.Object.create(rt, core.class.ids.object, null);
    const object_proto_slot = try global.cachedRealmValueSlot(rt, .object_prototype);
    try global.setOptionalValueSlot(rt, object_proto_slot, object_proto.value());

    const name = try rt.internAtom("AggregateError");
    defer rt.atoms.free(name);
    const constructor = try engine.exec.construct.functionObject(ctx, name);
    defer constructor.free(rt);

    const source = try core.Object.createArray(rt, null);
    defer source.value().free(rt);
    try source.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(core.JSValue.int32(1), true, true, true));
    try source.defineOwnProperty(rt, core.atom.atomFromUInt32(1), core.Descriptor.data(core.JSValue.int32(2), true, true, true));
    source.setArrayLength(2);
    try source.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(2), true, false, false));

    const baseline_objects = rt.gc.liveCount();
    const result = try engine.exec.construct.constructValue(ctx, constructor, &.{source.value()}, &.{});
    result.free(rt);
    _ = rt.runObjectCycleRemoval();

    try std.testing.expectEqual(baseline_objects, rt.gc.liveCount());
}

test "date prototype native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const date_key = try rt.internAtom("Date");
    defer rt.atoms.free(date_key);
    const set_time_key = try rt.internAtom("setTime");
    defer rt.atoms.free(set_time_key);
    const date_value = try global.getProperty(date_key);
    defer date_value.free(rt);
    const date_object: *core.Object = @fieldParentPtr("header", date_value.refHeader().?);
    const prototype_value = try date_object.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    const prototype_object: *core.Object = @fieldParentPtr("header", prototype_value.refHeader().?);
    const set_time_value = try prototype_object.getProperty(set_time_key);
    defer set_time_value.free(rt);
    const set_time_object: *core.Object = @fieldParentPtr("header", set_time_value.refHeader().?);
    try std.testing.expect(set_time_object.nativeFunctionIdSlot().* != 0);

    const fake = try engine.core.function.nativeFunction(ctx, "notDateSetTime", 1);
    defer fake.free(rt);
    const fake_object: *core.Object = @fieldParentPtr("header", fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = set_time_object.nativeFunctionIdSlot().*;
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notDateSetTime", dispatch_name);

    const direct_receiver = try engine.exec.date_ops.construct(rt, &.{core.JSValue.int32(0)});
    defer direct_receiver.free(rt);
    const direct_args = [_]core.JSValue{core.JSValue.int32(1)};
    const direct_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, direct_receiver, fake, &direct_args);
    defer direct_result.free(rt);
    try std.testing.expectEqual(@as(f64, 1), engine.exec.value_ops.numberValue(direct_result).?);

    const fake_key = try rt.internAtom("fakeDateSetTime");
    defer rt.atoms.free(fake_key);
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, true, false, true));

    var parsed = try engine.parser.compile(.{ .realm = ctx }, "const d = new Date(0); print(fakeDateSetTime.call(d, { valueOf: function(){ return 1704067200000; } })); print(d.getTime());", .{ .mode = .script, .filename = "date-prototype-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stackLimit());
    defer stack.deinit(rt);
    var output_buffer: [48]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("1704067200000\n1704067200000\n", output.buffered());
}

test "array static native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const array_key = try rt.internAtom("Array");
    defer rt.atoms.free(array_key);
    const is_array_key = try rt.internAtom("isArray");
    defer rt.atoms.free(is_array_key);
    const from_key = try rt.internAtom("from");
    defer rt.atoms.free(from_key);
    const array_value = try global.getProperty(array_key);
    defer array_value.free(rt);
    const array_object: *core.Object = @fieldParentPtr("header", array_value.refHeader().?);
    const is_array_value = try array_object.getProperty(is_array_key);
    defer is_array_value.free(rt);
    const is_array_object: *core.Object = @fieldParentPtr("header", is_array_value.refHeader().?);
    try std.testing.expect(is_array_object.nativeFunctionIdSlot().* != 0);
    const from_value = try array_object.getProperty(from_key);
    defer from_value.free(rt);
    const from_object: *core.Object = @fieldParentPtr("header", from_value.refHeader().?);
    try std.testing.expect(from_object.nativeFunctionIdSlot().* != 0);

    const fake_is_array = try engine.core.function.nativeFunction(ctx, "notArrayIsArray", 1);
    defer fake_is_array.free(rt);
    const fake_is_array_object: *core.Object = @fieldParentPtr("header", fake_is_array.refHeader().?);
    fake_is_array_object.nativeFunctionIdSlot().* = is_array_object.nativeFunctionIdSlot().*;
    const is_array_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_is_array_object);
    defer rt.memory.allocator.free(is_array_dispatch_name);
    try std.testing.expectEqualStrings("notArrayIsArray", is_array_dispatch_name);

    const direct_array = try engine.exec.array_builtin_ops.construct(rt, &.{core.JSValue.int32(1)});
    defer direct_array.free(rt);
    const direct_is_array_args = [_]core.JSValue{direct_array};
    const is_array_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, core.JSValue.undefinedValue(), fake_is_array, &direct_is_array_args);
    defer is_array_result.free(rt);
    try std.testing.expectEqual(true, is_array_result.asBool().?);

    const fake_from = try engine.core.function.nativeFunction(ctx, "notArrayFrom", 1);
    defer fake_from.free(rt);
    const fake_from_object: *core.Object = @fieldParentPtr("header", fake_from.refHeader().?);
    fake_from_object.nativeFunctionIdSlot().* = from_object.nativeFunctionIdSlot().*;
    const from_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_from_object);
    defer rt.memory.allocator.free(from_dispatch_name);
    try std.testing.expectEqualStrings("notArrayFrom", from_dispatch_name);

    const direct_from_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, array_value, fake_from, &direct_is_array_args);
    defer direct_from_result.free(rt);
    const direct_from_array: *core.Object = @fieldParentPtr("header", direct_from_result.refHeader().?);
    try std.testing.expect(direct_from_array.isArray());
    try std.testing.expectEqual(@as(u32, 1), direct_from_array.arrayLength());

    const fake_is_array_key = try rt.internAtom("fakeArrayIsArray");
    defer rt.atoms.free(fake_is_array_key);
    try global.defineOwnProperty(rt, fake_is_array_key, core.Descriptor.data(fake_is_array, true, false, true));
    const fake_from_key = try rt.internAtom("fakeArrayFrom");
    defer rt.atoms.free(fake_from_key);
    try global.defineOwnProperty(rt, fake_from_key, core.Descriptor.data(fake_from, true, false, true));

    var parsed = try engine.parser.compile(.{ .realm = ctx }, "print(fakeArrayIsArray([])); print(fakeArrayFrom.call(Array, [7, 8]).join(','));", .{ .mode = .script, .filename = "array-static-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stackLimit());
    defer stack.deinit(rt);
    var output_buffer: [24]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("true\n7,8\n", output.buffered());
}

test "array prototype native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const array_key = try rt.internAtom("Array");
    defer rt.atoms.free(array_key);
    const prototype_key = try rt.internAtom("prototype");
    defer rt.atoms.free(prototype_key);
    const to_string_key = try rt.internAtom("toString");
    defer rt.atoms.free(to_string_key);
    const join_key = try rt.internAtom("join");
    defer rt.atoms.free(join_key);
    const map_key = try rt.internAtom("map");
    defer rt.atoms.free(map_key);
    const values_key = try rt.internAtom("values");
    defer rt.atoms.free(values_key);
    const array_value = try global.getProperty(array_key);
    defer array_value.free(rt);
    const array_object: *core.Object = @fieldParentPtr("header", array_value.refHeader().?);
    const prototype_value = try array_object.getProperty(prototype_key);
    defer prototype_value.free(rt);
    const prototype_object: *core.Object = @fieldParentPtr("header", prototype_value.refHeader().?);

    const to_string_value = try prototype_object.getProperty(to_string_key);
    defer to_string_value.free(rt);
    const to_string_object: *core.Object = @fieldParentPtr("header", to_string_value.refHeader().?);
    try std.testing.expect(to_string_object.nativeFunctionIdSlot().* != 0);
    const join_value = try prototype_object.getProperty(join_key);
    defer join_value.free(rt);
    const join_object: *core.Object = @fieldParentPtr("header", join_value.refHeader().?);
    try std.testing.expect(join_object.nativeFunctionIdSlot().* != 0);
    const map_value = try prototype_object.getProperty(map_key);
    defer map_value.free(rt);
    const map_object: *core.Object = @fieldParentPtr("header", map_value.refHeader().?);
    try std.testing.expect(map_object.nativeFunctionIdSlot().* != 0);
    const values_value = try prototype_object.getProperty(values_key);
    defer values_value.free(rt);
    const values_object: *core.Object = @fieldParentPtr("header", values_value.refHeader().?);
    try std.testing.expect(values_object.nativeFunctionIdSlot().* != 0);

    const fake_join = try engine.core.function.nativeFunction(ctx, "notArrayJoin", 1);
    defer fake_join.free(rt);
    const fake_join_object: *core.Object = @fieldParentPtr("header", fake_join.refHeader().?);
    fake_join_object.nativeFunctionIdSlot().* = join_object.nativeFunctionIdSlot().*;
    const join_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_join_object);
    defer rt.memory.allocator.free(join_dispatch_name);
    try std.testing.expectEqualStrings("notArrayJoin", join_dispatch_name);

    const direct_array = try engine.exec.array_builtin_ops.constructWithPrototype(rt, &.{ core.JSValue.int32(1), core.JSValue.int32(2) }, prototype_object);
    defer direct_array.free(rt);
    const separator = (try core.string.String.createUtf8(rt, ":")).value();
    defer separator.free(rt);
    const join_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, direct_array, fake_join, &.{separator});
    defer join_result.free(rt);
    var join_text = std.ArrayList(u8).empty;
    defer join_text.deinit(rt.memory.allocator);
    try engine.exec.value_ops.appendRawString(rt, &join_text, join_result);
    try std.testing.expectEqualStrings("1:2", join_text.items);

    const fake_to_string = try engine.core.function.nativeFunction(ctx, "notArrayToString", 0);
    defer fake_to_string.free(rt);
    const fake_to_string_object: *core.Object = @fieldParentPtr("header", fake_to_string.refHeader().?);
    fake_to_string_object.nativeFunctionIdSlot().* = to_string_object.nativeFunctionIdSlot().*;
    const to_string_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, direct_array, fake_to_string, &.{});
    defer to_string_result.free(rt);
    var to_string_text = std.ArrayList(u8).empty;
    defer to_string_text.deinit(rt.memory.allocator);
    try engine.exec.value_ops.appendRawString(rt, &to_string_text, to_string_result);
    try std.testing.expectEqualStrings("1,2", to_string_text.items);

    const fake_map = try engine.core.function.nativeFunction(ctx, "notArrayMap", 1);
    defer fake_map.free(rt);
    const fake_map_object: *core.Object = @fieldParentPtr("header", fake_map.refHeader().?);
    fake_map_object.nativeFunctionIdSlot().* = map_object.nativeFunctionIdSlot().*;
    const fake_values = try engine.core.function.nativeFunction(ctx, "notArrayValues", 0);
    defer fake_values.free(rt);
    const fake_values_object: *core.Object = @fieldParentPtr("header", fake_values.refHeader().?);
    fake_values_object.nativeFunctionIdSlot().* = values_object.nativeFunctionIdSlot().*;

    const fake_map_key = try rt.internAtom("fakeArrayMap");
    defer rt.atoms.free(fake_map_key);
    try global.defineOwnProperty(rt, fake_map_key, core.Descriptor.data(fake_map, true, false, true));
    const fake_values_key = try rt.internAtom("fakeArrayValues");
    defer rt.atoms.free(fake_values_key);
    try global.defineOwnProperty(rt, fake_values_key, core.Descriptor.data(fake_values, true, false, true));

    var parsed = try engine.parser.compile(.{ .realm = ctx }, "print(fakeArrayMap.call([1,2], function(v){ return v + 1; }).join(',')); const it = fakeArrayValues.call([9]); print(it.next().value);", .{ .mode = .script, .filename = "array-prototype-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stackLimit());
    defer stack.deinit(rt);
    var output_buffer: [24]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("2,3\n9\n", output.buffered());
}

test "collection native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const map_key = try rt.internAtom("Map");
    defer rt.atoms.free(map_key);
    const set_key = try rt.internAtom("Set");
    defer rt.atoms.free(set_key);
    const prototype_key = try rt.internAtom("prototype");
    defer rt.atoms.free(prototype_key);
    const group_by_key = try rt.internAtom("groupBy");
    defer rt.atoms.free(group_by_key);
    const map_set_key = try rt.internAtom("set");
    defer rt.atoms.free(map_set_key);
    const map_for_each_key = try rt.internAtom("forEach");
    defer rt.atoms.free(map_for_each_key);
    const set_union_key = try rt.internAtom("union");
    defer rt.atoms.free(set_union_key);
    const set_values_key = try rt.internAtom("values");
    defer rt.atoms.free(set_values_key);

    const map_value = try global.getProperty(map_key);
    defer map_value.free(rt);
    const map_object: *core.Object = @fieldParentPtr("header", map_value.refHeader().?);
    const group_by_value = try map_object.getProperty(group_by_key);
    defer group_by_value.free(rt);
    const group_by_object: *core.Object = @fieldParentPtr("header", group_by_value.refHeader().?);
    try std.testing.expect(group_by_object.nativeFunctionIdSlot().* != 0);
    const map_prototype_value = try map_object.getProperty(prototype_key);
    defer map_prototype_value.free(rt);
    const map_prototype_object: *core.Object = @fieldParentPtr("header", map_prototype_value.refHeader().?);
    const map_set_value = try map_prototype_object.getProperty(map_set_key);
    defer map_set_value.free(rt);
    const map_set_object: *core.Object = @fieldParentPtr("header", map_set_value.refHeader().?);
    try std.testing.expect(map_set_object.nativeFunctionIdSlot().* != 0);
    const map_for_each_value = try map_prototype_object.getProperty(map_for_each_key);
    defer map_for_each_value.free(rt);
    const map_for_each_object: *core.Object = @fieldParentPtr("header", map_for_each_value.refHeader().?);
    try std.testing.expect(map_for_each_object.nativeFunctionIdSlot().* != 0);

    const set_value = try global.getProperty(set_key);
    defer set_value.free(rt);
    const set_object: *core.Object = @fieldParentPtr("header", set_value.refHeader().?);
    const set_prototype_value = try set_object.getProperty(prototype_key);
    defer set_prototype_value.free(rt);
    const set_prototype_object: *core.Object = @fieldParentPtr("header", set_prototype_value.refHeader().?);
    const set_union_value = try set_prototype_object.getProperty(set_union_key);
    defer set_union_value.free(rt);
    const set_union_object: *core.Object = @fieldParentPtr("header", set_union_value.refHeader().?);
    try std.testing.expect(set_union_object.nativeFunctionIdSlot().* != 0);
    const set_values_value = try set_prototype_object.getProperty(set_values_key);
    defer set_values_value.free(rt);
    const set_values_object: *core.Object = @fieldParentPtr("header", set_values_value.refHeader().?);
    try std.testing.expect(set_values_object.nativeFunctionIdSlot().* != 0);

    const fake_map_set = try engine.core.function.nativeFunction(ctx, "notMapSet", 2);
    defer fake_map_set.free(rt);
    const fake_map_set_object: *core.Object = @fieldParentPtr("header", fake_map_set.refHeader().?);
    fake_map_set_object.nativeFunctionIdSlot().* = map_set_object.nativeFunctionIdSlot().*;
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_map_set_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notMapSet", dispatch_name);

    const direct_map = try engine.exec.collection_ops.constructWithPrototype(rt, 1, map_prototype_object);
    defer direct_map.free(rt);
    const direct_key = (try core.string.String.createUtf8(rt, "direct")).value();
    defer direct_key.free(rt);
    const direct_args = [_]core.JSValue{ direct_key, core.JSValue.int32(7) };
    const direct_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, direct_map, fake_map_set, &direct_args);
    defer direct_result.free(rt);
    try std.testing.expect(direct_result.same(direct_map));
    const direct_get_result = try engine.exec.collection_ops.methodCall(rt, direct_map, 2, &.{direct_key});
    defer direct_get_result.free(rt);
    try std.testing.expectEqual(@as(?i32, 7), direct_get_result.asInt32());

    const fake_group_by = try engine.core.function.nativeFunction(ctx, "notMapGroupBy", 2);
    defer fake_group_by.free(rt);
    const fake_group_by_object: *core.Object = @fieldParentPtr("header", fake_group_by.refHeader().?);
    fake_group_by_object.nativeFunctionIdSlot().* = group_by_object.nativeFunctionIdSlot().*;
    const fake_map_for_each = try engine.core.function.nativeFunction(ctx, "notMapForEach", 1);
    defer fake_map_for_each.free(rt);
    const fake_map_for_each_object: *core.Object = @fieldParentPtr("header", fake_map_for_each.refHeader().?);
    fake_map_for_each_object.nativeFunctionIdSlot().* = map_for_each_object.nativeFunctionIdSlot().*;
    const fake_set_union = try engine.core.function.nativeFunction(ctx, "notSetUnion", 1);
    defer fake_set_union.free(rt);
    const fake_set_union_object: *core.Object = @fieldParentPtr("header", fake_set_union.refHeader().?);
    fake_set_union_object.nativeFunctionIdSlot().* = set_union_object.nativeFunctionIdSlot().*;
    const fake_set_values = try engine.core.function.nativeFunction(ctx, "notSetValues", 0);
    defer fake_set_values.free(rt);
    const fake_set_values_object: *core.Object = @fieldParentPtr("header", fake_set_values.refHeader().?);
    fake_set_values_object.nativeFunctionIdSlot().* = set_values_object.nativeFunctionIdSlot().*;

    const fake_map_set_key = try rt.internAtom("fakeMapSet");
    defer rt.atoms.free(fake_map_set_key);
    try global.defineOwnProperty(rt, fake_map_set_key, core.Descriptor.data(fake_map_set, true, false, true));
    const fake_group_by_key = try rt.internAtom("fakeMapGroupBy");
    defer rt.atoms.free(fake_group_by_key);
    try global.defineOwnProperty(rt, fake_group_by_key, core.Descriptor.data(fake_group_by, true, false, true));
    const fake_map_for_each_key = try rt.internAtom("fakeMapForEach");
    defer rt.atoms.free(fake_map_for_each_key);
    try global.defineOwnProperty(rt, fake_map_for_each_key, core.Descriptor.data(fake_map_for_each, true, false, true));
    const fake_set_union_key = try rt.internAtom("fakeSetUnion");
    defer rt.atoms.free(fake_set_union_key);
    try global.defineOwnProperty(rt, fake_set_union_key, core.Descriptor.data(fake_set_union, true, false, true));
    const fake_set_values_key = try rt.internAtom("fakeSetValues");
    defer rt.atoms.free(fake_set_values_key);
    try global.defineOwnProperty(rt, fake_set_values_key, core.Descriptor.data(fake_set_values, true, false, true));

    var parsed = try engine.parser.compile(.{ .realm = ctx }, "const grouped = fakeMapGroupBy.call(Map, ['aa', 'b'], function(v) { return v.length; }); print(grouped.get(2)[0]); const m = new Map(); fakeMapSet.call(m, 'a', 1); print(m.get('a')); fakeMapForEach.call(m, function(value, key) { print(key + ':' + value); }); const left = new Set(); left.add(1); const right = new Set(); right.add(2); const union = fakeSetUnion.call(left, right); print(Array.from(fakeSetValues.call(union)).join(','));", .{ .mode = .script, .filename = "collection-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stackLimit());
    defer stack.deinit(rt);
    var output_buffer: [32]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("aa\n1\na:1\n1,2\n", output.buffered());
}

test "buffer native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const array_buffer_key = try rt.internAtom("ArrayBuffer");
    defer rt.atoms.free(array_buffer_key);
    const shared_array_buffer_key = try rt.internAtom("SharedArrayBuffer");
    defer rt.atoms.free(shared_array_buffer_key);
    const data_view_key = try rt.internAtom("DataView");
    defer rt.atoms.free(data_view_key);
    const prototype_key = try rt.internAtom("prototype");
    defer rt.atoms.free(prototype_key);
    const is_view_key = try rt.internAtom("isView");
    defer rt.atoms.free(is_view_key);
    const slice_key = try rt.internAtom("slice");
    defer rt.atoms.free(slice_key);
    const byte_length_key = try rt.internAtom("byteLength");
    defer rt.atoms.free(byte_length_key);
    const get_uint8_key = try rt.internAtom("getUint8");
    defer rt.atoms.free(get_uint8_key);
    const set_uint8_key = try rt.internAtom("setUint8");
    defer rt.atoms.free(set_uint8_key);

    const array_buffer_value = try global.getProperty(array_buffer_key);
    defer array_buffer_value.free(rt);
    const array_buffer_object: *core.Object = @fieldParentPtr("header", array_buffer_value.refHeader().?);
    const is_view_value = try array_buffer_object.getProperty(is_view_key);
    defer is_view_value.free(rt);
    const is_view_object: *core.Object = @fieldParentPtr("header", is_view_value.refHeader().?);
    try std.testing.expect(is_view_object.nativeFunctionIdSlot().* != 0);
    const array_buffer_prototype_value = try array_buffer_object.getProperty(prototype_key);
    defer array_buffer_prototype_value.free(rt);
    const array_buffer_prototype_object: *core.Object = @fieldParentPtr("header", array_buffer_prototype_value.refHeader().?);
    const array_buffer_slice_value = try array_buffer_prototype_object.getProperty(slice_key);
    defer array_buffer_slice_value.free(rt);
    const array_buffer_slice_object: *core.Object = @fieldParentPtr("header", array_buffer_slice_value.refHeader().?);
    try std.testing.expect(array_buffer_slice_object.nativeFunctionIdSlot().* != 0);
    const array_buffer_byte_length_desc = (try array_buffer_prototype_object.getOwnProperty(rt, byte_length_key)).?;
    defer array_buffer_byte_length_desc.destroy(rt);
    const array_buffer_byte_length_getter: *core.Object = @fieldParentPtr("header", array_buffer_byte_length_desc.getter.refHeader().?);
    try std.testing.expect(array_buffer_byte_length_getter.nativeFunctionIdSlot().* != 0);

    const shared_array_buffer_value = try global.getProperty(shared_array_buffer_key);
    defer shared_array_buffer_value.free(rt);
    const shared_array_buffer_object: *core.Object = @fieldParentPtr("header", shared_array_buffer_value.refHeader().?);
    const shared_array_buffer_prototype_value = try shared_array_buffer_object.getProperty(prototype_key);
    defer shared_array_buffer_prototype_value.free(rt);
    const shared_array_buffer_prototype_object: *core.Object = @fieldParentPtr("header", shared_array_buffer_prototype_value.refHeader().?);
    const shared_array_buffer_slice_value = try shared_array_buffer_prototype_object.getProperty(slice_key);
    defer shared_array_buffer_slice_value.free(rt);
    const shared_array_buffer_slice_object: *core.Object = @fieldParentPtr("header", shared_array_buffer_slice_value.refHeader().?);
    try std.testing.expect(shared_array_buffer_slice_object.nativeFunctionIdSlot().* != 0);

    const data_view_value = try global.getProperty(data_view_key);
    defer data_view_value.free(rt);
    const data_view_object: *core.Object = @fieldParentPtr("header", data_view_value.refHeader().?);
    const data_view_prototype_value = try data_view_object.getProperty(prototype_key);
    defer data_view_prototype_value.free(rt);
    const data_view_prototype_object: *core.Object = @fieldParentPtr("header", data_view_prototype_value.refHeader().?);
    const get_uint8_value = try data_view_prototype_object.getProperty(get_uint8_key);
    defer get_uint8_value.free(rt);
    const get_uint8_object: *core.Object = @fieldParentPtr("header", get_uint8_value.refHeader().?);
    try std.testing.expect(get_uint8_object.nativeFunctionIdSlot().* != 0);
    const set_uint8_value = try data_view_prototype_object.getProperty(set_uint8_key);
    defer set_uint8_value.free(rt);
    const set_uint8_object: *core.Object = @fieldParentPtr("header", set_uint8_value.refHeader().?);
    try std.testing.expect(set_uint8_object.nativeFunctionIdSlot().* != 0);
    const data_view_byte_length_desc = (try data_view_prototype_object.getOwnProperty(rt, byte_length_key)).?;
    defer data_view_byte_length_desc.destroy(rt);
    const data_view_byte_length_getter: *core.Object = @fieldParentPtr("header", data_view_byte_length_desc.getter.refHeader().?);
    try std.testing.expect(data_view_byte_length_getter.nativeFunctionIdSlot().* != 0);

    const fake_is_view = try engine.core.function.nativeFunction(ctx, "notArrayBufferIsView", 1);
    defer fake_is_view.free(rt);
    const fake_is_view_object: *core.Object = @fieldParentPtr("header", fake_is_view.refHeader().?);
    fake_is_view_object.nativeFunctionIdSlot().* = is_view_object.nativeFunctionIdSlot().*;
    const fake_array_buffer_slice = try engine.core.function.nativeFunction(ctx, "notArrayBufferSlice", 2);
    defer fake_array_buffer_slice.free(rt);
    const fake_array_buffer_slice_object: *core.Object = @fieldParentPtr("header", fake_array_buffer_slice.refHeader().?);
    fake_array_buffer_slice_object.nativeFunctionIdSlot().* = array_buffer_slice_object.nativeFunctionIdSlot().*;
    const fake_array_buffer_byte_length = try engine.core.function.nativeFunction(ctx, "notArrayBufferByteLength", 0);
    defer fake_array_buffer_byte_length.free(rt);
    const fake_array_buffer_byte_length_object: *core.Object = @fieldParentPtr("header", fake_array_buffer_byte_length.refHeader().?);
    fake_array_buffer_byte_length_object.nativeFunctionIdSlot().* = array_buffer_byte_length_getter.nativeFunctionIdSlot().*;
    const fake_shared_array_buffer_slice = try engine.core.function.nativeFunction(ctx, "notSharedArrayBufferSlice", 2);
    defer fake_shared_array_buffer_slice.free(rt);
    const fake_shared_array_buffer_slice_object: *core.Object = @fieldParentPtr("header", fake_shared_array_buffer_slice.refHeader().?);
    fake_shared_array_buffer_slice_object.nativeFunctionIdSlot().* = shared_array_buffer_slice_object.nativeFunctionIdSlot().*;
    const fake_data_view_get_uint8 = try engine.core.function.nativeFunction(ctx, "notDataViewGetUint8", 1);
    defer fake_data_view_get_uint8.free(rt);
    const fake_data_view_get_uint8_object: *core.Object = @fieldParentPtr("header", fake_data_view_get_uint8.refHeader().?);
    fake_data_view_get_uint8_object.nativeFunctionIdSlot().* = get_uint8_object.nativeFunctionIdSlot().*;
    const fake_data_view_set_uint8 = try engine.core.function.nativeFunction(ctx, "notDataViewSetUint8", 2);
    defer fake_data_view_set_uint8.free(rt);
    const fake_data_view_set_uint8_object: *core.Object = @fieldParentPtr("header", fake_data_view_set_uint8.refHeader().?);
    fake_data_view_set_uint8_object.nativeFunctionIdSlot().* = set_uint8_object.nativeFunctionIdSlot().*;
    const fake_data_view_byte_length = try engine.core.function.nativeFunction(ctx, "notDataViewByteLength", 0);
    defer fake_data_view_byte_length.free(rt);
    const fake_data_view_byte_length_object: *core.Object = @fieldParentPtr("header", fake_data_view_byte_length.refHeader().?);
    fake_data_view_byte_length_object.nativeFunctionIdSlot().* = data_view_byte_length_getter.nativeFunctionIdSlot().*;

    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_array_buffer_slice_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notArrayBufferSlice", dispatch_name);

    const direct_buffer = try engine.exec.buffer_ops.arrayBufferConstructArgs(rt, &.{core.JSValue.int32(6)}, array_buffer_prototype_object);
    defer direct_buffer.free(rt);
    const direct_slice_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, direct_buffer, fake_array_buffer_slice, &.{ core.JSValue.int32(1), core.JSValue.int32(4) });
    defer direct_slice_result.free(rt);
    const direct_slice_object: *core.Object = @fieldParentPtr("header", direct_slice_result.refHeader().?);
    try std.testing.expectEqual(@as(usize, 3), direct_slice_object.byteStorage().len);
    const direct_length_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, direct_buffer, fake_array_buffer_byte_length, &.{});
    defer direct_length_result.free(rt);
    try std.testing.expectEqual(@as(?i32, 6), direct_length_result.asInt32());

    const fake_is_view_key = try rt.internAtom("fakeArrayBufferIsView");
    defer rt.atoms.free(fake_is_view_key);
    try global.defineOwnProperty(rt, fake_is_view_key, core.Descriptor.data(fake_is_view, true, false, true));
    const fake_array_buffer_slice_key = try rt.internAtom("fakeArrayBufferSlice");
    defer rt.atoms.free(fake_array_buffer_slice_key);
    try global.defineOwnProperty(rt, fake_array_buffer_slice_key, core.Descriptor.data(fake_array_buffer_slice, true, false, true));
    const fake_array_buffer_byte_length_key = try rt.internAtom("fakeArrayBufferByteLength");
    defer rt.atoms.free(fake_array_buffer_byte_length_key);
    try global.defineOwnProperty(rt, fake_array_buffer_byte_length_key, core.Descriptor.data(fake_array_buffer_byte_length, true, false, true));
    const fake_shared_array_buffer_slice_key = try rt.internAtom("fakeSharedArrayBufferSlice");
    defer rt.atoms.free(fake_shared_array_buffer_slice_key);
    try global.defineOwnProperty(rt, fake_shared_array_buffer_slice_key, core.Descriptor.data(fake_shared_array_buffer_slice, true, false, true));
    const fake_data_view_get_uint8_key = try rt.internAtom("fakeDataViewGetUint8");
    defer rt.atoms.free(fake_data_view_get_uint8_key);
    try global.defineOwnProperty(rt, fake_data_view_get_uint8_key, core.Descriptor.data(fake_data_view_get_uint8, true, false, true));
    const fake_data_view_set_uint8_key = try rt.internAtom("fakeDataViewSetUint8");
    defer rt.atoms.free(fake_data_view_set_uint8_key);
    try global.defineOwnProperty(rt, fake_data_view_set_uint8_key, core.Descriptor.data(fake_data_view_set_uint8, true, false, true));
    const fake_data_view_byte_length_key = try rt.internAtom("fakeDataViewByteLength");
    defer rt.atoms.free(fake_data_view_byte_length_key);
    try global.defineOwnProperty(rt, fake_data_view_byte_length_key, core.Descriptor.data(fake_data_view_byte_length, true, false, true));

    var parsed = try engine.parser.compile(.{ .realm = ctx },
        \\const b = new ArrayBuffer(6);
        \\print(fakeArrayBufferIsView(new DataView(b)));
        \\print(fakeArrayBufferSlice.call(b, 1, 4).byteLength);
        \\print(fakeArrayBufferByteLength.call(b));
        \\const s = new SharedArrayBuffer(5);
        \\print(fakeSharedArrayBufferSlice.call(s, 1, 3).byteLength);
        \\const v = new DataView(b);
        \\fakeDataViewSetUint8.call(v, 0, 77);
        \\print(fakeDataViewGetUint8.call(v, 0));
        \\print(fakeDataViewByteLength.call(v));
    , .{ .mode = .script, .filename = "buffer-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stackLimit());
    defer stack.deinit(rt);
    var output_buffer: [40]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("true\n3\n6\n2\n77\n6\n", output.buffered());
}

test "typed array accessor native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const typed_array_key = try rt.internAtom("TypedArray");
    defer rt.atoms.free(typed_array_key);
    const prototype_key = try rt.internAtom("prototype");
    defer rt.atoms.free(prototype_key);
    const byte_length_key = try rt.internAtom("byteLength");
    defer rt.atoms.free(byte_length_key);
    const length_key = try rt.internAtom("length");
    defer rt.atoms.free(length_key);

    const typed_array_value = try global.getProperty(typed_array_key);
    defer typed_array_value.free(rt);
    const typed_array_object: *core.Object = @fieldParentPtr("header", typed_array_value.refHeader().?);
    const prototype_value = try typed_array_object.getProperty(prototype_key);
    defer prototype_value.free(rt);
    const prototype_object: *core.Object = @fieldParentPtr("header", prototype_value.refHeader().?);

    const byte_length_desc = (try prototype_object.getOwnProperty(rt, byte_length_key)).?;
    defer byte_length_desc.destroy(rt);
    const byte_length_getter: *core.Object = @fieldParentPtr("header", byte_length_desc.getter.refHeader().?);
    try std.testing.expect(byte_length_getter.nativeFunctionIdSlot().* != 0);
    const length_desc = (try prototype_object.getOwnProperty(rt, length_key)).?;
    defer length_desc.destroy(rt);
    const length_getter: *core.Object = @fieldParentPtr("header", length_desc.getter.refHeader().?);
    try std.testing.expect(length_getter.nativeFunctionIdSlot().* != 0);
    const tag_desc = (try prototype_object.getOwnProperty(rt, core.atom.predefinedId("Symbol.toStringTag", .symbol).?)).?;
    defer tag_desc.destroy(rt);
    const tag_getter: *core.Object = @fieldParentPtr("header", tag_desc.getter.refHeader().?);
    try std.testing.expect(tag_getter.nativeFunctionIdSlot().* != 0);

    const fake_byte_length = try engine.core.function.nativeFunction(ctx, "notTypedArrayByteLength", 0);
    defer fake_byte_length.free(rt);
    const fake_byte_length_object: *core.Object = @fieldParentPtr("header", fake_byte_length.refHeader().?);
    fake_byte_length_object.nativeFunctionIdSlot().* = byte_length_getter.nativeFunctionIdSlot().*;
    const fake_length = try engine.core.function.nativeFunction(ctx, "notTypedArrayLength", 0);
    defer fake_length.free(rt);
    const fake_length_object: *core.Object = @fieldParentPtr("header", fake_length.refHeader().?);
    fake_length_object.nativeFunctionIdSlot().* = length_getter.nativeFunctionIdSlot().*;
    const fake_tag = try engine.core.function.nativeFunction(ctx, "notTypedArrayTag", 0);
    defer fake_tag.free(rt);
    const fake_tag_object: *core.Object = @fieldParentPtr("header", fake_tag.refHeader().?);
    fake_tag_object.nativeFunctionIdSlot().* = tag_getter.nativeFunctionIdSlot().*;

    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_byte_length_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notTypedArrayByteLength", dispatch_name);

    const direct_buffer = try engine.exec.buffer_ops.arrayBufferConstructArgs(rt, &.{core.JSValue.int32(8)}, null);
    defer direct_buffer.free(rt);
    const direct_typed_array = try engine.exec.buffer_ops.typedArrayConstructWithOptions(rt, 1, 2, direct_buffer, &.{direct_buffer}, prototype_object);
    defer direct_typed_array.free(rt);
    const direct_byte_length = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, direct_typed_array, fake_byte_length, &.{});
    defer direct_byte_length.free(rt);
    try std.testing.expectEqual(@as(?i32, 8), direct_byte_length.asInt32());
    const direct_length = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, direct_typed_array, fake_length, &.{});
    defer direct_length.free(rt);
    try std.testing.expectEqual(@as(?i32, 8), direct_length.asInt32());

    const fake_byte_length_key = try rt.internAtom("fakeTypedArrayByteLength");
    defer rt.atoms.free(fake_byte_length_key);
    try global.defineOwnProperty(rt, fake_byte_length_key, core.Descriptor.data(fake_byte_length, true, false, true));
    const fake_length_key = try rt.internAtom("fakeTypedArrayLength");
    defer rt.atoms.free(fake_length_key);
    try global.defineOwnProperty(rt, fake_length_key, core.Descriptor.data(fake_length, true, false, true));
    const fake_tag_key = try rt.internAtom("fakeTypedArrayTag");
    defer rt.atoms.free(fake_tag_key);
    try global.defineOwnProperty(rt, fake_tag_key, core.Descriptor.data(fake_tag, true, false, true));

    var parsed = try engine.parser.compile(.{ .realm = ctx },
        \\const ta = new Uint8Array([1, 2, 3, 4]);
        \\print(fakeTypedArrayByteLength.call(ta));
        \\print(fakeTypedArrayLength.call(ta));
        \\print(fakeTypedArrayTag.call(ta));
        \\print(fakeTypedArrayTag.call({}));
    , .{ .mode = .script, .filename = "typed-array-accessor-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stackLimit());
    defer stack.deinit(rt);
    var output_buffer: [32]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("4\n4\nUint8Array\nundefined\n", output.buffered());
}

test "regexp static native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const regexp_key = try rt.internAtom("RegExp");
    defer rt.atoms.free(regexp_key);
    const escape_key = try rt.internAtom("escape");
    defer rt.atoms.free(escape_key);
    const regexp_value = try global.getProperty(regexp_key);
    defer regexp_value.free(rt);
    const regexp_object: *core.Object = @fieldParentPtr("header", regexp_value.refHeader().?);
    const escape_value = try regexp_object.getProperty(escape_key);
    defer escape_value.free(rt);
    const escape_object: *core.Object = @fieldParentPtr("header", escape_value.refHeader().?);
    try std.testing.expect(escape_object.nativeFunctionIdSlot().* != 0);

    const fake = try engine.core.function.nativeFunction(ctx, "notRegExpEscape", 1);
    defer fake.free(rt);
    const fake_object: *core.Object = @fieldParentPtr("header", fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = escape_object.nativeFunctionIdSlot().*;
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notRegExpEscape", dispatch_name);

    const dot = try core.string.String.createUtf8(rt, ".");
    defer dot.value().free(rt);
    const direct_args = [_]core.JSValue{dot.value()};
    const direct_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, core.JSValue.undefinedValue(), fake, &direct_args);
    defer direct_result.free(rt);
    try std.testing.expect(direct_result.isString());
    const direct_result_string = direct_result.asStringBody().?;
    try std.testing.expect(direct_result_string.eqlBytes("\\."));

    const fake_key = try rt.internAtom("fakeRegExpEscape");
    defer rt.atoms.free(fake_key);
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, true, false, true));

    var parsed = try engine.parser.compile(.{ .realm = ctx }, "print(fakeRegExpEscape('.')); print(fakeRegExpEscape('a+b'));", .{ .mode = .script, .filename = "regexp-static-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stackLimit());
    defer stack.deinit(rt);
    var output_buffer: [24]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("\\.\n\\x61\\+b\n", output.buffered());
}

test "regexp prototype native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const regexp_key = try rt.internAtom("RegExp");
    defer rt.atoms.free(regexp_key);
    const exec_key = try rt.internAtom("exec");
    defer rt.atoms.free(exec_key);
    const test_key = try rt.internAtom("test");
    defer rt.atoms.free(test_key);
    const to_string_key = try rt.internAtom("toString");
    defer rt.atoms.free(to_string_key);
    const regexp_value = try global.getProperty(regexp_key);
    defer regexp_value.free(rt);
    const regexp_object: *core.Object = @fieldParentPtr("header", regexp_value.refHeader().?);
    const prototype_value = try regexp_object.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    const prototype_object: *core.Object = @fieldParentPtr("header", prototype_value.refHeader().?);
    const exec_value = try prototype_object.getProperty(exec_key);
    defer exec_value.free(rt);
    const exec_object: *core.Object = @fieldParentPtr("header", exec_value.refHeader().?);
    try std.testing.expect(exec_object.nativeFunctionIdSlot().* != 0);
    const test_value = try prototype_object.getProperty(test_key);
    defer test_value.free(rt);
    const test_object: *core.Object = @fieldParentPtr("header", test_value.refHeader().?);
    try std.testing.expect(test_object.nativeFunctionIdSlot().* != 0);
    const to_string_value = try prototype_object.getProperty(to_string_key);
    defer to_string_value.free(rt);
    const to_string_object: *core.Object = @fieldParentPtr("header", to_string_value.refHeader().?);
    try std.testing.expect(to_string_object.nativeFunctionIdSlot().* != 0);

    const fake_exec = try engine.core.function.nativeFunction(ctx, "notRegExpExec", 1);
    defer fake_exec.free(rt);
    const fake_exec_object: *core.Object = @fieldParentPtr("header", fake_exec.refHeader().?);
    fake_exec_object.nativeFunctionIdSlot().* = exec_object.nativeFunctionIdSlot().*;
    const exec_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_exec_object);
    defer rt.memory.allocator.free(exec_dispatch_name);
    try std.testing.expectEqualStrings("notRegExpExec", exec_dispatch_name);

    const fake_test = try engine.core.function.nativeFunction(ctx, "notRegExpTest", 1);
    defer fake_test.free(rt);
    const fake_test_object: *core.Object = @fieldParentPtr("header", fake_test.refHeader().?);
    fake_test_object.nativeFunctionIdSlot().* = test_object.nativeFunctionIdSlot().*;
    const test_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_test_object);
    defer rt.memory.allocator.free(test_dispatch_name);
    try std.testing.expectEqualStrings("notRegExpTest", test_dispatch_name);

    const fake_to_string = try engine.core.function.nativeFunction(ctx, "notRegExpToString", 0);
    defer fake_to_string.free(rt);
    const fake_to_string_object: *core.Object = @fieldParentPtr("header", fake_to_string.refHeader().?);
    fake_to_string_object.nativeFunctionIdSlot().* = to_string_object.nativeFunctionIdSlot().*;
    const to_string_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_to_string_object);
    defer rt.memory.allocator.free(to_string_dispatch_name);
    try std.testing.expectEqualStrings("notRegExpToString", to_string_dispatch_name);

    const pattern_string = try core.string.String.createUtf8(rt, "a");
    defer pattern_string.value().free(rt);
    const flags_string = try core.string.String.createUtf8(rt, "");
    defer flags_string.value().free(rt);
    const receiver = try engine.exec.regexp_ops.constructWithPrototype(rt, pattern_string.value(), flags_string.value(), prototype_object);
    defer receiver.free(rt);
    const input_string = try core.string.String.createUtf8(rt, "cat");
    defer input_string.value().free(rt);
    const direct_args = [_]core.JSValue{input_string.value()};
    const exec_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_exec, &direct_args);
    defer exec_result.free(rt);
    const exec_array: *core.Object = @fieldParentPtr("header", exec_result.refHeader().?);
    try std.testing.expect(exec_array.isArray());
    const first_match = try exec_array.getProperty(core.atom.atomFromUInt32(0));
    defer first_match.free(rt);
    try std.testing.expect(first_match.isString());
    const first_match_string = first_match.asStringBody().?;
    try std.testing.expect(first_match_string.eqlBytes("a"));
    const index_key = try rt.internAtom("index");
    defer rt.atoms.free(index_key);
    const index_value = try exec_array.getProperty(index_key);
    defer index_value.free(rt);
    try std.testing.expectEqual(@as(i32, 1), index_value.asInt32().?);

    const test_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_test, &direct_args);
    defer test_result.free(rt);
    try std.testing.expectEqual(true, test_result.asBool().?);

    const to_string_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_to_string, &.{});
    defer to_string_result.free(rt);
    try std.testing.expect(to_string_result.isString());
    const to_string_result_string = to_string_result.asStringBody().?;
    try std.testing.expect(to_string_result_string.eqlBytes("/a/"));

    const fake_exec_key = try rt.internAtom("fakeRegExpExec");
    defer rt.atoms.free(fake_exec_key);
    try global.defineOwnProperty(rt, fake_exec_key, core.Descriptor.data(fake_exec, true, false, true));
    const fake_test_key = try rt.internAtom("fakeRegExpTest");
    defer rt.atoms.free(fake_test_key);
    try global.defineOwnProperty(rt, fake_test_key, core.Descriptor.data(fake_test, true, false, true));
    const fake_to_string_key = try rt.internAtom("fakeRegExpToString");
    defer rt.atoms.free(fake_to_string_key);
    try global.defineOwnProperty(rt, fake_to_string_key, core.Descriptor.data(fake_to_string, true, false, true));

    var parsed = try engine.parser.compile(.{ .realm = ctx }, "const r = /a/; const m = fakeRegExpExec.call(r, 'cat'); print(m[0] + ':' + m.index); print(fakeRegExpTest.call(r, 'cat')); print(fakeRegExpToString.call(r));", .{ .mode = .script, .filename = "regexp-prototype-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stackLimit());
    defer stack.deinit(rt);
    var output_buffer: [32]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("a:1\ntrue\n/a/\n", output.buffered());
}

test "regexp symbol native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const regexp_key = try rt.internAtom("RegExp");
    defer rt.atoms.free(regexp_key);
    const regexp_value = try global.getProperty(regexp_key);
    defer regexp_value.free(rt);
    const regexp_object: *core.Object = @fieldParentPtr("header", regexp_value.refHeader().?);
    const prototype_value = try regexp_object.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    const prototype_object: *core.Object = @fieldParentPtr("header", prototype_value.refHeader().?);

    const search_value = try prototype_object.getProperty(core.atom.predefinedId("Symbol.search", .symbol).?);
    defer search_value.free(rt);
    const search_object: *core.Object = @fieldParentPtr("header", search_value.refHeader().?);
    try std.testing.expect(search_object.nativeFunctionIdSlot().* != 0);
    const match_value = try prototype_object.getProperty(core.atom.predefinedId("Symbol.match", .symbol).?);
    defer match_value.free(rt);
    const match_object: *core.Object = @fieldParentPtr("header", match_value.refHeader().?);
    try std.testing.expect(match_object.nativeFunctionIdSlot().* != 0);
    const match_all_value = try prototype_object.getProperty(core.atom.predefinedId("Symbol.matchAll", .symbol).?);
    defer match_all_value.free(rt);
    const match_all_object: *core.Object = @fieldParentPtr("header", match_all_value.refHeader().?);
    try std.testing.expect(match_all_object.nativeFunctionIdSlot().* != 0);
    const replace_value = try prototype_object.getProperty(core.atom.predefinedId("Symbol.replace", .symbol).?);
    defer replace_value.free(rt);
    const replace_object: *core.Object = @fieldParentPtr("header", replace_value.refHeader().?);
    try std.testing.expect(replace_object.nativeFunctionIdSlot().* != 0);
    const split_value = try prototype_object.getProperty(core.atom.predefinedId("Symbol.split", .symbol).?);
    defer split_value.free(rt);
    const split_object: *core.Object = @fieldParentPtr("header", split_value.refHeader().?);
    try std.testing.expect(split_object.nativeFunctionIdSlot().* != 0);

    const fake_search = try engine.core.function.nativeFunction(ctx, "notRegExpSearch", 1);
    defer fake_search.free(rt);
    const fake_search_object: *core.Object = @fieldParentPtr("header", fake_search.refHeader().?);
    fake_search_object.nativeFunctionIdSlot().* = search_object.nativeFunctionIdSlot().*;
    const search_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_search_object);
    defer rt.memory.allocator.free(search_dispatch_name);
    try std.testing.expectEqualStrings("notRegExpSearch", search_dispatch_name);

    const fake_match = try engine.core.function.nativeFunction(ctx, "notRegExpMatch", 1);
    defer fake_match.free(rt);
    const fake_match_object: *core.Object = @fieldParentPtr("header", fake_match.refHeader().?);
    fake_match_object.nativeFunctionIdSlot().* = match_object.nativeFunctionIdSlot().*;
    const fake_match_all = try engine.core.function.nativeFunction(ctx, "notRegExpMatchAll", 1);
    defer fake_match_all.free(rt);
    const fake_match_all_object: *core.Object = @fieldParentPtr("header", fake_match_all.refHeader().?);
    fake_match_all_object.nativeFunctionIdSlot().* = match_all_object.nativeFunctionIdSlot().*;
    const fake_replace = try engine.core.function.nativeFunction(ctx, "notRegExpReplace", 2);
    defer fake_replace.free(rt);
    const fake_replace_object: *core.Object = @fieldParentPtr("header", fake_replace.refHeader().?);
    fake_replace_object.nativeFunctionIdSlot().* = replace_object.nativeFunctionIdSlot().*;
    const fake_split = try engine.core.function.nativeFunction(ctx, "notRegExpSplit", 2);
    defer fake_split.free(rt);
    const fake_split_object: *core.Object = @fieldParentPtr("header", fake_split.refHeader().?);
    fake_split_object.nativeFunctionIdSlot().* = split_object.nativeFunctionIdSlot().*;

    const pattern_string = try core.string.String.createUtf8(rt, "a");
    defer pattern_string.value().free(rt);
    const flags_string = try core.string.String.createUtf8(rt, "");
    defer flags_string.value().free(rt);
    const receiver = try engine.exec.regexp_ops.constructWithPrototype(rt, pattern_string.value(), flags_string.value(), prototype_object);
    defer receiver.free(rt);
    const input_string = try core.string.String.createUtf8(rt, "cat");
    defer input_string.value().free(rt);
    const replacement_string = try core.string.String.createUtf8(rt, "o");
    defer replacement_string.value().free(rt);

    const one_arg = [_]core.JSValue{input_string.value()};
    const search_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_search, &one_arg);
    defer search_result.free(rt);
    try std.testing.expectEqual(@as(i32, 1), search_result.asInt32().?);

    const match_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_match, &one_arg);
    defer match_result.free(rt);
    const match_array: *core.Object = @fieldParentPtr("header", match_result.refHeader().?);
    const match_zero = try match_array.getProperty(core.atom.atomFromUInt32(0));
    defer match_zero.free(rt);
    try std.testing.expect(match_zero.isString());
    const match_zero_string = match_zero.asStringBody().?;
    try std.testing.expect(match_zero_string.eqlBytes("a"));

    const match_all_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_match_all, &one_arg);
    defer match_all_result.free(rt);
    const match_all_iterator: *core.Object = @fieldParentPtr("header", match_all_result.refHeader().?);
    try std.testing.expectEqual(core.class.ids.regexp_string_iterator, match_all_iterator.class_id);

    const replace_args = [_]core.JSValue{ input_string.value(), replacement_string.value() };
    const replace_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_replace, &replace_args);
    defer replace_result.free(rt);
    try std.testing.expect(replace_result.isString());
    const replace_result_string = replace_result.asStringBody().?;
    try std.testing.expect(replace_result_string.eqlBytes("cot"));

    const split_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_split, &one_arg);
    defer split_result.free(rt);
    const split_array: *core.Object = @fieldParentPtr("header", split_result.refHeader().?);
    try std.testing.expect(split_array.isArray());
    try std.testing.expectEqual(@as(u32, 2), split_array.arrayLength());

    const fake_search_key = try rt.internAtom("fakeRegExpSearch");
    defer rt.atoms.free(fake_search_key);
    try global.defineOwnProperty(rt, fake_search_key, core.Descriptor.data(fake_search, true, false, true));
    const fake_match_key = try rt.internAtom("fakeRegExpMatch");
    defer rt.atoms.free(fake_match_key);
    try global.defineOwnProperty(rt, fake_match_key, core.Descriptor.data(fake_match, true, false, true));
    const fake_match_all_key = try rt.internAtom("fakeRegExpMatchAll");
    defer rt.atoms.free(fake_match_all_key);
    try global.defineOwnProperty(rt, fake_match_all_key, core.Descriptor.data(fake_match_all, true, false, true));
    const fake_replace_key = try rt.internAtom("fakeRegExpReplace");
    defer rt.atoms.free(fake_replace_key);
    try global.defineOwnProperty(rt, fake_replace_key, core.Descriptor.data(fake_replace, true, false, true));
    const fake_split_key = try rt.internAtom("fakeRegExpSplit");
    defer rt.atoms.free(fake_split_key);
    try global.defineOwnProperty(rt, fake_split_key, core.Descriptor.data(fake_split, true, false, true));

    var parsed = try engine.parser.compile(.{ .realm = ctx },
        \\const r = /a/;
        \\print(fakeRegExpSearch.call(r, 'cat'));
        \\print(fakeRegExpMatch.call(r, 'cat')[0]);
        \\print(fakeRegExpMatchAll.call(r, 'cat').next().value[0]);
        \\print(fakeRegExpReplace.call(r, 'cat', 'o'));
        \\print(fakeRegExpSplit.call(r, 'cat').join('|'));
    , .{ .mode = .script, .filename = "regexp-symbol-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stackLimit());
    defer stack.deinit(rt);
    var output_buffer: [48]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("1\na\na\ncot\nc|t\n", output.buffered());
}

test "regexp accessor native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const regexp_key = try rt.internAtom("RegExp");
    defer rt.atoms.free(regexp_key);
    const regexp_value = try global.getProperty(regexp_key);
    defer regexp_value.free(rt);
    const regexp_object: *core.Object = @fieldParentPtr("header", regexp_value.refHeader().?);
    const prototype_value = try regexp_object.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    const prototype_object: *core.Object = @fieldParentPtr("header", prototype_value.refHeader().?);

    const source_key = try rt.internAtom("source");
    defer rt.atoms.free(source_key);
    const source_desc = (try prototype_object.getOwnProperty(rt, source_key)).?;
    defer source_desc.destroy(rt);
    const source_getter: *core.Object = @fieldParentPtr("header", source_desc.getter.refHeader().?);
    try std.testing.expect(source_getter.nativeFunctionIdSlot().* != 0);
    const global_key = try rt.internAtom("global");
    defer rt.atoms.free(global_key);
    const global_desc = (try prototype_object.getOwnProperty(rt, global_key)).?;
    defer global_desc.destroy(rt);
    const global_getter: *core.Object = @fieldParentPtr("header", global_desc.getter.refHeader().?);
    try std.testing.expect(global_getter.nativeFunctionIdSlot().* != 0);

    const fake_source = try engine.core.function.nativeFunction(ctx, "notRegExpSourceGetter", 0);
    defer fake_source.free(rt);
    const fake_source_object: *core.Object = @fieldParentPtr("header", fake_source.refHeader().?);
    fake_source_object.nativeFunctionIdSlot().* = source_getter.nativeFunctionIdSlot().*;
    const source_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_source_object);
    defer rt.memory.allocator.free(source_dispatch_name);
    try std.testing.expectEqualStrings("notRegExpSourceGetter", source_dispatch_name);

    const fake_global = try engine.core.function.nativeFunction(ctx, "notRegExpGlobalGetter", 0);
    defer fake_global.free(rt);
    const fake_global_object: *core.Object = @fieldParentPtr("header", fake_global.refHeader().?);
    fake_global_object.nativeFunctionIdSlot().* = global_getter.nativeFunctionIdSlot().*;

    const pattern_string = try core.string.String.createUtf8(rt, "a/b");
    defer pattern_string.value().free(rt);
    const flags_string = try core.string.String.createUtf8(rt, "g");
    defer flags_string.value().free(rt);
    const receiver = try engine.exec.regexp_ops.constructWithPrototype(rt, pattern_string.value(), flags_string.value(), prototype_object);
    defer receiver.free(rt);

    const source_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_source, &.{});
    defer source_result.free(rt);
    try std.testing.expect(source_result.isString());
    const source_string = source_result.asStringBody().?;
    try std.testing.expect(source_string.eqlBytes("a\\/b"));

    const global_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_global, &.{});
    defer global_result.free(rt);
    try std.testing.expectEqual(true, global_result.asBool().?);

    const fake_source_key = try rt.internAtom("fakeRegExpSourceGetter");
    defer rt.atoms.free(fake_source_key);
    try global.defineOwnProperty(rt, fake_source_key, core.Descriptor.data(fake_source, true, false, true));
    const fake_global_key = try rt.internAtom("fakeRegExpGlobalGetter");
    defer rt.atoms.free(fake_global_key);
    try global.defineOwnProperty(rt, fake_global_key, core.Descriptor.data(fake_global, true, false, true));

    var parsed = try engine.parser.compile(.{ .realm = ctx },
        \\const r = /a\/b/g;
        \\print(fakeRegExpSourceGetter.call(r));
        \\print(fakeRegExpGlobalGetter.call(r));
    , .{ .mode = .script, .filename = "regexp-accessor-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stackLimit());
    defer stack.deinit(rt);
    var output_buffer: [24]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("a\\/b\ntrue\n", output.buffered());
}

test "vm host native builtin records dispatch by id before name fallback" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;

    // This focused dispatch fixture intentionally has no intrinsic bootstrap,
    // but a callable RealmContext still owns an exact global. Its detached
    // native record declares a null final prototype explicitly instead of
    // using the post-bootstrap realm convenience API.
    const fake_species = try engine.core.function.nativeFunctionWithPrototypeAndCapacity(ctx, null, "notSpeciesGetter", 0, 2);
    defer fake_species.free(rt);
    const fake_species_object: *core.Object = @fieldParentPtr("header", fake_species.refHeader().?);
    fake_species_object.setNativeBuiltinIdAndRecord(
        rt,
        core.function.nativeBuiltinId(.host, @intFromEnum(core.function.HostGlobalMethod.species_getter)),
    );
    const native_ref = core.function.decodeNativeBuiltinId(fake_species_object.nativeFunctionId()).?;

    const receiver = try core.Object.create(rt, core.class.ids.object, null);
    defer receiver.value().free(rt);
    const dispatched = try engine.exec.call_runtime.callNativeBuiltinRecordForVm(
        ctx,
        null,
        global,
        fake_species,
        receiver.value(),
        fake_species_object,
        native_ref,
        &.{},
        null,
        null,
    );
    try std.testing.expect(dispatched != null);
    const result = dispatched.?;
    defer result.free(rt);
    try std.testing.expect(result.same(receiver.value()));
}

test "vm collection constructors use registered prototype methods" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    helpers.registerStandardGlobalsBare(rt);
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const name = try rt.internAtom("collection-prototype");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    const map_atom = try rt.internAtom("Map");
    defer rt.atoms.free(map_atom);
    var bytes: [8]u8 = undefined;
    bytes[0] = op.get_var;
    std.mem.writeInt(u16, bytes[1..3], 0, .little);
    bytes[3] = op.dup;
    bytes[4] = op.call_constructor;
    std.mem.writeInt(u16, bytes[5..7], 0, .little);
    bytes[7] = op.@"return";
    function.var_ref_names = try rt.memory.alloc(core.Atom, 1);
    function.var_ref_names[0] = rt.atoms.dup(map_atom);
    try helpers.setCodeAndStackSize(&function, &bytes);

    var vm_instance = engine.exec.Vm.init(ctx);
    defer vm_instance.deinit();
    const result = try helpers.runMutableVm(&vm_instance, &function);
    defer result.free(rt);

    const object: *core.Object = @fieldParentPtr("header", result.refHeader().?);
    const set_key = try rt.internAtom("set");
    defer rt.atoms.free(set_key);
    try std.testing.expect(object.getPrototype() != null);
    try std.testing.expect(!object.hasOwnProperty(set_key));
    try std.testing.expect(object.hasProperty(set_key));
    try std.testing.expect(object.getPrototype().?.hasOwnProperty(set_key));
}

test "finite number formatting keeps simple decimal fast path semantics" {
    var buffer: [64]u8 = undefined;

    try std.testing.expectEqualStrings("12.5", try engine.exec.value_ops.formatFiniteNumber(&buffer, 12.5));
    try std.testing.expectEqualStrings("-12.5", try engine.exec.value_ops.formatFiniteNumber(&buffer, -12.5));
    try std.testing.expectEqualStrings("1", try engine.exec.value_ops.formatFiniteNumber(&buffer, 1.0));
    try std.testing.expectEqualStrings("0.1", try engine.exec.value_ops.formatFiniteNumber(&buffer, 0.1));
    try std.testing.expectEqualStrings("1e+21", try engine.exec.value_ops.formatFiniteNumber(&buffer, 1e21));
}

// ================== engine_smoke.zig ==================

test "qjs alignment C1 for-head lexical self-reference observes TDZ" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\let caught = false;
        \\try {
        \\  for (let i = i; false; ) {}
        \\} catch (error) {
        \\  caught = error instanceof ReferenceError;
        \\}
        \\assert.sameValue(caught, true);
        \\let emptyHeadCaught = false;
        \\try {
        \\  for (let j = j; ; ) { break; }
        \\} catch (error) {
        \\  emptyHeadCaught = error instanceof ReferenceError;
        \\}
        \\assert.sameValue(emptyHeadCaught, true);
        \\let closureCaught = false;
        \\try {
        \\  for (let k = (() => k)(); false; ) {}
        \\} catch (error) {
        \\  closureCaught = error instanceof ReferenceError;
        \\}
        \\assert.sameValue(closureCaught, true);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "qjs alignment C2 string for-of observes patched iterator" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const saved = String.prototype[Symbol.iterator];
        \\try {
        \\  let calls = 0;
        \\  String.prototype[Symbol.iterator] = function() {
        \\    calls++;
        \\    let done = false;
        \\    return {
        \\      next() {
        \\        if (done) return { done: true };
        \\        done = true;
        \\        return { done: false, value: "X" };
        \\      }
        \\    };
        \\  };
        \\  let primitive = "";
        \\  for (const value of "ab") primitive += value;
        \\  let wrapped = "";
        \\  for (const value of new String("cd")) wrapped += value;
        \\  assert.sameValue(primitive, "X");
        \\  assert.sameValue(wrapped, "X");
        \\  assert.sameValue(calls, 2);
        \\} finally {
        \\  String.prototype[Symbol.iterator] = saved;
        \\}
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "qjs alignment C3 in operator respects null prototype" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const bare = Object.create(null);
        \\assert.sameValue("toString" in bare, false);
        \\assert.sameValue("toString" in {}, true);
        \\bare.toString = 1;
        \\assert.sameValue("toString" in bare, true);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "qjs alignment X-02 Array length Set redirects when Receiver differs" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var arr=[1,2,3], recv={};
        \\print(Reflect.set(arr,"length",2,recv));
        \\print("arr.length="+arr.length+" recv.length="+recv.length+
        \\      " hasOwn="+Object.prototype.hasOwnProperty.call(recv,"length"));
        \\var arr2=[1,2,3], recv2={};
        \\print(Reflect.set(arr2,"0",9,recv2));
        \\print("arr2[0]="+arr2[0]+" recv2[0]="+recv2[0]+
        \\      " hasOwn0="+Object.prototype.hasOwnProperty.call(recv2,"0"));
        \\var arr3=[1,2,3];
        \\print(Reflect.set(arr3,"length",1));
        \\print("arr3.length="+arr3.length);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings(
        \\true
        \\arr.length=3 recv.length=2 hasOwn=true
        \\true
        \\arr2[0]=1 recv2[0]=9 hasOwn0=true
        \\true
        \\arr3.length=1
        \\
    , stream.buffered());
}

test "qjs alignment X-08 eval var writable false syncs VARREF is_const" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\(0,eval)("var ev = 1;");
        \\Object.defineProperty(globalThis, "ev", {writable:false});
        \\print("desc.writable = " + Object.getOwnPropertyDescriptor(globalThis,"ev").writable);
        \\try { ev = 7; } catch(e){ print("assign threw " + e.name); }
        \\print("ev = " + ev);
        \\globalThis.gp = 5; Object.defineProperty(globalThis, "gp", {writable:false});
        \\print("gp desc.writable = " + Object.getOwnPropertyDescriptor(globalThis,"gp").writable);
        \\gp = 9; print("gp = " + gp);
        \\(0,eval)("var ev2 = 1;"); Object.defineProperty(globalThis, "ev2", {enumerable:false});
        \\print("ev2 desc.enumerable = " + Object.getOwnPropertyDescriptor(globalThis,"ev2").enumerable);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings(
        \\desc.writable = false
        \\ev = 1
        \\gp desc.writable = false
        \\gp = 5
        \\ev2 desc.enumerable = false
        \\
    , stream.buffered());
}

test "qjs alignment X-09 VARREF to GETSET detaches the stale cell" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\(0,eval)("var ev = 1;");
        \\ev = 7;
        \\Object.defineProperty(globalThis, "ev", {get:function(){return 42;}, configurable:true});
        \\print("bare ev = " + ev);
        \\print("globalThis.ev = " + globalThis.ev);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings(
        \\bare ev = 42
        \\globalThis.ev = 42
        \\
    , stream.buffered());
}

test "qjs alignment X-07 integer-key Set breaks on first proto hit" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\"use strict";
        \\function t(mk){
        \\  var B = {}; mk(B);
        \\  var A = Object.create(B); Object.defineProperty(A, "0", {value:2, writable:true, configurable:true});
        \\  var o = Object.create(A);
        \\  try { o[0] = 9; } catch(e) { return "THREW " + e.name; }
        \\  return "OK " + JSON.stringify(Object.getOwnPropertyDescriptor(o, "0"));
        \\}
        \\print("far readonly data : " + t(function(B){ Object.defineProperty(B,"0",{value:1,writable:false,configurable:true}); }));
        \\print("far no-setter acc : " + t(function(B){ Object.defineProperty(B,"0",{get:function(){return 1;},configurable:true}); }));
        \\function tn(mk){
        \\  var B = {}; mk(B);
        \\  var A = Object.create(B); Object.defineProperty(A, "zk", {value:2, writable:true, configurable:true});
        \\  var o = Object.create(A);
        \\  try { o.zk = 9; } catch(e) { return "THREW " + e.name; }
        \\  return "OK " + JSON.stringify(Object.getOwnPropertyDescriptor(o, "zk"));
        \\}
        \\print("named ctrl readonly: " + tn(function(B){ Object.defineProperty(B,"zk",{value:1,writable:false,configurable:true}); }));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings(
        \\far readonly data : OK {"value":9,"writable":true,"enumerable":true,"configurable":true}
        \\far no-setter acc : OK {"value":9,"writable":true,"enumerable":true,"configurable":true}
        \\named ctrl readonly: OK {"value":9,"writable":true,"enumerable":true,"configurable":true}
        \\
    , stream.buffered());
}

test "qjs alignment X-10 Get miss does not fall back to globalThis constructor prototype" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function f(){}
        \\Object.setPrototypeOf(f, null);
        \\print("f.call:", typeof f.call, "| f.bind:", typeof f.bind, "| f.toString:", typeof f.toString);
        \\print("'bind' in f:", ('bind' in f));
        \\print("desc:", String(Object.getOwnPropertyDescriptor(f,'call')));
        \\print("f.call===Function.prototype.call:", f.call === Function.prototype.call);
        \\var a=[1,2,3];
        \\Object.setPrototypeOf(a, null);
        \\print("a.join:", typeof a.join, "| hasJoin:", ('join' in a));
        \\var dv = new DataView(new ArrayBuffer(8));
        \\Object.setPrototypeOf(dv, null);
        \\print("dv.byteLength:", dv.byteLength);
        \\print("s0:", new String("hi")[0]);
        \\function g(){}
        \\globalThis.Function = { prototype: { zzz: "F-hijack" } };
        \\globalThis.Object   = { prototype: { qqq: "O-hijack" } };
        \\print("g.zzz:", g.zzz, "| g.qqq:", g.qqq);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings(
        \\f.call: undefined | f.bind: undefined | f.toString: undefined
        \\'bind' in f: false
        \\desc: undefined
        \\f.call===Function.prototype.call: false
        \\a.join: undefined | hasJoin: false
        \\dv.byteLength: undefined
        \\s0: h
        \\g.zzz: undefined | g.qqq: undefined
        \\
    , stream.buffered());
}

test "qjs alignment X-10 tagged template objects keep Array.prototype" {
    try helpers.expectPrints(
        \\function tag(strings) {
        \\  print(typeof strings.map);
        \\  print(Object.getPrototypeOf(strings) === Array.prototype);
        \\}
        \\tag`[${1}]`;
    , "function\ntrue\n");
}

test "qjs alignment C4 Array instanceof follows prototype chain" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\Object.defineProperty(Array, Symbol.hasInstance, {
        \\  value: undefined,
        \\  configurable: true
        \\});
        \\try {
        \\  const detached = [];
        \\  Object.setPrototypeOf(detached, null);
        \\  assert.sameValue(detached instanceof Array, false);
        \\  assert.sameValue([] instanceof Array, true);
        \\} finally {
        \\  delete Array[Symbol.hasInstance];
        \\}
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "instanceof resident dispatch preserves GetMethod and result coercion semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const candidate = { marker: 7 };
        \\function Truthy() {}
        \\Object.defineProperty(Truthy, Symbol.hasInstance, {
        \\  value: function(value) { return value.marker; },
        \\  configurable: true
        \\});
        \\assert.sameValue(candidate instanceof Truthy, true);
        \\function Falsy() {}
        \\Object.defineProperty(Falsy, Symbol.hasInstance, {
        \\  value: function() { return 0; },
        \\  configurable: true
        \\});
        \\assert.sameValue(candidate instanceof Falsy, false);
        \\function UndefinedResult() {}
        \\Object.defineProperty(UndefinedResult, Symbol.hasInstance, {
        \\  value: function() { return undefined; },
        \\  configurable: true
        \\});
        \\assert.sameValue(candidate instanceof UndefinedResult, false);
        \\function ObjectResult() {}
        \\Object.defineProperty(ObjectResult, Symbol.hasInstance, {
        \\  value: function() { return {}; },
        \\  configurable: true
        \\});
        \\assert.sameValue(candidate instanceof ObjectResult, true);
        \\
        \\let seenThis;
        \\let seenValue;
        \\function Observed() {}
        \\Object.defineProperty(Observed, Symbol.hasInstance, {
        \\  value: function(value) {
        \\    seenThis = this;
        \\    seenValue = value;
        \\    return "yes";
        \\  },
        \\  configurable: true
        \\});
        \\assert.sameValue(candidate instanceof Observed, true);
        \\assert.sameValue(seenThis, Observed);
        \\assert.sameValue(seenValue, candidate);
        \\
        \\function StrictObserved() {}
        \\Object.defineProperty(StrictObserved, Symbol.hasInstance, {
        \\  value: function(value) {
        \\    "use strict";
        \\    return this === StrictObserved && value === candidate;
        \\  },
        \\  configurable: true
        \\});
        \\assert.sameValue(candidate instanceof StrictObserved, true);
        \\
        \\function makeCapturedHasInstance(expected) {
        \\  return value => value === expected;
        \\}
        \\function ArrowBacked() {}
        \\Object.defineProperty(ArrowBacked, Symbol.hasInstance, {
        \\  value: makeCapturedHasInstance(candidate),
        \\  configurable: true
        \\});
        \\assert.sameValue(candidate instanceof ArrowBacked, true);
        \\
        \\let getterCalls = 0;
        \\function GetterBacked() {}
        \\Object.defineProperty(GetterBacked, Symbol.hasInstance, {
        \\  get: function() {
        \\    getterCalls++;
        \\    return function(value) { return value.marker === 7; };
        \\  },
        \\  configurable: true
        \\});
        \\assert.sameValue(candidate instanceof GetterBacked, true);
        \\assert.sameValue(getterCalls, 1);
        \\
        \\function Throwing() {}
        \\Object.defineProperty(Throwing, Symbol.hasInstance, {
        \\  value: function() { throw new RangeError("instanceof sentinel"); },
        \\  configurable: true
        \\});
        \\let caught = false;
        \\try {
        \\  candidate instanceof Throwing;
        \\} catch (error) {
        \\  caught = error instanceof RangeError && error.message === "instanceof sentinel";
        \\}
        \\assert.sameValue(caught, true);
        \\
        \\let primitiveGetterCalls = 0;
        \\Object.defineProperty(Number.prototype, Symbol.hasInstance, {
        \\  get: function() {
        \\    primitiveGetterCalls++;
        \\    return function() { return true; };
        \\  },
        \\  configurable: true
        \\});
        \\try {
        \\  let primitiveCaught = false;
        \\  try {
        \\    candidate instanceof 1;
        \\  } catch (error) {
        \\    primitiveCaught = error instanceof TypeError;
        \\  }
        \\  assert.sameValue(primitiveCaught, true);
        \\  assert.sameValue(primitiveGetterCalls, 0);
        \\} finally {
        \\  delete Number.prototype[Symbol.hasInstance];
        \\}
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "default Function hasInstance uses Ordinary; other native records still Call" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function C() {}
        \\const instance = new C();
        \\assert.sameValue(instance instanceof C, true);
        \\assert.sameValue(1 instanceof C, false);
        \\assert.sameValue(({}) instanceof C, false);
        \\const Bound = C.bind(null);
        \\assert.sameValue(instance instanceof Bound, true);
        \\
        \\const original = Function.prototype[Symbol.hasInstance];
        \\Object.defineProperty(C, Symbol.hasInstance, {
        \\  value: Function.prototype.call,
        \\  configurable: true
        \\});
        \\assert.sameValue(instance instanceof C, false);
        \\delete C[Symbol.hasInstance];
        \\assert.sameValue(instance instanceof C, true);
        \\
        \\let calls = 0;
        \\Object.defineProperty(C, Symbol.hasInstance, {
        \\  value: function(value) {
        \\    calls++;
        \\    return original.call(this, value);
        \\  },
        \\  configurable: true
        \\});
        \\assert.sameValue(instance instanceof C, true);
        \\assert.sameValue(calls, 1);
        \\delete C[Symbol.hasInstance];
        \\assert.sameValue(instance instanceof C, true);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "local reference-tail lowering preserves binding semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function compoundAssignment() {
        \\  var x = 1;
        \\  function rhs() { x = 10; return 2; }
        \\  x += rhs();
        \\  return x;
        \\}
        \\assert.sameValue(compoundAssignment(), 3);
        \\function declarationAssignment() {
        \\  var x = 1;
        \\  function rhs() { x = 10; return 2; }
        \\  var x = rhs();
        \\  return x;
        \\}
        \\assert.sameValue(declarationAssignment(), 2);
        \\function capturedLocal() {
        \\  var x = 0;
        \\  const read = () => x;
        \\  var x = 3;
        \\  return read();
        \\}
        \\assert.sameValue(capturedLocal(), 3);
        \\function dynamicWith() {
        \\  var x = 1;
        \\  const scope = { x: 2 };
        \\  with (scope) { x = 3; }
        \\  return x + ":" + scope.x;
        \\}
        \\assert.sameValue(dynamicWith(), "1:3");
        \\function directEval() {
        \\  var x = 1;
        \\  var x = eval("x = 5; 2");
        \\  return x;
        \\}
        \\assert.sameValue(directEval(), 2);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "qjs alignment const local writes throw from resolved bytecode" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function beforeDeclaration() { x = 1; const x = 2; }
        \\let beforeCaught = false;
        \\let beforeMessage = "";
        \\try { beforeDeclaration(); } catch (error) {
        \\  beforeCaught = error instanceof TypeError;
        \\  beforeMessage = error.message;
        \\}
        \\assert.sameValue(beforeCaught, true);
        \\assert.sameValue(beforeMessage, "'x' is read-only");
        \\let rhsCalls = 0;
        \\let compoundCaught = false;
        \\let compoundMessage = "";
        \\function compoundConst() {
        \\  const fixed = 1;
        \\  try { fixed += (rhsCalls = 1); } catch (error) {
        \\    compoundCaught = error instanceof TypeError;
        \\    compoundMessage = error.message;
        \\  }
        \\}
        \\compoundConst();
        \\assert.sameValue(compoundCaught, true);
        \\assert.sameValue(compoundMessage, "'fixed' is read-only");
        \\assert.sameValue(rhsCalls, 1);
        \\function sloppyName() {
        \\  return (function named() { named = 0; return typeof named; })();
        \\}
        \\assert.sameValue(sloppyName(), "function");
        \\let strictNameCaught = false;
        \\try {
        \\  (function named() { "use strict"; named = 0; })();
        \\} catch (error) {
        \\  strictNameCaught = error instanceof TypeError;
        \\}
        \\assert.sameValue(strictNameCaught, true);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "qjs alignment named function self-binding ignores every sloppy write form" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\let direct = (function named() {
        \\  let original = named;
        \\  named += 1;
        \\  named++;
        \\  ++named;
        \\  [named] = [0];
        \\  ({ value: named } = { value: 0 });
        \\  return named === original;
        \\})();
        \\assert.sameValue(direct, true);
        \\let nested = (function named() {
        \\  let original = named;
        \\  return function inner() {
        \\    named = 0;
        \\    named += 1;
        \\    named++;
        \\    ++named;
        \\    [named] = [0];
        \\    ({ value: named } = { value: 0 });
        \\    return named === original;
        \\  };
        \\})()();
        \\assert.sameValue(nested, true);
        \\let strictOuterCaught = false;
        \\try {
        \\  (function named() { "use strict"; return function inner() { named = 0; }; })()();
        \\} catch (error) {
        \\  strictOuterCaught = error instanceof TypeError;
        \\}
        \\assert.sameValue(strictOuterCaught, true);
        \\let strictInnerCaught = false;
        \\try {
        \\  (function named() { return function inner() { "use strict"; named = 0; }; })()();
        \\} catch (error) {
        \\  strictInnerCaught = error instanceof TypeError;
        \\}
        \\assert.sameValue(strictInnerCaught, false);
        \\let emptyWith = {};
        \\let emptyWithBinding = (function named() {
        \\  with (emptyWith) { named += 1; }
        \\  return typeof named;
        \\})();
        \\assert.sameValue(emptyWithBinding, "function");
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(emptyWith, "named"), false);
        \\let hitWith = { named: 1 };
        \\let hitWithBinding = (function named() {
        \\  with (hitWith) { named += 1; }
        \\  return typeof named;
        \\})();
        \\assert.sameValue(hitWithBinding, "function");
        \\assert.sameValue(hitWith.named, 2);
        \\let lateWith = {};
        \\(function named() {
        \\  with (lateWith) { named += (lateWith.named = 10, 1); }
        \\})();
        \\assert.sameValue(lateWith.named, 10);
        \\let deletedWith = { named: 1 };
        \\(function named() {
        \\  with (deletedWith) { named += (delete deletedWith.named, 2); }
        \\})();
        \\assert.sameValue(deletedWith.named, 3);
        \\let sloppyEvalBinding = (function named() {
        \\  eval("named = 0; named += 1; named++; ++named;");
        \\  return typeof named;
        \\})();
        \\assert.sameValue(sloppyEvalBinding, "function");
        \\let strictEvalInSloppyCaught = false;
        \\try {
        \\  (function named() { eval('"use strict"; named = 0;'); })();
        \\} catch (error) {
        \\  strictEvalInSloppyCaught = error instanceof TypeError;
        \\}
        \\assert.sameValue(strictEvalInSloppyCaught, false);
        \\let strictEvalCaught = false;
        \\try {
        \\  (function named() { "use strict"; eval("named = 0;"); })();
        \\} catch (error) {
        \\  strictEvalCaught = error instanceof TypeError;
        \\}
        \\assert.sameValue(strictEvalCaught, true);
        \\let defaultRead = function named(value = named) { return value; };
        \\assert.sameValue(defaultRead(), defaultRead);
        \\let defaultWrites = function named(
        \\  direct = (named = 0),
        \\  compound = (named += 1),
        \\  post = named++,
        \\  pre = ++named,
        \\  array = ([named] = [0]),
        \\  object = ({ value: named } = { value: 0 }),
        \\  deleted = delete named
        \\) { return named === defaultWrites && deleted === false; };
        \\assert.sameValue(defaultWrites(), true);
        \\let strictDefaultCaught = false;
        \\try {
        \\  let strictDefault = (function() {
        \\    "use strict";
        \\    return function named(value = (named = 0)) {};
        \\  })();
        \\  strictDefault();
        \\} catch (error) {
        \\  strictDefaultCaught = error instanceof TypeError;
        \\}
        \\assert.sameValue(strictDefaultCaught, true);
        \\let sameParameterTdz = false;
        \\try { (function named(named = named) {})(); } catch (error) {
        \\  sameParameterTdz = error instanceof ReferenceError;
        \\}
        \\assert.sameValue(sameParameterTdz, true);
        \\let nestedDefault = function named() {
        \\  return ((value = named) => value)();
        \\};
        \\assert.sameValue(nestedDefault(), nestedDefault);
        \\let generatorDefault = function* named(value = named) { yield value; };
        \\assert.sameValue(generatorDefault().next().value, generatorDefault);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Engine eval executes test262 helpers through generic call paths" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval("assert.sameValue(1 + 1, 2, 'sum');");
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
    try std.testing.expectError(error.JSException, js.eval("assert.sameValue(1, 2);"));
    try std.testing.expectError(error.JSException, js.eval("throw new Test262Error('boom');"));
}

test "shared test engine reset rebuilds global shape hash buckets" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval("assert.sameValue(1 + 1, 2, 'sum');");
    result.free(js.runtime);
    try std.testing.expectError(error.JSException, js.eval("assert.sameValue(1, 2);"));
    try std.testing.expectError(error.JSException, js.eval("throw new Test262Error('boom');"));
    helpers.endSharedTest();

    const clean = helpers.sharedTestEngine();
    var output_buffer: [16]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const clean_result = try clean.evalWithOutput(
        \\"use strict";
        \\print(this === globalThis);
    , &stream);
    defer clean_result.free(clean.runtime);

    try std.testing.expect(clean_result.isUndefined());
    try std.testing.expectEqualStrings("true\n", stream.buffered());
}

test "Engine eval strips TypeScript source kind before execution" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try helpers.evalTypeScriptChecked(js,
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

    const result = try helpers.evalTypeScriptChecked(js,
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

    const result = try helpers.evalTypeScriptChecked(js,
        \\const obj = { as: 1, satisfies: 2 };
        \\assert.sameValue(obj.as + obj.satisfies, 3);
    , .{ .source_kind = .typescript });
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine eval supports TypeScript parameter properties" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var result = try helpers.evalTypeScriptChecked(js,
        \\class Box {
        \\    constructor(public value: number) {}
        \\}
        \\const b = new Box(42);
        \\b.value === 42 ? 42 : 0
    , .{ .source_kind = .typescript, .mode = .eval_indirect });
    defer result.free(js.runtime);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32());
}

test "Engine eval strips TypeScript automatically for ts filenames" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try helpers.evalTypeScriptChecked(js,
        \\const value: number = 42;
        \\assert.sameValue(value, 42);
    , .{ .filename = "sample.ts" });
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
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

test "pc2line stack locations match QuickJS return and throw matrix" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalWithOptions(
        \\function outer() {
        \\  return inner();
        \\}
        \\function inner() {
        \\  throw new Error("x");
        \\}
        \\var captured;
        \\try { outer(); } catch (error) { captured = error.stack; }
        \\assert.sameValue(captured.indexOf("at inner (pc2line.js:5:18)") >= 0, true);
        \\assert.sameValue(captured.indexOf("at outer (pc2line.js:2:3)") >= 0, true);
        \\assert.sameValue(captured.indexOf("at <eval> (pc2line.js:8:12)") >= 0, true);
    , .{ .filename = "pc2line.js" });
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "X-89 sloppy and method tails keep the caller like QuickJS; strict tail_call reuses" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalWithOptions(
        \\function outer() { return inner(); }
        \\function inner() { throw new Error("x"); }
        \\var captured;
        \\try { outer(); } catch (error) { captured = error.stack; }
        \\assert.sameValue(captured.indexOf("at inner") >= 0, true);
        \\assert.sameValue(captured.indexOf("at outer") >= 0, true);
        \\function strictOuter() { "use strict"; return strictInner(); }
        \\function strictInner() { throw new Error("s"); }
        \\try { strictOuter(); } catch (error) { captured = error.stack; }
        \\assert.sameValue(captured.indexOf("at strictInner") >= 0, true);
        \\assert.sameValue(captured.indexOf("at strictOuter") < 0, true);
        \\function methOuter() { "use strict"; return o.m(); }
        \\var o = { m: function m() { throw new Error("m"); } };
        \\try { methOuter(); } catch (error) { captured = error.stack; }
        \\assert.sameValue(captured.indexOf("at m") >= 0, true);
        \\assert.sameValue(captured.indexOf("at methOuter") >= 0, true);
    , .{ .filename = "x89-stack.js" });
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "strict plain tail_call recursion stays in constant stack" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\"use strict";
        \\function f(n) { if (n <= 0) return "foo"; return f(n - 1); }
        \\assert.sameValue(f(20000), "foo");
        \\function even(n) { return n <= 0 ? "foo" : odd(n - 1); }
        \\function odd(n) { return n <= 0 ? "bar" : even(n - 1); }
        \\assert.sameValue(even(20000), "foo");
        \\assert.sameValue(even(20001), "bar");
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "sloppy tail recursion still overflows like QuickJS" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function f(n) { if (n <= 0) return 0; return f(n - 1); }
        \\var threw = false;
        \\try { f(200000); } catch (e) {
        \\  threw = e instanceof InternalError && String(e.message).indexOf("stack overflow") >= 0;
        \\}
        \\assert.sameValue(threw, true);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "X-89 frame disasm: return call and method emit tail opcodes" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function tailPlain(x) { "use strict"; return g(x); }
        \\function sloppyPlain(x) { return g(x); }
        \\function tailMethod(o, x) { return o.m(x); }
        \\function strictCond(p) { "use strict"; return p ? f() : g(); }
        \\function sloppyCond(p) { return p ? f() : g(); }
    );
    defer result.free(js.runtime);

    var buf: [2048]u8 = undefined;

    const plain = try globalFunctionBytecode(js, "tailPlain");
    var plain_w = std.Io.Writer.fixed(&buf);
    try bytecode.dump.dumpFunctionBytecode(&plain_w, plain, &js.runtime.atoms, .{});
    const plain_dump = plain_w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, plain_dump, ": tail_call ") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain_dump, "tail_call_method") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain_dump, ": return\n") != null);

    // Strict-only PTC: a sloppy plain tail stays an ordinary call so its
    // observable stack semantics keep matching QuickJS.
    const sloppy = try globalFunctionBytecode(js, "sloppyPlain");
    var sloppy_w = std.Io.Writer.fixed(&buf);
    try bytecode.dump.dumpFunctionBytecode(&sloppy_w, sloppy, &js.runtime.atoms, .{});
    const sloppy_dump = sloppy_w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, sloppy_dump, "tail_call") == null);

    // Method folding is mode-independent: tail_call_method aliases
    // call_method at runtime, so the fold is unobservable.
    const method = try globalFunctionBytecode(js, "tailMethod");
    var method_w = std.Io.Writer.fixed(&buf);
    try bytecode.dump.dumpFunctionBytecode(&method_w, method, &js.runtime.atoms, .{});
    const method_dump = method_w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, method_dump, ": tail_call_method ") != null);
    try std.testing.expect(std.mem.indexOf(u8, method_dump, ": return\n") != null);

    // Conditional-expression arms are tail positions in a strict function
    // (both arms converge on the shared return), but never fold in sloppy.
    const strict_cond = try globalFunctionBytecode(js, "strictCond");
    var strict_cond_w = std.Io.Writer.fixed(&buf);
    try bytecode.dump.dumpFunctionBytecode(&strict_cond_w, strict_cond, &js.runtime.atoms, .{});
    const strict_cond_dump = strict_cond_w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, strict_cond_dump, ": tail_call ") != null);

    const sloppy_cond = try globalFunctionBytecode(js, "sloppyCond");
    var sloppy_cond_w = std.Io.Writer.fixed(&buf);
    try bytecode.dump.dumpFunctionBytecode(&sloppy_cond_w, sloppy_cond, &js.runtime.atoms, .{});
    const sloppy_cond_dump = sloppy_cond_w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, sloppy_cond_dump, "tail_call") == null);
}

test "pc2line malformed transition reports zero location instead of header fallback" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function malformedLocationTarget(value) {
        \\    return value + 1;
        \\}
    );
    defer result.free(js.runtime);

    const function = try globalFunctionBytecode(js, "malformedLocationTarget");
    const bytes = function.pc2lineBuf();
    try std.testing.expect(bytes.len > 2);
    const saved = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(saved);
    defer @memcpy(bytes, saved);

    // Keep a valid 1:1 header, then make the first compact transition's
    // zig-zag column ULEB run off the end of the authoritative buffer.
    bytes[0] = 0;
    bytes[1] = 0;
    @memset(bytes[2..], 0x80);
    const location = engine.exec.exception_ops.resolveBacktraceLocation(function, 0);
    try std.testing.expectEqual(@as(i32, 0), location.line_num);
    try std.testing.expectEqual(@as(i32, 0), location.col_num);
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

test "native builtin errors capture a native callsite" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var defaultStack;
        \\try {
        \\    [].map(null);
        \\} catch (error) {
        \\    defaultStack = error.stack;
        \\}
        \\assert.sameValue(defaultStack.indexOf("    at map (native)"), 0);
        \\var callStack;
        \\try {
        \\    Array.prototype.map.call([], null);
        \\} catch (error) {
        \\    callStack = error.stack;
        \\}
        \\assert.sameValue(callStack.indexOf("    at map (native)\n    at call (native)"), 0);
        \\function forwardedCallTarget() { return new Error("forwarded").stack; }
        \\var forwardedCallStack = forwardedCallTarget.call(undefined);
        \\var forwardedFirstNewline = forwardedCallStack.indexOf("\n");
        \\assert.sameValue(forwardedCallStack.indexOf("    at forwardedCallTarget"), 0);
        \\assert.sameValue(forwardedCallStack.slice(forwardedFirstNewline + 1).indexOf("    at call (native)"), 0);
        \\function forwardedCallCaller() {
        \\    var stack = forwardedCallTarget.call(undefined);
        \\    return stack + "";
        \\}
        \\var forwardedNestedStack = forwardedCallCaller();
        \\var forwardedNestedFirst = forwardedNestedStack.indexOf("\n");
        \\var forwardedNestedSecond = forwardedNestedStack.indexOf("\n", forwardedNestedFirst + 1);
        \\assert.sameValue(forwardedNestedStack.indexOf("    at forwardedCallTarget"), 0);
        \\assert.sameValue(forwardedNestedStack.slice(forwardedNestedFirst + 1).indexOf("    at call (native)"), 0);
        \\assert.sameValue(forwardedNestedStack.slice(forwardedNestedSecond + 1).indexOf("    at forwardedCallCaller"), 0);
        \\var applyStack;
        \\try {
        \\    Array.prototype.map.apply([], [null]);
        \\} catch (error) {
        \\    applyStack = error.stack;
        \\}
        \\assert.sameValue(applyStack.indexOf("    at map (native)\n    at apply (native)"), 0);
        \\var rawErrorStack;
        \\try {
        \\    String.fromCharCode(Symbol());
        \\} catch (error) {
        \\    rawErrorStack = error.stack;
        \\}
        \\assert.sameValue(rawErrorStack.indexOf("    at fromCharCode (native)"), 0);
        \\var nestedRawErrorStack;
        \\try {
        \\    [][Symbol.iterator]().next.call({});
        \\} catch (error) {
        \\    nestedRawErrorStack = error.stack;
        \\}
        \\assert.sameValue(nestedRawErrorStack.indexOf("    at next (native)\n    at call (native)"), 0);
        \\var arrayConstructStack;
        \\try { new Array(-1); } catch (error) { arrayConstructStack = error.stack; }
        \\assert.sameValue(arrayConstructStack.indexOf("    at Array (native)"), 0);
        \\var regexpConstructStack;
        \\try { new RegExp("["); } catch (error) { regexpConstructStack = error.stack; }
        \\assert.sameValue(regexpConstructStack.indexOf("    at RegExp (native)"), 0);
        \\var regexpCallStack;
        \\try { RegExp("["); } catch (error) { regexpCallStack = error.stack; }
        \\assert.sameValue(regexpCallStack.indexOf("    at RegExp (native)"), 0);
        \\assert.sameValue(regexpCallStack.indexOf("    at <anonymous> (native)"), -1);
        \\var stringConstructStack;
        \\try { new String(Symbol()); } catch (error) { stringConstructStack = error.stack; }
        \\assert.sameValue(stringConstructStack.indexOf("    at String (native)"), 0);
        \\var dateConstructStack;
        \\try { new Date(Symbol()); } catch (error) { dateConstructStack = error.stack; }
        \\assert.sameValue(dateConstructStack.indexOf("    at Date (native)"), 0);
        \\Error.prepareStackTrace = function(_, sites) {
        \\    return sites.map(function(site) {
        \\        return [site.getFunctionName(), site.isNative()];
        \\    });
        \\};
        \\function outerMapBacktrace() {
        \\    return [1].map(function callback() {
        \\        return new Error("cross-machine").stack;
        \\    })[0];
        \\}
        \\var crossMachineSites = outerMapBacktrace();
        \\assert.sameValue(crossMachineSites[0][0], "callback");
        \\assert.sameValue(crossMachineSites[0][1], false);
        \\assert.sameValue(crossMachineSites[1][0], "map");
        \\assert.sameValue(crossMachineSites[1][1], true);
        \\assert.sameValue(crossMachineSites[2][0], "outerMapBacktrace");
        \\assert.sameValue(crossMachineSites[2][1], false);
        \\function nativeFenceHelper() {
        \\    return new Error("same-machine").stack;
        \\}
        \\function nativeFenceCallback() {
        \\    return nativeFenceHelper();
        \\}
        \\function nativeFenceOuter() {
        \\    return nativeFenceCallback.apply(null, []);
        \\}
        \\var sameMachineSites = nativeFenceOuter();
        \\assert.sameValue(sameMachineSites[0][0], "nativeFenceHelper");
        \\assert.sameValue(sameMachineSites[0][1], false);
        \\assert.sameValue(sameMachineSites[1][0], "nativeFenceCallback");
        \\assert.sameValue(sameMachineSites[1][1], false);
        \\assert.sameValue(sameMachineSites[2][0], "apply");
        \\assert.sameValue(sameMachineSites[2][1], true);
        \\assert.sameValue(sameMachineSites[3][0], "nativeFenceOuter");
        \\assert.sameValue(sameMachineSites[3][1], false);
        \\Error.prepareStackTrace = undefined;
        \\Error.prepareStackTrace = function(error, sites) {
        \\    assert.sameValue(sites[0].getFunctionName(), "map");
        \\    assert.sameValue(sites[0].getFileName(), null);
        \\    assert.sameValue(sites[0].getLineNumber(), null);
        \\    assert.sameValue(sites[0].getColumnNumber(), null);
        \\    assert.sameValue(sites[0].isNative(), true);
        \\    assert.sameValue(sites[1].getFunctionName(), "call");
        \\    assert.sameValue(sites[1].isNative(), true);
        \\    assert.sameValue(sites[2].isNative(), false);
        \\    return "native:map:call";
        \\};
        \\try {
        \\    Array.prototype.map.call([], null);
        \\} catch (error) {
        \\    assert.sameValue(error.stack, "native:map:call");
        \\}
        \\Error.prepareStackTrace = undefined;
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "external host errors capture the native host callsite" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var probe: u8 = 0;
    try js.defineGlobalExternalHostFunction(
        "hostBacktraceProbe",
        0,
        &probe,
        HostBacktraceErrorProbe.call,
        null,
    );

    var output_buffer: [4096]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOptions(
        \\function captureHostBacktrace() {
        \\    try {
        \\        hostBacktraceProbe();
        \\    } catch (error) {
        \\        return String(error.stack);
        \\    }
        \\}
        \\function captureInternalBacktrace() {
        \\    try {
        \\        [].map(null);
        \\    } catch (error) {
        \\        return String(error.stack);
        \\    }
        \\}
        \\const hostStack = captureHostBacktrace();
        \\const internalStack = captureInternalBacktrace();
        \\print(hostStack.indexOf(
        \\    "    at hostBacktraceProbe (native)\n    at captureHostBacktrace "
        \\) === 0);
        \\print(internalStack.indexOf(
        \\    "    at map (native)\n    at captureInternalBacktrace "
        \\) === 0);
    , .{ .filename = "host-backtrace.js", .output = &stream });
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("true\ntrue\n", stream.buffered());
}

test "native record calls preflight the native stack and recover" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    js.runtime.setNativeStackSize(64 * 1024);
    try js.ensureTest262GlobalsInstalled();

    const function_value = try core.function.nativeFunction(js.context, "nativeRecordRecurse", 0);
    defer function_value.free(js.runtime);
    const function_object: *core.Object = @fieldParentPtr("header", function_value.refHeader().?);
    function_object.nativeRecordSlot().* = &NativeRecordStackProbe.record;

    const global = try js.context.globalObject();
    const name = try js.runtime.internAtom("nativeRecordRecurse");
    defer js.runtime.atoms.free(name);
    try global.defineOwnProperty(
        js.runtime,
        name,
        core.Descriptor.data(function_value, true, false, true),
    );

    NativeRecordStackProbe.callable = function_value;
    NativeRecordStackProbe.calls = 0;
    NativeRecordStackProbe.recurse = true;
    defer NativeRecordStackProbe.callable = core.JSValue.undefinedValue();

    const overflow = try js.eval(
        \\let nativeStackResult = "missing";
        \\try {
        \\    nativeRecordRecurse();
        \\} catch (error) {
        \\    nativeStackResult = error.name + ":" + error.message;
        \\}
        \\assert.sameValue(nativeStackResult, "InternalError:stack overflow");
    );
    overflow.free(js.runtime);

    NativeRecordStackProbe.recurse = false;
    const recovery = try js.eval("assert.sameValue(nativeRecordRecurse(), 7);");
    defer recovery.free(js.runtime);
    try std.testing.expect(recovery.isUndefined());
}

test "external C function preflight uses caller realm and callback errors use callee realm" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var caller_facade = zjs.JSContext.borrowCore(js.context);
    const caller_global = try caller_facade.globalObject();
    const callee_holder = try engine.exec.call.createRealmObject(js.context);
    defer callee_holder.free(js.runtime);
    const callee_record = try core.Object.expect(callee_holder);
    const callee = callee_record.realmContext() orelse return error.TestUnexpectedResult;
    const callee_global = try engine.exec.zjs_vm.contextGlobal(callee);

    var probe: CrossRealmNativeProbe = .{};
    const external_id = try js.runtime.registerExternalHostFunction(.{
        .ptr = &probe,
        .call = crossRealmNativeProbe,
    });
    const native_value = try core.function.nativeFunction(callee, "realmProbe", 0);
    defer native_value.free(js.runtime);
    const native_object = try core.Object.expect(native_value);
    native_object.hostFunctionKindSlot().* = core.host_function.ids.external_host;
    native_object.externalHostFunctionIdSlot().* = external_id;

    js.runtime.setNativeStackSize(1);
    defer js.runtime.setNativeStackSize(0);
    try std.testing.expectError(
        error.StackOverflow,
        engine.exec.call_runtime.callValueOrBytecodeRoot(
            js.context,
            null,
            caller_global,
            core.JSValue.undefinedValue(),
            native_value,
            &.{},
            null,
            null,
        ),
    );
    try std.testing.expect(probe.seen_realm == null);
    try std.testing.expect(js.context.hasException());

    const overflow_value = js.context.takeException();
    defer overflow_value.free(js.runtime);
    const overflow_error = try core.Object.expect(overflow_value);
    const caller_internal_error = object_ops.constructorPrototypeFromGlobal(
        js.runtime,
        caller_global,
        "InternalError",
    ) orelse return error.TestUnexpectedResult;
    const callee_internal_error = object_ops.constructorPrototypeFromGlobal(
        js.runtime,
        callee_global,
        "InternalError",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(caller_internal_error, overflow_error.getPrototype().?);
    try std.testing.expect(caller_internal_error != callee_internal_error);

    js.runtime.setNativeStackSize(0);
    try std.testing.expectError(
        error.JSException,
        engine.exec.call_runtime.callValueOrBytecodeRoot(
            js.context,
            null,
            caller_global,
            core.JSValue.undefinedValue(),
            native_value,
            &.{},
            null,
            null,
        ),
    );
    try std.testing.expectEqual(callee, probe.seen_realm.?);
    try std.testing.expectEqual(callee_global, probe.seen_global.?);
    // Pending exceptions are runtime-wide; the Error prototype below is the
    // realm discriminator.
    try std.testing.expect(js.context.hasException());

    const callback_error_value = callee.takeException();
    defer callback_error_value.free(js.runtime);
    const callback_error = try core.Object.expect(callback_error_value);
    const caller_type_error = object_ops.constructorPrototypeFromGlobal(
        js.runtime,
        caller_global,
        "TypeError",
    ) orelse return error.TestUnexpectedResult;
    const callee_type_error = object_ops.constructorPrototypeFromGlobal(
        js.runtime,
        callee_global,
        "TypeError",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(callee_type_error, callback_error.getPrototype().?);
    try std.testing.expect(caller_type_error != callee_type_error);
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

test "eval SyntaxError carries construction stack" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Pins the createNamedError stack capture: the SyntaxError materialized
    // for a failed `eval` parse used to carry no call sites, so a delayed
    // `.stack` read fell back to the reader's frames and lost the
    // construction frame ("at evalThrower" was absent before the fix).
    const result = try js.eval(
        \\function evalThrower() {
        \\    try { eval("]"); } catch (e) { return e; }
        \\    return null;
        \\}
        \\var evalErr = evalThrower();
        \\assert.sameValue(evalErr instanceof SyntaxError, true);
        \\var evalStack = evalErr.stack;
        \\assert.sameValue(typeof evalStack, "string");
        \\assert.sameValue(evalStack.length > 0, true);
        \\assert.sameValue(evalStack.indexOf("at evalThrower") >= 0, true);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "TypeError thrown via message helper carries stack exactly once" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Pins the throw*Message relocation: the TypeError thrown for calling a
    // non-callable keeps its construction stack ("at typeThrower"), and the
    // frame appears exactly once (no double attach from the former
    // shell-level capture plus the primitive-level capture).
    const result = try js.eval(
        \\function typeThrower() {
        \\    try { (0)(); } catch (e) { return e; }
        \\    return null;
        \\}
        \\var typeErr = typeThrower();
        \\assert.sameValue(typeErr instanceof TypeError, true);
        \\var typeStack = typeErr.stack;
        \\assert.sameValue(typeof typeStack, "string");
        \\assert.sameValue(typeStack.length > 0, true);
        \\assert.sameValue(typeStack.indexOf("at typeThrower") >= 0, true);
        \\assert.sameValue(typeStack.indexOf("at typeThrower"), typeStack.lastIndexOf("at typeThrower"));
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

test "Error stack setter rejects non-string stack values" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var err = new Error("x");
        \\assert.throws(TypeError, function() {
        \\    err.stack = 123;
        \\});
        \\assert.throws(TypeError, function() {
        \\    Object.getOwnPropertyDescriptor(Error.prototype, "stack").set.call(err);
        \\});
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(err, "stack"), false);
        \\assert.sameValue(typeof err.stack, "string");
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
        \\assert.throws(TypeError, function() {
        \\    err.stack = 123;
        \\});
        \\err.stack = "updated";
        \\var desc = Object.getOwnPropertyDescriptor(err, "stack");
        \\assert.sameValue(desc.value, "updated");
        \\assert.sameValue(desc.writable, true);
        \\assert.sameValue(err.stack, "updated");
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
        \\proxy.stack = "updated";
        \\var desc = Object.getOwnPropertyDescriptor(proxy, "stack");
        \\assert.sameValue(desc.value, "updated");
        \\assert.sameValue(desc.writable, true);
        \\assert.sameValue(proxy.stack, "updated");
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
        \\print(desc !== undefined);
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

test "runtime-strict eval overrides parse-time mapped arguments subtype" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [96]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileWithOutputModeRuntimeStrict(
        \\function forcedArguments(value) {
        \\  const before = arguments[0];
        \\  value = 7;
        \\  arguments[0] = 9;
        \\  let callee = "no-throw";
        \\  try { arguments.callee; } catch (error) { callee = error.name; }
        \\  print(before, value, arguments[0], callee);
        \\}
        \\forcedArguments(5);
    , &output, .script, "runtime-strict-arguments.js", true);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("5 7 9 TypeError\n", output.buffered());
}

test "Engine strict script top-level this remains the global object" {
    try helpers.expectPrints(
        \\"use strict";
        \\print(this === globalThis);
        \\function strictThis() { return this === undefined; }
        \\print(strictThis());
    , "true\ntrue\n");
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

fn expectEvalCycleReclaimed(js: *helpers.TestEngine, warmup_source: []const u8, cycle_source: []const u8) !void {
    const old_threshold = js.runtime.gcThreshold();
    js.runtime.setGCThreshold(std.math.maxInt(usize));
    defer js.runtime.setGCThreshold(old_threshold);

    const warmup = try js.eval(warmup_source);
    warmup.free(js.runtime);
    try js.runJobs();
    _ = js.runtime.runObjectCycleRemoval();
    const baseline_live_objects = js.runtime.gc.liveCount();

    const result = try js.eval(cycle_source);
    result.free(js.runtime);
    try js.runJobs();

    try std.testing.expect(js.runtime.gc.liveCount() > baseline_live_objects);
    try std.testing.expect(js.runtime.runObjectCycleRemoval() > 0);
    try std.testing.expectEqual(baseline_live_objects, js.runtime.gc.liveCount());
    try std.testing.expectEqual(@as(usize, 0), js.runtime.runObjectCycleRemoval());
}

test "Engine eval exit leaves closed var-ref cycles for explicit collection" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const old_threshold = js.runtime.gcThreshold();
    js.runtime.setGCThreshold(std.math.maxInt(usize));
    defer js.runtime.setGCThreshold(old_threshold);

    const warmup = try js.eval(";");
    warmup.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();
    const baseline_live_objects = js.runtime.gc.liveCount();
    const baseline_major_gc_count = js.runtime.gcStats().major_gc_count;

    const result = try js.eval(
        \\{
        \\    let self = function() { return self; };
        \\}
    );
    result.free(js.runtime);

    try std.testing.expectEqual(baseline_major_gc_count, js.runtime.gcStats().major_gc_count);
    try std.testing.expect(js.runtime.gc.liveCount() > baseline_live_objects);
    try std.testing.expect(js.runtime.runObjectCycleRemoval() > 0);
    try std.testing.expectEqual(baseline_live_objects, js.runtime.gc.liveCount());
    try std.testing.expectEqual(@as(usize, 0), js.runtime.runObjectCycleRemoval());
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
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    var ctx_alive = true;
    defer if (ctx_alive) ctx.destroy();

    const module_name = try rt.internAtom("gc-module-payload-cycle.mjs");
    defer rt.atoms.free(module_name);
    const back_key = try rt.internAtom("module");
    defer rt.atoms.free(back_key);
    var pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer pending.deinit(rt);
    const prepared = try ctx.modules.prepareFreshTarget(module_name, &pending);
    const record = prepared.record();
    const import_meta = try core.Object.create(rt, core.class.ids.object, null);
    const eval_exception = try core.Object.create(rt, core.class.ids.object, null);
    const record_value = core.JSValue.module(&record.header);
    try import_meta.defineOwnProperty(rt, back_key, core.Descriptor.data(record_value, true, true, true));
    try eval_exception.defineOwnProperty(rt, back_key, core.Descriptor.data(record_value, true, true, true));

    // Pins ModuleRecord import_meta/eval_exception edges, module.zig:572-573.
    record.import_meta = import_meta.value().dup();
    record.setEvalException(rt, eval_exception.value().dup());

    import_meta.value().free(rt);
    eval_exception.value().free(rt);
    ctx.destroy();
    ctx_alive = false;
    const expected = rt.gc.liveCount();
    try std.testing.expect(expected != 0);
    try std.testing.expectEqual(expected, rt.runObjectCycleRemoval());
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.shape));
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
        var js = try helpers.TestEngine.init(std.testing.allocator);
        defer js.deinit();
        try std.testing.expectError(error.TypeError, js.eval("const obj = {}; obj.missing(\"a\", \"a\");"));
    }
    {
        var js = try helpers.TestEngine.init(std.testing.allocator);
        defer js.deinit();
        try std.testing.expectError(error.TypeError, js.eval("RegExp.test(\"a\", \"a\");"));
    }
}

test "vm call handler accepts allocator-backed argument lists" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    helpers.registerStandardGlobalsBare(rt);
    const ctx = try core.JSContext.create(rt);
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
    var print_ref: [2]u8 = undefined;
    std.mem.writeInt(u16, &print_ref, 0, .little);
    try bytes.appendSlice(rt.memory.allocator, &print_ref);
    function.var_ref_names = try rt.memory.alloc(core.Atom, 1);
    function.var_ref_names[0] = rt.atoms.dup(print_key);
    var arg: i32 = 1;
    while (arg <= 40) : (arg += 1) {
        try bytes.append(rt.memory.allocator, op.push_i32);
        try bytes.appendSlice(rt.memory.allocator, std.mem.asBytes(&arg));
    }
    try bytes.append(rt.memory.allocator, op.call);
    const argc: u16 = 40;
    try bytes.appendSlice(rt.memory.allocator, std.mem.asBytes(&argc));
    try bytes.append(rt.memory.allocator, op.@"return");
    try helpers.setCodeAndStackSize(&function, bytes.items);

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    var vm_instance = engine.exec.Vm.initWithOutput(ctx, &stream);
    defer vm_instance.deinit();
    const result = try helpers.runMutableVm(&vm_instance, &function);
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

    try std.testing.expectError(error.SyntaxError, js.eval("1 2"));
    if (js.context.hasException()) js.context.clearException();

    const result = try js.eval("1; 2");
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());

    helpers.job_counter = 0;
    try js.runtime.job_queue.enqueueFunc(js.context, countJob, &.{});
    try js.runtime.job_queue.enqueueFunc(js.context, countJob, &.{});
    try js.runJobs();
    try std.testing.expectEqual(@as(usize, 2), helpers.job_counter);

    helpers.job_counter = 0;
    var i: usize = 0;
    while (i < 16) : (i += 1) try js.runtime.job_queue.enqueueFunc(js.context, countJob, &.{});
    try js.runJobs();
    try std.testing.expectEqual(@as(usize, 16), helpers.job_counter);

    helpers.job_counter = 0;
    try js.runtime.job_queue.enqueueFunc(js.context, countJobArgs, &.{ core.JSValue.int32(2), core.JSValue.int32(3) });
    try js.runJobs();
    try std.testing.expectEqual(@as(usize, 5), helpers.job_counter);

    helpers.job_counter = 0;
    try js.runtime.job_queue.enqueueFunc(js.context, countJobArgs, &.{
        core.JSValue.int32(1),
        core.JSValue.int32(2),
        core.JSValue.int32(3),
        core.JSValue.int32(4),
        core.JSValue.int32(5),
    });
    try js.runJobs();
    try std.testing.expectEqual(@as(usize, 15), helpers.job_counter);

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
    var buffer: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    var account = core.memory.MemoryAccount.init(fixed.allocator());
    var queue = engine.core.jobs.Queue.init(&account);
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
    defer promise.value().free(js.runtime);
    const reaction = try engine.exec.promise_ops.promiseReactionRecord(
        js.runtime,
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
    );
    defer reaction.free(js.runtime);
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
        .promise => |payload| try std.testing.expectEqual(@as(?i32, 99), payload.value.asInt32()),
        else => return error.TypeError,
    }

    var second = js.runtime.job_queue.takeFirst().?;
    defer second.deinit();
    switch (second.payload) {
        .promise_reaction => |payload| try std.testing.expectEqual(@as(?i32, 42), payload.value.asInt32()),
        else => return error.TypeError,
    }
}

test "waitAsync completions enter one typed cross-realm FIFO after facade release" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const global_a = try engine.exec.zjs_vm.contextGlobal(js.context);

    const realm_b = try core.JSContext.create(js.runtime);
    var realm_b_owner = true;
    defer if (realm_b_owner) realm_b.destroy();
    _ = try engine.exec.zjs_vm.contextGlobal(realm_b);

    const promise_a = try core.Object.create(js.runtime, core.class.ids.promise, null);
    defer promise_a.value().free(js.runtime);
    const promise_b = try core.Object.create(js.runtime, core.class.ids.promise, null);
    defer promise_b.value().free(js.runtime);

    const waiter_a = try js.runtime.memory.create(engine.exec.atomics_ops.AtomicsWaiter);
    waiter_a.* = .{
        .key = .{ .offset_or_ptr = @intFromPtr(promise_a) },
        .completion = .notified,
        .promise = promise_a.value().dup(),
        .realm = core.RealmRef.retain(js.context),
    };
    engine.exec.promise_ops.atomicsLinkAsyncWaiter(waiter_a);
    const waiter_b = try js.runtime.memory.create(engine.exec.atomics_ops.AtomicsWaiter);
    waiter_b.* = .{
        .key = .{ .offset_or_ptr = @intFromPtr(promise_b) },
        .completion = .notified,
        .promise = promise_b.value().dup(),
        .realm = core.RealmRef.retain(realm_b),
    };
    engine.exec.promise_ops.atomicsLinkAsyncWaiter(waiter_b);
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

    try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(js.context, null, global_a)) == .success);
    try std.testing.expect(promise_a.promiseResult() != null);
    try std.testing.expect(promise_b.promiseResult() == null);
    try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(js.context, null, global_a)) == .success);
    try std.testing.expect(promise_b.promiseResult() != null);

    // Each completion appended its ordinary Promise continuation behind the
    // other already-queued completion.
    try std.testing.expectEqual(@as(usize, 2), js.runtime.job_queue.jobs.len);
    try std.testing.expect(js.runtime.job_queue.jobs[0].realm.borrow() == js.context);
    try std.testing.expect(js.runtime.job_queue.jobs[1].realm.borrow() == realm_b);
    try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(js.context, null, global_a)) == .success);
    try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(js.context, null, global_a)) == .success);
}

test "waitAsync completion OOM stays at FIFO head for same-runtime retry" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const promise = try core.Object.create(js.runtime, core.class.ids.promise, null);
    defer promise.value().free(js.runtime);

    const waiter = try js.runtime.memory.create(engine.exec.atomics_ops.AtomicsWaiter);
    waiter.* = .{
        .key = .{ .offset_or_ptr = @intFromPtr(promise) },
        .completion = .notified,
        .promise = promise.value().dup(),
        .realm = core.RealmRef.retain(js.context),
    };
    engine.exec.promise_ops.atomicsLinkAsyncWaiter(waiter);
    var waiter_linked = true;
    defer if (waiter_linked) engine.exec.atomics_ops.cleanupAtomicsWaitersForContext(js.context);

    try engine.exec.atomics_ops.processExpiredAtomicsWaiters(js.context);
    waiter_linked = false;
    helpers.job_counter = 0;
    try js.runtime.job_queue.enqueueFunc(js.context, countJob, &.{});

    js.runtime.setMemoryLimit(js.runtime.memory.allocated_bytes);
    defer js.runtime.setMemoryLimit(null);
    try std.testing.expectError(
        error.OutOfMemory,
        engine.exec.promise_ops.drainOnePendingJob(js.context, null, global),
    );
    try std.testing.expect(promise.promiseResult() == null);
    try std.testing.expectEqual(@as(usize, 2), js.runtime.job_queue.jobs.len);
    try std.testing.expect(std.meta.activeTag(js.runtime.job_queue.jobs[0].payload) == .atomics_waiter);
    try std.testing.expect(std.meta.activeTag(js.runtime.job_queue.jobs[1].payload) == .generic);

    js.runtime.setMemoryLimit(null);
    try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(js.context, null, global)) == .success);
    try std.testing.expect(promise.promiseResult() != null);
    try std.testing.expectEqual(@as(usize, 2), js.runtime.job_queue.jobs.len);
    try std.testing.expect(std.meta.activeTag(js.runtime.job_queue.jobs[0].payload) == .generic);
    try std.testing.expect(std.meta.activeTag(js.runtime.job_queue.jobs[1].payload) == .promise);
    try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(js.context, null, global)) == .success);
    try std.testing.expectEqual(@as(usize, 1), helpers.job_counter);
    try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(js.context, null, global)) == .success);
}

test "dynamic import job OOM retains its FIFO position for retry" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);

    const ImportProbe = struct {
        var attempts: usize = 0;

        fn run(
            _: *core.JSContext,
            _: ?*std.Io.Writer,
            _: *const engine.core.jobs.DynamicImportPayload,
        ) core.context.DynamicImportError!core.JSValue {
            attempts += 1;
            if (attempts == 1) return error.OutOfMemory;
            return core.JSValue.undefinedValue();
        }
    };
    ImportProbe.attempts = 0;
    helpers.job_counter = 0;
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
        engine.exec.promise_ops.drainOnePendingJob(js.context, null, global),
    );
    try std.testing.expectEqual(@as(usize, 2), js.runtime.job_queue.jobs.len);
    try std.testing.expect(std.meta.activeTag(js.runtime.job_queue.jobs[0].payload) == .dynamic_import);
    try std.testing.expect(std.meta.activeTag(js.runtime.job_queue.jobs[1].payload) == .generic);

    try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(js.context, null, global)) == .success);
    try std.testing.expectEqual(@as(usize, 2), ImportProbe.attempts);
    try std.testing.expectEqual(@as(usize, 1), js.runtime.job_queue.jobs.len);
    try std.testing.expect(std.meta.activeTag(js.runtime.job_queue.jobs[0].payload) == .generic);
    try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(js.context, null, global)) == .success);
    try std.testing.expectEqual(@as(usize, 1), helpers.job_counter);
}

test "dynamic import job keeps its enqueue Realm after creator facade release" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const host_global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const entry_realm = try core.JSContext.create(js.runtime);
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
        ) core.context.DynamicImportError!core.JSValue {
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
    try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(js.context, null, host_global)) == .success);
    try std.testing.expect(ImportProbe.seen_realm == entry_realm);
    try std.testing.expect(ImportProbe.seen_global == entry_global);
}

test "dynamic import loader mutates only the enqueue Realm registry after public owner release" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const facade_global = try engine.exec.zjs_vm.contextGlobal(js.context);

    const entry_realm = try core.JSContext.create(js.runtime);
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
            defer ctx.runtime.atoms.free(name);
            var pending = core.module.PendingDefinition.init(&ctx.runtime.memory, &ctx.runtime.atoms);
            defer pending.deinit(ctx.runtime);
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
    defer specifier.free(js.runtime);
    const import_promise = try engine.exec.module_graph.enqueueDynamicImportJob(
        entry_realm,
        entry_global,
        null,
        "/w1e/enqueue/main.mjs",
        specifier,
    );
    // The queued capability owns everything it needs; do not let the test's
    // returned Promise stand in for the Job's enqueue-Realm owner.
    import_promise.free(js.runtime);

    entry_realm.destroy();
    entry_realm_owner = false;
    try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(js.context, null, facade_global)) == .success);
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
    defer promise.value().free(js.runtime);
    const resolving = try engine.exec.promise_ops.createPromiseResolvingPair(js.runtime, global, promise.value());
    defer resolving.resolve.free(js.runtime);
    defer resolving.reject.free(js.runtime);
    const resolve_object = try property_ops.expectObject(resolving.resolve);
    const state_value = resolve_object.functionPromiseResolvingState() orelse return error.TypeError;
    const state = try property_ops.expectObject(state_value);

    const thenable = try core.Object.create(js.runtime, core.class.ids.object, null);
    defer thenable.value().free(js.runtime);
    const promise_key = try js.runtime.internAtom("Promise");
    defer js.runtime.atoms.free(promise_key);
    const callable = try global.getProperty(promise_key);
    defer callable.free(js.runtime);
    const then_key = try js.runtime.internAtom("then");
    defer js.runtime.atoms.free(then_key);
    try thenable.defineOwnProperty(
        js.runtime,
        then_key,
        core.Descriptor.data(callable, true, true, true),
    );

    js.runtime.setMemoryLimit(js.runtime.memory.allocated_bytes);
    defer js.runtime.setMemoryLimit(null);
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

    js.runtime.setMemoryLimit(null);
    const result = try engine.exec.promise_ops.promiseResolvingFunctionCall(
        js.context,
        null,
        global,
        resolve_object,
        &.{thenable.value()},
        null,
        null,
    );
    if (result) |value| value.free(js.runtime);

    try std.testing.expect(state.promiseAlreadyResolved());
    try std.testing.expect(promise.promiseResult() == null);
    try std.testing.expectEqual(@as(usize, 1), js.runtime.job_queue.jobs.len);
    try std.testing.expect(std.meta.activeTag(js.runtime.job_queue.jobs[0].payload) == .promise_thenable);
}

test "published Promise resolution survives resolver collection through typed FIFO owner" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    defer js.runtime.setMemoryLimit(null);

    const promise = try core.Object.create(js.runtime, core.class.ids.promise, null);
    defer promise.value().free(js.runtime);
    const reaction = try engine.exec.promise_ops.promiseReactionRecord(
        js.runtime,
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
    );
    defer reaction.free(js.runtime);
    try engine.exec.promise_ops.appendPromiseReaction(js.runtime, promise, reaction);

    const resolving = try engine.exec.promise_ops.createPromiseResolvingPair(js.runtime, global, promise.value());
    var resolving_alive = true;
    defer if (resolving_alive) {
        resolving.resolve.free(js.runtime);
        resolving.reject.free(js.runtime);
    };
    const resolve_object = try property_ops.expectObject(resolving.resolve);

    // Reserve the durable continuation node, then force reaction-batch
    // preparation to fail after the resolving once-guard has committed.
    try js.runtime.job_queue.ensureCapacity(1);
    js.runtime.setMemoryLimit(js.runtime.memory.allocated_bytes);
    const result = try engine.exec.promise_ops.promiseResolvingFunctionCall(
        js.context,
        null,
        global,
        resolve_object,
        &.{core.JSValue.int32(41)},
        null,
        null,
    );
    if (result) |value| value.free(js.runtime);
    try std.testing.expect(promise.promiseResult() == null);
    try std.testing.expectEqual(@as(usize, 1), js.runtime.job_queue.jobs.len);
    try std.testing.expect(std.meta.activeTag(js.runtime.job_queue.jobs[0].payload) == .promise_settlement);

    // Neither resolver is needed after publication: the Runtime FIFO owns the
    // target, completion and Realm until the same-runtime retry succeeds.
    resolving.resolve.free(js.runtime);
    resolving.reject.free(js.runtime);
    resolving_alive = false;
    _ = js.runtime.runObjectCycleRemoval();

    js.runtime.setMemoryLimit(null);
    try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(js.context, null, global)) == .success);
    try std.testing.expectEqual(@as(?i32, 41), promise.promiseResult().?.asInt32());
    try std.testing.expect(!promise.promiseIsRejected());
    try std.testing.expectEqual(@as(usize, 1), js.runtime.job_queue.jobs.len);
    try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(js.context, null, global)) == .success);
}

test "Promise reaction retains callable Proxy classification after revocation" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const eval_result = try js.eval(
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
    defer eval_result.free(js.runtime);
    try js.runJobs();

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const result_key = try js.runtime.internAtom("__revokedPromiseReaction");
    defer js.runtime.atoms.free(result_key);
    const result = try global.getProperty(result_key);
    defer result.free(js.runtime);
    try helpers.expectStringValueBytes(result, "TypeError");
}

test "job queue keeps symbol arguments rooted until release" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    var queue = engine.core.jobs.Queue.init(&rt.memory);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-job-queue-symbol");
    const symbol_value = try rt.symbolValue(symbol_atom);
    try queue.enqueueFunc(ctx, countJob, &.{symbol_value});
    symbol_value.free(rt);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);

    queue.deinit();
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "job queue symbol roots preserve weak map values" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    var queue = engine.core.jobs.Queue.init(&rt.memory);

    const weak_map = try core.Object.create(rt, core.class.ids.weakmap, null);
    defer weak_map.value().free(rt);

    const value = try core.Object.create(rt, core.class.ids.object, null);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-job-queue-weak-key");
    const weak_key = try rt.symbolValue(symbol_atom);
    try engine.exec.collection_ops.setWeakMapEntry(rt, weak_map, weak_key, value.value());

    const queued_key = weak_key.dup();
    try queue.enqueueFunc(ctx, countJob, &.{queued_key});
    queued_key.free(rt);
    weak_key.free(rt);
    value.value().free(rt);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    try std.testing.expectEqual(@as(usize, 1), weak_map.weakCollectionEntries().len);
    try std.testing.expectEqual(&value.header, weak_map.weakCollectionEntries()[0].value.refHeader().?);

    queue.deinit();
    _ = rt.runObjectCycleRemoval();
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
    const ordinary = try js.eval(
        \\globalThis.__evalExitClosure = (function () {
        \\  let value = 40;
        \\  return eval("() => ++value");
        \\})();
    );
    ordinary.free(js.runtime);
    try std.testing.expectEqual(baseline_major_gc_count, js.runtime.gcStats().major_gc_count);

    const escaped = try js.eval(
        \\assert.sameValue(globalThis.__evalExitClosure(), 41);
        \\delete globalThis.__evalExitClosure;
    );
    escaped.free(js.runtime);
    try std.testing.expectEqual(baseline_major_gc_count, js.runtime.gcStats().major_gc_count);

    var context = zjs.JSContext.borrowCore(js.context);
    const host_eval_script = try context.evalScriptSource(
        "globalThis.__hostEvalExitProbe = 7; __hostEvalExitProbe",
        .{ .filename = "no-exit-cycle-host-eval-script.js" },
    );
    try std.testing.expectEqual(@as(?i32, 7), host_eval_script.asInt32());
    host_eval_script.free(js.runtime);
    try std.testing.expectEqual(baseline_major_gc_count, js.runtime.gcStats().major_gc_count);

    const indirect = try js.eval(
        \\(0, eval)("globalThis.__indirectEvalExitProbe = 9");
        \\assert.sameValue(globalThis.__indirectEvalExitProbe, 9);
        \\delete globalThis.__indirectEvalExitProbe;
        \\delete globalThis.__hostEvalExitProbe;
    );
    indirect.free(js.runtime);
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
    var stack = engine.exec.stack.Stack.init(&js.runtime.memory, js.context.stackLimit());
    defer stack.deinit(js.runtime);
    const canonical = try engine.exec.zjs_vm.runWithOutput(js.context, &stack, function, null);
    try std.testing.expectEqual(@as(?i32, 3), canonical.asInt32());
    canonical.free(js.runtime);
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

test "Engine eval executes simple variable assignment and print" {
    try helpers.expectPrints("let value = 5; value = value + 7; print(value);", "12\n");
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

test "flagless RegExp flags accessor reuses the runtime empty string" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const pattern = try core.string.String.createAscii(rt, "a");
    defer pattern.value().free(rt);
    const empty = try rt.emptyString();
    const regexp = try engine.exec.regexp_ops.constructWithPrototype(rt, pattern.value(), empty.value(), null);
    defer regexp.free(rt);

    const allocations = rt.memory.allocation_count;
    const flags = try engine.exec.regexp_ops.accessor(rt, regexp, "flags");
    defer flags.free(rt);
    try std.testing.expect(flags.asStringBody().? == empty);
    try std.testing.expectEqual(allocations, rt.memory.allocation_count);
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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
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
    , "41 42\n41 replaced false [object Object]\ninside inside inside\ninside inside\nfalse false true false\n");
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
    , "ordinary outer\nparameter parameter outer\nparameter-arrow parameter-arrow outer\nold new\narrow arrow\n");
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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Engine eval assigns contextual await bindings in sloppy scripts" {
    try helpers.expectPrints(
        \\var await = 0;
        \\await = 1;
        \\print(await);
    , "1\n");
}

test "Engine eval creates non-configurable enumerable global var bindings" {
    try helpers.expectPrints(
        \\print(delete __globalVar);
        \\var __globalVar = "defined";
        \\print(__globalVar);
        \\print(delete __globalVar, delete this["__globalVar"]);
        \\var seen = false;
        \\for (var key in this) { if (key === "__globalVar") seen = true; }
        \\print(seen);
        \\var first = 1, second = first + 1, third;
        \\print(first, second, third);
    , "false\ndefined\nfalse false\ntrue\n1 2 undefined\n");
}

test "Engine eval executes object property assignment through quick parser" {
    try helpers.expectPrints("const obj = { x: 1 }; obj.x = obj.x + 2; print(obj.x);", "3\n");
}

test "Engine eval executes parenthesized literal postfix through quick parser" {
    try helpers.expectPrints("const obj = { x: 1 }; print(({ y: obj.x + 2 }).y); print(([3, 4])[1]);", "3\n4\n");
}

// qjs CASE(OP_define_field) (quickjs.c:19269) takes the same
// JS_DefinePropertyValue route for refcounted values as for ints — no value
// form gate. The zjs fast leg mirrors that: append consumes the value into the
// slot, and the duplicate-key replace (`({a:o1,a:o2})`) dups into the slot and
// retires the caller's ref. This pins the refcount balance end-to-end through
// the resident op_define_field handler (a pre-fix borrow/consume mismatch
// leaked one ref per duplicate refcounted key).
test "Engine eval balances refcounts for refcounted duplicate-key object literals" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const rt = js.runtime;

    const setup = try js.eval(
        \\globalThis.__dupLitO1 = { m: 1 };
        \\globalThis.__dupLitO2 = { m: 2 };
    );
    setup.free(rt);

    // TestEngine only returns the script completion value for "<repl>".
    const o1 = try js.evalWithOptions("__dupLitO1", .{ .filename = "<repl>" });
    defer o1.free(rt);
    const o2 = try js.evalWithOptions("__dupLitO2", .{ .filename = "<repl>" });
    defer o2.free(rt);
    const o1_baseline = o1.refHeader().?.meta().rc;
    const o2_baseline = o2.refHeader().?.meta().rc;

    const result = try js.evalWithOptions(
        \\let __dupLitLast = null;
        \\for (let i = 0; i < 16; i++) {
        \\  __dupLitLast = { a: __dupLitO1, a: __dupLitO2, keep: __dupLitO1 };
        \\}
        \\const __dupLitOk = __dupLitLast.a === __dupLitO2 && __dupLitLast.keep === __dupLitO1;
        \\__dupLitLast = null;
        \\__dupLitOk ? 1 : 0
    , .{ .filename = "<repl>" });
    defer result.free(rt);
    try std.testing.expectEqual(@as(?i32, 1), result.asInt32());

    // Every literal died (last = null): both source objects must be back at
    // their pre-loop refcounts — no per-iteration leak from the duplicate-key
    // replace, no over-free from the append move.
    try std.testing.expectEqual(o1_baseline, o1.refHeader().?.meta().rc);
    try std.testing.expectEqual(o2_baseline, o2.refHeader().?.meta().rc);
}

test "Engine eval executes compound assignment and update statements through quick parser" {
    try helpers.expectPrints("let x = 10; x += 5; x -= 3; x *= 2; x /= 4; x %= 5; x++; x--; print(x);", "1\n");
}

test "Engine eval executes console.log with many arguments" {
    try helpers.expectPrints("console.log(1,2,3,4,5,6,7,8,9,10);", "1 2 3 4 5 6 7 8 9 10\n");
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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("dispose true\n", stream.buffered());

    const plain = try globalFunctionBytecode(js, "plainBlockForUsingOpcodeCheck");
    try std.testing.expectEqual(@as(usize, 0), try finalOpcodeCount(plain.byteCode(), op.using));

    var disassembly_buffer: [2048]u8 = undefined;
    var disassembly = std.Io.Writer.fixed(&disassembly_buffer);
    try bytecode.dump.dumpFunctionBytecode(&disassembly, plain, &js.runtime.atoms, .{});
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
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
    try helpers.expectPrints(
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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
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
    try helpers.expectPrints(
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
    try helpers.expectPrints(
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

test "Engine eval executes simple template interpolation" {
    try helpers.expectPrints("const x = 10; const y = 20; print(`${x} + ${y} = ${x + y}`);", "10 + 20 = 30\n");
}

test "Engine eval template interpolation calls object toString" {
    try helpers.expectPrints("const x = { toString(){ return 'custom'; } }; print(`${x}`);", "custom\n");
}

test "Engine eval executes simple arrays and map" {
    try helpers.expectPrints("const arr = [1, 2, 3]; print(arr); print(arr.length); print(arr[0]); print(arr.map(x => x * 2));", "1,2,3\n3\n1\n2,4,6\n");
}

test "Engine eval executes simple functions and arrows" {
    try helpers.expectPrints(
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
    , "5\n42\n720\n12\nobject\n");
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

// qjs:41171 resolves length through ordinary [[Get]] before qjs:41182-41197
// selects ARRAY/ARGUMENTS/MAPPED_ARGUMENTS or the observable element fallback.
test "apply resolves arguments length and preserves observable fallback" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
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

    const setup = try js.eval(
        \\function* mappedArgStorage(first) {
        \\  globalThis.__mappedArgArguments = arguments;
        \\  yield first;
        \\  first += 1;
        \\  yield first;
        \\}
        \\globalThis.__mappedArgGenerator = mappedArgStorage(41);
        \\__mappedArgGenerator.next();
    );
    defer setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const generator_key = try js.runtime.internAtom("__mappedArgGenerator");
    defer js.runtime.atoms.free(generator_key);
    const generator_value = try global.getProperty(generator_key);
    defer generator_value.free(js.runtime);
    const generator = try property_ops.expectObject(generator_value);
    const state = generator.generatorExecutionState();
    const arg_slot = &state.storage.frame.args[0];

    const arguments_key = try js.runtime.internAtom("__mappedArgArguments");
    defer js.runtime.atoms.free(arguments_key);
    const arguments_value = try global.getProperty(arguments_key);
    defer arguments_value.free(js.runtime);
    const arguments = try property_ops.expectObject(arguments_value);
    const argument_refs = arguments.argumentsVarRefs();
    try std.testing.expectEqual(@as(usize, 1), argument_refs.len);
    const cell = argument_refs[0] orelse return error.TypeError;

    try std.testing.expectEqual(@as(?i32, 41), arg_slot.asInt32());
    try std.testing.expect(core.VarRef.fromValue(arg_slot.*) == null);
    try std.testing.expect(cell.is_open);
    try std.testing.expect(cell.pvalue == arg_slot);
    var identity_matches: usize = 0;
    for (state.storage.frame.open_var_refs) |maybe_ref| {
        if (maybe_ref == cell) identity_matches += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), identity_matches);

    const resumed = try js.eval(
        \\const step = __mappedArgGenerator.next();
        \\assert.sameValue(step.value, 42);
        \\assert.sameValue(step.done, false);
    );
    defer resumed.free(js.runtime);
    try std.testing.expect(arg_slot == &generator.generatorExecutionState().storage.frame.args[0]);
    try std.testing.expect(cell.pvalue == arg_slot);
    try std.testing.expectEqual(@as(?i32, 42), arg_slot.asInt32());
}

test "generic arg opcodes preserve mapped aliases in a bare resident slot" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const setup = try js.eval(
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
    defer setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const generator_key = try js.runtime.internAtom("__genericArgGenerator");
    defer js.runtime.atoms.free(generator_key);
    const generator_value = try global.getProperty(generator_key);
    defer generator_value.free(js.runtime);
    const generator = try property_ops.expectObject(generator_value);
    const fifth_slot = &generator.generatorExecutionState().storage.frame.args[4];
    try std.testing.expectEqual(@as(?i32, 50), fifth_slot.asInt32());
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
    defer completion.free(js.runtime);
    try std.testing.expect(completion.isUndefined());
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);
    try js.runJobs();

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "before 55\nafter 55 55 55\nresolved 55\n",
        stream.buffered(),
    );
}

test "escaped generator arg aliases retain resident backing across cycle collection" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const setup = try js.eval(
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
    defer setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const arguments_key = try js.runtime.internAtom("__argCycleArguments");
    defer js.runtime.atoms.free(arguments_key);
    const arguments_value = try global.getProperty(arguments_key);
    defer arguments_value.free(js.runtime);
    const arguments = try property_ops.expectObject(arguments_value);
    const refs = arguments.argumentsVarRefs();
    try std.testing.expectEqual(@as(usize, 1), refs.len);
    const cell = refs[0] orelse return error.TypeError;
    try std.testing.expect(cell.is_open);
    try std.testing.expectEqual(@as(?i32, 41), cell.varRefValue().asInt32());

    const release = try js.eval("__argCycleHolder = null;");
    release.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();
    // QuickJS's attached JSVarRef owns the parked async-function state. The
    // escaped arguments object and closures therefore keep this generator
    // frame resident even after its direct global reference is gone.
    try std.testing.expect(cell.is_open);
    try std.testing.expect(cell.value.isObject());
    try std.testing.expectEqual(core.class.ids.generator, (try property_ops.expectObject(cell.value)).class_id);
    try std.testing.expectEqual(@as(?i32, 41), cell.varRefValue().asInt32());

    const escaped = try js.eval(
        \\assert.sameValue(__argCycleRead(), 41);
        \\__argCycleArguments[0] = 52;
        \\assert.sameValue(__argCycleRead(), 52);
        \\__argCycleWrite(63);
        \\assert.sameValue(__argCycleArguments[0], 63);
    );
    defer escaped.free(js.runtime);
    try std.testing.expect(escaped.isUndefined());
}

test "generator completion closes escaped arg aliases before releasing resident backing" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const setup = try js.eval(
        \\function* completingArgAlias(argument) {
        \\  globalThis.__completedArgArguments = arguments;
        \\  globalThis.__completedArgRead = function() { return argument; };
        \\  yield 0;
        \\  return argument;
        \\}
        \\globalThis.__completedArgGenerator = completingArgAlias(41);
        \\__completedArgGenerator.next();
    );
    defer setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const generator_key = try js.runtime.internAtom("__completedArgGenerator");
    defer js.runtime.atoms.free(generator_key);
    const generator_value = try global.getProperty(generator_key);
    defer generator_value.free(js.runtime);
    const generator = try property_ops.expectObject(generator_value);

    const arguments_key = try js.runtime.internAtom("__completedArgArguments");
    defer js.runtime.atoms.free(arguments_key);
    const arguments_value = try global.getProperty(arguments_key);
    defer arguments_value.free(js.runtime);
    const arguments = try property_ops.expectObject(arguments_value);
    const cell = arguments.argumentsVarRefs()[0] orelse return error.TypeError;
    try std.testing.expect(cell.is_open);

    const completion = try js.eval(
        \\const step = __completedArgGenerator.next();
        \\assert.sameValue(step.value, 41);
        \\assert.sameValue(step.done, true);
    );
    defer completion.free(js.runtime);
    try std.testing.expect(!cell.is_open);
    try std.testing.expect(generator.generatorExecutionState().storage.isEmpty());

    const escaped = try js.eval(
        \\__completedArgArguments[0] = 52;
        \\assert.sameValue(__completedArgRead(), 52);
    );
    defer escaped.free(js.runtime);
    try std.testing.expect(escaped.isUndefined());
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "inline calls release lazily materialized arguments state" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const setup = try js.eval(
        \\function readArguments(value) {
        \\    return arguments.length + value;
        \\}
        \\assert.sameValue(readArguments(1), 2);
    );
    setup.free(js.runtime);
    const exercise =
        \\(function exerciseArgumentsCalls() {
        \\    let total = 0;
        \\    for (let i = 0; i < 256; i++) total += readArguments(i);
        \\    assert.sameValue(total, 32896);
        \\})();
    ;
    const warmup = try js.eval(exercise);
    warmup.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();
    const baseline_objects = js.runtime.gc.liveCount();

    const result = try js.eval(exercise);
    result.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "inline empty leaf abrupt teardown releases pending operands" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const setup = try js.eval(
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
    setup.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();
    const baseline_objects = js.runtime.gc.liveCount();

    const result = try js.eval("exerciseEmptyLeafThrow()");
    result.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();

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
    const setup = try js.eval(
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
    setup.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();
    const baseline_objects = js.runtime.gc.liveCount();

    const result = try js.eval("exerciseExactArgsLeafThrow()");
    result.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();

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
    const setup = try js.eval(
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
    setup.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();
    const baseline_objects = js.runtime.gc.liveCount();

    const result = try js.eval("exerciseLeafLeftovers()");
    result.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "missing-argument calls read undefined across every entry arm" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    const rt = js.runtime;
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);

    // Outcome side of the `argc < arg_count` call shape (qjs's `for(i = argc;
    // i < arg_count; i++) arg_buf[i] = JS_UNDEFINED`, quickjs.c:17856-17857):
    // missing params read undefined, writes to a padded slot stay frame-local
    // (fresh undefined on the next call), the supplied prefix stays bound, and
    // the sloppy/strict/arrow/method `this` arms keep their policies. A
    // dedicated warm padded-leaf family used to serve these calls and was
    // deleted (3273 Octane hits total); the callees below are still published
    // exact-args leaves, so this is also the regression pin that their
    // MISSING-arg siblings keep generic-path semantics.
    const setup = try js.eval(
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
    setup.free(rt);

    // Publication pins: these callees really are published exact-args leaves,
    // so the outcomes above are the missing-arg shape of the leaf family and
    // not some unrelated generic callee. The sloppy plain callee and sloppy
    // arrow publish `.sloppy`; the non-`this`-reading strict callee publishes
    // `.raw_this`. The `this`-READING strict callee pins `.none`: `this`
    // compiles to `push_this; put_loc` (a local), so `var_count > 0` refuses
    // the whole leaf family by geometry.
    const one_name = try rt.internAtom("__padOne");
    defer rt.atoms.free(one_name);
    const strict_name = try rt.internAtom("__padStrict");
    defer rt.atoms.free(strict_name);
    const strict_leaf_name = try rt.internAtom("__padStrictLeaf");
    defer rt.atoms.free(strict_leaf_name);
    const arrow_name = try rt.internAtom("__padArrow");
    defer rt.atoms.free(arrow_name);
    const one_fn = try global.getProperty(one_name);
    defer one_fn.free(rt);
    const strict_fn = try global.getProperty(strict_name);
    defer strict_fn.free(rt);
    const strict_leaf_fn = try global.getProperty(strict_leaf_name);
    defer strict_leaf_fn.free(rt);
    const arrow_fn = try global.getProperty(arrow_name);
    defer arrow_fn.free(rt);
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

    _ = rt.runObjectCycleRemoval();
    const baseline_objects = rt.gc.liveCount();

    const result = try js.eval("exercisePaddedLeafOutcomes()");
    result.free(rt);
    _ = rt.runObjectCycleRemoval();

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
    const setup = try js.eval(
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
    setup.free(rt);

    // Publication pins: every excluded shape must read `.none`, which proves
    // these calls can never enter any leaf constructor.
    const names = [_][]const u8{ "__exArguments", "__exDefault", "__exRest", "__exCapture" };
    for (names) |name| {
        const atom_name = try rt.internAtom(name);
        defer rt.atoms.free(atom_name);
        const fn_value = try global.getProperty(atom_name);
        defer fn_value.free(rt);
        const resolved = inline_calls.resolveInlineFunction(global, fn_value) orelse
            return error.InvalidFunctionBytecode;
        try std.testing.expect(resolved.fb.exactArgsLeafKind() == .none);
    }

    _ = rt.runObjectCycleRemoval();
    const baseline_objects = rt.gc.liveCount();

    const result = try js.eval("exercisePaddedExclusions()");
    result.free(rt);
    _ = rt.runObjectCycleRemoval();

    try std.testing.expectEqual(baseline_objects, rt.gc.liveCount());
}

test "missing-argument abrupt teardown releases supplied args and pads exactly once" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Release-balance side: a frame that throws mid-body dies through general
    // teardown, whose args release walks the FULL `arg_count` window — the
    // supplied refcounted prefix exactly once (double free corrupts rc, missed
    // free strands the object) and the undefined pads as tag-test no-ops.
    // Covers supplied-prefix (argc=1 < 2), all-missing (argc=0 < 2), the
    // plain/strict/method entry arms, and the deep-recursion overflow unwind
    // (every live frame's window released during the exception walk; the
    // engine keeps running afterwards).
    const setup = try js.eval(
        \\function padThrow(a, b) { return a.x + null.missing + String(b); }
        \\function strictPadThrow(a, b) { "use strict"; return a.x + null.missing + String(b); }
        \\const padThrowRecv = { m: function (a, b) { return a.x + null.missing + String(b); } };
        \\function padOverflow(n, unused) { return padOverflow(n + 1) + (unused === undefined ? 1 : 0); }
        \\function exercisePaddedLeafThrow() {
        \\    for (let i = 0; i < 256; i++) {
        \\        try { padThrow({ x: 1 }); } catch (error) {}
        \\        try { padThrow(); } catch (error) {}
        \\        try { strictPadThrow({ x: 2 }); } catch (error) {}
        \\        try { padThrowRecv.m({ x: 3 }); } catch (error) {}
        \\    }
        \\    let overflow_caught = false;
        \\    try { padOverflow(0); } catch (error) { overflow_caught = true; }
        \\    if (!overflow_caught) throw new Error("overflow not raised");
        \\    if (padThrowRecv.m !== padThrowRecv.m) throw new Error("machine wedged");
        \\    return true;
        \\}
        \\exercisePaddedLeafThrow();
    );
    setup.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();
    const baseline_objects = js.runtime.gc.liveCount();

    const result = try js.eval("exercisePaddedLeafThrow()");
    result.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "missing-argument leftover-carrying returns route through general teardown" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Missing-argument twin of the exact-args leftover coverage. Parser-elided
    // trailing drops and switch discriminants held across `return` must route
    // to general teardown, which releases the leftovers AND the padded args
    // window exactly once.
    const setup = try js.eval(
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
    setup.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();
    const baseline_objects = js.runtime.gc.liveCount();

    const result = try js.eval("exercisePaddedLeafLeftovers()");
    result.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();

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
    const setup = try js.eval(
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
    setup.free(rt);

    // Publication pins: unbalanced bodies are refused BOTH zero-arg leaf
    // bits; the branchy-but-balanced body keeps its publication (the
    // BFS proof carries exact per-pc levels — it is not a conservative
    // straight-line scan that would refuse every branch).
    const drop_name = try rt.internAtom("__zeroTrailingDrop");
    defer rt.atoms.free(drop_name);
    const switch_name = try rt.internAtom("__zeroSwitchLeftover");
    defer rt.atoms.free(switch_name);
    const branchy_name = try rt.internAtom("__zeroBalancedBranchy");
    defer rt.atoms.free(branchy_name);
    const drop_fn = try global.getProperty(drop_name);
    defer drop_fn.free(rt);
    const switch_fn = try global.getProperty(switch_name);
    defer switch_fn.free(rt);
    const branchy_fn = try global.getProperty(branchy_name);
    defer branchy_fn.free(rt);
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

    _ = rt.runObjectCycleRemoval();
    const baseline_objects = rt.gc.liveCount();

    const result = try js.eval("exerciseZeroArgLeftovers()");
    result.free(rt);
    _ = rt.runObjectCycleRemoval();

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
    const setup = try js.eval(
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
    setup.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();
    const baseline_objects = js.runtime.gc.liveCount();

    const result = try js.eval("exerciseCaptureLeafThrow()");
    result.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();

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
    const setup = try js.eval(
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
    setup.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();
    const baseline_objects = js.runtime.gc.liveCount();

    const result = try js.eval("exerciseCaptureLeafLeftovers()");
    result.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();

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
    defer result.free(js.runtime);
    // bump()=3, read()=3, arrow read()=42, owner.value=42.
    try std.testing.expectEqual(@as(?i32, 3034242), result.asInt32());
}

test "inline empty leaf warm constructor preserves miss fallback and ownership" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    const rt = js.runtime;
    const ctx = js.context;
    const global = try engine.exec.zjs_vm.contextGlobal(ctx);

    const setup = try js.eval("globalThis.__warmEmptyLeaf = function () { return 1; };");
    setup.free(rt);
    const leaf_name = try rt.internAtom("__warmEmptyLeaf");
    defer rt.atoms.free(leaf_name);
    const callable = try global.getProperty(leaf_name);
    defer callable.free(rt);
    const resolved = inline_calls.resolveInlineFunction(global, callable) orelse
        return error.InvalidFunctionBytecode;
    try std.testing.expect(resolved.fb.simpleInlineEmptyLeaf());

    var l0_function = try helpers.makeFunction(rt, &.{op.return_undef});
    defer l0_function.deinit(rt);
    var l0_execution_adapter: bytecode.LegacyExecutionAdapter = undefined;
    const l0_execution_function = l0_execution_adapter.init(&l0_function);
    var l0_frame = engine.exec.frame.Frame.init(l0_execution_function);
    defer l0_frame.deinit(&rt.memory, rt);
    var l0_stack = engine.exec.stack.Stack.init(&rt.memory, rt.stackSize());
    defer l0_stack.deinit(rt);
    var catch_target: ?usize = null;
    const l0 = inline_calls.L0State{ .level = .{
        .frame = &l0_frame,
        .stack = &l0_stack,
        .catch_target = &catch_target,
    } };
    var machine = inline_calls.Machine.init(ctx, null, global, &l0);
    defer machine.deinit();
    const initial_call_depth = ctx.runtime.hot.call_depth;

    // A fresh Machine has neither Entry nor arena backing. The speculative
    // arm must miss without consuming the source or changing call depth.
    try l0_stack.pushOwned(callable.dup());
    var region_start = l0_stack.topPtr() - 1;
    l0_stack.setTopPtr(region_start);
    const l0_resume_pc = l0_frame.function.byteCode().ptr + l0_frame.pc;
    try std.testing.expect(machine.tryPushEmptyLeafCallFast(.sloppy_global, ctx.runtime, global, &l0_stack, resolved.fb, resolved.call_facts, region_start, l0_resume_pc) == null);
    try std.testing.expectEqual(initial_call_depth, ctx.runtime.hot.call_depth);
    try std.testing.expect(!region_start[0].isUndefined());

    const first = try machine.pushEmptyLeafCall(.sloppy_global, global, &l0_stack, resolved.fb, resolved.call_facts, region_start);
    try std.testing.expect(first.isEmptyLeaf());
    machine.popReturnedEmptyLeaf(ctx.runtime);
    try std.testing.expectEqual(initial_call_depth, ctx.runtime.hot.call_depth);
    const steady_bytes = rt.memory.allocated_bytes;

    // Entry and arena chunks are now warm. A second exact call must publish
    // the same leaf shape without touching the allocator.
    try l0_stack.pushOwned(callable.dup());
    region_start = l0_stack.topPtr() - 1;
    l0_stack.setTopPtr(region_start);
    const alloc_calls = rt.memory.alloc_calls;
    const create_calls = rt.memory.create_calls;
    const warm = machine.tryPushEmptyLeafCallFast(.sloppy_global, ctx.runtime, global, &l0_stack, resolved.fb, resolved.call_facts, region_start, l0_resume_pc) orelse
        return error.Unexpected;
    try std.testing.expect(warm.isEmptyLeaf());
    try std.testing.expectEqual(alloc_calls, rt.memory.alloc_calls);
    try std.testing.expectEqual(create_calls, rt.memory.create_calls);
    machine.popReturnedEmptyLeaf(ctx.runtime);
    try std.testing.expectEqual(steady_bytes, rt.memory.allocated_bytes);

    // An oversized operand window cannot use the active arena chunk. The fast
    // miss is pure and the authoritative constructor owns/frees heap backing.
    const oversized = try createOversizedLeafFixture(rt, resolved.fb);
    var oversized_alive = true;
    defer if (oversized_alive) oversized.destroyUnpublishedFixture(rt);
    const oversized_bytes = rt.memory.allocated_bytes;
    try l0_stack.pushOwned(callable.dup());
    region_start = l0_stack.topPtr() - 1;
    l0_stack.setTopPtr(region_start);
    try std.testing.expect(machine.tryPushEmptyLeafCallFast(.sloppy_global, ctx.runtime, global, &l0_stack, oversized, oversized.callFacts(), region_start, l0_resume_pc) == null);
    try std.testing.expectEqual(initial_call_depth, ctx.runtime.hot.call_depth);
    const heap_entry = try machine.pushEmptyLeafCall(.sloppy_global, global, &l0_stack, oversized, oversized.callFacts(), region_start);
    try std.testing.expect(!heap_entry.isEmptyLeaf());
    var continuation = machine.popReturnedFrame();
    continuation.deinit(rt);
    try std.testing.expectEqual(oversized_bytes, rt.memory.allocated_bytes);

    // The same miss under a hard memory cap must restore depth/watermark and
    // release the source slot, leaving the warmed Machine reusable.
    try l0_stack.pushOwned(callable.dup());
    region_start = l0_stack.topPtr() - 1;
    l0_stack.setTopPtr(region_start);
    rt.setMemoryLimit(rt.memory.allocated_bytes);
    const failed = machine.pushEmptyLeafCall(.sloppy_global, global, &l0_stack, oversized, oversized.callFacts(), region_start);
    rt.setMemoryLimit(null);
    try std.testing.expectError(error.OutOfMemory, failed);
    try std.testing.expectEqual(initial_call_depth, ctx.runtime.hot.call_depth);
    try std.testing.expect(region_start[0].isUndefined());
    try std.testing.expectEqual(oversized_bytes, rt.memory.allocated_bytes);
    oversized.destroyUnpublishedFixture(rt);
    oversized_alive = false;
    try std.testing.expectEqual(steady_bytes, rt.memory.allocated_bytes);
}

test "forwarded leaf warm constructor preserves miss fallback and ownership" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    const rt = js.runtime;
    const ctx = js.context;
    const global = try engine.exec.zjs_vm.contextGlobal(ctx);

    // Publication pins for the O3 forwarded-leaf shapes: the pivot body, a
    // throwing body (abrupt coverage really crosses the arm), and the
    // leftover-operand body (refused publication by the return-balance
    // proof, so it never reaches the forwarded arm).
    const setup = try js.eval(
        \\globalThis.__fwdLeaf = function () { return 1; };
        \\globalThis.__fwdLeafThrower = function () { return (void 0).x; };
        \\globalThis.__fwdLeafLeftover = function () { ({}); };
        \\globalThis.__fwdNativeCall = Function.prototype.call;
    );
    setup.free(rt);
    const leaf_name = try rt.internAtom("__fwdLeaf");
    defer rt.atoms.free(leaf_name);
    const thrower_name = try rt.internAtom("__fwdLeafThrower");
    defer rt.atoms.free(thrower_name);
    const leftover_name = try rt.internAtom("__fwdLeafLeftover");
    defer rt.atoms.free(leftover_name);
    const native_name = try rt.internAtom("__fwdNativeCall");
    defer rt.atoms.free(native_name);
    const callable = try global.getProperty(leaf_name);
    defer callable.free(rt);
    const thrower = try global.getProperty(thrower_name);
    defer thrower.free(rt);
    const leftover = try global.getProperty(leftover_name);
    defer leftover.free(rt);
    const native_call = try global.getProperty(native_name);
    defer native_call.free(rt);
    const resolved = inline_calls.resolveInlineFunction(global, callable) orelse
        return error.InvalidFunctionBytecode;
    try std.testing.expect(resolved.fb.simpleInlineEmptyLeaf());
    const resolved_thrower = inline_calls.resolveInlineFunction(global, thrower) orelse
        return error.InvalidFunctionBytecode;
    try std.testing.expect(resolved_thrower.fb.simpleInlineEmptyLeaf());
    const resolved_leftover = inline_calls.resolveInlineFunction(global, leftover) orelse
        return error.InvalidFunctionBytecode;
    // The leftover-operand body fails the static return-balance proof, so it
    // is refused zero-arg leaf publication entirely: forwarded calls of it
    // ride the authoritative forwarding path and the O3 arm's len==0 guard
    // becomes a defensive backstop rather than the routing mechanism.
    try std.testing.expect(!resolved_leftover.fb.simpleInlineEmptyLeaf());

    var l0_function = try helpers.makeFunction(rt, &.{op.return_undef});
    defer l0_function.deinit(rt);
    var l0_execution_adapter: bytecode.LegacyExecutionAdapter = undefined;
    const l0_execution_function = l0_execution_adapter.init(&l0_function);
    var l0_frame = engine.exec.frame.Frame.init(l0_execution_function);
    defer l0_frame.deinit(&rt.memory, rt);
    var l0_stack = engine.exec.stack.Stack.init(&rt.memory, rt.stackSize());
    defer l0_stack.deinit(rt);
    var catch_target: ?usize = null;
    const l0 = inline_calls.L0State{ .level = .{
        .frame = &l0_frame,
        .stack = &l0_stack,
        .catch_target = &catch_target,
    } };
    var machine = inline_calls.Machine.init(ctx, null, global, &l0);
    defer machine.deinit();
    const initial_call_depth = ctx.runtime.hot.call_depth;

    // A fresh Machine has neither Entry nor arena backing. The speculative
    // arm must miss without consuming EITHER owned source slot (target and
    // skipped native `call` function) or changing call depth — the adapter
    // then restores its operand top and takes the authoritative
    // pushForwardedCall path.
    try l0_stack.pushOwned(callable.dup());
    try l0_stack.pushOwned(native_call.dup());
    var region_start = l0_stack.topPtr() - 2;
    l0_stack.setTopPtr(region_start);
    try std.testing.expect(machine.tryPushForwardedEmptyLeafCallFast(.sloppy_global, global, &l0_stack, resolved.fb, resolved.call_facts, region_start) == null);
    try std.testing.expectEqual(initial_call_depth, ctx.runtime.hot.call_depth);
    try std.testing.expect(!region_start[0].isUndefined());
    try std.testing.expect(!region_start[1].isUndefined());
    region_start[1].free(rt);
    region_start[1] = core.JSValue.undefinedValue();

    // Prime Entry and arena chunks through the authoritative zero-arg leaf
    // constructor (the forwarded twin shares both pools).
    const primed = try machine.pushEmptyLeafCall(.sloppy_global, global, &l0_stack, resolved.fb, resolved.call_facts, region_start);
    try std.testing.expect(primed.isEmptyLeaf());
    machine.popReturnedEmptyLeaf(ctx.runtime);
    try std.testing.expectEqual(initial_call_depth, ctx.runtime.hot.call_depth);
    const steady_bytes = rt.memory.allocated_bytes;

    // Warm hit: allocation-free, publishes the forwarded-leaf teardown shape
    // (native ownership bit + forwarded bit, NEVER the empty-leaf bit whose
    // resume record would overlay the live native_caller), consumes both
    // source slots, and the paired pop releases the native frame and
    // restores depth and watermark.
    try l0_stack.pushOwned(callable.dup());
    try l0_stack.pushOwned(native_call.dup());
    region_start = l0_stack.topPtr() - 2;
    l0_stack.setTopPtr(region_start);
    const alloc_calls = rt.memory.alloc_calls;
    const create_calls = rt.memory.create_calls;
    const warm = machine.tryPushForwardedEmptyLeafCallFast(.sloppy_global, global, &l0_stack, resolved.fb, resolved.call_facts, region_start) orelse
        return error.Unexpected;
    try std.testing.expect(warm.isForwardedLeaf());
    try std.testing.expect(warm.teardown.has_native_caller);
    try std.testing.expect(!warm.isEmptyLeaf());
    try std.testing.expect(!warm.isExactArgsLeaf());
    try std.testing.expectEqual(alloc_calls, rt.memory.alloc_calls);
    try std.testing.expectEqual(create_calls, rt.memory.create_calls);
    try std.testing.expect(region_start[0].isUndefined());
    try std.testing.expect(region_start[1].isUndefined());
    machine.popReturnedForwardedLeaf(ctx.runtime);
    try std.testing.expectEqual(initial_call_depth, ctx.runtime.hot.call_depth);
    try std.testing.expectEqual(steady_bytes, rt.memory.allocated_bytes);

    // An oversized operand window cannot use the active arena chunk. The
    // fast miss is pure — both slots stay owned by the region for the
    // authoritative fallback.
    const oversized = try createOversizedLeafFixture(rt, resolved.fb);
    var oversized_alive = true;
    defer if (oversized_alive) oversized.destroyUnpublishedFixture(rt);
    const oversized_bytes = rt.memory.allocated_bytes;
    try l0_stack.pushOwned(callable.dup());
    try l0_stack.pushOwned(native_call.dup());
    region_start = l0_stack.topPtr() - 2;
    l0_stack.setTopPtr(region_start);
    try std.testing.expect(machine.tryPushForwardedEmptyLeafCallFast(.sloppy_global, global, &l0_stack, oversized, oversized.callFacts(), region_start) == null);
    try std.testing.expectEqual(initial_call_depth, ctx.runtime.hot.call_depth);
    try std.testing.expect(!region_start[0].isUndefined());
    try std.testing.expect(!region_start[1].isUndefined());
    region_start[0].free(rt);
    region_start[0] = core.JSValue.undefinedValue();
    region_start[1].free(rt);
    region_start[1] = core.JSValue.undefinedValue();
    try std.testing.expectEqual(oversized_bytes, rt.memory.allocated_bytes);
    oversized.destroyUnpublishedFixture(rt);
    oversized_alive = false;
    try std.testing.expectEqual(steady_bytes, rt.memory.allocated_bytes);
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
    defer result.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 256 * (1 + 1 + 1 + 1 + 10 + 100 + 1000)), result.asInt32());
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
    const setup = try js.eval(
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
    setup.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();
    const baseline_objects = js.runtime.gc.liveCount();

    const result = try js.eval("exerciseForwardedThrow()");
    result.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();

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
    const setup = try js.eval(
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
    setup.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();
    const baseline_objects = js.runtime.gc.liveCount();

    const result = try js.eval("exerciseForwardedLeftovers()");
    result.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "method call empty leaf binds receiver as this and balances refcounts" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const setup = try js.eval(
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
    setup.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();
    const baseline_objects = js.runtime.gc.liveCount();

    const result = try js.eval("exerciseMethodEmptyLeaf()");
    result.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "method call empty leaf abrupt teardown releases receiver" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const setup = try js.eval(
        \\function exerciseMethodEmptyLeafThrow() {
        \\    for (let i = 0; i < 256; i++) {
        \\        const recv = { boom() { return null.missing; } };
        \\        try { recv.boom(); } catch (error) {}
        \\    }
        \\}
        \\exerciseMethodEmptyLeafThrow();
    );
    setup.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();
    const baseline_objects = js.runtime.gc.liveCount();

    const result = try js.eval("exerciseMethodEmptyLeafThrow()");
    result.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "method empty leaf warm constructor moves receiver ownership" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    const rt = js.runtime;
    const ctx = js.context;
    const global = try engine.exec.zjs_vm.contextGlobal(ctx);

    const setup = try js.eval("globalThis.__warmMethodLeafRecv = { m() { return 1; } };");
    setup.free(rt);
    const holder_name = try rt.internAtom("__warmMethodLeafRecv");
    defer rt.atoms.free(holder_name);
    const receiver = try global.getProperty(holder_name);
    defer receiver.free(rt);
    const receiver_object = object_ops.objectFromValue(receiver) orelse
        return error.Unexpected;
    const method_name = try rt.internAtom("m");
    defer rt.atoms.free(method_name);
    const callable = try receiver_object.getProperty(method_name);
    defer callable.free(rt);
    const resolved = inline_calls.resolveInlineFunction(global, callable) orelse
        return error.InvalidFunctionBytecode;
    try std.testing.expect(resolved.fb.simpleInlineEmptyLeaf());

    var l0_function = try helpers.makeFunction(rt, &.{op.return_undef});
    defer l0_function.deinit(rt);
    var l0_execution_adapter: bytecode.LegacyExecutionAdapter = undefined;
    const l0_execution_function = l0_execution_adapter.init(&l0_function);
    var l0_frame = engine.exec.frame.Frame.init(l0_execution_function);
    defer l0_frame.deinit(&rt.memory, rt);
    var l0_stack = engine.exec.stack.Stack.init(&rt.memory, rt.stackSize());
    defer l0_stack.deinit(rt);
    var catch_target: ?usize = null;
    const l0 = inline_calls.L0State{ .level = .{
        .frame = &l0_frame,
        .stack = &l0_stack,
        .catch_target = &catch_target,
    } };
    var machine = inline_calls.Machine.init(ctx, null, global, &l0);
    defer machine.deinit();
    const initial_call_depth = ctx.runtime.hot.call_depth;
    const baseline_rc = receiver_object.header.meta().rc;

    // Fresh Machine: the speculative arm must miss without consuming either
    // slot of the [receiver, callable] region or changing call depth.
    try l0_stack.pushOwned(receiver.dup());
    try l0_stack.pushOwned(callable.dup());
    var region_start = l0_stack.topPtr() - 2;
    l0_stack.setTopPtr(region_start);
    const l0_resume_pc = l0_frame.function.byteCode().ptr + l0_frame.pc;
    try std.testing.expect(machine.tryPushEmptyLeafCallFast(.receiver, ctx.runtime, global, &l0_stack, resolved.fb, resolved.call_facts, region_start, l0_resume_pc) == null);
    try std.testing.expectEqual(initial_call_depth, ctx.runtime.hot.call_depth);
    try std.testing.expect(!region_start[0].isUndefined());
    try std.testing.expect(!region_start[1].isUndefined());

    // Authoritative constructor: receiver moves into the frame's owned raw
    // `this` (region slot cleared, no extra refcount), and the empty-leaf
    // return epilogue releases exactly that moved reference.
    const first = try machine.pushEmptyLeafCall(.receiver, global, &l0_stack, resolved.fb, resolved.call_facts, region_start);
    try std.testing.expect(first.isEmptyLeaf());
    try std.testing.expect(first.frame.this_value.same(receiver));
    try std.testing.expect(first.frame.ownership.this_value == .owned);
    try std.testing.expect(region_start[0].isUndefined());
    try std.testing.expectEqual(baseline_rc + 1, receiver_object.header.meta().rc);
    machine.popReturnedEmptyLeaf(ctx.runtime);
    try std.testing.expectEqual(baseline_rc, receiver_object.header.meta().rc);
    try std.testing.expectEqual(initial_call_depth, ctx.runtime.hot.call_depth);
    const steady_bytes = rt.memory.allocated_bytes;

    // Warm hit: same leaf shape, allocation-free, same ownership movement.
    try l0_stack.pushOwned(receiver.dup());
    try l0_stack.pushOwned(callable.dup());
    region_start = l0_stack.topPtr() - 2;
    l0_stack.setTopPtr(region_start);
    const alloc_calls = rt.memory.alloc_calls;
    const create_calls = rt.memory.create_calls;
    const warm = machine.tryPushEmptyLeafCallFast(.receiver, ctx.runtime, global, &l0_stack, resolved.fb, resolved.call_facts, region_start, l0_resume_pc) orelse
        return error.Unexpected;
    try std.testing.expect(warm.isEmptyLeaf());
    try std.testing.expect(warm.frame.this_value.same(receiver));
    try std.testing.expect(warm.frame.ownership.this_value == .owned);
    try std.testing.expectEqual(alloc_calls, rt.memory.alloc_calls);
    try std.testing.expectEqual(create_calls, rt.memory.create_calls);
    try std.testing.expectEqual(baseline_rc + 1, receiver_object.header.meta().rc);
    machine.popReturnedEmptyLeaf(ctx.runtime);
    try std.testing.expectEqual(baseline_rc, receiver_object.header.meta().rc);
    try std.testing.expectEqual(steady_bytes, rt.memory.allocated_bytes);

    // Setup failure must restore depth/watermark and release BOTH region
    // slots — receiver and callable — leaving the warmed Machine reusable.
    const oversized = try createOversizedLeafFixture(rt, resolved.fb);
    var oversized_alive = true;
    defer if (oversized_alive) oversized.destroyUnpublishedFixture(rt);
    const oversized_bytes = rt.memory.allocated_bytes;
    try l0_stack.pushOwned(receiver.dup());
    try l0_stack.pushOwned(callable.dup());
    region_start = l0_stack.topPtr() - 2;
    l0_stack.setTopPtr(region_start);
    rt.setMemoryLimit(rt.memory.allocated_bytes);
    const failed = machine.pushEmptyLeafCall(.receiver, global, &l0_stack, oversized, oversized.callFacts(), region_start);
    rt.setMemoryLimit(null);
    try std.testing.expectError(error.OutOfMemory, failed);
    try std.testing.expectEqual(initial_call_depth, ctx.runtime.hot.call_depth);
    try std.testing.expect(region_start[0].isUndefined());
    try std.testing.expect(region_start[1].isUndefined());
    try std.testing.expectEqual(baseline_rc, receiver_object.header.meta().rc);
    try std.testing.expectEqual(oversized_bytes, rt.memory.allocated_bytes);
    oversized.destroyUnpublishedFixture(rt);
    oversized_alive = false;
    try std.testing.expectEqual(steady_bytes, rt.memory.allocated_bytes);
}

test "strict empty leaf preserves undefined this across call forms" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Three plain-call forms of the strict leaf: a directly strict function,
    // a nested function inheriting strictness from its enclosing 'use strict'
    // body, and a strict method detached and called as a plain function. All
    // must observe `this === undefined` (no sloppy global substitution).
    const setup = try js.eval(
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
    setup.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();
    const baseline_objects = js.runtime.gc.liveCount();

    const result = try js.eval("exerciseStrictLeafThis()");
    result.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "strict method empty leaf passes primitive receiver uncoerced" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const setup = try js.eval(
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
    setup.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();
    const baseline_objects = js.runtime.gc.liveCount();

    const result = try js.eval("exerciseStrictMethodLeaf()");
    result.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "strict empty leaf frame preserves undefined this and borrowed ownership" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    const rt = js.runtime;
    const ctx = js.context;
    const global = try engine.exec.zjs_vm.contextGlobal(ctx);

    const setup = try js.eval("globalThis.__strictWarmLeaf = function () { \"use strict\"; return 1; };");
    setup.free(rt);
    const leaf_name = try rt.internAtom("__strictWarmLeaf");
    defer rt.atoms.free(leaf_name);
    const callable = try global.getProperty(leaf_name);
    defer callable.free(rt);
    const resolved = inline_calls.resolveInlineFunction(global, callable) orelse
        return error.InvalidFunctionBytecode;
    // The raw-this leaf publishes its own eligibility byte (the packed sloppy
    // bit stays clear); the call adapter selects the undefined-`this` arm.
    try std.testing.expect(!resolved.fb.simpleInlineEmptyLeaf());
    try std.testing.expect(resolved.fb.rawThisInlineEmptyLeaf());
    try std.testing.expect(resolved.fb.isStrictMode());

    var l0_function = try helpers.makeFunction(rt, &.{op.return_undef});
    defer l0_function.deinit(rt);
    var l0_execution_adapter: bytecode.LegacyExecutionAdapter = undefined;
    const l0_execution_function = l0_execution_adapter.init(&l0_function);
    var l0_frame = engine.exec.frame.Frame.init(l0_execution_function);
    defer l0_frame.deinit(&rt.memory, rt);
    var l0_stack = engine.exec.stack.Stack.init(&rt.memory, rt.stackSize());
    defer l0_stack.deinit(rt);
    var catch_target: ?usize = null;
    const l0 = inline_calls.L0State{ .level = .{
        .frame = &l0_frame,
        .stack = &l0_stack,
        .catch_target = &catch_target,
    } };
    var machine = inline_calls.Machine.init(ctx, null, global, &l0);
    defer machine.deinit();
    const initial_call_depth = ctx.runtime.hot.call_depth;

    // Authoritative constructor: `this` stays undefined and borrowed (no rc
    // traffic), matching setupSimpleInlineEntryImpl's strict plain arm.
    try l0_stack.pushOwned(callable.dup());
    var region_start = l0_stack.topPtr() - 1;
    l0_stack.setTopPtr(region_start);
    const first = try machine.pushEmptyLeafCall(.raw_undefined, global, &l0_stack, resolved.fb, resolved.call_facts, region_start);
    try std.testing.expect(first.isEmptyLeaf());
    try std.testing.expect(first.frame.this_value.isUndefined());
    try std.testing.expect(first.frame.ownership.this_value == .borrowed);
    machine.popReturnedEmptyLeaf(ctx.runtime);
    try std.testing.expectEqual(initial_call_depth, ctx.runtime.hot.call_depth);
    const steady_bytes = rt.memory.allocated_bytes;

    // Warm arm publishes the same strict shape allocation-free.
    try l0_stack.pushOwned(callable.dup());
    region_start = l0_stack.topPtr() - 1;
    l0_stack.setTopPtr(region_start);
    const l0_resume_pc = l0_frame.function.byteCode().ptr + l0_frame.pc;
    const alloc_calls = rt.memory.alloc_calls;
    const create_calls = rt.memory.create_calls;
    const warm = machine.tryPushEmptyLeafCallFast(.raw_undefined, ctx.runtime, global, &l0_stack, resolved.fb, resolved.call_facts, region_start, l0_resume_pc) orelse
        return error.Unexpected;
    try std.testing.expect(warm.isEmptyLeaf());
    try std.testing.expect(warm.frame.this_value.isUndefined());
    try std.testing.expect(warm.frame.ownership.this_value == .borrowed);
    try std.testing.expectEqual(alloc_calls, rt.memory.alloc_calls);
    try std.testing.expectEqual(create_calls, rt.memory.create_calls);
    machine.popReturnedEmptyLeaf(ctx.runtime);
    try std.testing.expectEqual(initial_call_depth, ctx.runtime.hot.call_depth);
    try std.testing.expectEqual(steady_bytes, rt.memory.allocated_bytes);
}

test "inline call teardown releases every escaped storage shape" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    helpers.registerStandardGlobalsBare(rt);
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try engine.exec.zjs_vm.contextGlobal(ctx);

    var l0_function = try helpers.makeFunction(rt, &.{op.return_undef});
    defer l0_function.deinit(rt);
    var l0_execution_adapter: bytecode.LegacyExecutionAdapter = undefined;
    const l0_execution_function = l0_execution_adapter.init(&l0_function);
    var l0_frame = engine.exec.frame.Frame.init(l0_execution_function);
    defer l0_frame.deinit(&rt.memory, rt);
    var l0_stack = engine.exec.stack.Stack.init(&rt.memory, rt.stackSize());
    defer l0_stack.deinit(rt);
    var catch_target: ?usize = null;
    const l0 = inline_calls.L0State{ .level = .{
        .frame = &l0_frame,
        .stack = &l0_stack,
        .catch_target = &catch_target,
    } };
    var machine = inline_calls.Machine.init(ctx, null, global, &l0);
    defer machine.deinit();

    var function = try helpers.makeFunction(rt, &.{op.return_undef});
    defer function.deinit(rt);
    function.simple_inline_eligible = true;
    var execution_adapter: bytecode.LegacyExecutionAdapter = undefined;
    const execution_function = execution_adapter.init(&function);
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
    continuation.deinit(rt);
    const baseline_bytes = rt.memory.allocated_bytes;

    try l0_stack.pushOwned(core.JSValue.undefinedValue());
    l0_stack.setLen(0);
    var entry = try machine.pushCall(global, &l0_stack, &target, l0_stack.topPtr(), 0, .plain);
    _ = try entry.frame.ensureCold(&rt.memory);
    continuation = machine.popFrame();
    continuation.deinit(rt);
    try std.testing.expectEqual(baseline_bytes, rt.memory.allocated_bytes);

    try l0_stack.pushOwned(core.JSValue.undefinedValue());
    l0_stack.setLen(0);
    entry = try machine.pushCall(global, &l0_stack, &target, l0_stack.topPtr(), 0, .plain);
    _ = try entry.frame.allocOwnedStorage(&rt.memory, 1);
    continuation = machine.popFrame();
    continuation.deinit(rt);
    try std.testing.expectEqual(baseline_bytes, rt.memory.allocated_bytes);

    try l0_stack.pushOwned(core.JSValue.undefinedValue());
    l0_stack.setLen(0);
    entry = try machine.pushCall(global, &l0_stack, &target, l0_stack.topPtr(), 0, .plain);
    try entry.stack.reserveAdditional(entry.stack.capacity + 1);
    continuation = machine.popFrame();
    continuation.deinit(rt);
    try std.testing.expectEqual(baseline_bytes, rt.memory.allocated_bytes);

    // A window larger than one arena chunk uses the setup-time heap fallback.
    function.stack_size = core.VmStackArena.chunk_slots;
    try l0_stack.pushOwned(core.JSValue.undefinedValue());
    l0_stack.setLen(0);
    _ = try machine.pushCall(global, &l0_stack, &target, l0_stack.topPtr(), 0, .plain);
    continuation = machine.popFrame();
    continuation.deinit(rt);
    try std.testing.expectEqual(baseline_bytes, rt.memory.allocated_bytes);
}

test "inline operand Stack keeps limit and ownership flags in one word" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(engine.exec.stack.Stack));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(inline_calls.Machine.ArgsSource));
    // Frame and Entry are layout-sensitive (see the Entry pin in
    // inline_calls.zig and the QCP-1B note in docs/refactor-policy.md), so pin
    // both sizes here rather than leaving them to a benchmark to notice.
    try std.testing.expectEqual(@as(usize, 152), @sizeOf(engine.exec.frame.Frame));
    try std.testing.expectEqual(@as(usize, 256), @sizeOf(inline_calls.Entry));
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
    defer callable.free(js.runtime);

    try std.testing.expectEqual(@as(usize, 0), js.runtime.vm_stack.chunk_count);
    const result = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        callable,
        &.{},
        null,
        null,
    );
    defer result.free(js.runtime);

    try std.testing.expectEqual(@as(usize, 1), js.runtime.vm_stack.chunk_count);
    try std.testing.expectEqual(
        core.VmStackArena.Mark{ .chunk = 0, .used = 0 },
        js.runtime.vm_stack.mark(),
    );
}

test "method calls preserve receiver arguments eval captures and abrupt ownership" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "primitive prototype lookup preserves raw receiver and exotic prototype semantics" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "computed named reads preserve prototype accessors proxies and operand ownership" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "computed integer write misses preserve generic set semantics" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "dense write leaf consumes reserved appends only inside the qjs capacity window" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const array = try core.Object.createArray(rt, null);
    defer array.value().free(rt);
    try array.fastArrayEnsureCapacity(rt, 2);

    const stored = try core.Object.create(rt, core.class.ids.object, null);
    const stored_witness = stored.value().dup();
    defer stored_witness.free(rt);
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
    try std.testing.expectEqual(&stored.header, array.fastArrayElementAt(0).refHeader().?);
    try std.testing.expectEqual(@as(i32, 2), stored.header.meta().rc);

    const growth_array = try core.Object.createArray(rt, null);
    defer growth_array.value().free(rt);
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
    try std.testing.expectEqual(@as(i32, 1), retained.header.meta().rc);
    retained.value().free(rt);

    const shaped_array = try core.Object.createArray(rt, null);
    defer shaped_array.value().free(rt);
    try shaped_array.fastArrayEnsureCapacity(rt, 1);
    const extra_atom = try rt.internAtom("extra");
    defer rt.atoms.free(extra_atom);
    try shaped_array.defineOwnProperty(
        rt,
        extra_atom,
        core.Descriptor.data(core.JSValue.int32(1), true, true, true),
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
    try std.testing.expectEqual(@as(i32, 1), shaped_retained.header.meta().rc);
    shaped_retained.value().free(rt);
}

test "static named getter and proxy fast paths preserve receivers throws and invariants" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "computed proxy bytecode trap continuations preserve nested calls throws and invariants" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "strict arrow tails stay constant while method recursion exhausts the logical stack budget" {

    // In a STRICT script, plain / arrow `return f()` is a proper tail call
    // and stays in constant stack. Method tails (`return this.m()`) still
    // grow a logical frame, so deep method recursion remains a catchable
    // stack overflow. Prove the runtime is usable after each catch.

    try helpers.expectPrints(
        \\"use strict";
        \\function expectStackOverflow(run) {
        \\  try {
        \\    run();
        \\    print("missing overflow");
        \\  } catch (error) {
        \\    print(error.name + ": " + error.message);
        \\  }
        \\}
        \\const arrowRecurse = (n) => n === 0 ? 0 : arrowRecurse(n - 1);
        \\print("arrow:" + arrowRecurse(40000));
        \\const machine = {
        \\  even(n) { return n === 0 ? "even" : this.odd(n - 1); },
        \\  odd(n) { return n === 0 ? "odd" : this.even(n - 1); },
        \\};
        \\expectStackOverflow(() => machine.even(40000));
        \\const counter = { loop(n) { return n === 0 ? 0 : this.loop(n - 1); } };
        \\expectStackOverflow(() => counter.loop(40000));
        \\print("recovered");
    , "arrow:0\n" ++
        "InternalError: stack overflow\n" ++
        "InternalError: stack overflow\n" ++
        "recovered\n");
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());

    // An ordinary nested function does not inherit a method's Super grammar
    // capability. QuickJS rejects the complete source during parsing; the
    // surrounding runtime try/catch cannot intercept that early error.
    try std.testing.expectError(error.SyntaxError, js.eval(
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "forwarded call releases ignored arrow thisArg" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // The strict arrow publishes the ordinary raw frame policy. Forwarded
    // Function.call still transfers and releases its explicit receiver even
    // though arrow bytecode ignores that slot.
    const setup = try js.eval(
        \\globalThis.strictArrowForCall = (function () {
        \\    "use strict";
        \\    return () => 0;
        \\})();
        \\strictArrowForCall.call({ marker: 0 });
    );
    setup.free(js.runtime);
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const arrow_name = try js.runtime.internAtom("strictArrowForCall");
    defer js.runtime.atoms.free(arrow_name);
    const arrow = try global.getProperty(arrow_name);
    defer arrow.free(js.runtime);
    const resolved = inline_calls.resolveInlineFunction(global, arrow) orelse
        return error.InvalidFunctionBytecode;
    try std.testing.expect(!resolved.fb.simpleInlineEmptyLeaf());
    try std.testing.expect(resolved.fb.rawThisInlineEmptyLeaf());

    _ = js.runtime.runObjectCycleRemoval();
    const baseline_objects = js.runtime.gc.liveCount();

    const result = try js.eval(
        \\for (let i = 0; i < 256; i++) {
        \\    strictArrowForCall.call({ marker: i });
        \\}
    );
    result.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();

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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine eval Function.prototype.toString returns source or native text" {
    try helpers.expectPrints(
        \\function f(x) { return x; }
        \\print(f.toString());
        \\function /* a */ g /* b */ ( /* c */ y /* d */ ) /* e */ { /* f */ return y; /* g */ }
        \\print(g.toString());
        \\const arrow = y => y + 1;
        \\print(arrow.toString());
        \\print(print.toString());
        \\try { Function.prototype.toString.call({}); } catch (e) { print(e.name); }
        \\try { String({ toString: Function.prototype.toString }); } catch (e) { print(e.name); }
    , "function f(x) { return x; }\n" ++
        "function /* a */ g /* b */ ( /* c */ y /* d */ ) /* e */ { /* f */ return y; /* g */ }\n" ++
        "y => y + 1\n" ++
        "function print() {\n    [native code]\n}\n" ++
        "TypeError\n" ++
        "TypeError\n");
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
    try helpers.expectPrints(
        \\const method = { /* before */ f /* a */ ( /* b */ ) /* c */ { /* d */ } /* after */ }.f;
        \\print(method.toString());
        \\const asyncComputed = { async /* a */ [ /* b */ "g" /* c */ ] /* d */ ( /* e */ ) /* f */ { /* g */ } }.g;
        \\print(asyncComputed.toString());
        \\const asyncGeneratorComputed = { async /* a */ * /* b */ [ /* c */ "h" /* d */ ] /* e */ ( /* f */ ) /* g */ { /* h */ } }.h;
        \\print(asyncGeneratorComputed.toString());
        \\function B() {}
        \\const C = class /* a */ A /* b */ extends /* c */ B /* d */ { /* e */ constructor /* f */ ( /* g */ ) /* h */ { /* i */ } /* j */ };
        \\print(C.toString());
    , "f /* a */ ( /* b */ ) /* c */ { /* d */ }\n" ++
        "async /* a */ [ /* b */ \"g\" /* c */ ] /* d */ ( /* e */ ) /* f */ { /* g */ }\n" ++
        "async /* a */ * /* b */ [ /* c */ \"h\" /* d */ ] /* e */ ( /* f */ ) /* g */ { /* h */ }\n" ++
        "class /* a */ A /* b */ extends /* c */ B /* d */ { /* e */ constructor /* f */ ( /* g */ ) /* h */ { /* i */ } /* j */ }\n");
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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
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

test "Engine eval preserves ASCII string integer literal concat semantics" {
    try helpers.expectPrints(
        \\print("a" + 1);
        \\print("a" + -1);
        \\print("" + 12345);
    , "a1\na-1\n12345\n");
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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);

    try std.testing.expectEqual(@as(?i32, 10), result.asInt32());
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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "private fields isolate class evaluations and preserve lexical call and eval semantics" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const setup = try js.eval(
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
    defer setup.free(js.runtime);

    const identity_checks = try js.eval(
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
    defer identity_checks.free(js.runtime);

    const field_checks = try js.eval(
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
    defer field_checks.free(js.runtime);

    const capture_checks = try js.eval(
        \\(function ({ first }) {
        \\  assert.sameValue(first.readFromArrow(), 12, "nested arrow captures private environment");
        \\  assert.sameValue(
        \\    first.readFromInnerFunction(),
        \\    12,
        \\    "nested ordinary function captures private environment"
        \\  );
        \\})(__execPrivateFieldRegression);
    );
    defer capture_checks.free(js.runtime);

    const receiver_check = try js.eval(
        \\(function ({ first }) {
        \\  assert.sameValue(
        \\    first.callStoredFunction(),
        \\    first,
        \\    "calling a function stored in a private field preserves the instance receiver"
        \\  );
        \\})(__execPrivateFieldRegression);
    );
    defer receiver_check.free(js.runtime);

    const direct_eval_checks = try js.eval(
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
    defer direct_eval_checks.free(js.runtime);
}

test "private method brands use lexical initializers on every constructor path" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
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
    defer result.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const instance_names = [_][]const u8{
        "__privateMethodExplicitBase",
        "__privateMethodDirectDerived",
        "__privateMethodSpreadDerived",
        "__privateMethodDefaultDerived",
    };
    for (instance_names) |name| {
        const atom = try js.runtime.internAtom(name);
        defer js.runtime.atoms.free(atom);
        const value = try global.getProperty(atom);
        defer value.free(js.runtime);
        const instance = try core.Object.expect(value);
        try std.testing.expect(!instance.hasOwnProperty(core.atom.ids.Private_brand));
    }
}

test "private methods and accessors preserve brands captures and readonly semantics" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const setup = try js.eval(
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
    defer setup.free(js.runtime);

    const brand_checks = try js.eval(
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
    defer brand_checks.free(js.runtime);

    const instance_checks = try js.eval(
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
    defer instance_checks.free(js.runtime);

    const static_checks = try js.eval(
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
    defer static_checks.free(js.runtime);

    const capture_checks = try js.eval(
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
    defer capture_checks.free(js.runtime);

    const wrong_brand_checks = try js.eval(
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
    defer wrong_brand_checks.free(js.runtime);

    const readonly_checks = try js.eval(
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
    defer readonly_checks.free(js.runtime);
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
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "array named proto field uses ordinary lookup; length and index stay exotic" {
    // qjs GET_FIELD_INLINE (quickjs.c:19135-19138): Array exotic is index +
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
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "iterator results use ordinary transitions without a sixth realm shape" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);

    try std.testing.expect(!@hasField(core.RealmContext, "iterator_result_shape"));

    const warm = try engine.exec.iterator_ops.createIteratorResult(js.runtime, global, core.JSValue.int32(1), false);
    warm.free(js.runtime);
    const alloc_calls = js.runtime.memory.alloc_calls;
    const create_calls = js.runtime.memory.create_calls;
    const result = try engine.exec.iterator_ops.createIteratorResult(js.runtime, global, core.JSValue.int32(2), true);
    defer result.free(js.runtime);

    // QuickJS's js_create_iterator_result performs the ordinary `value` then
    // `done` transitions. With no realm-pinned iterator layout, zjs likewise
    // creates the object and the transient one-property Shape; the property
    // array remains pre-sized in one allocation.
    try std.testing.expectEqual(alloc_calls + 1, js.runtime.memory.alloc_calls);
    try std.testing.expectEqual(create_calls + 2, js.runtime.memory.create_calls);
    const object = try core.Object.expect(result);
    try std.testing.expectEqual(@as(?i32, 2), object.asDataAt(0).?.asInt32());
    try std.testing.expect(object.asDataAt(1).?.asBool().?);
}

test "bytecode closures reuse the final function-prototype shape" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.evalWithOptions(
        "(function () { function make() { return function () {}; } return [make(), make()]; })()",
        .{ .filename = "<repl>" },
    );
    defer result.free(js.runtime);
    const functions = try core.Object.expect(result);
    const first_value = try functions.getProperty(core.atom.atomFromUInt32(0));
    defer first_value.free(js.runtime);
    const second_value = try functions.getProperty(core.atom.atomFromUInt32(1));
    defer second_value.free(js.runtime);
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
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const compile_facade = try zjs.JSContext.create(rt);
    var compile_facade_alive = true;
    defer if (compile_facade_alive) compile_facade.destroy();
    const compile_realm = compile_facade.core;
    const compile_global = try compile_facade.globalObject();
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

    const caller = try zjs.JSContext.create(rt);
    defer caller.destroy();
    const root_function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    var stack = engine.exec.stack.Stack.init(&rt.memory, caller.core.stackLimit());
    defer stack.deinit(rt);
    const escaped = try engine.exec.zjs_vm.runWithOutput(caller.core, &stack, root_function, null);
    var escaped_alive = true;
    defer if (escaped_alive) escaped.free(rt);

    // Drop the root FB and its cpool edge. The escaped closure's child FB must
    // still own the compile realm independently.
    parsed.deinit();
    parsed_alive = false;
    const result = try caller.callFunction(escaped, &.{}, .{});
    try std.testing.expectEqual(compile_global, try core.Object.expect(result));
    result.free(rt);

    escaped.free(rt);
    escaped_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.contextForGlobalIncludingConstructing(compile_global) == null);
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
        defer js.runtime.atoms.free(key);
        const constructor = global.getOwnDataObjectBorrowed(key) orelse return error.TestUnexpectedResult;
        const prototype = constructor.getOwnDataObjectBorrowed(core.atom.ids.prototype) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(prototype, js.context.classPrototypeObject(item.class_id).?);
    }
}

test "FunctionRealm query separates owned carriers from caller-semantics classes" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const setup = try js.eval(
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
    setup.free(js.runtime);
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const carriers_atom = try js.runtime.internAtom("__functionRealmCarriers");
    defer js.runtime.atoms.free(carriers_atom);
    const carriers = try global.getProperty(carriers_atom);
    defer carriers.free(js.runtime);
    const carrier_array = try core.Object.expect(carriers);
    var values: [7]core.JSValue = undefined;
    for (&values, 0..) |*slot, index| slot.* = try carrier_array.getProperty(core.atom.atomFromUInt32(@intCast(index)));
    defer for (values) |value| value.free(js.runtime);

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

test "generator async and wrapper noncarriers derive cross-realm state across GC" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const setup = try js.eval(
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
    setup.free(js.runtime);

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
    defer for (values) |value| value.free(js.runtime);
    for (names, &values) |name, *value| {
        const key = try js.runtime.internAtom(name);
        defer js.runtime.atoms.free(key);
        value.* = try global.getProperty(key);
    }

    const other_global = try core.Object.expect(values[0]);
    for (values[1..]) |value| {
        const object = try core.Object.expect(value);
        try std.testing.expect(!js.runtime.borrowedReferenceHolderRegistered(object));
        try std.testing.expect(object.borrowedReferenceHolderIndex() == null);
        try std.testing.expect(object.functionRealmGlobalPtr() == null);
        try std.testing.expectEqual(other_global, object_ops.objectRealmGlobal(object).?);
    }
    for (values[1..5]) |value| {
        const generator = try core.Object.expect(value);
        try std.testing.expectEqual(other_global, generator.generatorFunctionRealmGlobalPtr().?);
    }

    _ = js.runtime.runObjectCycleRemoval();

    for (values[1..]) |value| {
        const object = try core.Object.expect(value);
        try std.testing.expect(!js.runtime.borrowedReferenceHolderRegistered(object));
        try std.testing.expectEqual(other_global, object_ops.objectRealmGlobal(object).?);
    }

    const exercise = try js.eval(
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
    exercise.free(js.runtime);

    try js.runJobs();
    const verify_async = try js.eval(
        \\assert.sameValue(__w1b3eAsyncFunctionValue, __w1b3eOther);
        \\assert.sameValue(__w1b3eAsyncGeneratorStep.value, __w1b3eOther);
        \\assert.sameValue(Object.getPrototypeOf(__w1b3eAsyncGeneratorStep), __w1b3eOther.Object.prototype);
    );
    defer verify_async.free(js.runtime);
    try std.testing.expect(verify_async.isUndefined());
}

test "FinalizationRegistry cleanup job keeps registry realm before invoking callback realm" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const registry_facade = try zjs.JSContext.create(rt);
    var registry_facade_alive = true;
    defer if (registry_facade_alive) registry_facade.destroy();
    const registry_realm = registry_facade.core;
    const registry_global = try registry_facade.globalObject();

    const callback_facade = try zjs.JSContext.create(rt);
    var callback_facade_alive = true;
    defer if (callback_facade_alive) callback_facade.destroy();
    const callback_realm = callback_facade.core;
    const callback_global = try callback_facade.globalObject();
    try std.testing.expect(registry_realm != callback_realm);

    var probe: CrossRealmNativeProbe = .{};
    const external_id = try rt.registerExternalHostFunction(.{
        .ptr = &probe,
        .call = crossRealmNativeProbe,
    });
    const callback = try core.function.nativeFunction(callback_realm, "finalizationRealmProbe", 1);
    defer callback.free(rt);
    const callback_object = try core.Object.expect(callback);
    callback_object.hostFunctionKindSlot().* = core.host_function.ids.external_host;
    callback_object.externalHostFunctionIdSlot().* = external_id;

    const registry_value = try object_ops.constructFinalizationRegistryWithPrototype(
        registry_realm,
        callback,
        null,
    );
    defer registry_value.free(rt);
    const registry = try core.Object.expect(registry_value);
    try std.testing.expectEqual(registry_realm, registry.finalizationRegistryRealmContext().?);
    try std.testing.expectEqual(callback_realm, callback_object.nativeFunctionRealm().?);

    // Drop both public construction owners before GC. The registry and
    // callback carriers must independently keep their construction Realms
    // alive through enqueue and invocation.
    registry_facade.destroy();
    registry_facade_alive = false;
    callback_facade.destroy();
    callback_facade_alive = false;

    const target = try core.Object.create(rt, core.class.ids.object, null);
    try registry.appendFinalizationRegistryCell(
        rt,
        target.value(),
        core.JSValue.int32(73),
        core.JSValue.undefinedValue(),
    );
    target.value().free(rt);
    _ = try rt.tryRunObjectCycleRemoval();

    try std.testing.expectEqual(@as(usize, 1), rt.pendingFinalizationJobCountForTest());
    try std.testing.expectEqual(registry_realm, rt.job_queue.jobs[0].realm.borrow().?);
    const queued_payload = switch (rt.job_queue.jobs[0].payload) {
        .finalization => |payload| payload,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(?i32, 73), queued_payload.held_value.asInt32());

    // The job starts with the registry construction realm, but the final call
    // still follows the callback C_FUNCTION's independent RealmRef.
    try std.testing.expectEqual(
        .exception,
        try engine.exec.promise_ops.drainOnePendingJob(registry_realm, null, registry_global),
    );
    try std.testing.expectEqual(callback_realm, probe.seen_realm.?);
    try std.testing.expectEqual(callback_global, probe.seen_global.?);
    try std.testing.expectEqual(@as(usize, 0), rt.pendingFinalizationJobCountForTest());
    registry_realm.clearException();
}

test "event-loop caller reaches external C function with one callee realm view" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const setup = try js.eval(
        \\(function () {
        \\    globalThis.__calleeRealm = $262.createRealm().global;
        \\    globalThis.__callerRealm = $262.createRealm().global;
        \\})();
    );
    setup.free(js.runtime);

    const loop_global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const callee_key = try js.runtime.internAtom("__calleeRealm");
    defer js.runtime.atoms.free(callee_key);
    const caller_key = try js.runtime.internAtom("__callerRealm");
    defer js.runtime.atoms.free(caller_key);
    const callee_value = try loop_global.getProperty(callee_key);
    defer callee_value.free(js.runtime);
    const caller_value = try loop_global.getProperty(caller_key);
    defer caller_value.free(js.runtime);
    const callee_global = try core.Object.expect(callee_value);
    const caller_global = try core.Object.expect(caller_value);
    const callee_realm = js.runtime.contextForGlobalIncludingConstructing(callee_global) orelse return error.TestUnexpectedResult;
    const caller_realm = js.runtime.contextForGlobalIncludingConstructing(caller_global) orelse return error.TestUnexpectedResult;
    try std.testing.expect(callee_realm != caller_realm);
    try std.testing.expect(callee_realm != js.context);
    try std.testing.expect(caller_realm != js.context);

    var probe: CrossRealmNativeProbe = .{};
    const external_id = try js.runtime.registerExternalHostFunction(.{
        .ptr = &probe,
        .call = crossRealmNativeProbe,
    });
    const native_value = try core.function.nativeFunction(callee_realm, "realmProbe", 0);
    defer native_value.free(js.runtime);
    const native_object = try core.Object.expect(native_value);
    native_object.hostFunctionKindSlot().* = core.host_function.ids.external_host;
    native_object.externalHostFunctionIdSlot().* = external_id;

    const escaped_key = try js.runtime.internAtom("__escapedNative");
    defer js.runtime.atoms.free(escaped_key);
    try caller_global.defineOwnProperty(
        js.runtime,
        escaped_key,
        core.Descriptor.data(native_value, true, true, true),
    );

    var caller_wrapper = zjs.JSContext.borrowCore(caller_realm);
    const wrapper_setup = try caller_wrapper.eval(
        \\globalThis.__eventLoopWrapper = function () {
        \\    globalThis.__caller_body_ran = true;
        \\    try {
        \\        __escapedNative();
        \\    } catch (error) {
        \\        globalThis.__callee_error = error;
        \\    }
        \\};
    , .{});
    wrapper_setup.free(js.runtime);
    const wrapper_key = try js.runtime.internAtom("__eventLoopWrapper");
    defer js.runtime.atoms.free(wrapper_key);
    const wrapper_value = try caller_global.getProperty(wrapper_key);
    defer wrapper_value.free(js.runtime);

    try js.event_loop.enqueueTimer(js.context, 1, wrapper_value, 0, false);
    try std.testing.expect(try engine.exec.call_runtime.runNextOsTimer(js.context, null, loop_global));

    try std.testing.expectEqual(callee_realm, probe.seen_realm.?);
    try std.testing.expectEqual(callee_global, probe.seen_global.?);
    const mutation_key = try js.runtime.internAtom("__native_realm_mutation");
    defer js.runtime.atoms.free(mutation_key);
    const callee_mutation = try callee_global.getProperty(mutation_key);
    defer callee_mutation.free(js.runtime);
    const caller_mutation = try caller_global.getProperty(mutation_key);
    defer caller_mutation.free(js.runtime);
    const loop_mutation = try loop_global.getProperty(mutation_key);
    defer loop_mutation.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 1), callee_mutation.asInt32());
    try std.testing.expect(caller_mutation.isUndefined());
    try std.testing.expect(loop_mutation.isUndefined());

    const error_key = try js.runtime.internAtom("__callee_error");
    defer js.runtime.atoms.free(error_key);
    const caught_error = try caller_global.getProperty(error_key);
    defer caught_error.free(js.runtime);
    const caught_object = try core.Object.expect(caught_error);
    const type_error_value = try callee_global.getProperty(core.atom.predefinedId("TypeError", .string).?);
    defer type_error_value.free(js.runtime);
    const type_error_constructor = try core.Object.expect(type_error_value);
    const type_error_prototype_value = try type_error_constructor.getProperty(core.atom.ids.prototype);
    defer type_error_prototype_value.free(js.runtime);
    const type_error_prototype = try core.Object.expect(type_error_prototype_value);
    try std.testing.expectEqual(type_error_prototype, caught_object.getPrototype().?);

    const body_ran_key = try js.runtime.internAtom("__caller_body_ran");
    defer js.runtime.atoms.free(body_ran_key);
    const body_ran = try caller_global.getProperty(body_ran_key);
    defer body_ran.free(js.runtime);
    try std.testing.expectEqual(true, body_ran.asBool().?);
}

test "true C function without its RealmRef fails the final-arm invariant" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);

    const function_value = try core.function.nativeFunction(js.context, "missingRealm", 0);
    defer function_value.free(js.runtime);
    const function_object = try core.Object.expect(function_value);
    function_object.hostFunctionKindSlot().* = core.host_function.ids.output;
    function_object.releaseNativeFunctionRealmForRuntimeTeardown(js.context);

    try std.testing.expectError(
        error.InvalidBuiltinRegistry,
        engine.exec.call.callValueWithThisGlobalsAndGlobal(
            js.context,
            null,
            global,
            &.{},
            core.JSValue.undefinedValue(),
            function_value,
            &.{},
        ),
    );
}

test "generator creation avoids a second payload copy of rooted input slices" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);

    const argument = (try core.Object.create(js.runtime, core.class.ids.object, null)).value();
    defer argument.free(js.runtime);
    const argument_setup = try js.eval("globalThis.__argumentGenerator = function* () {};");
    argument_setup.free(js.runtime);
    const argument_key = try js.runtime.internAtom("__argumentGenerator");
    defer js.runtime.atoms.free(argument_key);
    const argument_generator = try global.getProperty(argument_key);
    defer argument_generator.free(js.runtime);
    const argument_values = [_]core.JSValue{argument};

    const warm_argument = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        argument_generator,
        &argument_values,
        null,
        null,
    );
    warm_argument.free(js.runtime);
    const warm_no_argument = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        argument_generator,
        &.{},
        null,
        null,
    );
    // Keep one final-prototype root Shape live. A qjs-style detached generator
    // construction then needs two fixed creates (public Object + compact
    // payload) and one variable allocation containing execution state + stack;
    // it must not allocate a temporary null-prototype Shape or stack buffer.
    defer warm_no_argument.free(js.runtime);

    var alloc_calls = js.runtime.memory.alloc_calls;
    var create_calls = js.runtime.memory.create_calls;
    const no_argument_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        argument_generator,
        &.{},
        null,
        null,
    );
    no_argument_result.free(js.runtime);
    const no_argument_alloc_count = js.runtime.memory.alloc_calls - alloc_calls;
    const no_argument_create_count = js.runtime.memory.create_calls - create_calls;
    try std.testing.expectEqual(@as(usize, 2), no_argument_create_count);
    try std.testing.expectEqual(@as(usize, 1), no_argument_alloc_count);

    alloc_calls = js.runtime.memory.alloc_calls;
    create_calls = js.runtime.memory.create_calls;
    const argument_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        argument_generator,
        &argument_values,
        null,
        null,
    );
    argument_result.free(js.runtime);
    const argument_alloc_count = js.runtime.memory.alloc_calls - alloc_calls;
    const argument_create_count = js.runtime.memory.create_calls - create_calls;
    // Args/locals/var-ref windows enlarge the same variable-sized execution
    // allocation; the construction root borrows the caller slice until those
    // resident windows have been initialized and parked.
    try std.testing.expectEqual(no_argument_alloc_count, argument_alloc_count);
    try std.testing.expectEqual(no_argument_create_count, argument_create_count);

    const capture_setup = try js.eval("globalThis.__captureGenerator = (function () { var captured = {}; return function* () { yield captured; }; })();");
    capture_setup.free(js.runtime);
    const capture_key = try js.runtime.internAtom("__captureGenerator");
    defer js.runtime.atoms.free(capture_key);
    const capture_generator = try global.getProperty(capture_key);
    defer capture_generator.free(js.runtime);
    const warm_capture = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        capture_generator,
        &.{},
        null,
        null,
    );
    defer warm_capture.free(js.runtime);

    alloc_calls = js.runtime.memory.alloc_calls;
    create_calls = js.runtime.memory.create_calls;
    const no_capture_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        argument_generator,
        &.{},
        null,
        null,
    );
    no_capture_result.free(js.runtime);
    const no_capture_alloc_count = js.runtime.memory.alloc_calls - alloc_calls;
    const no_capture_create_count = js.runtime.memory.create_calls - create_calls;

    alloc_calls = js.runtime.memory.alloc_calls;
    create_calls = js.runtime.memory.create_calls;
    const capture_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        capture_generator,
        &.{},
        null,
        null,
    );
    capture_result.free(js.runtime);
    const capture_alloc_count = js.runtime.memory.alloc_calls - alloc_calls;
    const capture_create_count = js.runtime.memory.create_calls - create_calls;
    try std.testing.expectEqual(no_capture_alloc_count, capture_alloc_count);
    try std.testing.expectEqual(no_capture_create_count, capture_create_count);
}

test "Engine generator return propagates an explicit finally throw" {
    try helpers.expectPrints(
        \\var syncError = new Error('sync');
        \\function* syncGenerator() {
        \\  try { yield 1; } finally { throw syncError; }
        \\}
        \\var syncIterator = syncGenerator();
        \\syncIterator.next();
        \\try {
        \\  syncIterator.return('sent');
        \\  print('sync-resolved');
        \\} catch (error) {
        \\  print('sync-rejected', error === syncError);
        \\}
        \\var asyncError = new Error('async');
        \\async function* asyncGenerator() {
        \\  try { yield 1; } finally { throw asyncError; }
        \\}
        \\var asyncIterator = asyncGenerator();
        \\asyncIterator.next().then(function() {
        \\  return asyncIterator.return('sent');
        \\}).then(function() {
        \\  print('async-resolved');
        \\}, function(error) {
        \\  print('async-rejected', error === asyncError);
        \\  return asyncIterator.next();
        \\}).then(function(result) {
        \\  print('async-closed', result.value, result.done);
        \\});
    , "sync-rejected true\nasync-rejected true\nasync-closed undefined true\n");
}

test "async generator return awaits for-await iterator close before completing" {
    try helpers.expectPrints(
        \\var closeCalls = 0;
        \\var awaitCalls = 0;
        \\var iterable = {};
        \\iterable[Symbol.asyncIterator] = function() {
        \\  return {
        \\    next: function() { return Promise.resolve({ value: 1, done: false }); },
        \\    return: function() {
        \\      closeCalls++;
        \\      return { then: function(resolve) { awaitCalls++; resolve({ done: true }); } };
        \\    }
        \\  };
        \\};
        \\async function* values() {
        \\  for await (var value of iterable) yield value;
        \\}
        \\var iterator = values();
        \\iterator.next().then(function() {
        \\  return iterator.return(9);
        \\}).then(function(result) {
        \\  print(result.value, result.done, closeCalls, awaitCalls);
        \\}, function(error) {
        \\  print("rejected", error.name, closeCalls, awaitCalls);
        \\});
    , "9 true 1 1\n");
}

test "async generator return closes an inner iterator before its enclosing finally" {
    try helpers.expectPrints(
        \\const events = [];
        \\const iterable = {
        \\  [Symbol.asyncIterator]() {
        \\    return {
        \\      next() { return Promise.resolve({ value: 1, done: false }); },
        \\      return() { events.push("return"); return Promise.resolve({ done: true }); },
        \\    };
        \\  },
        \\};
        \\async function* values() {
        \\  try {
        \\    for await (const value of iterable) yield value;
        \\  } finally {
        \\    events.push("finally");
        \\  }
        \\}
        \\const generator = values();
        \\generator.next().then(function() {
        \\  return generator.return(9);
        \\}).then(function(returned) {
        \\  print(events.join(","), returned.value, returned.done);
        \\});
    , "return,finally 9 true\n");
}

test "async generator return awaits its value once before a yielding finalizer" {
    try helpers.expectPrints(
        \\let awaitCount = 0;
        \\const returned = { then(resolve) { awaitCount++; resolve(7); } };
        \\async function* values() {
        \\  try { yield 1; }
        \\  finally { yield 2; }
        \\}
        \\const iterator = values();
        \\iterator.next().then(function() {
        \\  return iterator.return(returned);
        \\}).then(function(finalizerYield) {
        \\  print(finalizerYield.value, finalizerYield.done, awaitCount);
        \\  return iterator.next();
        \\}).then(function(completion) {
        \\  print(completion.value, completion.done, awaitCount);
        \\});
    , "2 false 1\n7 true 1\n");
}

test "Engine eval preserves simple for-in mutation semantics" {
    try helpers.expectPrints(
        \\let obj = { a: 1, b: 2, c: 3 };
        \\let keys = "";
        \\for (var k in obj) {
        \\  keys += k;
        \\  if (k === "a") delete obj.b;
        \\}
        \\print(keys);
        \\let obj2 = { a: 1, b: 2 };
        \\keys = "";
        \\for (var k in obj2) {
        \\  keys += k;
        \\  if (k === "a") {
        \\    delete obj2.b;
        \\    obj2.b = 3;
        \\  }
        \\}
        \\print(keys);
    , "ac\nab\n");
}

test "Engine runJobs preserves pending JS exceptions for callers" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    js.context.preserve_uncaught_exception = true;

    const setup = try js.eval("var __zjs_timer_throw = function() { throw new Error('timer boom'); };");
    defer setup.free(js.runtime);
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const callback_key = try js.runtime.internAtom("__zjs_timer_throw");
    defer js.runtime.atoms.free(callback_key);
    const callback = try global.getProperty(callback_key);
    defer callback.free(js.runtime);

    try js.event_loop.enqueueTimer(@ptrCast(js.context), 1, callback, 0, false);

    try js.runJobs();
    try std.testing.expect(js.context.hasException());

    var exception = try js.takeExceptionInfo();
    defer exception.deinit();
}

test "host module graph syntax diagnostics do not write to program output" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
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
    var js = try helpers.TestEngine.init(std.testing.allocator);
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

test "module graph evaluates block var declarations as module bindings" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const registry = engine.exec.standard_globals;
    registry.configureRuntime(js.runtime);

    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithOutput(
        \\if (true) {
        \\  var proto = {};
        \\  print(typeof proto);
        \\  print(proto !== null);
        \\}
    ,
        &output,
        "block-var-module.mjs",
        std.testing.io,
        std.testing.allocator,
        2048,
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("object\ntrue\n", output.buffered());
}

test "module evaluation does not skip a body-leading function expression" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const registry = engine.exec.standard_globals;
    registry.configureRuntime(js.runtime);

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithOutput(
        \\print((function () { return 42; })());
    ,
        &output,
        "module-leading-function-expression.mjs",
        std.testing.io,
        std.testing.allocator,
        2048,
    );
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("42\n", output.buffered());
}

test "module evaluation does not mistake a body-leading this branch for a hoist prologue" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const registry = engine.exec.standard_globals;
    registry.configureRuntime(js.runtime);

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithOutput(
        \\if (this) print('bad');
        \\print('ok');
    ,
        &output,
        "module-leading-this-branch.mjs",
        std.testing.io,
        std.testing.allocator,
        2048,
    );
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("ok\n", output.buffered());
}

test "module cycles initialize wide function declaration closures before evaluation" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var module_a: std.ArrayList(u8) = .empty;
    defer module_a.deinit(std.testing.allocator);
    try module_a.appendSlice(std.testing.allocator, "import { pre } from './b.mjs';\n");
    for (0..257) |index| {
        var line_buffer: [80]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &line_buffer,
            "export function f{d}() {{ return {d}; }}\n",
            .{ index, index },
        );
        try module_a.appendSlice(std.testing.allocator, line);
    }
    try module_a.appendSlice(std.testing.allocator, "export const observed = pre;\n");

    const modules = [_]HostFixtureModule{
        .{
            .specifier = "./a.mjs",
            .path = "/fixture/a.mjs",
            .source = module_a.items,
            .kind = .esm,
        },
        .{
            .specifier = "./b.mjs",
            .path = "/fixture/b.mjs",
            .source =
            \\import { f255, f256 } from './a.mjs';
            \\export const pre = (() => {
            \\  try { return typeof f255 + ',' + typeof f256; }
            \\  catch (error) { return typeof f255 + ',' + error.name; }
            \\})();
            ,
            .kind = .esm,
        },
    };
    const host = HostFixture{ .modules = &modules };
    const hooks = hostHooks(&host);

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithHostHooks(
        \\import { observed } from './a.mjs';
        \\print(observed);
    ,
        &output,
        "/fixture/main.mjs",
        hooks,
        std.testing.allocator,
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("function,function\n", output.buffered());
}

test "module cycles do not hoist a body-leading named function expression" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const modules = [_]HostFixtureModule{
        .{
            .specifier = "./a.mjs",
            .path = "/fixture/a.mjs",
            .source =
            \\import { observed } from './b.mjs';
            \\export const value = function inner() { return 1; };
            \\export const result = observed;
            ,
            .kind = .esm,
        },
        .{
            .specifier = "./b.mjs",
            .path = "/fixture/b.mjs",
            .source =
            \\import { value } from './a.mjs';
            \\let observed;
            \\try { observed = typeof value; }
            \\catch (error) { observed = error.name; }
            \\export { observed };
            ,
            .kind = .esm,
        },
    };
    const host = HostFixture{ .modules = &modules };
    const hooks = hostHooks(&host);

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithHostHooks(
        \\import { result } from './a.mjs';
        \\print(result);
    ,
        &output,
        "/fixture/main.mjs",
        hooks,
        std.testing.allocator,
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("ReferenceError\n", output.buffered());
}

test "W1e: module namespace exposes sorted immutable live export properties" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const modules = [_]HostFixtureModule{
        .{
            .specifier = "./namespace-source.mjs",
            .path = "/fixture/namespace-source.mjs",
            .source =
            \\export function update(next) { omega = next; }
            \\export let omega = 2;
            \\export const alpha = 1;
            ,
            .kind = .esm,
        },
    };
    const host = HostFixture{ .modules = &modules };

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithHostHooks(
        \\import * as namespace from './namespace-source.mjs';
        \\
        \\assert.sameValue(Object.getPrototypeOf(namespace), null);
        \\assert.sameValue(namespace.omega, 2);
        \\namespace.update(7);
        \\assert.sameValue(namespace.omega, 7);
        \\
        \\const descriptor = Object.getOwnPropertyDescriptor(namespace, "omega");
        \\assert.sameValue(descriptor.value, 7);
        \\assert.sameValue(descriptor.writable, true);
        \\assert.sameValue(descriptor.enumerable, true);
        \\assert.sameValue(descriptor.configurable, false);
        \\
        \\let assignmentRejected = false;
        \\try { namespace.omega = 9; }
        \\catch (error) { assignmentRejected = error instanceof TypeError; }
        \\assert.sameValue(assignmentRejected, true);
        \\assert.sameValue(Reflect.set(namespace, "omega", 9), false);
        \\
        \\let defineRejected = false;
        \\try { Object.defineProperty(namespace, "omega", { value: 9 }); }
        \\catch (error) { defineRejected = error instanceof TypeError; }
        \\assert.sameValue(defineRejected, true);
        \\
        \\let deleteRejected = false;
        \\try { delete namespace.omega; }
        \\catch (error) { deleteRejected = error instanceof TypeError; }
        \\assert.sameValue(deleteRejected, true);
        \\assert.sameValue(namespace.omega, 7);
        \\
        \\const keys = Reflect.ownKeys(namespace);
        \\assert.sameValue(keys.length, 4);
        \\assert.sameValue(keys[0], "alpha");
        \\assert.sameValue(keys[1], "omega");
        \\assert.sameValue(keys[2], "update");
        \\assert.sameValue(keys[3], Symbol.toStringTag);
    ,
        &output,
        "/fixture/main.mjs",
        hostHooks(&host),
        std.testing.allocator,
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("", output.buffered());
}

test "module namespace has and super set preserve uninitialized export semantics" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const modules = [_]HostFixtureModule{
        .{
            .specifier = "./self.mjs",
            .path = "/fixture/main.mjs",
            .source = "",
            .kind = .esm,
        },
    };
    const host = HostFixture{ .modules = &modules };

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithHostHooks(
        \\import * as namespace from './self.mjs';
        \\
        \\assert.sameValue('value' in namespace, true);
        \\assert.sameValue(Reflect.has(namespace, 'value'), true);
        \\
        \\class Base { constructor() { return namespace; } }
        \\class Derived extends Base {
        \\  constructor() {
        \\    super();
        \\    super.value = 14;
        \\  }
        \\}
        \\assert.throws(ReferenceError, function() { new Derived(); });
        \\
        \\class NonWritableBase { constructor() { return namespace; } }
        \\Object.defineProperty(NonWritableBase.prototype, 'value', {
        \\  value: 0,
        \\  writable: false,
        \\});
        \\class NonWritableDerived extends NonWritableBase {
        \\  constructor() {
        \\    super();
        \\    super.value = 14;
        \\  }
        \\}
        \\assert.throws(TypeError, function() { new NonWritableDerived(); });
        \\
        \\export let value = 42;
    ,
        &output,
        "/fixture/main.mjs",
        hostHooks(&host),
        std.testing.allocator,
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("", output.buffered());
}

test "W1e: named aliases and namespace reexports share live canonical bindings" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const modules = [_]HostFixtureModule{
        .{
            .specifier = "./binding-source.mjs",
            .path = "/fixture/binding-source.mjs",
            .source =
            \\export let value = 3;
            \\export const token = {};
            \\export function setValue(next) { value = next; }
            ,
            .kind = .esm,
        },
        .{
            .specifier = "./binding-bridge.mjs",
            .path = "/fixture/binding-bridge.mjs",
            .source =
            \\export * as namespace from './binding-source.mjs';
            \\export { value as alias, token, setValue } from './binding-source.mjs';
            ,
            .kind = .esm,
        },
    };
    const host = HostFixture{ .modules = &modules };

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithHostHooks(
        \\import { alias, token, setValue, namespace as reexportedNamespace } from './binding-bridge.mjs';
        \\import { value as directAlias, token as directToken } from './binding-source.mjs';
        \\import * as directNamespace from './binding-source.mjs';
        \\
        \\assert.sameValue(alias, 3);
        \\assert.sameValue(alias, directAlias);
        \\assert.sameValue(token, directToken);
        \\assert.sameValue(token, directNamespace.token);
        \\assert.sameValue(reexportedNamespace, directNamespace);
        \\
        \\setValue(41);
        \\assert.sameValue(alias, 41);
        \\assert.sameValue(directAlias, 41);
        \\assert.sameValue(directNamespace.value, 41);
        \\assert.sameValue(reexportedNamespace.value, 41);
        \\assert.sameValue(reexportedNamespace.token, token);
    ,
        &output,
        "/fixture/main.mjs",
        hostHooks(&host),
        std.testing.allocator,
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("", output.buffered());
}

test "W1e: missing indirect export precedes bad import wiring" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const modules = [_]HostFixtureModule{
        .{
            .specifier = "./empty.mjs",
            .path = "/fixture/empty.mjs",
            .source = "export const present = 1;",
            .kind = .esm,
        },
        .{
            .specifier = "./link-failures.mjs",
            .path = "/fixture/link-failures.mjs",
            .source =
            \\export { missingIndirect as indirectFirst } from './empty.mjs';
            \\import { badImport } from './empty.mjs';
            \\export const marker = typeof badImport;
            ,
            .kind = .esm,
        },
    };
    const host = HostFixture{ .modules = &modules };

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    // QuickJS js_inner_module_linking validates every indirect export before
    // wiring import_entries. Its error call uses the re-exporting module and
    // public export name, so this must not report badImport or empty.mjs.
    try std.testing.expectError(
        error.SyntaxError,
        js.evalFileModuleGraphWithHostHooks(
            "import './link-failures.mjs';",
            &output,
            "/fixture/main.mjs",
            hostHooks(&host),
            std.testing.allocator,
        ),
    );
    try std.testing.expect(js.context.hasException());

    var exception = try js.takeExceptionInfo();
    defer exception.deinit();
    const message = try exception.getMessage(std.testing.allocator);
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings(
        "SyntaxError: Could not find export 'indirectFirst' in module '/fixture/link-failures.mjs'",
        message,
    );
    try std.testing.expectEqualStrings("", output.buffered());
}

test "W1e: one host source load spans declaration body TLA resume and dynamic import" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const modules = [_]HostFixtureModule{
        .{
            .specifier = "./single-load.mjs",
            .path = "/fixture/single-load.mjs",
            .source =
            \\globalThis.__w1eSingleLoadRuns = (globalThis.__w1eSingleLoadRuns || 0) + 1;
            \\globalThis.__w1eSingleLoadPhases = ["body"];
            \\export function read() { return value; }
            \\export let value = 1;
            \\await 0;
            \\value = 2;
            \\globalThis.__w1eSingleLoadPhases.push("resume");
            ,
            .kind = .esm,
        },
    };
    var resolve_calls: usize = 0;
    var load_calls: usize = 0;
    const host = HostFixture{
        .modules = &modules,
        .resolve_calls = &resolve_calls,
        .load_calls = &load_calls,
    };

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithHostHooks(
        \\import * as staticNamespace from './single-load.mjs';
        \\
        \\assert.sameValue(staticNamespace.value, 2);
        \\assert.sameValue(staticNamespace.read(), 2);
        \\assert.sameValue(globalThis.__w1eSingleLoadRuns, 1);
        \\assert.sameValue(globalThis.__w1eSingleLoadPhases.join(","), "body,resume");
        \\
        \\const dynamicNamespace = await import('./single-load.mjs');
        \\assert.sameValue(dynamicNamespace, staticNamespace);
        \\assert.sameValue(dynamicNamespace.value, 2);
        \\assert.sameValue(dynamicNamespace.read(), 2);
        \\assert.sameValue(globalThis.__w1eSingleLoadRuns, 1);
        \\assert.sameValue(globalThis.__w1eSingleLoadPhases.join(","), "body,resume");
    ,
        &output,
        "/fixture/main.mjs",
        hostHooks(&host),
        std.testing.allocator,
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expect(resolve_calls > 0);
    // Resolution may be repeated for normalization, but handing source to the
    // compiler is a one-shot host operation for one canonical module record.
    try std.testing.expectEqual(@as(usize, 1), load_calls);
    try std.testing.expectEqualStrings("", output.buffered());
}

fn retainedModuleExportCell(
    record: *const core.module.ModuleRecord,
    export_name: core.Atom,
) ?*core.VarRef {
    for (record.exports, 0..) |entry, index| {
        if (entry.export_name != export_name) continue;
        const value = record.retainedExportCellValue(@intCast(index)) orelse return null;
        return core.VarRef.fromValue(value);
    }
    return null;
}

test "same module specifier keeps record cells namespace import meta and error state per Realm" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const realm_b = try core.JSContext.create(js.runtime);
    defer realm_b.destroy();
    var facade_a = zjs.JSContext.borrowCore(js.context);
    var facade_b = zjs.JSContext.borrowCore(realm_b);
    const filename = "w1e-shared-module-identity.mjs";

    try std.testing.expectError(
        error.JSException,
        facade_a.eval(
            \\globalThis.__w1eRuns = (globalThis.__w1eRuns || 0) + 1;
            \\export let value = 11;
            \\export function realmFunction() { return value; }
            \\export const meta = import.meta;
            \\throw new Error("realm A only");
        , .{ .mode = .module, .filename = filename }),
    );
    if (js.context.hasException()) {
        const exception = js.context.takeException();
        exception.free(js.runtime);
    }

    const result_b = try facade_b.eval(
        \\globalThis.__w1eRuns = (globalThis.__w1eRuns || 0) + 1;
        \\export let value = 22;
        \\export function realmFunction() { return value; }
        \\export const meta = import.meta;
    , .{ .mode = .module, .filename = filename });
    defer result_b.free(js.runtime);

    const module_name = try js.runtime.internAtom(filename);
    defer js.runtime.atoms.free(module_name);
    const record_a = js.context.modules.find(module_name) orelse return error.TestUnexpectedResult;
    const record_b = realm_b.modules.find(module_name) orelse return error.TestUnexpectedResult;
    try std.testing.expect(record_a != record_b);
    try std.testing.expectEqual(core.module.Status.errored, record_a.status);
    try std.testing.expectEqual(core.module.Status.evaluated, record_b.status);
    try std.testing.expect(record_a.eval_exception != null);
    try std.testing.expect(record_b.eval_exception == null);

    const meta_a = record_a.import_meta orelse return error.TestUnexpectedResult;
    const meta_b = record_b.import_meta orelse return error.TestUnexpectedResult;
    try std.testing.expect(!meta_a.same(meta_b));

    const value_name = try js.runtime.internAtom("value");
    defer js.runtime.atoms.free(value_name);
    const value_a_cell = retainedModuleExportCell(record_a, value_name) orelse return error.TestUnexpectedResult;
    const value_b_cell = retainedModuleExportCell(record_b, value_name) orelse return error.TestUnexpectedResult;
    try std.testing.expect(value_a_cell != value_b_cell);

    const function_name = try js.runtime.internAtom("realmFunction");
    defer js.runtime.atoms.free(function_name);
    const function_a_cell = retainedModuleExportCell(record_a, function_name) orelse return error.TestUnexpectedResult;
    const function_b_cell = retainedModuleExportCell(record_b, function_name) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!function_a_cell.varRefValue().same(function_b_cell.varRefValue()));

    const namespace_a = try engine.exec.module.moduleNamespaceValue(js.context, module_name);
    defer namespace_a.free(js.runtime);
    const namespace_b = try engine.exec.module.moduleNamespaceValue(realm_b, module_name);
    defer namespace_b.free(js.runtime);
    try std.testing.expect(!namespace_a.same(namespace_b));

    const runs_name = try js.runtime.internAtom("__w1eRuns");
    defer js.runtime.atoms.free(runs_name);
    const global_a = try engine.exec.zjs_vm.contextGlobal(js.context);
    const global_b = try engine.exec.zjs_vm.contextGlobal(realm_b);
    const runs_a = try global_a.getProperty(runs_name);
    defer runs_a.free(js.runtime);
    const runs_b = try global_b.getProperty(runs_name);
    defer runs_b.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 1), runs_a.asInt32());
    try std.testing.expectEqual(@as(?i32, 1), runs_b.asInt32());
}

test "context module eval does not rerun evaluated or errored records" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const evaluated_filename = "context-eval-evaluated-once.mjs";
    const first = try js.evalWithOptions(
        \\globalThis.__contextEvaluatedRuns =
        \\  (globalThis.__contextEvaluatedRuns || 0) + 1;
        \\export const value = 1;
    , .{ .mode = .module, .filename = evaluated_filename });
    defer first.free(js.runtime);
    try std.testing.expect(first.isUndefined());

    const second = try js.evalWithOptions(
        \\globalThis.__contextEvaluatedRuns += 100;
        \\export const value = 2;
    , .{ .mode = .module, .filename = evaluated_filename });
    defer second.free(js.runtime);
    try std.testing.expect(second.isUndefined());

    const evaluated_name = try js.runtime.internAtom("__contextEvaluatedRuns");
    defer js.runtime.atoms.free(evaluated_name);
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const evaluated_runs = try global.getProperty(evaluated_name);
    defer evaluated_runs.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 1), evaluated_runs.asInt32());

    const errored_filename = "context-eval-errored-once.mjs";
    try std.testing.expectError(
        error.JSException,
        js.evalWithOptions(
            \\globalThis.__contextErroredRuns =
            \\  (globalThis.__contextErroredRuns || 0) + 1;
            \\throw new Error("cached context module failure");
        , .{ .mode = .module, .filename = errored_filename }),
    );
    const errored_name = try js.runtime.internAtom(errored_filename);
    defer js.runtime.atoms.free(errored_name);
    const errored_record = js.context.modules.find(errored_name) orelse
        return error.TestUnexpectedResult;
    const cached_exception = errored_record.eval_exception orelse
        return error.TestUnexpectedResult;
    const first_exception = js.context.takeException();
    defer first_exception.free(js.runtime);
    try std.testing.expect(first_exception.same(cached_exception));

    try std.testing.expectError(
        error.JSException,
        js.evalWithOptions(
            \\globalThis.__contextErroredRuns += 100;
            \\export const value = 2;
        , .{ .mode = .module, .filename = errored_filename }),
    );
    const second_exception = js.context.takeException();
    defer second_exception.free(js.runtime);
    try std.testing.expect(second_exception.same(cached_exception));

    const errored_runs_name = try js.runtime.internAtom("__contextErroredRuns");
    defer js.runtime.atoms.free(errored_runs_name);
    const errored_runs = try global.getProperty(errored_runs_name);
    defer errored_runs.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 1), errored_runs.asInt32());
}

test "context module eval resumes TLA from its reaction FIFO position" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.evalWithOptions(
        \\const actual = [];
        \\let resolveAwaited;
        \\const awaited = new Promise(resolve => resolveAwaited = resolve);
        \\awaited.then(() => actual.push("before"));
        \\Promise.resolve().then(() => {
        \\  awaited.then(() => actual.push("after"));
        \\  resolveAwaited(42);
        \\});
        \\const value = await awaited;
        \\actual.push("module:" + value);
        \\let rejection = "not caught";
        \\try {
        \\  await Promise.reject(new Error("tla rejection"));
        \\} catch (error) {
        \\  rejection = error.message;
        \\}
        \\Promise.resolve().then(() => {
        \\  globalThis.__contextTlaResult =
        \\    actual.join(",") + "|" + rejection;
        \\});
    , .{ .mode = .module, .filename = "context-eval-tla-fifo.mjs" });
    defer result.free(js.runtime);

    const checked = try js.eval(
        \\assert.sameValue(
        \\  globalThis.__contextTlaResult,
        \\  "before,module:42,after|tla rejection"
        \\);
    );
    defer checked.free(js.runtime);
}

test "Runtime loader keeps same-path TLA continuations and waiters in parent and child Realms" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var parent_facade = zjs.JSContext.borrowCore(js.context);
    _ = try parent_facade.globalObject();

    const dir = ".zig-cache/w1e-cross-realm-tla";
    const main_path = dir ++ "/main.js";
    const module_path = dir ++ "/shared.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = module_path,
        .data =
        \\globalThis.__w1eTlaRuns = (globalThis.__w1eTlaRuns || 0) + 1;
        \\await 0;
        \\globalThis.__w1eTlaRuns += 10;
        \\export const value = globalThis.__w1eTlaRuns;
        ,
    });

    var state = engine.exec.module_graph.DynamicImportState{
        .runtime = js.runtime,
        .output = null,
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .max_source_size = 4096,
    };
    defer state.deinit();
    var loader_scope = engine.exec.module_graph.installDynamicImport(&state);
    defer loader_scope.deinit();

    const child_holder = try engine.exec.call.createRealmObject(js.context);
    defer child_holder.free(js.runtime);
    const child_record = try property_ops.expectObject(child_holder);
    const child = child_record.realmContext() orelse return error.TestUnexpectedResult;
    const parent_global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const child_global = try engine.exec.zjs_vm.contextGlobal(child);

    const specifier = try engine.exec.value_ops.createStringValue(js.runtime, "./shared.mjs");
    defer specifier.free(js.runtime);
    const parent_first = try engine.exec.module_graph.enqueueDynamicImportJob(js.context, parent_global, null, main_path, specifier);
    defer parent_first.free(js.runtime);
    const child_first = try engine.exec.module_graph.enqueueDynamicImportJob(child, child_global, null, main_path, specifier);
    defer child_first.free(js.runtime);
    const parent_second = try engine.exec.module_graph.enqueueDynamicImportJob(js.context, parent_global, null, main_path, specifier);
    defer parent_second.free(js.runtime);
    const child_second = try engine.exec.module_graph.enqueueDynamicImportJob(child, child_global, null, main_path, specifier);
    defer child_second.free(js.runtime);

    // The first import in each Realm creates one TLA continuation and waiter;
    // the second sees that Realm's evaluating record and adds only a waiter.
    // All four dynamic-import jobs precede the Promise reactions they enqueue.
    for (0..4) |_| {
        try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(child, null, child_global)) == .success);
    }
    try std.testing.expectEqual(@as(usize, 2), state.owned_continuations.items.len);
    try std.testing.expectEqual(@as(usize, 4), state.owned_waiters.items.len);
    try std.testing.expect(state.owned_continuations.items[0].realm.borrow() == js.context);
    try std.testing.expect(state.owned_continuations.items[1].realm.borrow() == child);
    try std.testing.expect(state.owned_waiters.items[0].realm.borrow() == js.context);
    try std.testing.expect(state.owned_waiters.items[1].realm.borrow() == child);
    try std.testing.expect(state.owned_waiters.items[2].realm.borrow() == js.context);
    try std.testing.expect(state.owned_waiters.items[3].realm.borrow() == child);

    // The facade selects only the Runtime. Each continuation resumes and each
    // same-path waiter settles through its own retained Realm.
    try state.runJobs(child);
    try std.testing.expectEqual(@as(usize, 0), state.owned_continuations.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.owned_waiters.items.len);

    const PromiseResult = struct {
        fn get(value: core.JSValue) !core.JSValue {
            const promise = try property_ops.expectObject(value);
            if (promise.promiseIsRejected()) return error.TestUnexpectedResult;
            return promise.promiseResult() orelse error.TestUnexpectedResult;
        }
    };
    const parent_namespace_first = try PromiseResult.get(parent_first);
    const parent_namespace_second = try PromiseResult.get(parent_second);
    const child_namespace_first = try PromiseResult.get(child_first);
    const child_namespace_second = try PromiseResult.get(child_second);
    try std.testing.expect(parent_namespace_first.same(parent_namespace_second));
    try std.testing.expect(child_namespace_first.same(child_namespace_second));
    try std.testing.expect(!parent_namespace_first.same(child_namespace_first));

    const runs_name = try js.runtime.internAtom("__w1eTlaRuns");
    defer js.runtime.atoms.free(runs_name);
    const parent_runs = try parent_global.getProperty(runs_name);
    defer parent_runs.free(js.runtime);
    const child_runs = try child_global.getProperty(runs_name);
    defer child_runs.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 11), parent_runs.asInt32());
    try std.testing.expectEqual(@as(?i32, 11), child_runs.asInt32());

    const resolved_path = try std.fs.path.resolve(std.testing.allocator, &.{module_path});
    defer std.testing.allocator.free(resolved_path);
    const module_name = try js.runtime.internAtom(resolved_path);
    defer js.runtime.atoms.free(module_name);
    const parent_module = js.context.modules.find(module_name) orelse return error.TestUnexpectedResult;
    const child_module = child.modules.find(module_name) orelse return error.TestUnexpectedResult;
    try std.testing.expect(parent_module != child_module);
    try std.testing.expectEqual(core.module.Status.evaluated, parent_module.status);
    try std.testing.expectEqual(core.module.Status.evaluated, child_module.status);
}

test "module top-level await resumes in Promise reaction FIFO order" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const registry = engine.exec.standard_globals;
    registry.configureRuntime(js.runtime);

    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithOutput(
        \\var actual = [];
        \\Promise.resolve(0)
        \\  .then(() => actual.push("tick 1"))
        \\  .then(() => actual.push("tick 2"))
        \\  .then(() => actual.push("tick 3"))
        \\  .then(() => actual.push("tick 4"))
        \\  .then(() => print("done:" + actual.join(",")));
        \\await 1;
        \\actual.push("await 1");
        \\await 2;
        \\actual.push("await 2");
        \\await 3;
        \\actual.push("await 3");
        \\await 4;
        \\actual.push("await 4");
    ,
        &output,
        "module-tla-promise-fifo.mjs",
        std.testing.io,
        std.testing.allocator,
        4096,
    );
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings(
        "done:tick 1,await 1,tick 2,await 2,tick 3,await 3,tick 4,await 4\n",
        output.buffered(),
    );
}

test "module await reaction keeps its position on the awaited Promise" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const registry = engine.exec.standard_globals;
    registry.configureRuntime(js.runtime);

    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithOutput(
        \\let resolveAwaited;
        \\const awaited = new Promise((resolve) => resolveAwaited = resolve);
        \\const actual = [];
        \\awaited.then(() => actual.push("before"));
        \\Promise.resolve().then(() => {
        \\  awaited.then(() => actual.push("after"));
        \\  resolveAwaited();
        \\});
        \\await awaited;
        \\actual.push("module");
        \\Promise.resolve().then(() => print(actual.join(",")));
    ,
        &output,
        "module-await-reaction-position.mjs",
        std.testing.io,
        std.testing.allocator,
        4096,
    );
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("before,module,after\n", output.buffered());
}

test "module TLA continuation OOM retains FIFO node for retry" {
    const ArmableOneShotAllocator = struct {
        backing: std.mem.Allocator,
        armed: bool = false,
        induced: bool = false,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
            };
        }

        fn arm(self: *@This()) void {
            self.armed = true;
            self.induced = false;
        }

        fn disarm(self: *@This()) void {
            self.armed = false;
        }

        fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (self.armed and !self.induced) {
                self.induced = true;
                return null;
            }
            return self.backing.rawAlloc(len, alignment, ret_addr);
        }

        fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.backing.rawResize(memory, alignment, new_len, ret_addr);
        }

        fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
        }

        fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.backing.rawFree(memory, alignment, ret_addr);
        }
    };

    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const registry = engine.exec.standard_globals;
    registry.configureRuntime(js.runtime);

    const dir = ".zig-cache/module-tla-continuation-oom-retry-test";
    const main_path = dir ++ "/main.js";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = dir ++ "/a.mjs",
        .data =
        \\globalThis.__aRetry = (globalThis.__aRetry || 0) + 1;
        \\await 1;
        \\globalThis.__aRetry += 10;
        \\await 2;
        \\globalThis.__aRetry += 100;
        \\export const value = "a";
        ,
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = dir ++ "/b.mjs",
        .data =
        \\globalThis.__bRetry = (globalThis.__bRetry || 0) + 1;
        \\await 1;
        \\globalThis.__bRetry += 10;
        \\await 2;
        \\globalThis.__bRetry += 100;
        \\export const value = "b";
        ,
    });

    var injector = ArmableOneShotAllocator{ .backing = std.testing.allocator };
    var state = engine.exec.module_graph.DynamicImportState{
        .runtime = js.runtime,
        .output = null,
        .io = std.testing.io,
        .allocator = injector.allocator(),
        .max_source_size = 4096,
    };
    defer state.deinit();
    var dynamic_import_scope = engine.exec.module_graph.installDynamicImport(&state);
    defer dynamic_import_scope.deinit();

    const setup = try js.evalWithOptions(
        \\globalThis.__paRetry = import("./a.mjs");
        \\globalThis.__pbRetry = import("./b.mjs");
    , .{ .filename = main_path });
    setup.free(js.runtime);
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    // Script eval drains the two dynamic-import jobs, but TLA resumptions stay
    // in the loader state's owned continuation FIFO until state.runJobs().
    try std.testing.expectEqual(@as(usize, 2), state.owned_continuations.items.len);
    try std.testing.expect(std.mem.endsWith(u8, state.owned_continuations.items[0].path, "/a.mjs"));
    try std.testing.expect(std.mem.endsWith(u8, state.owned_continuations.items[1].path, "/b.mjs"));
    const a_counter_atom = try js.runtime.internAtom("__aRetry");
    defer js.runtime.atoms.free(a_counter_atom);
    const b_counter_atom = try js.runtime.internAtom("__bRetry");
    defer js.runtime.atoms.free(b_counter_atom);

    // The next state-allocation is the source copy for A's newly-yielded
    // continuation. The old generator has already resumed, so dropping the
    // node here strands the exposed import Promise and cannot be repaired by
    // simply running A's previous continuation again.
    injector.arm();
    try std.testing.expectError(error.OutOfMemory, state.runJobs(js.context));
    try std.testing.expect(injector.induced);
    try std.testing.expectEqual(@as(usize, 2), state.owned_continuations.items.len);
    try std.testing.expect(std.mem.endsWith(u8, state.owned_continuations.items[0].path, "/a.mjs"));
    try std.testing.expect(std.mem.endsWith(u8, state.owned_continuations.items[1].path, "/b.mjs"));
    const a_after_oom = try global.getProperty(a_counter_atom);
    defer a_after_oom.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 11), a_after_oom.asInt32());
    const b_after_oom = try global.getProperty(b_counter_atom);
    defer b_after_oom.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 1), b_after_oom.asInt32());

    injector.disarm();
    try state.runJobs(js.context);
    try std.testing.expectEqual(@as(usize, 0), state.owned_continuations.items.len);

    const a_counter = try global.getProperty(a_counter_atom);
    defer a_counter.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 111), a_counter.asInt32());
    const b_counter = try global.getProperty(b_counter_atom);
    defer b_counter.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 111), b_counter.asInt32());

    inline for (.{ "__paRetry", "__pbRetry" }) |name| {
        const promise_atom = try js.runtime.internAtom(name);
        defer js.runtime.atoms.free(promise_atom);
        const promise_value = try global.getProperty(promise_atom);
        defer promise_value.free(js.runtime);
        const promise = try property_ops.expectObject(promise_value);
        try std.testing.expect(promise.promiseResult() != null);
        try std.testing.expect(!promise.promiseIsRejected());
    }
}

test "async module dependency does not preempt an independent sibling" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const registry = engine.exec.standard_globals;
    registry.configureRuntime(js.runtime);

    const dir = ".zig-cache/module-async-sibling-order-test";
    const main_path = dir ++ "/main.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = dir ++ "/b.mjs",
        .data = "globalThis.__moduleOrder = globalThis.__moduleOrder || [];\n" ++
            "globalThis.__moduleOrder.push('b-start');\n" ++
            "await 0;\n" ++
            "globalThis.__moduleOrder.push('b-end');\n",
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = dir ++ "/a.mjs",
        .data = "import './b.mjs';\nglobalThis.__moduleOrder.push('a');\n",
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = dir ++ "/c.mjs",
        .data = "globalThis.__moduleOrder = globalThis.__moduleOrder || [];\n" ++
            "globalThis.__moduleOrder.push('c');\n",
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = main_path,
        .data = "import './a.mjs';\n" ++
            "import './c.mjs';\n" ++
            "print(globalThis.__moduleOrder.join(','));\n",
    });

    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, main_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(source);
    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithOutput(
        source,
        &output,
        main_path,
        std.testing.io,
        std.testing.allocator,
        4096,
    );
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("b-start,c,b-end,a\n", output.buffered());
}

test "import bytes module creates immutable ArrayBuffer backing store" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const dir = ".zig-cache/module-import-bytes-immutable-test";
    const bytes_path = dir ++ "/payload.bin";
    const main_path = dir ++ "/main.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = bytes_path, .data = "ABC" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = main_path, .data =
        \\import value from "./payload.bin" with { type: "bytes" };
        \\print(value instanceof Uint8Array);
        \\print(value.buffer instanceof ArrayBuffer);
        \\print(value.length);
        \\print(value[0]);
        \\print(value.buffer.immutable);
        \\print(Object.hasOwn(value.buffer, "immutable"));
        \\try { value.buffer.resize(0); print("resize-ok"); } catch (e) { print(e.name); }
        \\try { value.buffer.transfer(); print("transfer-ok"); } catch (e) { print(e.name); }
    });

    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, main_path, std.testing.allocator, .limited(2048));
    defer std.testing.allocator.free(source);
    const result = try js.evalFileModuleGraphWithOutput(source, &output, main_path, std.testing.io, std.testing.allocator, 2048);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("true\ntrue\n3\n65\ntrue\nfalse\nTypeError\nTypeError\n", output.buffered());
}

const HostFixtureModule = struct {
    specifier: []const u8,
    path: []const u8,
    source: []const u8,
    kind: helpers.TestEngine.HostHooks.ModuleKind,
};

const HostFixture = struct {
    modules: []const HostFixtureModule,
    resolve_calls: ?*usize = null,
    load_calls: ?*usize = null,

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

fn hostHooks(host: *const HostFixture) helpers.TestEngine.HostHooks {
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
) anyerror!helpers.TestEngine.HostHooks.ResolvedModule {
    _ = referrer;
    const host: *const HostFixture = @ptrCast(@alignCast(ptr));
    if (host.resolve_calls) |calls| calls.* += 1;
    const module = host.findBySpecifierOrPath(specifier) orelse return error.ModuleNotFound;
    return .{
        .specifier = try allocator.dupe(u8, specifier),
        .path = try allocator.dupe(u8, module.path),
        .kind = module.kind,
    };
}

fn loadFixtureModule(
    ptr: *anyopaque,
    resolved: helpers.TestEngine.HostHooks.ResolvedModule,
    allocator: std.mem.Allocator,
) anyerror!helpers.TestEngine.HostHooks.LoadedModule {
    const host: *const HostFixture = @ptrCast(@alignCast(ptr));
    if (host.load_calls) |calls| calls.* += 1;
    const module = host.findByPath(resolved.path) orelse return error.ModuleNotFound;
    return .{
        .source = module.source,
        .path = try allocator.dupe(u8, module.path),
        .kind = module.kind,
        .owned = false,
    };
}

// Bootstrap-integration tests relocated from src/exec/{call,zjs_vm}.zig during
// Phase 6b-3 STEP 7B. They build a bare `core.JSRuntime` and install the
// standard globals through `rt.installStandardGlobals`; the helper wires the
// exec-owned bootstrap seam before installation.

test "host global bootstrap installs and tears down builtin plus host domains" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    _ = try global.ensureRealmPayload(rt);
    defer global.value().free(rt);

    try helpers.installHostGlobalsBare(rt, global);
}

test "engine eval host globals and throw intrinsic tear down cleanly" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    _ = try global.ensureRealmPayload(rt);
    defer global.value().free(rt);

    try helpers.installHostGlobalsBare(rt, global);

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);

    const value = try engine.exec.eval_entry.eval(ctx, "print(1);", .{ .output = &output });
    defer value.free(rt);

    try std.testing.expect(value.isUndefined());
    try std.testing.expectEqualStrings("1\n", output.buffered());
}

const ReflectActiveRootSymbolProbe = struct {
    rt: *core.JSRuntime,
    atom_id: u32,
    saw_symbol: bool = false,
    trace_failed: bool = false,

    fn trigger(context: ?*anyopaque, size: usize) void {
        _ = size;
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const saved_trigger_fn = self.rt.memory.trigger_gc_fn;
        const saved_trigger_ctx = self.rt.memory.trigger_gc_ctx;
        self.rt.memory.trigger_gc_fn = null;
        self.rt.memory.trigger_gc_ctx = null;
        defer {
            self.rt.memory.trigger_gc_fn = saved_trigger_fn;
            self.rt.memory.trigger_gc_ctx = saved_trigger_ctx;
        }
        _ = self.rt.runObjectCycleRemoval();
        self.saw_symbol = self.rt.atoms.name(self.atom_id) != null;
    }
};

fn reflectTestSetArrayIndex(rt: *core.JSRuntime, array: *core.Object, index: u32, value: core.JSValue) !void {
    try array.defineOwnProperty(rt, core.atom.atomFromUInt32(index), core.Descriptor.data(value, true, true, true));
    if (array.arrayLength() <= index) array.setArrayLength(index + 1);
}

test "reflect construct roots argument list while resolving prototype" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    // `reflectConstruct` routes builtin construction (Array, like Date/RegExp/
    // String) through the internal record table, so the realm globals must be
    // installed to wire `rt.internal_builtins` before the construct record is
    // reachable.
    const realm_global = try core.Object.create(rt, core.class.ids.object, null);
    _ = try realm_global.ensureRealmPayload(rt);
    defer realm_global.value().free(rt);
    engine.exec.standard_globals.configureRuntime(rt);
    try rt.installStandardGlobals(realm_global);

    const target = try core.function.nativeFunction(ctx, "Array", 1);
    defer target.free(rt);
    const target_object = try core.Object.expect(target);
    try std.testing.expect(try target_object.addArrayBuiltinMarker(rt, .constructor));
    const new_target = try core.function.nativeFunction(ctx, "Array", 1);
    defer new_target.free(rt);
    const new_target_object = engine.exec.call.thisObject(new_target) orelse return error.TypeError;
    try new_target_object.defineOwnProperty(rt, core.atom.ids.prototype, core.Descriptor.data(core.JSValue.int32(1), true, false, true));

    const args_object = try core.Object.createArray(rt, null);
    var args_alive = true;
    defer if (args_alive) args_object.value().free(rt);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-reflect-construct-argument-root");
    const symbol_value = try rt.symbolValue(symbol_atom);
    try reflectTestSetArrayIndex(rt, args_object, 0, symbol_value);
    symbol_value.free(rt);

    const saved_trigger_fn = rt.memory.trigger_gc_fn;
    const saved_trigger_ctx = rt.memory.trigger_gc_ctx;
    var probe = ReflectActiveRootSymbolProbe{
        .rt = rt,
        .atom_id = symbol_atom,
    };
    rt.memory.trigger_gc_fn = ReflectActiveRootSymbolProbe.trigger;
    rt.memory.trigger_gc_ctx = &probe;
    defer {
        rt.memory.trigger_gc_fn = saved_trigger_fn;
        rt.memory.trigger_gc_ctx = saved_trigger_ctx;
    }

    var globals = [_]engine.exec.globals.Slot{};
    const reflect_args = [_]core.JSValue{ target, args_object.value(), new_target };
    const result = try engine.exec.reflect_ops.reflectConstruct(ctx, &reflect_args, globals[0..]);
    var result_alive = true;
    defer if (result_alive) result.free(rt);

    try std.testing.expect(!probe.trace_failed);
    try std.testing.expect(probe.saw_symbol);

    args_object.value().free(rt);
    args_alive = false;
    result.free(rt);
    result_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

// ===========================================================================
// Branch-to-end forms. The register-resident dispatch carries no hot falloff
// check (qjs-aligned), so every parser epilogue must terminate branch-to-end
// paths with a real return op and the verifier must reject reachable falloff.
// Each test pins the observable completion value.
// ===========================================================================

test "short conditional branches preserve immediate and full ToBoolean semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function choose(value) { if (value) return 1; return 0; }
        \\function orValue(value) { return value || 9; }
        \\function andValue(value) { return value && 9; }
        \\assert.sameValue(choose(-1), 1);
        \\assert.sameValue(choose(0), 0);
        \\assert.sameValue(choose(1), 1);
        \\assert.sameValue(choose(false), 0);
        \\assert.sameValue(choose(true), 1);
        \\assert.sameValue(choose(null), 0);
        \\assert.sameValue(choose(undefined), 0);
        \\assert.sameValue(choose(-0), 0);
        \\assert.sameValue(choose(0.5), 1);
        \\assert.sameValue(choose(""), 0);
        \\assert.sameValue(choose("x"), 1);
        \\assert.sameValue(choose({}), 1);
        \\assert.sameValue(orValue(0), 9);
        \\assert.sameValue(orValue(4), 4);
        \\assert.sameValue(andValue(0), 0);
        \\assert.sameValue(andValue(4), 9);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "if-throw fall-off form returns undefined (if_false8 branch-to-end)" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function fallOffIfThrow(x) { if (x) throw 1; }
        \\assert.sameValue(fallOffIfThrow(false), undefined);
        \\var threw = false;
        \\try { fallOffIfThrow(true); } catch (e) { threw = (e === 1); }
        \\assert.sameValue(threw, true);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "if-return fall-off form returns undefined on the fall-through leg" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function fallOffIfReturn(x) { if (x) return 1; }
        \\assert.sameValue(fallOffIfReturn(true), 1);
        \\assert.sameValue(fallOffIfReturn(false), undefined);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "else-return goto-to-end form returns undefined on the taken if leg" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function fallOffElseReturn(x) { if (x) { 1; } else return 2; }
        \\assert.sameValue(fallOffElseReturn(true), undefined);
        \\assert.sameValue(fallOffElseReturn(false), 2);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "nested-block branch-to-end survives trailing scope cleanup lowering" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Parser-phase target points at the block's leave_scope/close_loc run;
    // lowering removes it, leaving the resolved target == code_end. The
    // epilogue's jump-to-end scan must treat the trailing cleanup run as an
    // end target and still append the terminator.
    const result = try js.eval(
        \\function fallOffNestedBlock(c) { { let x; if (c) throw 1; } }
        \\assert.sameValue(fallOffNestedBlock(false), undefined);
        \\function fallOffCaptured(c) { { let x = 1; if (c) throw 2; var probe = function () { return x; }; } return probe(); }
        \\assert.sameValue(fallOffCaptured(false), 1);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "arrow block body branch-to-end returns undefined" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var fallOffArrow = (x) => { if (x) throw 3; };
        \\assert.sameValue(fallOffArrow(false), undefined);
        \\var fallOffArrowReturn = (x) => { if (x) return 4; };
        \\assert.sameValue(fallOffArrowReturn(true), 4);
        \\assert.sameValue(fallOffArrowReturn(false), undefined);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "generator branch-to-end completes with undefined value" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function* fallOffGen(x) { if (x) throw 4; yield 1; }
        \\var it = fallOffGen(false);
        \\assert.sameValue(it.next().value, 1);
        \\var r = it.next();
        \\assert.sameValue(r.done, true);
        \\assert.sameValue(r.value, undefined);
        \\function* fallOffGenNoYield(x) { if (x) throw 5; }
        \\var r2 = fallOffGenNoYield(false).next();
        \\assert.sameValue(r2.done, true);
        \\assert.sameValue(r2.value, undefined);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "eval and script completion end in an explicit value return" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Direct/indirect eval bodies end with `get_loc <ret>; return`.
    const result = try js.eval(
        \\assert.sameValue(eval("if (false) throw 5;"), undefined);
        \\assert.sameValue(eval("1 + 2"), 3);
        \\assert.sameValue(eval("{ let x; if (false) throw 6; }"), undefined);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());

    // Script completion (<repl> return_completion form) uses the same explicit
    // value-return epilogue at the top level.
    const repl_undef = try js.evalWithOptions("if (false) throw 7;", .{ .filename = "<repl>" });
    defer repl_undef.free(js.runtime);
    try std.testing.expect(repl_undef.isUndefined());

    const repl_value = try js.evalWithOptions("40 + 2", .{ .filename = "<repl>" });
    defer repl_value.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 42), repl_value.asInt32());
}

test "eval preserves completion through nested shared finalizers" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(eval("1; try { 2; } finally { 3; }"), 2);
        \\assert.sameValue(eval("1; try { try { 2; } finally { 3; } } finally { 4; }"), 2);
        \\assert.sameValue(eval("1; try { throw 5; } catch (error) { error + 1; } finally { 7; }"), 6);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "module top-level branch-to-end gets a terminator (no fall-off)" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalModule(
        \\if (false) throw 9;
    );
    defer result.free(js.runtime);
}

test "W1d: module import.meta identity survives methods and nested closures" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalModule(
        \\const rootMeta = import.meta;
        \\class Holder {
        \\  read() { return import.meta; }
        \\}
        \\function nested() {
        \\  const arrow = () => import.meta;
        \\  return [import.meta, arrow()];
        \\}
        \\const [nestedMeta, arrowMeta] = nested();
        \\if (new Holder().read() !== rootMeta ||
        \\    nestedMeta !== rootMeta ||
        \\    arrowMeta !== rootMeta) {
        \\  throw new Error("import.meta identity escaped its module");
        \\}
    );
    defer result.free(js.runtime);
}

test "module function declaration cells do not leak onto the global object" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const module_result = try js.evalModule(
        \\function __moduleLocalHoist() {}
        \\export function __moduleExportHoist() {}
        \\export default function __moduleDefaultHoist() {}
    );
    defer module_result.free(js.runtime);

    const probe_result = try js.eval(
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(globalThis, "__moduleLocalHoist"), false);
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(globalThis, "__moduleExportHoist"), false);
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(globalThis, "__moduleDefaultHoist"), false);
    );
    defer probe_result.free(js.runtime);
}

test "call consumers derive receiver and direct-eval provenance from the final opcode" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\  const __call_consumer_local = 17;
        \\  const holder = { get() { return eval; } };
        \\  assert.sameValue(holder.get()("typeof __call_consumer_local"), "undefined");
        \\  assert.sameValue((eval)("__call_consumer_local"), 17);
        \\  assert.sameValue((0, eval)("typeof __call_consumer_local"), "undefined");
        \\  assert.sameValue(eval?.("typeof __call_consumer_local"), "undefined");
        \\  const withScope = {
        \\  value: 23,
        \\  method() { return this.value; },
        \\  tag(parts) { return this.value + parts[0]; },
        \\  };
        \\  with (withScope) {
        \\  assert.sameValue((method)(), 23);
        \\  assert.sameValue(tag`!`, "23!");
        \\  assert.sameValue(({ value }).value, 23);
        \\  }
        \\  assert.sameValue(withScope.method?.(), 23);
        \\  class CallBase {
        \\  method() { return this.value; }
        \\  tag(parts) { return this.value + parts[0]; }
        \\  }
        \\  class CallDerived extends CallBase {
        \\  constructor() { super(); this.value = 31; }
        \\  probe() { return [(super.method)(), (super.tag)`?`]; }
        \\  }
        \\  const superResults = new CallDerived().probe();
        \\  assert.sameValue(superResults[0], 31);
        \\  assert.sameValue(superResults[1], "31?");
        \\  const commaReceiver = {
        \\  tag(parts) { "use strict"; void parts; return this; },
        \\  };
        \\  assert.sameValue((0, commaReceiver.tag)`x`, undefined);
        \\})();
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());

    // Pinned QuickJS currently rejects this exact optional-with reference
    // during stack verification (`InternalError: inconsistent stack size`).
    // Keep it separate from the positive receiver matrix so a future
    // reference upgrade makes the intentional divergence explicit.
    try std.testing.expectError(error.SyntaxError, js.eval(
        \\const optionalWithScope = { method() { return this; } };
        \\with (optionalWithScope) method?.();
    ));
    if (js.context.hasException()) js.context.clearException();
}

test "optional chains use one unbounded shared label and preserve closed-chain calls" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);

    try source.appendSlice(std.testing.allocator, "const nil = null;\nassert.sameValue(");
    try source.appendSlice(std.testing.allocator, "nil");
    for (0..257) |_| try source.appendSlice(std.testing.allocator, "?.x");
    try source.appendSlice(std.testing.allocator, ", undefined);\nassert.sameValue(delete nil");
    for (0..257) |_| try source.appendSlice(std.testing.allocator, "?.x");
    try source.appendSlice(std.testing.allocator, ", true);\nlet closedThrew = false;\ntry { (nil");
    for (0..32) |_| try source.appendSlice(std.testing.allocator, "?.x");
    try source.appendSlice(std.testing.allocator, "?.method)(); } catch (error) { closedThrew = error instanceof TypeError; }\nassert.sameValue(closedThrew, true);\nassert.sameValue((nil");
    for (0..32) |_| try source.appendSlice(std.testing.allocator, "?.x");
    try source.appendSlice(std.testing.allocator, "?.method)?.(), undefined);\nconst live = {};\nlive.x = live;\nlive.method = function () { \"use strict\"; return this === live; };\nassert.sameValue((live");
    for (0..32) |_| try source.appendSlice(std.testing.allocator, "?.x");
    try source.appendSlice(std.testing.allocator, "?.method)(), true);\n");

    const result = try js.eval(source.items);
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "direct eval inside a module function forwards module live bindings" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalModule(
        \\export let moduleDirectEvalBinding = 37;
        \\export function readModuleBindingByEval() {
        \\  return eval("moduleDirectEvalBinding");
        \\}
        \\assert.sameValue(readModuleBindingByEval(), 37);
    );
    defer result.free(js.runtime);
}

test "dynamic global put keeps cell and global-object legs semantically separate" {
    const cases = [_]struct {
        name: []const u8,
        source: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "initialized-cell-hit",
            .source =
            \\var cell = 1;
            \\function writeCell() { cell = 2; return cell; }
            \\print(writeCell(), cell);
            ,
            .expected = "2 2\n",
        },
        .{
            .name = "uninitialized-global-object-hit",
            .source =
            \\globalThis.dynamicHit = 1;
            \\function writeDynamicHit() { dynamicHit = 2; return dynamicHit; }
            \\print(writeDynamicHit(), globalThis.dynamicHit);
            ,
            .expected = "2 2\n",
        },
        .{
            .name = "uninitialized-global-object-miss",
            .source =
            \\delete globalThis.dynamicMiss;
            \\function writeDynamicMiss() { dynamicMiss = 3; return dynamicMiss; }
            \\print(writeDynamicMiss(), globalThis.dynamicMiss);
            ,
            .expected = "3 3\n",
        },
        .{
            .name = "strict-miss",
            .source =
            \\delete globalThis.strictMissing;
            \\function writeStrictMissing() { "use strict"; strictMissing = 3; }
            \\try { writeStrictMissing(); print("no throw"); }
            \\catch (error) { print(error.name, typeof strictMissing); }
            ,
            .expected = "ReferenceError undefined\n",
        },
        .{
            .name = "lexical-tdz",
            .source =
            \\function writeTdz() { lexicalTdz = 3; }
            \\try { writeTdz(); print("no throw"); }
            \\catch (error) { print(error.name); }
            \\let lexicalTdz;
            \\print(lexicalTdz);
            ,
            .expected = "ReferenceError\nundefined\n",
        },
        .{
            .name = "lexical-const",
            .source =
            \\const fixedCell = 1;
            \\function writeConst() { fixedCell = 2; }
            \\try { writeConst(); print("no throw"); }
            \\catch (error) { print(error.name, fixedCell); }
            ,
            .expected = "TypeError 1\n",
        },
        .{
            .name = "proxy-global-prototype",
            .source =
            \\(function () {
            \\  var emit = print;
            \\  var global = globalThis;
            \\  var ObjectCtor = Object;
            \\  var oldPrototype = ObjectCtor.getPrototypeOf(global);
            \\  var log = [];
            \\  var proxy = new Proxy({}, {
            \\    has: function (_, key) {
            \\      log.push("has:" + key);
            \\      return key === "proxiedDynamic";
            \\    },
            \\    set: function (_, key, value, receiver) {
            \\      log.push("set:" + key + ":" + value + ":" + (receiver === global));
            \\      return true;
            \\    },
            \\  });
            \\  function writeProxy() { proxiedDynamic = 9; }
            \\  ObjectCtor.setPrototypeOf(global, proxy);
            \\  writeProxy();
            \\  ObjectCtor.setPrototypeOf(global, oldPrototype);
            \\  emit(
            \\    log.join("|"),
            \\    ObjectCtor.prototype.hasOwnProperty.call(global, "proxiedDynamic"),
            \\  );
            \\})();
            ,
            .expected = "has:proxiedDynamic|set:proxiedDynamic:9:true false\n",
        },
    };

    for (cases) |case| {
        var js = try helpers.TestEngine.init(std.testing.allocator);
        defer js.deinit();

        var output_buffer: [256]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        const result = try js.evalWithOutput(case.source, &output);
        defer result.free(js.runtime);

        try std.testing.expect(result.isUndefined());
        try std.testing.expectEqualStrings(case.expected, output.buffered());
    }
}

test "get_var uninitialized-cell inline global-object leg preserves the cold waterfall semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    const rt = js.runtime;

    // Q1 red lights: op_get_var's inline uninit leg (qjs OP_get_var
    // quickjs.c:18469-18483 mirror) must stay outcome-identical to the cold
    // waterfall (vm_property_globals.getVar) it short-circuits.
    //
    // JS level, exercised through function-hot reads of parked cells:
    //   * frozen `undefined` own-data hit (the pivot shape), including under
    //     "use strict" (runtime_strict gate falls back cold, same value);
    //   * static shadows (var/param/catch) and direct-eval var injection
    //     never reach the leg (locals / checked sequences);
    //   * accessor globals miss the own-DATA test and keep protocol reads;
    //   * deleted dynamic globals park back at UNINITIALIZED and throw
    //     ReferenceError through the cold arm;
    //   * store visibility: no caching, every read sees the live property;
    //   * global lexical TDZ (lexical closure var) still throws cold.
    const setup = try js.eval(
        \\globalThis.__q1 = (function () {
        \\  var out = [];
        \\  function readUndef() { return undefined; }
        \\  var hot = 0;
        \\  for (var i = 0; i < 3000; i++) { if (readUndef() === void 0) hot++; }
        \\  out.push(hot);                                            // [0] 3000
        \\  out.push((function(){var undefined = 5; return undefined})()); // [1] 5
        \\  out.push((function(undefined){return undefined})(7));     // [2] 7
        \\  out.push((function(){try{throw 3}catch(undefined){return undefined}})()); // [3] 3
        \\  out.push((function(){eval("var undefined=9"); return undefined})()); // [4] 9
        \\  out.push((function(){"use strict"; return undefined === void 0})()); // [5] true
        \\  Object.defineProperty(globalThis, "__q1acc", { get: function(){ return 42; }, configurable: true });
        \\  var acc = 0;
        \\  function readAcc() { return __q1acc; }
        \\  for (var j = 0; j < 1000; j++) { acc += readAcc(); }
        \\  out.push(acc);                                            // [6] 42000
        \\  globalThis.__q1dyn = 3;
        \\  function readDyn() { return __q1dyn; }
        \\  var dyn = 0;
        \\  for (var k = 0; k < 1000; k++) { dyn += readDyn(); }
        \\  out.push(dyn);                                            // [7] 3000
        \\  globalThis.__q1dyn = 4;
        \\  out.push(readDyn());                                      // [8] 4 (no caching)
        \\  delete globalThis.__q1dyn;
        \\  var threw = 0;
        \\  try { readDyn(); } catch (e) { threw = e instanceof ReferenceError ? 1 : 2; }
        \\  out.push(threw);                                          // [9] 1
        \\  function readTdz() { return __q1lex; }
        \\  var tdz = 0;
        \\  try { readTdz(); } catch (e) { tdz = e instanceof ReferenceError ? 1 : 2; }
        \\  out.push(tdz);                                            // [10] 1
        \\  return out.length * 100 +
        \\    ((out[0] === 3000 && out[1] === 5 && out[2] === 7 && out[3] === 3 &&
        \\      out[4] === 9 && out[5] === true && out[6] === 42000 && out[7] === 3000 &&
        \\      out[8] === 4 && out[9] === 1 && out[10] === 1) ? 1 : 0);
        \\})();
        \\let __q1lex = 1;
    );
    setup.free(rt);
    try std.testing.expect(!js.context.hasException());

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const q1_name = try rt.internAtom("__q1");
    defer rt.atoms.free(q1_name);
    const verdict = try global.getProperty(q1_name);
    defer verdict.free(rt);
    // 11 probes, all green.
    try std.testing.expectEqual(@as(?i32, 1101), verdict.asInt32());
}

test "named function expression self-binding materializes lazily with pinned QuickJS semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    const rt = js.runtime;

    // Q2 red lights: the self-binding var (kind `.function_name`) and its
    // `special_object THIS_FUNC ; put_loc` prologue materialize lazily now
    // (qjs add_func_var call sites: resolve_scope_var quickjs.c:32977/33153,
    // add_eval_variables quickjs.c:33650/33698) instead of unconditionally at
    // function entry. Every observable of the eager model must hold:
    //   * self-reference returns/recurses the binding, incl. nested
    //     functions, arrows, and generators;
    //   * direct eval materializes conservatively (own body and nested,
    //     including through an invisible block shadow);
    //   * `delete name` stays false (own body and nested arrow);
    //   * strict assignment throws TypeError, sloppy write is ignored;
    //   * `.name` stays intact and non-referencing bodies stay correct;
    //   * shadows win: param, whole-body var, let TDZ, with-object;
    //   * `function arguments(){...}` resolves the arguments object (qjs
    //     parity: the retired eager var used to shadow it -> "function");
    //   * eval under a whole-body var shadow follows pinned QuickJS's
    //     add_eval_variables ordering: the lazily appended function-name row
    //     wins find_var's newest-first scan, so eval reads undefined here.
    const setup = try js.eval(
        \\globalThis.__q2 = (function () {
        \\  var out = [];
        \\  var f = function rec(){ return rec; };
        \\  out.push(f() === f);                                        // [0] true
        \\  var fact = function frec(n){ return n <= 1 ? 1 : n * frec(n - 1); };
        \\  out.push(fact(6));                                          // [1] 720
        \\  var e1 = function rec(){ return eval('rec'); };
        \\  out.push(e1() === e1);                                      // [2] true
        \\  var e2 = function rec(){ return (function inner(){ return eval('rec'); })(); };
        \\  out.push(e2() === e2);                                      // [3] true
        \\  var e3 = function rec(){ { let rec = 0; } return eval('typeof rec'); };
        \\  out.push(e3());                                             // [4] "function"
        \\  out.push(f.name);                                           // [5] "rec"
        \\  var a1 = function rec(){ return () => rec; };
        \\  out.push(a1()() === a1);                                    // [6] true
        \\  var d1 = function rec(){ return function m1(){ return function m2(){ return rec; }; }; };
        \\  out.push(d1()()() === d1);                                  // [7] true
        \\  out.push((function rec(){ return delete rec; })());         // [8] false
        \\  out.push((function rec(){ return (() => delete rec)(); })()); // [9] false
        \\  var threw = 0;
        \\  try { (function rec(){ "use strict"; rec = 1; })(); } catch (e) { threw = e instanceof TypeError ? 1 : 2; }
        \\  out.push(threw);                                            // [10] 1
        \\  out.push((function rec(){ rec = 1; return rec; })() instanceof Function); // [11] true
        \\  var g1 = function* grec(){ yield grec; };
        \\  out.push(g1().next().value === g1);                         // [12] true
        \\  var noref = function nr(a, b){ return a + b; };
        \\  out.push(noref(1, 2) === 3 && noref.name === "nr");         // [13] true
        \\  out.push((function rec(rec){ return rec; })(7));            // [14] 7
        \\  out.push((function rec(){ var rec = 3; return rec; })());   // [15] 3
        \\  var tdz = 0;
        \\  try { (function rec(){ rec; let rec = 1; })(); } catch (e) { tdz = e instanceof ReferenceError ? 1 : 2; }
        \\  out.push(tdz);                                              // [16] 1
        \\  out.push((function arguments(){ return typeof arguments; })()); // [17] "object"
        \\  out.push((function rec(){ with ({ rec: 9 }) { return rec; } })()); // [18] 9
        \\  var w1 = function rec(){ with ({}) { return rec; } };
        \\  out.push(w1() === w1);                                      // [19] true
        \\  out.push((function rec(){ var rec = 11; return eval('rec'); })()); // [20] undefined (pinned qjs)
        \\  out.push(typeof (function rec(){ { let rec; } return rec; })()); // [21] "function"
        \\  return out.length * 1000 +
        \\    ((out[0] === true && out[1] === 720 && out[2] === true && out[3] === true &&
        \\      out[4] === "function" && out[5] === "rec" && out[6] === true && out[7] === true &&
        \\      out[8] === false && out[9] === false && out[10] === 1 && out[11] === true &&
        \\      out[12] === true && out[13] === true && out[14] === 7 && out[15] === 3 &&
        \\      out[16] === 1 && out[17] === "object" && out[18] === 9 && out[19] === true &&
        \\      out[20] === undefined && out[21] === "function") ? 1 : 0);
        \\})();
    );
    setup.free(rt);
    try std.testing.expect(!js.context.hasException());

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const q2_name = try rt.internAtom("__q2");
    defer rt.atoms.free(q2_name);
    const verdict = try global.getProperty(q2_name);
    defer verdict.free(rt);
    // 22 probes, all green.
    try std.testing.expectEqual(@as(?i32, 22001), verdict.asInt32());
}

test "K2 warm leaf miss retreat keeps call accounting balanced across chunk and carve misses" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    // The budget check compares native SP minus the accumulated bytecode
    // budget against the native limit; this test intentionally accumulates
    // ~0.8MB of planned frame bytes to cross the 32K-slot arena chunk, so
    // widen the native window (the miss-retreat mechanism under test never
    // depends on it — an admission failure commits nothing).
    js.runtime.setNativeStackSize(8 * 1024 * 1024);

    const baseline_call_depth = js.runtime.hot.call_depth;
    const baseline_native_depth = js.runtime.hot.native_call_depth;
    const baseline_stack_bytes = js.runtime.hot.active_bytecode_stack_bytes;
    const baseline_arena_mark = js.runtime.vm_stack.mark();

    // A right-nested addition gives the leaf bodies a ~97-slot operand stack
    // window, an order of magnitude above the driver's ~20 slots/frame, so
    // the level at which arena chunk 0 first lacks leaf capacity is reached
    // while the driver itself still fits: the warm leaf constructors take the
    // carve-miss retreat there (and the entries-chunk 16-boundary miss ~150
    // times on the way down). bigleaf covers the empty-leaf family, bigleaf1
    // the exact-args family, cap the capture family.
    const deep_expr = ("1+(" ** 96) ++ "1" ++ (")" ** 96);
    const source =
        "function bigleaf(){ return " ++ deep_expr ++ "; }\n" ++
        "function bigleaf1(x){ return " ++ deep_expr ++ "; }\n" ++
        "function mkcap(){ var q = 3; return function(){ return q + q; }; }\n" ++
        "var cap = mkcap();\n" ++
        "function f(n){\n" ++
        "  bigleaf(); bigleaf1(n); cap();\n" ++
        "  var a=n+1, b=a+1, c=b+1, d=c+1, e=d+1, g=e+1, h=g+1, k=h+1, m=k+1, p=m+1, r=p+1, s=r+1;\n" ++
        "  if (n === 0) return a+b+c+d+e+g+h+k+m+p+r+s;\n" ++
        "  return f(n-1) + 1;\n" ++
        "}\n" ++
        "var __k2_deep = f(2400);\n";

    const result = try js.eval(source);
    result.free(js.runtime);
    try std.testing.expect(!js.context.hasException());

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const key = try js.runtime.internAtom("__k2_deep");
    defer js.runtime.atoms.free(key);
    const deep_value = try global.getProperty(key);
    defer deep_value.free(js.runtime);
    // n=0 level: locals sum 1+2+...+12 = 78, plus one per recursion level.
    try std.testing.expectEqual(@as(?i32, 78 + 2400), deep_value.asInt32());

    // The arena must actually have crossed into a second chunk — otherwise
    // this test lost its carve-miss coverage (e.g. geometry drift).
    try std.testing.expect(js.runtime.vm_stack.chunk_count >= 2);

    // Every warm miss committed and then retreated its budget charge; any
    // imbalance (missing or doubled retreat) leaves a residue here.
    try std.testing.expectEqual(baseline_call_depth, js.runtime.hot.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.hot.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.hot.active_bytecode_stack_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
}

test "latin1 high bytes survive raw-string byte bridges (qjs JS_ToCStringLen2 mirror)" {
    // Regression: value_ops.appendRawString used to append latin1 payload
    // bytes raw into UTF-8 byte buffers; any 0x80-0xFF code point then broke
    // the createStringValue re-decode ("URIError: expecting hex digit").
    // Each leg below reproduced against qjs before the width-aware fix.
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.evalWithOptions(
        \\(function () {
        \\    var out = [];
        \\    var f = function () {};
        \\    Object.defineProperty(f, "name", { value: "é" });
        \\    out.push(f.bind(null).name === "bound é");
        \\    var tagged = {};
        \\    tagged[Symbol.toStringTag] = "étag";
        \\    out.push(Object.prototype.toString.call(tagged) === "[object étag]");
        \\    out.push(Symbol("é").toString() === "Symbol(é)");
        \\    out.push(Symbol("é").description === "é");
        \\    out.push(new Error("mé").toString() === "Error: mé");
        \\    out.push(["a", "b"].join("é") === "aéb");
        \\    out.push(new Int8Array([1, 2]).join("é") === "1é2");
        \\    out.push(new RegExp("éx").toString() === "/éx/");
        \\    out.push(["é"].toLocaleString() === "é");
        \\    try {
        \\        var C = class éc {};
        \\        C();
        \\        out.push("no-throw");
        \\    } catch (e) {
        \\        out.push(e instanceof TypeError);
        \\    }
        \\    var stack_ok = false;
        \\    try {
        \\        (function éfn() { throw new Error("boom"); })();
        \\    } catch (e) {
        \\        stack_ok = typeof e.stack === "string" && e.stack.indexOf("éfn") >= 0;
        \\    }
        \\    out.push(stack_ok);
        \\    return out.join(",");
        \\})()
    , .{ .filename = "<repl>" });
    defer result.free(js.runtime);
    try helpers.expectStringValueBytes(
        result,
        "true,true,true,true,true,true,true,true,true,true,true",
    );
}

test "ToNumber latin1 high bytes are code points not UTF-8 whitespace" {
    // X-38: latin1 0x80-0xFF are single code points. Feeding the raw bytes to
    // a UTF-8 whitespace decoder made Number("\xe2\x80\x801") == 1 while
    // qjs skip_spaces (qjs:11230) / lre_is_space classify by code point.

    try helpers.expectPrints(
        \\var s = String.fromCharCode(0xE2,0x80,0x80) + "1";
        \\print("len="+s.length+" cc="+s.charCodeAt(0)+","+s.charCodeAt(1)+","+s.charCodeAt(2)+","+s.charCodeAt(3));
        \\print("Number(s)="+Number(s));  print("+s="+(+s));  print("-s="+(-s));
        \\print("parseFloat="+parseFloat(s));  print("parseInt="+parseInt(s));  print("Math.abs="+Math.abs(s));
        \\print("eqloose="+(s==1));  print("at="+[7,8].at(s));
        \\print("Math.max="+Math.max(s,0));  print("slice="+[1,2,3].slice(s).length);
        \\print("s*2="+(s*2));  print("s|0="+(s|0));
        \\var seqs = [
        \\  [0xC2,0xA0],
        \\  [0xE1,0x9A,0x80],
        \\  [0xE2,0x81,0x9F],
        \\  [0xE3,0x80,0x80],
        \\  [0xEF,0xBB,0xBF],
        \\  [0xE2,0x80,0x8A],
        \\  [0xE2,0x80,0xA8]
        \\];
        \\seqs.forEach(function(seq, i){
        \\  var prefix = String.fromCharCode.apply(null, seq) + "1";
        \\  var suffix = "1" + String.fromCharCode.apply(null, seq);
        \\  print("p"+i+" Number="+Number(prefix)+" parseFloat="+parseFloat(prefix)+" parseInt="+parseInt(prefix));
        \\  print("s"+i+" Number="+Number(suffix)+" parseFloat="+parseFloat(suffix)+" parseInt="+parseInt(suffix));
        \\});
        \\var a0 = String.fromCharCode(0xA0) + "1";
        \\print("bareA0 Number="+Number(a0)+" parseFloat="+parseFloat(a0));
        \\print("U00A0 Number="+Number("\u00A0"+"1")+" parseFloat="+parseFloat("\u00A0"+"1"));
        \\print("U2000 Number="+Number("\u2000"+"1")+" parseFloat="+parseFloat("\u2000"+"1"));
        \\print("UFEFF Number="+Number("\uFEFF"+"1")+" parseFloat="+parseFloat("\uFEFF"+"1"));
    , "len=4 cc=226,128,128,49\n" ++
        "Number(s)=NaN\n" ++
        "+s=NaN\n" ++
        "-s=NaN\n" ++
        "parseFloat=NaN\n" ++
        "parseInt=NaN\n" ++
        "Math.abs=NaN\n" ++
        "eqloose=false\n" ++
        "at=7\n" ++
        "Math.max=NaN\n" ++
        "slice=3\n" ++
        "s*2=NaN\n" ++
        "s|0=0\n" ++
        "p0 Number=NaN parseFloat=NaN parseInt=NaN\n" ++
        "s0 Number=NaN parseFloat=1 parseInt=1\n" ++
        "p1 Number=NaN parseFloat=NaN parseInt=NaN\n" ++
        "s1 Number=NaN parseFloat=1 parseInt=1\n" ++
        "p2 Number=NaN parseFloat=NaN parseInt=NaN\n" ++
        "s2 Number=NaN parseFloat=1 parseInt=1\n" ++
        "p3 Number=NaN parseFloat=NaN parseInt=NaN\n" ++
        "s3 Number=NaN parseFloat=1 parseInt=1\n" ++
        "p4 Number=NaN parseFloat=NaN parseInt=NaN\n" ++
        "s4 Number=NaN parseFloat=1 parseInt=1\n" ++
        "p5 Number=NaN parseFloat=NaN parseInt=NaN\n" ++
        "s5 Number=NaN parseFloat=1 parseInt=1\n" ++
        "p6 Number=NaN parseFloat=NaN parseInt=NaN\n" ++
        "s6 Number=NaN parseFloat=1 parseInt=1\n" ++
        "bareA0 Number=1 parseFloat=1\n" ++
        "U00A0 Number=1 parseFloat=1\n" ++
        "U2000 Number=1 parseFloat=1\n" ++
        "UFEFF Number=1 parseFloat=1\n");
}

test "JSON.rawJSON latin1 payload survives the simple stringify byte buffer" {
    // Regression: json_ops' local appendRawString clone appended raw latin1
    // bytes into the stringify buffer, breaking the final UTF-8 re-decode.
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.evalWithOptions(
        \\[
        \\    JSON.stringify(JSON.rawJSON('"é"')) === '"é"',
        \\    JSON.stringify({ x: JSON.rawJSON('"é"') }, null, 1) === '{\n "x": "é"\n}',
        \\].join(",")
    , .{ .filename = "<repl>" });
    defer result.free(js.runtime);
    try helpers.expectStringValueBytes(result, "true,true");
}

test "native function toString keeps non-ASCII identifier names (qjs js_function_toString)" {
    // Regression: the native-source name filter only accepted ASCII
    // identifiers, silently dropping latin1/unicode identifier names that
    // qjs js_function_toString (quickjs.c:41335) emits verbatim.
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.evalWithOptions(
        \\(function () {
        \\    Object.defineProperty(Math.max, "name", { value: "ém", configurable: true });
        \\    return Math.max.toString() === "function ém() {\n    [native code]\n}";
        \\})()
    , .{ .filename = "<repl>" });
    defer result.free(js.runtime);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "switch dispatch trampoline shapes keep their identity and semantics" {
    // QCP-1 switch-dispatch regression corpus. Each source below reproduced a
    // real divergence while two backends existed; with one backend left they
    // pin the observable clause-fallthrough semantics of the shapes that
    // exercise the resolver's dispatch folding.
    //
    // The epilogue dispatch bridge several of these shapes were written
    // against no longer exists: the unmatched-dispatch references now move onto
    // the default identity (`Builder.retargetLabelRefs`), which is what legacy
    // `patchJumpTarget` does. The shapes stay as the corpus that proves it.
    //
    // Each shape reproduced a distinct lowering divergence:
    //   [0] `case a: b(); case c: default: e();` — the branch whose target
    //       resolves to its own fallthrough only after the bridge folds away.
    //   [1] `case a: default: e();` — the empty case falling into a trailing
    //       default (first found through the atom-balance corpus).
    //   [2]/[5]/[6] empty `default` clause followed by a `case`: the clause
    //       tail flow predicate has to read the code emitted BEFORE the empty
    //       body, exactly like `caseCanFallthrough`'s whole-stream summary.
    //   [3]/[7] a default label bound at the switch epilogue: the dispatch
    //       bridge must not be emitted at all.
    //   [4] leading empty `default`.
    //   [8] nested loops whose inner backedge dies: the for-loop top label is
    //       a physical `OP_label` in the legacy stream and keeps its
    //       sequential-match barrier, so `put_loc; get_loc` never fuses.
    //   [9]/[10] a leading `default` whose switch ends in a break-only clause:
    //       the dispatch bridge must stay invisible to the branch-inversion
    //       peephole (pdfjs `CanvasGraphics_showText`).
    //   [11] `while (..) { if (..) return; }`: the `undefined; return` fold has
    //       to drop its dead tail or the loop backedge survives.
    //   [12]-[15] a clause body ending in an if/else whose test folds falsy and
    //       whose taken arm is empty. Its two converging labels bind exactly
    //       where the epilogue starts, so while the dispatch bridge existed
    //       they bound on the bridge's skip goto instead of the epilogue:
    //       `findJumpTarget` threaded one hop further than legacy and the
    //       jump-to-own-fallthrough legacy folds survived in v2 (test262
    //       annexB `*if-stmt-else-decl-*-skip-early-err-switch`, 5 files).
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalWithOptions(
        \\(function () {
        \\    function run(f) {
        \\        var parts = [];
        \\        var inputs = [1, 2, 3, 9];
        \\        for (var i = 0; i < inputs.length; i++) parts.push(f(inputs[i]));
        \\        return parts.join(",");
        \\    }
        \\    var out = [];
        \\    out.push(run(function (d) { var s = ""; switch (d) { case 1: s += "a"; case 2: default: s += "b"; } return s; }));
        \\    out.push(run(function (d) { var s = ""; switch (d) { case 1: default: s += "b"; } return s; }));
        \\    out.push(run(function (d) { var s = ""; switch (d) { case 1: s += "a"; default: case 2: s += "b"; } return s; }));
        \\    out.push(run(function (d) { var s = "x"; switch (d) { case 1: case 2: default: } return s; }));
        \\    out.push(run(function (d) { var s = ""; switch (d) { default: case 1: s += "b"; } return s; }));
        \\    out.push(run(function (d) { var s = ""; switch (d) { case 1: s += "a"; default: case 2: s += "b"; case 3: s += "c"; } return s; }));
        \\    out.push(run(function (d) { var s = ""; switch (d) { case 1: case 2: default: case 3: case 9: s += "z"; } return s; }));
        \\    out.push(run(function (d) { var s = "y"; switch (d) { case 1: s += "a"; break; default: } return s; }));
        \\    out.push((function () {
        \\        var n = 0;
        \\        outer: for (var i = 0; i < 3; i++) { for (var j = 0; j < 3; j++) { n += 1; continue outer; } }
        \\        return "" + n;
        \\    })());
        \\    out.push(run(function (d) { var s = "q"; switch (d) { default: s += "d"; break; case 3: break; } return s; }));
        \\    out.push(run(function (d) { var s = ""; switch (d) { default: case 1: s += "a"; break; case 2: case 9: s += "b"; break; case 3: break; } return s; }));
        \\    out.push((function () {
        \\        var n = 0;
        \\        function loopReturn(a, c) { while (a) { n += 1; if (c) return "r"; } return "w"; }
        \\        return loopReturn(1, 1) + loopReturn(0, 0);
        \\    })());
        \\    out.push(run(function (d) { var s = "e"; switch (d) { default: if (false) ; else ; } return s; }));
        \\    out.push(run(function (d) { var s = ""; switch (d) { case 1: s += "a"; default: if (false) { } else { } } return s; }));
        \\    out.push(run(function (d) { var s = ""; switch (d) { default: let f = "L"; s += f; if (false) ; else ; } return s; }));
        \\    out.push(run(function (d) { var s = "n"; switch (d) { case 1: s += "a"; break; default: switch (d) { default: if (false) ; else ; } } return s; }));
        \\    return out.join("|");
        \\})()
    , .{ .filename = "<repl>" });
    defer result.free(js.runtime);
    try helpers.expectStringValueBytes(
        result,
        "ab,b,b,b|b,b,b,b|ab,b,b,b|x,x,x,x|b,b,b,b|abc,bc,c,bc|z,z,z,z|ya,y,y,y|3" ++
            "|qd,qd,q,qd|a,b,,b|rw" ++
            "|e,e,e,e|a,,,|L,L,L,L|na,n,n,n",
    );
}

test "Annex B if/else function declarations update the shared function binding" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function f(x) {
        \\  if (x) function g() { return "g0"; }
        \\  else function g() { return "g1"; }
        \\  return typeof g + ":" + (typeof g === "function" ? g() : "missing");
        \\}
    );
    result.free(js.runtime);
    const observed = try js.evalWithOptions("f(true) + ',' + f(false)", .{ .filename = "<repl>" });
    defer observed.free(js.runtime);
    try helpers.expectStringValueBytes(observed, "function:g0,function:g1");
}

test "sloppy CallExpression assignment targets throw after evaluating only the call" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.evalWithOptions(
        \\(function () {
        \\    var calls = 0;
        \\    var rhs = 0;
        \\    var coercions = 0;
        \\    function f() {
        \\        calls += 1;
        \\        return { valueOf: function () { coercions += 1; return 1; } };
        \\    }
        \\    function g() { rhs += 1; return 2; }
        \\    var out = [];
        \\    try { f() = g(); } catch (e) { out.push(e instanceof ReferenceError); }
        \\    try { f() += g(); } catch (e) { out.push(e instanceof ReferenceError); }
        \\    try { f()++; } catch (e) { out.push(e instanceof ReferenceError); }
        \\    try { ++f(); } catch (e) { out.push(e instanceof ReferenceError); }
        \\    try { for (f() in [1]) {} } catch (e) { out.push(e instanceof ReferenceError); }
        \\    try { for (f() of [1]) {} } catch (e) { out.push(e instanceof ReferenceError); }
        \\    return out.join(",") + "|" + calls + "," + rhs + "," + coercions;
        \\})()
    , .{ .filename = "<repl>" });
    defer result.free(js.runtime);
    try helpers.expectStringValueBytes(result, "true,true,true,true,true,true|6,0,0");
}

test "async context-keyword arrow binding identifier is a function" {
    try helpers.expectPrints(
        \\var f = async yield => yield+1;
        \\f(41).then(v=>print(v));
    , "42\n");
}

test "get/set object shorthand serializes like a named property" {
    try helpers.expectPrints(
        \\var get=1; print(JSON.stringify({get}));
        \\var set=1; print(JSON.stringify({set}));
    , "{\"get\":1}\n{\"set\":1}\n");
}

test "top-level direct eval does not break private-name eval resolution" {
    try helpers.expectPrints(
        \\class C {
        \\  #f = 1;
        \\  get #g(){ return 2; }
        \\  #p(){ return 3; }
        \\  read(){ return eval("this.#f"); }
        \\  getg(){ return eval("this.#g"); }
        \\  callp(){ return eval("this.#p()"); }
        \\  brand(){ return eval("#f in this"); }
        \\  write(){ return eval("this.#f = 50, this.#f"); }
        \\  noneval(){ return this.#f + this.#g + this.#p(); }
        \\}
        \\var o = new C();
        \\function show(label, fn){
        \\  try { print(label + ": " + fn()); }
        \\  catch(e){ print(label + " threw: " + e.name + " | " + e.message); }
        \\}
        \\show("field", function(){ return o.read(); });
        \\show("getter", function(){ return o.getg(); });
        \\show("method", function(){ return o.callp(); });
        \\show("brand", function(){ return o.brand(); });
        \\show("write", function(){ return o.write(); });
        \\show("noneval", function(){ return o.noneval(); });
        \\eval("1");
    , "field: 1\ngetter: 2\nmethod: 3\nbrand: true\nwrite: 50\nnoneval: 55\n");
}

test "switch fallthrough after while-family tails reaches the next case" {
    try helpers.expectPrints(
        \\function run(body){
        \\  var r=[];
        \\  switch(0){
        \\    case 0: body();
        \\    case 1: r.push("b"); break;
        \\    default: r.push("d");
        \\  }
        \\  return r.join(",");
        \\}
        \\print(run(function(){ while(true){break;} }));
        \\print(run(function(){ while(1)break; }));
        \\print(run(function(){ lbl:while(true){break lbl;} }));
        \\print(run(function(){ for(;;){break;} }));
        \\print(run(function(){ for(;;)break; }));
        \\print(run(function(){ do{break;}while(0); }));
        \\print(run(function(){ { } }));
        \\print(run(function(){ if(1){}else{} }));
        \\print(run(function(){ for(var i of []){} }));
        \\print(run(function(){ for(var k in {}){} }));
        \\print(run(function(){ try{}catch(e){} }));
        \\print(run(function(){ for(var q=0;q<1;q++){continue;} }));
        \\function t(x){ var r=[]; switch(x){ case 0: while(true){ r.push("a"); break; } case 1: r.push("b"); break; default: r.push("d"); } return r.join(","); }
        \\print(t(0));
        \\switch(0){ case 0: if(false) break; print("y"); case 1: print("z"); }
    , "b\nb\nb\nb\nb\nb\nb\nb\nb\nb\nb\nb\na,b\ny\nz\n");
}

test "long numeric literals parse without a 128-byte cap" {
    try helpers.expectPrints(
        \\print(111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111);
        \\print(0x1111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111);
    , "1.1111111111111112e+128\n2.288265886710203e+155\n");
}

test "small-function-inlining: sc_Pair constructor is eligible and arguments ctor is not" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function sc_Pair(car, cdr) { this.car = car; this.cdr = cdr; }
        \\function usesArgs() { return arguments[0]; }
        \\function big(a,b,c,d,e) { this.a=a; this.b=b; this.c=c; this.d=d; this.e=e; }
        \\globalThis.__p = sc_Pair;
        \\globalThis.__a = usesArgs;
        \\globalThis.__b = big;
    );
    defer result.free(js.runtime);

    const global = try js.context.globalObject();
    const pair_fn = try global.getProperty(try js.runtime.internAtom("__p"));
    defer pair_fn.free(js.runtime);
    const args_fn = try global.getProperty(try js.runtime.internAtom("__a"));
    defer args_fn.free(js.runtime);
    const big_fn = try global.getProperty(try js.runtime.internAtom("__b"));
    defer big_fn.free(js.runtime);

    const pair_obj = zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(pair_fn).?;
    const args_obj = zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(args_fn).?;
    const big_obj = zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(big_fn).?;
    const pair_fb = pair_obj.u.bytecode_function.function_bytecode.?;
    try std.testing.expect(pair_fb.smallInlineEligible());
    try std.testing.expect(!args_obj.u.bytecode_function.function_bytecode.?.smallInlineEligible());
    try std.testing.expect(!big_obj.u.bytecode_function.function_bytecode.?.smallInlineEligible());
}

test "small-function-inlining: setter throw stack is setter, ctor, caller" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var output_buffer: [512]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function C(v) { this.x = v; }
        \\function outer(v) { return new C(v); }
        \\var i;
        \\for (i = 0; i < 16; i++) outer(i);
        \\Object.defineProperty(C.prototype, "x", {
        \\  set: function setX(v) { throw new Error("boom"); }
        \\});
        \\try {
        \\  outer(99);
        \\} catch (e) {
        \\  var s = String(e.stack);
        \\  print(s.indexOf("setX") >= 0 ? "setX" : "no-setX");
        \\  print(s.indexOf("C") >= 0 ? "C" : "no-C");
        \\  print(s.indexOf("outer") >= 0 ? "outer" : "no-outer");
        \\}
    , &output);
    defer result.free(js.runtime);
    try std.testing.expectEqualStrings("setX\nC\nouter\n", output.buffered());
}

test "small-function-inlining: redefinition takes the new function" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function m1() { return 1; }
        \\function m2() { return 2; }
        \\var o = { m: m1 };
        \\function outer(obj) { return obj.m(); }
        \\var i, last;
        \\for (i = 0; i < 16; i++) last = outer(o);
        \\o.m = m2;
        \\assert.sameValue(outer(o), 2);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "small-function-inlining: new C field write is visible" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function C() { this.x = 1; }
        \\function outer() { return new C(); }
        \\var i, o;
        \\for (i = 0; i < 16; i++) o = outer();
        \\assert.sameValue(o.x, 1);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "small-function-inlining: polymorphic site is not specialized" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function A(v) { this.v = v; }
        \\function B(v) { this.v = v + 1; }
        \\function outer(C, v) { return new C(v); }
        \\var i, last;
        \\for (i = 0; i < 20; i++) last = outer(i & 1 ? A : B, i);
        \\assert.sameValue(typeof last.v, "number");
        \\assert.sameValue(outer(A, 10).v, 10);
        \\assert.sameValue(outer(B, 10).v, 11);
        \\globalThis.__outer = outer;
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());

    const global = try js.context.globalObject();
    const outer_fn = try global.getProperty(try js.runtime.internAtom("__outer"));
    defer outer_fn.free(js.runtime);
    const outer_obj = zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(outer_fn).?;
    const outer_fb = outer_obj.u.bytecode_function.function_bytecode.?;
    if (zjs.exec.small_inline.callerState(outer_fb)) |state| {
        try std.testing.expectEqual(@as(u8, 0), state.inlined_len);
        var i: u8 = 0;
        var saw_never = false;
        while (i < state.site_len) : (i += 1) {
            if (state.sites[i].never) saw_never = true;
        }
        try std.testing.expect(saw_never);
    }
}

test "small-function-inlining: R-2 getter on callee is invoked once per new" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\var n = 0;
        \\function RealC(v) { this.x = v; }
        \\Object.defineProperty(globalThis, "C", {
        \\  get: function () { n += 1; return RealC; },
        \\  configurable: true
        \\});
        \\function outer(v) { return new C(v); }
        \\var i;
        \\for (i = 0; i < 16; i++) outer(i);
        \\assert.sameValue(n, 16);
        \\assert.sameValue(outer(7).x, 7);
        \\assert.sameValue(n, 17);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "small-function-inlining: inner throw stack and caller catch" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var output_buffer: [512]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function inner() { throw new Error("x"); }
        \\function outer() { return inner(); }
        \\var i;
        \\for (i = 0; i < 16; i++) { try { outer(); } catch (e) {} }
        \\try { outer(); } catch (e) {
        \\  var s = String(e.stack);
        \\  print(s.indexOf("inner") >= 0 ? "inner" : "no-inner");
        \\  print(s.indexOf("outer") >= 0 ? "outer" : "no-outer");
        \\}
    , &output);
    defer result.free(js.runtime);
    try std.testing.expectEqualStrings("inner\nouter\n", output.buffered());
}

test "small-function-inlining: primitive ctor return keeps instance" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function C() { this.x = 1; return 0; }
        \\function outer() { return new C(); }
        \\var i, o;
        \\for (i = 0; i < 16; i++) o = outer();
        \\assert.sameValue(typeof o, "object");
        \\assert.sameValue(o.x, 1);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "small-function-inlining: Reflect.construct with foreign NewTarget is not expanded" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function C(v) { this.x = v; }
        \\function NT() {}
        \\NT.prototype = { mark: 1 };
        \\function outer(v) { return Reflect.construct(C, [v], NT); }
        \\var i, o;
        \\for (i = 0; i < 16; i++) o = outer(i);
        \\assert.sameValue(o.x, 15);
        \\assert.sameValue(o.mark, 1);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "small-function-inlining: derived class constructor is not eligible" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\class B {}
        \\class D extends B { constructor(v) { super(); this.x = v; } }
        \\globalThis.__d = D;
    );
    defer result.free(js.runtime);
    const global = try js.context.globalObject();
    const d_fn = try global.getProperty(try js.runtime.internAtom("__d"));
    defer d_fn.free(js.runtime);
    const d_obj = zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(d_fn).?;
    try std.testing.expect(!d_obj.u.bytecode_function.function_bytecode.?.smallInlineEligible());
}

test "small-function-inlining: next-entry specialize is installed on the caller" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function Three(a, b, c) { this.x = a; this.y = b; this.z = c; }
        \\function batch(n) {
        \\  var i, s = 0, p;
        \\  for (i = 0; i < n; i++) { p = new Three(1, 2, 3); s = s + p.x; }
        \\  return s;
        \\}
        \\globalThis.__batch = batch;
        \\assert.sameValue(batch(16), 16);
        \\assert.sameValue(batch(16), 16);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
    const global = try js.context.globalObject();
    const batch_fn = try global.getProperty(try js.runtime.internAtom("__batch"));
    defer batch_fn.free(js.runtime);
    const batch_obj = zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(batch_fn).?;
    const batch_fb = batch_obj.u.bytecode_function.function_bytecode.?;
    const state = zjs.exec.small_inline.callerState(batch_fb);
    try std.testing.expect(state != null);
    try std.testing.expect(state.?.inlined_len >= 1);
    try std.testing.expect(state.?.specialized);
}

test "small-function-inlining: spec copy keeps simple_inline bits after extra TAKE locals" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function C(v) { this.x = v; }
        \\function outer(v) { return new C(v); }
        \\globalThis.__outer = outer;
        \\var i, last;
        \\for (i = 0; i < 16; i++) last = outer(i);
        \\assert.sameValue(last.x, 15);
        \\assert.sameValue(outer(7).x, 7);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
    const global = try js.context.globalObject();
    const outer_fn = try global.getProperty(try js.runtime.internAtom("__outer"));
    defer outer_fn.free(js.runtime);
    const outer_obj = zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(outer_fn).?;
    const outer_fb = outer_obj.u.bytecode_function.function_bytecode.?;
    const state = zjs.exec.small_inline.callerState(outer_fb);
    try std.testing.expect(state != null);
    try std.testing.expect(state.?.inlined_len >= 1);
    // Extra TAKE window: not a Fast leaf (var_count==0), but still the
    // qjs:17828 simple-inline shape (simple_inline_base holds).
    try std.testing.expect(outer_fb.var_count > 0);
    try std.testing.expect(outer_fb.simpleInlineEligible());
    try std.testing.expect(!outer_fb.strictSimpleInlineEligible());
    try std.testing.expect(!outer_fb.strictSimpleSnapshotInlineEligible());
    try std.testing.expect(!outer_fb.simpleInlineEmptyLeaf());
    try std.testing.expect(!outer_fb.rawThisInlineEmptyLeaf());
    try std.testing.expect(!outer_fb.simpleInlineExactArgsLeaf());
    try std.testing.expect(!outer_fb.rawThisInlineExactArgsLeaf());
    try std.testing.expectEqual(.none, outer_fb.exactArgsLeafKind());
    try std.testing.expectEqual(.none, outer_fb.captureLeafKind());
}

test "small-function-inlining: sibling constructor sites both specialize" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function Pair(a, b) { this.x = a; this.y = b; }
        \\function both(a, b) {
        \\  var p = new Pair(a, b);
        \\  var q = new Pair(b, a);
        \\  return p.x + q.x;
        \\}
        \\globalThis.__both = both;
        \\var i, last;
        \\for (i = 0; i < 16; i++) last = both(1, 2);
        \\assert.sameValue(last, 3);
        \\assert.sameValue(both(4, 5), 9);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
    const global = try js.context.globalObject();
    const both_fn = try global.getProperty(try js.runtime.internAtom("__both"));
    defer both_fn.free(js.runtime);
    const both_obj = zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(both_fn).?;
    const both_fb = both_obj.u.bytecode_function.function_bytecode.?;
    const state = zjs.exec.small_inline.callerState(both_fb);
    try std.testing.expect(state != null);
    try std.testing.expect(state.?.inlined_len >= 2);
}

test "small-function-inlining: proto replacement after specialize is observed" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function C(v) { this.x = v; }
        \\function outer(v) { return new C(v); }
        \\var i, o;
        \\for (i = 0; i < 16; i++) o = outer(i);
        \\C.prototype = { mark: 1 };
        \\o = outer(99);
        \\assert.sameValue(o.x, 99);
        \\assert.sameValue(o.mark, 1);
        \\C.foo = 1;
        \\o = outer(7);
        \\assert.sameValue(o.x, 7);
        \\assert.sameValue(o.mark, 1);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "small-function-inlining: call_constructor callers keep published frame geometry" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function C(v) { this.x = v; }
        \\function outer(v) { return new C(v); }
        \\globalThis.__outer = outer;
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
    const global = try js.context.globalObject();
    const outer_fn = try global.getProperty(try js.runtime.internAtom("__outer"));
    defer outer_fn.free(js.runtime);
    const outer_obj = zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(outer_fn).?;
    const outer_fb = outer_obj.u.bytecode_function.function_bytecode.?;
    // Deleted OSR spare was +9 locals / +4 stack on every call_constructor
    // caller. Published geometry must match the compiler's real slots.
    try std.testing.expectEqual(@as(u16, 0), outer_fb.var_count);
}

test "small-function-inlining: leftover-operand bodies are not small-inline eligible" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function leftoverDrop() { ({ z: 1 }); }
        \\function leftoverSwitch() { switch ({ x: 7 }) { default: return 5; } }
        \\function leftoverCtor() { ({ z: 1 }); }
        \\function balancedInc() { return this.v + 1; }
        \\globalThis.__drop = leftoverDrop;
        \\globalThis.__sw = leftoverSwitch;
        \\globalThis.__ctor = leftoverCtor;
        \\globalThis.__inc = balancedInc;
    );
    defer result.free(js.runtime);
    const global = try js.context.globalObject();
    const drop_fn = try global.getProperty(try js.runtime.internAtom("__drop"));
    defer drop_fn.free(js.runtime);
    const sw_fn = try global.getProperty(try js.runtime.internAtom("__sw"));
    defer sw_fn.free(js.runtime);
    const ctor_fn = try global.getProperty(try js.runtime.internAtom("__ctor"));
    defer ctor_fn.free(js.runtime);
    const inc_fn = try global.getProperty(try js.runtime.internAtom("__inc"));
    defer inc_fn.free(js.runtime);
    try std.testing.expect(!zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(drop_fn).?.u.bytecode_function.function_bytecode.?.smallInlineEligible());
    try std.testing.expect(!zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(sw_fn).?.u.bytecode_function.function_bytecode.?.smallInlineEligible());
    try std.testing.expect(!zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(ctor_fn).?.u.bytecode_function.function_bytecode.?.smallInlineEligible());
    try std.testing.expect(zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(inc_fn).?.u.bytecode_function.function_bytecode.?.smallInlineEligible());
}

test "small-function-inlining: leftover ctor is not specialized and does not overflow" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function C() { ({ z: 1 }); }
        \\function outer() { return new C(); }
        \\var i, last;
        \\for (i = 0; i < 256; i++) last = outer();
        \\assert.sameValue(typeof last, "object");
        \\globalThis.__C = C;
        \\globalThis.__outer = outer;
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
    const global = try js.context.globalObject();
    const c_fn = try global.getProperty(try js.runtime.internAtom("__C"));
    defer c_fn.free(js.runtime);
    try std.testing.expect(!zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(c_fn).?.u.bytecode_function.function_bytecode.?.smallInlineEligible());
    const outer_fn = try global.getProperty(try js.runtime.internAtom("__outer"));
    defer outer_fn.free(js.runtime);
    const outer_obj = zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(outer_fn).?;
    const outer_fb = outer_obj.u.bytecode_function.function_bytecode.?;
    if (zjs.exec.small_inline.callerState(outer_fb)) |state| {
        try std.testing.expectEqual(@as(u8, 0), state.inlined_len);
    }
}

test "small-function-inlining: extra ctor args do not overwrite callee fields" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function Pair(a, b) { this.x = a; this.y = b; }
        \\function outer() { return new Pair(1, 2, { leak: 1 }); }
        \\var i, last;
        \\for (i = 0; i < 16; i++) last = outer();
        \\assert.sameValue(last.x, 1);
        \\assert.sameValue(last.y, 2);
        \\assert.sameValue(last.leak, undefined);
        \\globalThis.__outer = outer;
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
    const global = try js.context.globalObject();
    const outer_fn = try global.getProperty(try js.runtime.internAtom("__outer"));
    defer outer_fn.free(js.runtime);
    const outer_obj = zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(outer_fn).?;
    const outer_fb = outer_obj.u.bytecode_function.function_bytecode.?;
    const state = zjs.exec.small_inline.callerState(outer_fb);
    try std.testing.expect(state != null);
    try std.testing.expect(state.?.inlined_len >= 1);
}

test "small-function-inlining: monomorphic method is expanded" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function Box(v) { this.v = v; }
        \\Box.prototype.inc = function () { return this.v + 1; };
        \\function outer(b) { return b.inc(); }
        \\var i, last, box = new Box(3);
        \\for (i = 0; i < 16; i++) last = outer(box);
        \\assert.sameValue(last, 4);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "small-function-inlining L1: apply-arguments ctor specializes" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function K() { this.initialize.apply(this, arguments); }
        \\K.prototype.initialize = function (a, b) { this.a = a; this.b = b; };
        \\function outer(a, b) { return new K(a, b); }
        \\globalThis.__outer = outer;
        \\var i, o;
        \\for (i = 0; i < 16; i++) o = outer(1, 2);
        \\assert.sameValue(o.a, 1);
        \\assert.sameValue(o.b, 2);
        \\assert.sameValue(outer(7, 8).a, 7);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
    const global = try js.context.globalObject();
    const outer_fn = try global.getProperty(try js.runtime.internAtom("__outer"));
    defer outer_fn.free(js.runtime);
    const outer_obj = zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(outer_fn).?;
    const outer_fb = outer_obj.u.bytecode_function.function_bytecode.?;
    const state = zjs.exec.small_inline.callerState(outer_fb);
    try std.testing.expect(state != null);
    try std.testing.expect(state.?.inlined_len >= 1);
    try std.testing.expect(state.?.apply_forward[0].call_pc != std.math.maxInt(u32));
    try std.testing.expect(outer_fb.applyForwardInlined());
}

test "small-function-inlining L1: next-entry take does not leak initialize return" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function K() { this.initialize.apply(this, arguments); }
        \\K.prototype.initialize = function (a, b) { this.a = a; this.b = b; };
        \\function batch(n) {
        \\  var i, s = 0, p;
        \\  for (i = 0; i < n; i++) { p = new K(1, 2); s = s + p.a; }
        \\  return s;
        \\}
        \\assert.sameValue(batch(16), 16);
        \\assert.sameValue(batch(64), 64);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "small-function-inlining L1: forwarded argc is the site argc" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function K() { this.initialize.apply(this, arguments); }
        \\K.prototype.initialize = function () { this.n = arguments.length; };
        \\function outer() { return new K(1, 2, 3); }
        \\var i, o;
        \\for (i = 0; i < 16; i++) o = outer();
        \\assert.sameValue(o.n, 3);
        \\assert.sameValue(outer().n, 3);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "small-function-inlining L1: Error.stack is initialize, apply native, ctor" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function C() { this.initialize.apply(this, arguments); }
        \\C.prototype.initialize = function init(a) { this.a = a; throw new Error("boom"); };
        \\function outer(v) { return new C(v); }
        \\var i;
        \\for (i = 0; i < 16; i++) { try { outer(i); } catch (e) {} }
        \\try { outer(99); } catch (e) {
        \\  var s = String(e.stack);
        \\  var iInit = s.indexOf("init");
        \\  var iApply = s.indexOf("apply (native)");
        \\  var iC = s.indexOf("\n    at C");
        \\  print(iInit >= 0 && iApply > iInit && iC > iApply ? "order" : "bad");
        \\  print(s.indexOf("apply (native)", iApply + 1) == -1 ? "once" : "dup");
        \\}
    , &output);
    defer result.free(js.runtime);
    try std.testing.expectEqualStrings("order\nonce\n", output.buffered());
}

test "small-function-inlining L1: own apply misses take" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function C() { this.initialize.apply(this, arguments); }
        \\C.prototype.initialize = function (a) { this.a = a; this.via = "init"; };
        \\function outer(v) { return new C(v); }
        \\var i;
        \\for (i = 0; i < 16; i++) outer(i);
        \\C.prototype.initialize.apply = function (thisArg, args) {
        \\  thisArg.a = args[0];
        \\  thisArg.via = "own";
        \\};
        \\assert.sameValue(outer(99).via, "own");
        \\assert.sameValue(outer(99).a, 99);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "small-function-inlining L1: replaced Function.prototype.apply misses take" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function C() { this.initialize.apply(this, arguments); }
        \\C.prototype.initialize = function (a) { this.a = a; };
        \\function outer(v) { return new C(v); }
        \\var i;
        \\for (i = 0; i < 16; i++) outer(i);
        \\var saved = Function.prototype.apply;
        \\var seen = 0;
        \\Function.prototype.apply = function (thisArg, args) {
        \\  seen += 1;
        \\  return saved.call(this, thisArg, args);
        \\};
        \\try {
        \\  assert.sameValue(outer(7).a, 7);
        \\  assert.sameValue(seen, 1);
        \\} finally {
        \\  Function.prototype.apply = saved;
        \\}
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "flat string strict-eq matches content across distinct objects" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function check(cond) { if (!cond) throw new Error("streq"); }
        \\var lit = "k0";
        \\var made = "k" + 0;
        \\var other = "k32";
        \\var empty_a = "";
        \\var empty_b = "" + "";
        \\check(lit === made);
        \\check(made === "k0");
        \\check(!(lit === other));
        \\check(lit !== other);
        \\check(empty_a === empty_b);
        \\check(!("" === "k0"));
        \\check(("α" + "") === "α");
        \\var acc = 0;
        \\var i = 0;
        \\while (i < 64) {
        \\    if (("k" + i) === "k32") acc = acc + 1;
        \\    i = i + 1;
        \\}
        \\check(acc === 1);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}
