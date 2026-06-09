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

pub const ResumeState = struct {
    throw_on_entry: bool = false,
    catch_target: ?usize = null,
};

const AwaitSuspendMode = enum {
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

pub fn reserveGeneratorStackAdditional(rt: *core.JSRuntime, stack: *stack_mod.Stack, generator: *core.Object, additional: usize) !void {
    const values = generator.generatorStack();
    const capacity = generator.generatorStackCapacity();
    if (values.len > stack.limit) return error.StackOverflow;
    if (additional > stack.limit - values.len) return error.StackOverflow;
    const needed = values.len + additional;
    if (needed <= capacity) return;

    var next_capacity = if (capacity == 0) @as(usize, 8) else capacity;
    while (next_capacity < needed) {
        next_capacity *= 2;
        if (next_capacity > stack.limit) {
            next_capacity = stack.limit;
            break;
        }
    }

    const next = try stack.memory.alloc(core.JSValue, next_capacity);
    errdefer stack.memory.free(core.JSValue, next);
    @memcpy(next[0..values.len], values);
    try generator.writeValueSliceBarrier(rt, next[0..values.len]);
    generator.generatorStackSlot().* = next[0..values.len];
    generator.generatorStackCapacitySlot().* = next_capacity;
    if (capacity != 0) {
        stack.memory.free(core.JSValue, values.ptr[0..capacity]);
    } else if (values.len != 0) {
        stack.memory.free(core.JSValue, values);
    }
}

pub fn saveGeneratorExecutionState(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    generator: *core.Object,
    pc: usize,
) !void {
    generator.generatorPcSlot().* = pc;
    try generator.writeValueSliceBarrier(ctx.runtime, stack.values);
    try generator.writeValueSliceBarrier(ctx.runtime, frame.locals);
    try generator.writeValueSliceBarrier(ctx.runtime, frame.args);
    try generator.writeValueSliceBarrier(ctx.runtime, frame.var_refs);
    const old_stack = generator.generatorStack();
    const old_stack_capacity = generator.generatorStackCapacity();
    const old_frame_locals = generator.generatorFrameLocals();
    const old_frame_args = generator.generatorFrameArgs();
    const old_frame_var_refs = generator.generatorFrameVarRefs();
    const old_frame_locals_uninit = generator.generatorFrameLocalsUninit();
    generator.generatorStackSlot().* = stack.values;
    generator.generatorStackCapacitySlot().* = stack.capacity;
    generator.generatorFrameLocalsSlot().* = frame.locals;
    generator.generatorFrameArgsSlot().* = frame.args;
    generator.generatorFrameVarRefsSlot().* = frame.var_refs;
    generator.generatorFrameLocalsUninitSlot().* = frame.locals_uninit;
    stack.values = &.{};
    stack.capacity = 0;
    frame.locals = &.{};
    frame.args = &.{};
    frame.var_refs = &.{};
    frame.locals_uninit = &.{};
    frame.locals_uninit_count = 0;
    frame.locals_on_heap = false;
    frame.locals_uninit_on_heap = false;
    frame.args_on_heap = false;
    frame.original_args_on_heap = false;
    frame.var_refs_on_heap = false;

    for (old_stack) |stored| stored.free(ctx.runtime);
    if (old_stack_capacity != 0) {
        ctx.runtime.memory.free(core.JSValue, old_stack.ptr[0..old_stack_capacity]);
    } else if (old_stack.len != 0) {
        ctx.runtime.memory.free(core.JSValue, old_stack);
    }
    freeValueSlice(ctx.runtime, old_frame_locals);
    freeValueSlice(ctx.runtime, old_frame_args);
    freeValueSlice(ctx.runtime, old_frame_var_refs);
    if (old_frame_locals_uninit.len != 0) ctx.runtime.memory.free(bool, old_frame_locals_uninit);
}

pub fn resumeExecutionState(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    generator: ?*core.Object,
    resume_value: ?core.JSValue,
    comptime generatorYieldStarSuspended: anytype,
    comptime generatorResumeCompletionType: anytype,
    comptime setGeneratorYieldStarSuspended: anytype,
    comptime setGeneratorResumeCompletionType: anytype,
) !ResumeState {
    const generator_object = generator orelse return .{};
    return resumeExecutionStateRaw(ctx, stack, function, frame, generator_object, resume_value, generatorYieldStarSuspended, generatorResumeCompletionType, setGeneratorYieldStarSuspended, setGeneratorResumeCompletionType);
}

fn resumeExecutionStateRaw(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    generator: *core.Object,
    resume_value: ?core.JSValue,
    comptime generatorYieldStarSuspended: anytype,
    comptime generatorResumeCompletionType: anytype,
    comptime setGeneratorYieldStarSuspended: anytype,
    comptime setGeneratorResumeCompletionType: anytype,
) !ResumeState {
    if (generator.generatorPc() == 0) {
        generator.generatorJustYieldedSlot().* = false;
        return .{};
    }

    const resume_pc = generator.generatorPc();
    const generator_started = generator.generatorStarted();
    const was_yield_star_suspended = generator_started and generatorYieldStarSuspended(ctx.runtime, generator);
    const completion_type = if (generator_started) generatorResumeCompletionType(ctx.runtime, generator) else 0;
    const resume_needs_branch_false = generator_started and
        resume_pc > 0 and
        resume_pc <= function.code.len and
        function.code[resume_pc - 1] == bytecode.opcode.op.yield and
        resume_pc < function.code.len and
        (function.code[resume_pc] == bytecode.opcode.op.if_false or function.code[resume_pc] == bytecode.opcode.op.if_false8);

    var resume_push_count: usize = if (!generator_started)
        0
    else if (was_yield_star_suspended)
        2
    else if (completion_type == 2)
        0
    else
        1;
    if (resume_needs_branch_false) resume_push_count += 1;
    try reserveGeneratorStackAdditional(ctx.runtime, stack, generator, resume_push_count);

    generator.generatorJustYieldedSlot().* = false;
    frame.pc = resume_pc;
    frame.releaseOwnedStorage(&ctx.runtime.memory, ctx.runtime);
    frame.locals = generator.generatorFrameLocals();
    frame.locals_on_heap = frame.locals.len != 0;
    frame.args = generator.generatorFrameArgs();
    frame.original_args = &.{};
    frame.args_on_heap = true;
    frame.original_args_on_heap = false;
    frame.var_refs = generator.generatorFrameVarRefs();
    frame.var_refs_on_heap = frame.var_refs.len != 0;
    frame.locals_uninit = generator.generatorFrameLocalsUninit();
    frame.locals_uninit_on_heap = frame.locals_uninit.len != 0;
    frame.recomputeLocalsUninitCount();
    frame.global_lexical_sync_slots = &.{};
    frame.global_lexical_sync_indices = &.{};
    frame.global_lexical_sync_env = null;
    frame.global_lexical_sync_checked = false;
    generator.generatorFrameLocalsSlot().* = &.{};
    generator.generatorFrameArgsSlot().* = &.{};
    generator.generatorFrameVarRefsSlot().* = &.{};
    generator.generatorFrameLocalsUninitSlot().* = &.{};
    stack.values = generator.generatorStack();
    stack.capacity = generator.generatorStackCapacity();
    generator.generatorStackSlot().* = &.{};
    generator.generatorStackCapacitySlot().* = 0;
    const catch_target = activeCatchTargetForPc(function, frame.pc);

    if (!generator_started) return .{ .catch_target = catch_target };
    if (was_yield_star_suspended) {
        try setGeneratorYieldStarSuspended(ctx.runtime, generator, false);
        try setGeneratorResumeCompletionType(ctx.runtime, generator, 0);
        stack.pushAssumeCapacity(resume_value orelse core.JSValue.undefinedValue());
        stack.pushOwnedAssumeCapacity(core.JSValue.int32(completion_type));
    } else {
        if (completion_type == 2) {
            try setGeneratorResumeCompletionType(ctx.runtime, generator, 0);
            if (resume_needs_branch_false) {
                stack.pushOwnedAssumeCapacity(core.JSValue.boolean(false));
            }
            return .{ .throw_on_entry = true, .catch_target = catch_target };
        }
        stack.pushAssumeCapacity(resume_value orelse core.JSValue.undefinedValue());
        if (completion_type != 0) try setGeneratorResumeCompletionType(ctx.runtime, generator, 0);
    }
    if (resume_needs_branch_false) {
        stack.pushOwnedAssumeCapacity(core.JSValue.boolean(false));
    }
    return .{ .catch_target = catch_target };
}

pub fn completeResumeState(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    state: ResumeState,
    resume_value: ?core.JSValue,
    comptime closeForAwaitIteratorForPendingError: anytype,
    comptime closeStackTopForOfIteratorForPendingError: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !?usize {
    var catch_target = state.catch_target;
    if (!state.throw_on_entry) return catch_target;
    const thrown = resume_value orelse core.JSValue.undefinedValue();
    _ = ctx.throwValue(thrown.dup());
    try closeIteratorForPendingError(ctx, output, global, stack, function, frame, closeForAwaitIteratorForPendingError, closeStackTopForOfIteratorForPendingError);
    if (!(try handleCatchableRuntimeError(ctx, stack, frame, &catch_target, global, error.JSException))) {
        return error.JSException;
    }
    return catch_target;
}

fn handleAwaitError(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    err: anyerror,
    comptime closeForAwaitIteratorForPendingError: anytype,
    comptime closeStackTopForOfIteratorForPendingError: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !bool {
    try closeIteratorForPendingError(ctx, output, global, stack, function, frame, closeForAwaitIteratorForPendingError, closeStackTopForOfIteratorForPendingError);
    return try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err);
}

pub fn stopBeforePc(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    generator: ?*core.Object,
    stop_before_pc: ?usize,
) !?core.JSValue {
    const stop_pc = stop_before_pc orelse return null;
    if (frame.pc != stop_pc) return null;
    if (generator) |generator_object| {
        try saveGeneratorExecutionState(ctx, stack, frame, generator_object, stop_pc);
    }
    return core.JSValue.undefinedValue();
}

pub fn initialYield(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    generator: ?*core.Object,
    stop_on_yield: bool,
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
    catch_target: *?usize,
    comptime iteratorForValue: anytype,
    comptime iteratorStepResult: anytype,
    comptime setGeneratorYieldStarSuspended: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !Result {
    return yieldStarRaw(ctx, output, global, stack, function, frame, generator, stop_on_yield, iteratorForValue, iteratorStepResult, setGeneratorYieldStarSuspended) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) {
            return .continue_loop;
        }
        return err;
    };
}

fn yieldStarRaw(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    generator: ?*core.Object,
    stop_on_yield: bool,
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
    suspend_on_module_await: bool,
    stop_on_yield: bool,
    catch_target: *?usize,
    comptime settlePendingPromiseReaction: anytype,
    comptime awaitPendingPromise: anytype,
    comptime drainPendingPromiseJobs: anytype,
    comptime awaitThenableValue: anytype,
    comptime closeForAwaitIteratorForPendingError: anytype,
    comptime closeStackTopForOfIteratorForPendingError: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !Result {
    return awaitValueRaw(ctx, output, global, stack, function, frame, generator, suspend_on_module_await, stop_on_yield, settlePendingPromiseReaction, awaitPendingPromise, drainPendingPromiseJobs, awaitThenableValue) catch |err| {
        if (try handleAwaitError(ctx, output, global, stack, function, frame, catch_target, err, closeForAwaitIteratorForPendingError, closeStackTopForOfIteratorForPendingError, handleCatchableRuntimeError)) {
            return .continue_loop;
        }
        return err;
    };
}

fn awaitValueRaw(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    generator: ?*core.Object,
    suspend_on_module_await: bool,
    stop_on_yield: bool,
    comptime settlePendingPromiseReaction: anytype,
    comptime awaitPendingPromise: anytype,
    comptime drainPendingPromiseJobs: anytype,
    comptime awaitThenableValue: anytype,
) !Result {
    const suspend_mode = awaitSuspendMode(function, suspend_on_module_await, stop_on_yield);
    const awaited = try stack.pop();
    defer awaited.free(ctx.runtime);
    if (suspend_mode == .raw) {
        if (try suspendAwaitValue(ctx, stack, frame, generator, true, awaited)) |result| return result;
        try stack.push(awaited);
        return .continue_loop;
    }
    const promise = objectFromValue(awaited) orelse {
        if (try awaitThenableValue(ctx, output, global, awaited, function, frame)) |value| {
            defer value.free(ctx.runtime);
            if (try suspendAwaitValue(ctx, stack, frame, generator, suspend_mode == .settled, value)) |result| return result;
            try stack.push(value);
            return .none;
        }
        if (try suspendAwaitValue(ctx, stack, frame, generator, suspend_mode == .settled, awaited)) |result| return result;
        try stack.push(awaited);
        return .continue_loop;
    };
    if (promise.class_id != core.class.ids.promise) {
        if (try awaitThenableValue(ctx, output, global, awaited, function, frame)) |value| {
            defer value.free(ctx.runtime);
            if (try suspendAwaitValue(ctx, stack, frame, generator, suspend_mode == .settled, value)) |result| return result;
            try stack.push(value);
            return .none;
        }
        if (try suspendAwaitValue(ctx, stack, frame, generator, suspend_mode == .settled, awaited)) |result| return result;
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
        return error.JSException;
    }
    if (try suspendAwaitValue(ctx, stack, frame, generator, suspend_mode == .settled, result)) |suspended| return suspended;
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
) !?Result {
    if (!suspend_on_await) return null;
    const generator_object = generator orelse return null;
    try saveGeneratorExecutionState(ctx, stack, frame, generator_object, frame.pc);
    generator_object.generatorStartedSlot().* = true;
    generator_object.generatorJustYieldedSlot().* = true;
    return .{ .return_value = value.dup() };
}

fn awaitSuspendMode(function: *const bytecode.Bytecode, suspend_on_module_await: bool, stop_on_yield: bool) AwaitSuspendMode {
    if (suspend_on_module_await and function.flags.is_module) return .settled;
    if (suspend_on_module_await and function.flags.is_async) return .raw;
    if (stop_on_yield and function.flags.is_async) return .drain;
    return .none;
}

fn activeCatchTargetForPc(function: *const bytecode.Bytecode, start_pc: usize) ?usize {
    var pc: usize = 0;
    var found: ?usize = null;
    while (pc < start_pc and pc < function.code.len) {
        const op_id = function.code[pc];
        if (op_id == bytecode.opcode.op.@"catch") {
            if (pc + 5 > function.code.len) return found;
            const operand_pc = pc + 1;
            const diff = readInt(i32, function.code[operand_pc..][0..4]);
            const target = @as(i64, @intCast(operand_pc)) + @as(i64, diff);
            if (target > start_pc and target <= function.code.len) found = @intCast(target);
        }
        const size = bytecode.opcode.sizeOf(op_id);
        if (size == 0) return found;
        pc += size;
    }
    return found;
}

fn closeIteratorForPendingError(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    comptime closeForAwaitIteratorForPendingError: anytype,
    comptime closeStackTopForOfIteratorForPendingError: anytype,
) !void {
    if (frame.pc < function.code.len and function.code[frame.pc] == bytecode.opcode.op.iterator_get_value_done) {
        try closeForAwaitIteratorForPendingError(ctx, output, global, stack);
    } else {
        try closeStackTopForOfIteratorForPendingError(ctx, output, global, stack);
    }
}

fn objectFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

fn freeValueSlice(rt: *core.JSRuntime, values: []core.JSValue) void {
    for (values) |value| value.free(rt);
    if (values.len != 0) rt.memory.free(core.JSValue, values);
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
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
