const std = @import("std");

const bytecode = @import("../bytecode/root.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const stack_mod = @import("stack.zig");

pub const Result = union(enum) {
    none,
    continue_loop,
    return_value: core.JSValue,
};

pub const AwaitSuspendMode = enum {
    none,
    /// Async generators drain promise jobs for internal await points, then keep
    /// executing until the next generator yield.
    drain,
    /// Top-level module await currently resumes with the already-settled value.
    settled,
    /// Async functions yield the raw awaited value; the caller wires it through
    /// Promise.resolve(...).then(resume, reject), matching QuickJS.
    raw,
};

pub fn initialYield(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    generator: ?*core.Object,
    stop_on_yield: bool,
    comptime saveGeneratorExecutionState: anytype,
) !Result {
    if (stop_on_yield) {
        if (generator) |generator_object| {
            try saveGeneratorExecutionState(ctx, stack, frame, generator_object, frame.pc);
            generator_object.generatorStartedSlot().* = true;
            generator_object.generatorJustYieldedSlot().* = true;
        }
        return .{ .return_value = core.JSValue.undefinedValue() };
    }
    try stack.pushOwned(core.JSValue.undefinedValue());
    return .none;
}

pub fn yieldValue(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    generator: ?*core.Object,
    stop_on_yield: bool,
    comptime saveGeneratorExecutionState: anytype,
) !Result {
    const value = try stack.pop();
    var value_owned = true;
    errdefer if (value_owned) value.free(ctx.runtime);
    if (stop_on_yield) {
        if (generator) |generator_object| {
            try saveGeneratorExecutionState(ctx, stack, frame, generator_object, frame.pc);
            generator_object.generatorStartedSlot().* = true;
            generator_object.generatorJustYieldedSlot().* = true;
        }
        value_owned = false;
        return .{ .return_value = value };
    }
    try stack.reserveAdditional(1);
    value.free(ctx.runtime);
    value_owned = false;
    stack.pushOwnedAssumeCapacity(core.JSValue.undefinedValue());
    return .none;
}

pub fn yieldStar(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    generator: ?*core.Object,
    stop_on_yield: bool,
    comptime saveGeneratorExecutionState: anytype,
    comptime iteratorForValue: anytype,
    comptime iteratorStepResult: anytype,
    comptime setGeneratorYieldStarSuspended: anytype,
) !Result {
    const opcode_pc = frame.pc - 1;
    const expanded_lowering = frame.pc < function.code.len and function.code[frame.pc] == bytecode.opcode.op.dup;
    if (expanded_lowering) {
        const result_object = try stack.pop();
        var result_object_owned = true;
        errdefer if (result_object_owned) result_object.free(ctx.runtime);
        if (stop_on_yield) {
            if (generator) |generator_object| {
                try saveGeneratorExecutionState(ctx, stack, frame, generator_object, frame.pc);
                try setGeneratorYieldStarSuspended(ctx.runtime, generator_object, true);
                generator_object.generatorStartedSlot().* = true;
                generator_object.generatorJustYieldedSlot().* = true;
            } else {
                try stack.reserveAdditional(2);
                result_object.free(ctx.runtime);
                result_object_owned = false;
                stack.pushOwnedAssumeCapacity(core.JSValue.undefinedValue());
                stack.pushOwnedAssumeCapacity(core.JSValue.int32(0));
                return .none;
            }
            result_object_owned = false;
            return .{ .return_value = result_object };
        }
        try stack.reserveAdditional(2);
        result_object.free(ctx.runtime);
        result_object_owned = false;
        stack.pushOwnedAssumeCapacity(core.JSValue.undefinedValue());
        stack.pushOwnedAssumeCapacity(core.JSValue.int32(0));
        return .none;
    }

    var iterator_value: core.JSValue = undefined;
    var using_stored_iterator = false;
    var next_arg = core.JSValue.undefinedValue();
    var next_arg_needs_free = false;
    defer if (next_arg_needs_free) next_arg.free(ctx.runtime);
    if (generator) |generator_object| {
        if (generator_object.generatorYieldStarIterator()) |stored| {
            iterator_value = stored.dup();
            using_stored_iterator = true;
            if (generator_object.generatorStarted() and stack.values.len > 0) {
                next_arg = try stack.pop();
                next_arg_needs_free = true;
            }
        } else {
            const iterable = try stack.pop();
            defer iterable.free(ctx.runtime);
            iterator_value = try iteratorForValue(ctx, output, global, iterable, function, frame);
        }
    } else {
        const iterable = try stack.pop();
        defer iterable.free(ctx.runtime);
        iterator_value = try iteratorForValue(ctx, output, global, iterable, function, frame);
    }
    defer iterator_value.free(ctx.runtime);
    const step = try iteratorStepResult(ctx, output, global, iterator_value, next_arg);
    defer step.result.free(ctx.runtime);
    defer step.value.free(ctx.runtime);
    if (step.done) {
        try stack.reserveAdditional(1);
        if (generator) |generator_object| {
            generator_object.clearOptionalValueSlot(ctx.runtime, generator_object.generatorYieldStarIteratorSlot());
        }
        stack.pushAssumeCapacity(step.value);
        return .continue_loop;
    }
    if (stop_on_yield) {
        if (generator) |generator_object| {
            if (!using_stored_iterator) try generator_object.setOptionalValueSlot(ctx.runtime, generator_object.generatorYieldStarIteratorSlot(), iterator_value.dup());
            try saveGeneratorExecutionState(ctx, stack, frame, generator_object, opcode_pc);
            generator_object.generatorStartedSlot().* = true;
            generator_object.generatorJustYieldedSlot().* = true;
        }
        return .{ .return_value = step.result.dup() };
    }
    try stack.reserveAdditional(1);
    stack.pushOwnedAssumeCapacity(core.JSValue.undefinedValue());
    return .none;
}

pub fn awaitValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    generator: ?*core.Object,
    suspend_mode: AwaitSuspendMode,
    comptime settlePendingPromiseReaction: anytype,
    comptime awaitPendingPromise: anytype,
    comptime drainPendingPromiseJobs: anytype,
    comptime awaitThenableValue: anytype,
    comptime saveGeneratorExecutionState: anytype,
) !Result {
    const awaited = try stack.pop();
    defer awaited.free(ctx.runtime);
    if (suspend_mode == .raw) {
        if (try suspendAwaitValue(ctx, stack, frame, generator, true, awaited, saveGeneratorExecutionState)) |result| return result;
        try stack.push(awaited);
        return .continue_loop;
    }
    const promise = objectFromValue(awaited) orelse {
        if (try awaitThenableValue(ctx, output, global, awaited, function, frame)) |value| {
            defer value.free(ctx.runtime);
            if (try suspendAwaitValue(ctx, stack, frame, generator, suspend_mode == .settled, value, saveGeneratorExecutionState)) |result| return result;
            try stack.push(value);
            return .none;
        }
        if (try suspendAwaitValue(ctx, stack, frame, generator, suspend_mode == .settled, awaited, saveGeneratorExecutionState)) |result| return result;
        try stack.push(awaited);
        return .continue_loop;
    };
    if (promise.class_id != core.class.ids.promise) {
        if (try awaitThenableValue(ctx, output, global, awaited, function, frame)) |value| {
            defer value.free(ctx.runtime);
            if (try suspendAwaitValue(ctx, stack, frame, generator, suspend_mode == .settled, value, saveGeneratorExecutionState)) |result| return result;
            try stack.push(value);
            return .none;
        }
        if (try suspendAwaitValue(ctx, stack, frame, generator, suspend_mode == .settled, awaited, saveGeneratorExecutionState)) |result| return result;
        try stack.push(awaited);
        return .continue_loop;
    }
    try settlePendingPromiseReaction(ctx, output, global, promise);
    if ((suspend_mode == .settled or suspend_mode == .drain) and promise.promiseResult() == null) try drainPendingPromiseJobs(ctx, output, global);
    if (promise.promiseResult() == null) try awaitPendingPromise(ctx, output, global, promise);
    const result = if (promise.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
    defer result.free(ctx.runtime);
    if (promise.promiseIsRejected()) {
        _ = ctx.throwValue(result.dup());
        return error.Test262Error;
    }
    if (try suspendAwaitValue(ctx, stack, frame, generator, suspend_mode == .settled, result, saveGeneratorExecutionState)) |suspended| return suspended;
    try stack.push(result);
    return .none;
}

fn suspendAwaitValue(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    generator: ?*core.Object,
    suspend_on_await: bool,
    value: core.JSValue,
    comptime saveGeneratorExecutionState: anytype,
) !?Result {
    if (!suspend_on_await) return null;
    const generator_object = generator orelse return null;
    try saveGeneratorExecutionState(ctx, stack, frame, generator_object, frame.pc);
    generator_object.generatorStartedSlot().* = true;
    generator_object.generatorJustYieldedSlot().* = true;
    return .{ .return_value = value.dup() };
}

fn objectFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

fn testSaveGeneratorExecutionState(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    generator: *core.Object,
    pc: usize,
) !void {
    _ = ctx;
    _ = stack;
    _ = frame;
    _ = generator;
    _ = pc;
}

fn testIteratorForValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterable: core.JSValue,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !core.JSValue {
    _ = ctx;
    _ = output;
    _ = global;
    _ = iterable;
    _ = function;
    _ = frame;
    return error.UnexpectedIteratorRequest;
}

const TestIteratorStepResult = struct {
    result: core.JSValue,
    value: core.JSValue,
    done: bool,
};

fn testDoneIteratorStepResult(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator: core.JSValue,
    next_arg: core.JSValue,
) !TestIteratorStepResult {
    _ = ctx;
    _ = output;
    _ = global;
    _ = iterator;
    _ = next_arg;
    return .{
        .result = core.JSValue.undefinedValue(),
        .value = core.JSValue.int32(7),
        .done = true,
    };
}

fn testSetGeneratorYieldStarSuspended(rt: *core.JSRuntime, generator: *core.Object, value: bool) !void {
    _ = rt;
    generator.generatorYieldStarSuspendedSlot().* = value;
}

