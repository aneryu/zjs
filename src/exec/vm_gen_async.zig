const std = @import("std");

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const call_runtime = @import("call_runtime.zig");
const forof_ops = @import("forof_ops.zig");
const promise_ops = @import("promise_ops.zig");
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
    /// Legacy synchronous-drain mode. Kept for the non-suspending helper legs;
    /// module TLA now uses `.raw` and is resumed as an ordered Promise reaction.
    settled,
    /// Async functions and async generators yield the raw awaited value; the
    /// caller wires it through Promise.resolve(...).then(resume, reject),
    /// matching QuickJS OP_await (quickjs.c:20592: save frame, return
    /// FUNC_RET_AWAIT with the operand at cur_sp[-1]).
    raw,
};

pub fn reserveGeneratorStackAdditional(rt: *core.JSRuntime, stack: *stack_mod.Stack, generator: *core.Object, additional: usize) !void {
    const execution = generator.generatorPayloadPtr().execution orelse return error.TypeError;
    return reserveGeneratorExecutionStackAdditional(rt, stack, execution, additional);
}

inline fn reserveGeneratorExecutionStackAdditional(rt: *core.JSRuntime, stack: *stack_mod.Stack, execution: *core.object.GeneratorExecutionState, additional: usize) !void {
    const parked = &execution.suspended.storage.stack;
    if (parked.values.len <= stack.stackLimit() and
        additional <= stack.stackLimit() - parked.values.len and
        parked.values.len <= parked.capacity and
        additional <= parked.capacity - parked.values.len)
    {
        return;
    }
    const resident_backing = execution.stackUsesCombinedStorage();
    try parked.ensureAdditionalWithResidentBacking(rt, stack.stackLimit(), additional, resident_backing);
}

fn sameSlice(comptime T: type, left: []T, right: []T) bool {
    return left.len == right.len and (left.len == 0 or left.ptr == right.ptr);
}

fn residentFrameViewsMatch(state: *const core.object.SuspendedExecutionState, frame: *const frame_mod.Frame) bool {
    const parked = state.storage.frame;
    return sameSlice(core.JSValue, parked.storage, frame.storage_values) and
        sameSlice(core.JSValue, parked.locals, frame.locals) and
        sameSlice(core.JSValue, parked.args, frame.args) and
        sameSlice(*core.VarRef, parked.var_refs, frame.var_refs) and
        sameSlice(?*core.VarRef, parked.open_var_refs, frame.open_var_refs);
}

fn clearLiveExecutionViews(stack: *stack_mod.Stack, frame: *frame_mod.Frame) void {
    stack.clearBacking();
    stack.setArenaWindow(false);
    stack.setResidentWindow(false);
    frame.storage_values = &.{};
    frame.ownership.storage = .borrowed;
    frame.locals = &.{};
    frame.args = &.{};
    frame.var_refs = &.{};
    frame.ownership.var_refs = .owned;
    frame.open_var_refs = &.{};
}

/// Park live execution views without moving the resident frame on the common
/// path. QuickJS keeps one JSAsyncFunctionState backing allocation and changes
/// only cur_sp/cur_pc at a suspension; this is the corresponding zjs seam.
///
/// A defensive frame-growth path can replace one of the combined windows. In
/// that case publish the live descriptors once and return to the legacy
/// transfer model. Normal compiled generator frames are sized exactly and stay
/// on the descriptor-free resident path after their first suspension.
fn parkGeneratorExecutionState(
    rt: *core.JSRuntime,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    execution: *core.object.GeneratorExecutionState,
    pc: usize,
    catch_target_pc: u32,
    has_frame: bool,
) void {
    const state = &execution.suspended;
    const was_resident_owner = state.running_aliases and state.resident_storage_owner;
    const frame_views_match = was_resident_owner and residentFrameViewsMatch(state, frame);

    if (frame_views_match) {
        const old_stack = state.storage.stack;
        const old_stack_uses_combined_storage = execution.stackUsesCombinedStorage();
        state.storage.stack = .{
            .values = stack.liveValues(),
            .capacity = stack.capacity,
        };
        state.pc = pc;
        state.catch_target_pc = catch_target_pc;
        state.has_frame = has_frame;
        state.running_aliases = false;
        clearLiveExecutionViews(stack, frame);

        // Stack growth copies raw owned slots to its new buffer. Once the new
        // view is authoritative, release only the old backing bytes; its stale
        // slot copies must never decrement references.
        if (old_stack.capacity != 0 and
            old_stack.values.ptr != state.storage.stack.values.ptr and
            !old_stack_uses_combined_storage)
        {
            rt.memory.free(core.JSValue, old_stack.values.ptr[0..old_stack.capacity]);
        }
        return;
    }

    if (was_resident_owner) {
        // Resident frame growth is expected only on defensive malformed or
        // synthetic bytecode paths. The first such change still starts from
        // the combined FAM backing, which remains owned by the execution-state
        // allocation after the live replacement is published.
        std.debug.assert(execution.frameUsesCombinedStorage() or state.storage.frame.storage.len == 0);
    }

    const old_stack = state.storage.stack;
    const old_stack_uses_combined_storage = execution.stackUsesCombinedStorage();
    var replacement = core.object.SuspendedExecutionStorage{
        .stack = .{
            .values = stack.liveValues(),
            .capacity = stack.capacity,
        },
        .frame = .{
            .storage = frame.storage_values,
            .locals = frame.locals,
            .args = frame.args,
            .var_refs = frame.var_refs,
            .open_var_refs = frame.open_var_refs,
        },
    };
    clearLiveExecutionViews(stack, frame);
    state.replaceStorageOwned(pc, catch_target_pc, &replacement, rt);
    state.has_frame = has_frame;

    if (was_resident_owner and old_stack.capacity != 0 and
        old_stack.values.ptr != state.storage.stack.values.ptr and
        !old_stack_uses_combined_storage)
    {
        rt.memory.free(core.JSValue, old_stack.values.ptr[0..old_stack.capacity]);
    }

    if (has_frame and !was_resident_owner and execution.canRetainResidentStorageOwnership()) {
        state.resident_storage_owner = true;
    }
}

/// Keep the ownership handoff as one cold-ish seam. Every yield/await opcode
/// reaches this helper, and duplicating its reset/swap/deinit sequence into
/// each handler measurably bloats the ReleaseFast instruction working set.
pub noinline fn saveGeneratorExecutionState(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    generator: *core.Object,
    pc: usize,
    catch_target: ?usize,
) !void {
    const execution = generator.generatorPayloadPtr().execution orelse return error.TypeError;
    // Generator frames must run on heap-backed stacks: suspension transfers
    // buffer ownership into the generator object, which is incompatible with
    // borrowed VM stack-arena windows.
    std.debug.assert(!stack.isArenaWindow());
    std.debug.assert(frame.ownership.storage == .owned or frame.storage_values.len == 0 or execution.frameUsesCombinedStorage());
    std.debug.assert(frame.ownership.var_refs == .owned or frame.var_refs.len == 0);
    std.debug.assert(frame.open_var_refs.len == 0 or frame.storage_values.len != 0);
    if (frame.open_var_refs.len != @as(usize, frame.function.open_var_ref_count)) return error.InvalidBytecode;
    // Encode every fallible scalar before changing any ownership. An invalid
    // oversized target must leave the live VM state intact for normal unwind.
    const catch_target_pc = if (catch_target) |target|
        std.math.cast(u32, target) orelse return error.InvalidBytecode
    else
        std.math.maxInt(u32);
    parkGeneratorExecutionState(ctx.runtime, stack, frame, execution, pc, catch_target_pc, true);
}

pub fn resumeExecutionState(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    generator: ?*core.Object,
    resume_value: ?core.JSValue,
) !ResumeState {
    const generator_object = generator orelse return .{};
    return resumeExecutionStateRaw(ctx, stack, function, frame, generator_object, resume_value);
}

/// Install parked buffers after every fallible resume preparation has
/// completed. The typed state keeps these addresses as non-owning aliases while
/// running, mirroring qjs's resident async frame with `cur_sp == NULL`. GC and
/// teardown consult `running_aliases`, so only the live Frame/Stack owns them.
inline fn installSuspendedExecutionStorage(
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    state: *core.object.SuspendedExecutionState,
    resident_stack: bool,
    resident_frame: bool,
) void {
    const suspended = &state.storage;
    const resident_owner = state.resident_storage_owner;
    frame.storage_values = suspended.frame.storage;
    frame.ownership.storage = if (frame.storage_values.len != 0 and !resident_frame and !resident_owner) .owned else .borrowed;
    frame.locals = suspended.frame.locals;
    frame.args = suspended.frame.args;
    frame.var_refs = suspended.frame.var_refs;
    frame.ownership.var_refs = .owned;
    frame.open_var_refs = suspended.frame.open_var_refs;
    stack.installBacking(suspended.stack.values, suspended.stack.capacity);
    stack.setArenaWindow(false);
    stack.setResidentWindow(resident_stack or resident_owner);
    state.beginRunningAliases();
}

/// Clear aliases after completion/error. A suspension already republished the
/// live owners and cleared `running_aliases`, making this a cheap no-op there.
pub fn finishExecutionStateRun(rt: *core.JSRuntime, stack: *stack_mod.Stack, frame: *frame_mod.Frame, generator: ?*core.Object) void {
    const object = generator orelse return;
    // The payload outlives its nullable execution record. Internal module
    // continuations can complete and release that record before this defer.
    const execution = object.generatorPayloadPtr().execution orelse return;
    const state = &execution.suspended;
    if (!state.running_aliases) return;
    if (state.resident_storage_owner) {
        parkGeneratorExecutionState(rt, stack, frame, execution, frame.pc, std.math.maxInt(u32), false);
        return;
    }
    state.finishRunningAliases();
}

/// Keep generator-only ownership installation out of the universal
/// runWithArgsState frame. The nullable wrapper still folds to a cheap null
/// return for ordinary calls, while an actual resume crosses this boundary
/// once, like qjs's async_func_resume re-entry seam.
noinline fn resumeExecutionStateRaw(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    generator: *core.Object,
    resume_value: ?core.JSValue,
) align(64) !ResumeState {
    const payload = generator.generatorPayloadPtr();
    const execution = payload.execution orelse return error.TypeError;
    const state = &execution.suspended;
    if (!state.has_frame) {
        if (execution.stackUsesCombinedStorage()) {
            std.debug.assert(stack.capacity == 0 and stack.len() == 0);
            stack.installBacking(state.storage.stack.values, state.storage.stack.capacity);
            stack.setArenaWindow(false);
            stack.setResidentWindow(true);
            state.beginRunningAliases();
        }
        payload.just_yielded = false;
        return .{};
    }
    // Resume installs generator-owned heap buffers into the stack; the stack
    // must not be an arena window (its deinit would skip freeing them).
    std.debug.assert(!stack.isArenaWindow());

    const resume_pc = state.pc;
    const generator_started = payload.started;
    const was_yield_star_suspended = generator_started and payload.yield_star_suspended;
    const completion_type = if (generator_started) payload.resume_completion_type else 0;
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
    try reserveGeneratorExecutionStackAdditional(ctx.runtime, stack, execution, resume_push_count);

    payload.just_yielded = false;
    // Started resumes no longer build a throwaway frame slab in zjs_vm. The
    // fresh Frame contains only borrowed call bindings until the resident
    // windows below are installed, so there is no pre-existing storage to
    // close or release here.
    std.debug.assert(frame.storage_values.len == 0);
    std.debug.assert(frame.locals.len == 0 and frame.args.len == 0);
    std.debug.assert(frame.var_refs.len == 0 and frame.open_var_refs.len == 0);
    frame.pc = resume_pc;
    const resident_stack = execution.stackUsesCombinedStorage();
    const resident_frame = execution.frameUsesCombinedStorage();
    if (state.storage.frame.open_var_refs.len != @as(usize, function.open_var_ref_count)) return error.InvalidBytecode;
    installSuspendedExecutionStorage(stack, frame, state, resident_stack, resident_frame);
    // The interpreter's catch target is a control-flow cursor, not frame
    // ownership state.  A suspension can resume in a different leg of a
    // nested try/finally after the saved scalar was produced (notably after a
    // completion is injected and the finally body yields).  Reconstruct the
    // active target from the bytecode at the resumed pc, as QuickJS does when
    // restoring the execution cursor, instead of letting a stale cached
    // target swallow the completion on the next resume.
    const catch_target = activeCatchTargetForPc(function, resume_pc);

    if (!generator_started) return .{ .catch_target = catch_target };
    if (was_yield_star_suspended) {
        payload.yield_star_suspended = false;
        payload.resume_completion_type = 0;
        stack.pushAssumeCapacity(resume_value orelse core.JSValue.undefinedValue());
        stack.pushOwnedAssumeCapacity(core.JSValue.int32(completion_type));
    } else {
        if (completion_type == 2) {
            payload.resume_completion_type = 0;
            if (resume_needs_branch_false) {
                stack.pushOwnedAssumeCapacity(core.JSValue.boolean(false));
            }
            return .{ .throw_on_entry = true, .catch_target = catch_target };
        }
        stack.pushAssumeCapacity(resume_value orelse core.JSValue.undefinedValue());
        if (completion_type != 0) payload.resume_completion_type = 0;
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
) !?usize {
    var catch_target = state.catch_target;
    if (!state.throw_on_entry) return catch_target;
    const thrown = resume_value orelse core.JSValue.undefinedValue();
    _ = ctx.throwValue(thrown.dup());
    try closeIteratorForPendingError(ctx, output, global, stack, function, frame);
    if (!(try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, &catch_target, global, error.JSException))) {
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
) !bool {
    try closeIteratorForPendingError(ctx, output, global, stack, function, frame);
    return try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err);
}

pub fn stopBeforePc(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    generator: ?*core.Object,
    catch_target: ?usize,
    stop_before_pc: ?usize,
) !?core.JSValue {
    const stop_pc = stop_before_pc orelse return null;
    if (frame.pc != stop_pc) return null;
    if (generator) |generator_object| {
        // QuickJS closes parameter-environment refs at the body boundary while
        // keeping arg_buf resident. zjs-side adaptation: args and locals share
        // one open-ref table, so retain entries whose pvalue targets the stable
        // resident arg backing and close only the parameter-environment refs.
        // Later finally-return stops belong to an already-started generator and
        // must keep every open alias parked across the suspension.
        if (!generator_object.generatorStarted()) try frame.closeParameterEnvironmentVarRefs(ctx.runtime);
        try saveGeneratorExecutionState(ctx, stack, frame, generator_object, stop_pc, catch_target);
        generator_object.generatorSuspendKindSlot().* = @intFromEnum(core.object.GeneratorSuspendKind.none);
    }
    return core.JSValue.undefinedValue();
}

pub fn initialYield(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    generator: ?*core.Object,
    catch_target: ?usize,
    stop_on_yield: bool,
) !Result {
    if (stop_on_yield) {
        if (generator) |generator_object| {
            try saveGeneratorExecutionState(ctx, stack, frame, generator_object, frame.pc, catch_target);
            generator_object.generatorSuspendKindSlot().* = @intFromEnum(core.object.GeneratorSuspendKind.none);
            generator_object.generatorStartedSlot().* = true;
            generator_object.generatorJustYieldedSlot().* = true;
        }
        return .{ .return_value = core.JSValue.undefinedValue() };
    }
    try stack.pushOwned(core.JSValue.undefinedValue());
    return .none;
}

pub noinline fn yieldValue(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    generator: ?*core.Object,
    catch_target: ?usize,
    stop_on_yield: bool,
) !Result {
    const value = try stack.pop();
    var value_owned = true;
    errdefer if (value_owned) value.free(ctx.runtime);
    if (stop_on_yield) {
        if (generator) |generator_object| {
            try saveGeneratorExecutionState(ctx, stack, frame, generator_object, frame.pc, catch_target);
            const payload = generator_object.generatorPayloadPtr();
            payload.suspend_kind = @intFromEnum(core.object.GeneratorSuspendKind.yield);
            payload.started = true;
            payload.just_yielded = true;
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

pub noinline fn yieldStar(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    generator: ?*core.Object,
    stop_on_yield: bool,
    catch_target: *?usize,
) !Result {
    return yieldStarRaw(ctx, output, global, stack, function, frame, generator, stop_on_yield, catch_target.*) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) {
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
    catch_target: ?usize,
) !Result {
    const opcode_pc = frame.pc - 1;
    const expanded_lowering = frame.pc < function.code.len and function.code[frame.pc] == bytecode.opcode.op.dup;
    if (expanded_lowering) {
        const result_object = try stack.pop();
        var result_object_owned = true;
        errdefer if (result_object_owned) result_object.free(ctx.runtime);
        if (stop_on_yield) {
            if (generator) |generator_object| {
                try saveGeneratorExecutionState(ctx, stack, frame, generator_object, frame.pc, catch_target);
                generator_object.generatorSuspendKindSlot().* = @intFromEnum(core.object.GeneratorSuspendKind.yield_star);
                try call_runtime.setGeneratorYieldStarSuspended(ctx.runtime, generator_object, true);
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
            if (generator_object.generatorStarted() and stack.len() > 0) {
                next_arg = try stack.pop();
                next_arg_needs_free = true;
            }
        } else {
            const iterable = try stack.pop();
            defer iterable.free(ctx.runtime);
            iterator_value = try call_runtime.iteratorForValue(ctx, output, global, iterable, function, frame);
        }
    } else {
        const iterable = try stack.pop();
        defer iterable.free(ctx.runtime);
        iterator_value = try call_runtime.iteratorForValue(ctx, output, global, iterable, function, frame);
    }
    defer iterator_value.free(ctx.runtime);
    const step = try call_runtime.iteratorStepResult(ctx, output, global, iterator_value, next_arg);
    defer step.result.free(ctx.runtime);
    defer step.value.free(ctx.runtime);
    if (step.done) {
        try stack.reserveAdditional(1);
        if (generator) |generator_object| {
            generator_object.clearGeneratorYieldStarIterator(ctx.runtime);
        }
        stack.pushAssumeCapacity(step.value);
        return .continue_loop;
    }
    if (stop_on_yield) {
        if (generator) |generator_object| {
            if (!using_stored_iterator) generator_object.setGeneratorYieldStarIterator(ctx.runtime, iterator_value.dup());
            try saveGeneratorExecutionState(ctx, stack, frame, generator_object, opcode_pc, catch_target);
            generator_object.generatorSuspendKindSlot().* = @intFromEnum(core.object.GeneratorSuspendKind.yield_star);
            generator_object.generatorStartedSlot().* = true;
            generator_object.generatorJustYieldedSlot().* = true;
        }
        return .{ .return_value = step.result.dup() };
    }
    try stack.reserveAdditional(1);
    stack.pushOwnedAssumeCapacity(core.JSValue.undefinedValue());
    return .none;
}

pub noinline fn awaitValue(
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
) !Result {
    return awaitValueRaw(ctx, output, global, stack, function, frame, generator, suspend_on_module_await, stop_on_yield, catch_target.*) catch |err| {
        if (try handleAwaitError(ctx, output, global, stack, function, frame, catch_target, err)) {
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
    catch_target: ?usize,
) !Result {
    const suspend_mode = awaitSuspendMode(function, suspend_on_module_await, stop_on_yield);
    const awaited = try stack.pop();
    defer awaited.free(ctx.runtime);
    if (suspend_mode == .raw) {
        if (try suspendAwaitValue(ctx, stack, frame, generator, true, awaited, catch_target)) |result| return result;
        try stack.push(awaited);
        return .continue_loop;
    }
    const promise = objectFromValue(awaited) orelse {
        if (try promise_ops.awaitThenableValue(ctx, output, global, awaited, function, frame)) |value| {
            defer value.free(ctx.runtime);
            if (try suspendAwaitValue(ctx, stack, frame, generator, suspend_mode == .settled, value, catch_target)) |result| return result;
            try stack.push(value);
            return .none;
        }
        if (try suspendAwaitValue(ctx, stack, frame, generator, suspend_mode == .settled, awaited, catch_target)) |result| return result;
        try stack.push(awaited);
        return .continue_loop;
    };
    if (promise.class_id != core.class.ids.promise) {
        if (try promise_ops.awaitThenableValue(ctx, output, global, awaited, function, frame)) |value| {
            defer value.free(ctx.runtime);
            if (try suspendAwaitValue(ctx, stack, frame, generator, suspend_mode == .settled, value, catch_target)) |result| return result;
            try stack.push(value);
            return .none;
        }
        if (try suspendAwaitValue(ctx, stack, frame, generator, suspend_mode == .settled, awaited, catch_target)) |result| return result;
        try stack.push(awaited);
        return .continue_loop;
    }
    try promise_ops.settlePendingPromiseReaction(ctx, output, global, promise);
    if (suspend_mode == .settled and promise.promiseResult() == null) try promise_ops.drainPendingPromiseJobs(ctx, output, global);
    if (promise.promiseResult() == null) try promise_ops.awaitPendingPromise(ctx, output, global, promise);
    const result = if (promise.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
    defer result.free(ctx.runtime);
    if (promise.promiseIsRejected()) {
        _ = ctx.throwValue(result.dup());
        return error.JSException;
    }
    if (try suspendAwaitValue(ctx, stack, frame, generator, suspend_mode == .settled, result, catch_target)) |suspended| return suspended;
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
    catch_target: ?usize,
) !?Result {
    if (!suspend_on_await) return null;
    const generator_object = generator orelse return null;
    try saveGeneratorExecutionState(ctx, stack, frame, generator_object, frame.pc, catch_target);
    generator_object.generatorSuspendKindSlot().* = @intFromEnum(core.object.GeneratorSuspendKind.await_op);
    generator_object.generatorStartedSlot().* = true;
    generator_object.generatorJustYieldedSlot().* = true;
    return .{ .return_value = value.dup() };
}

fn awaitSuspendMode(function: *const bytecode.Bytecode, suspend_on_module_await: bool, stop_on_yield: bool) AwaitSuspendMode {
    if (suspend_on_module_await and function.flags.is_module) return .raw;
    if (suspend_on_module_await and function.flags.is_async) return .raw;
    // Async-generator bodies genuinely suspend at every await; the queue
    // machine (exec/async_generator.zig) resumes them via promise-reaction
    // jobs (mirrors js_async_generator_await + resume trampolines,
    // quickjs.c:21446/21670).
    if (stop_on_yield and function.flags.is_async) return .raw;
    return .none;
}

/// Recover the innermost catch/finally target whose protected range contains
/// `start_pc`.  Catch opcodes are nested in emission order, so the last active
/// target encountered before the resume pc is authoritative.
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
) !void {
    if (frame.pc < function.code.len and function.code[frame.pc] == bytecode.opcode.op.iterator_get_value_done) {
        // for-await-of: qjs js_for_await_of_next DISABLES the catch offset for
        // the await between OP_for_await_of_next and
        // OP_iterator_get_value_done (quickjs.c:16713-16726) — a rejection
        // while awaiting the step result must NOT close the iterator from the
        // unwind path; the AsyncFromSyncIterator close-wrap reaction
        // (quickjs.c:54468) is the only closer.
        return;
    }
    try forof_ops.closeStackTopForOfIteratorForPendingError(ctx, output, global, stack);
}

fn objectFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}
