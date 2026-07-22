//! Async-generator request queue + state machine.
//!
//! Mirrors the qjs AsyncGenerator machinery (quickjs.c @ 04be246):
//!   - JSAsyncGeneratorStateEnum        quickjs.c:21345
//!   - JSAsyncGeneratorRequest/Data     quickjs.c:21354-21370 (zjs: GeneratorPayload
//!     async_queue/async_state — the side data lives in the generator object's
//!     payload instead of an opaque struct; GC tracing in object.zig mirrors
//!     js_async_generator_mark quickjs.c:21400)
//!   - js_async_generator_next          quickjs.c:21706 (asyncGeneratorEnqueue)
//!   - js_async_generator_resume_next   quickjs.c:21568 (resumeNext + execBody)
//!   - js_async_generator_await         quickjs.c:21446 (asyncGeneratorAwait)
//!   - js_async_generator_resolve_function quickjs.c:21670 (qjsAsyncGeneratorResolveFunctionCall)
//!   - js_async_generator_complete      quickjs.c:21520 (complete)
//!   - js_async_generator_completed_return quickjs.c:21532 (completedReturn)
//!
//! Frame-model adaptation: qjs resumes a
//! heap-saved JSAsyncFunctionState in-place; zjs re-enters the body via
//! callFunctionBytecodeModeState with the generator object's preserved
//! buffers. The parser compiles the return-path awaits and cleanup into the
//! body; the yield-operand await remains a driver trampoline:
//!   - OP_await before OP_yield (quickjs.c:28134): carried here by the
//!     `.yield_operand` trampoline action — the yield operand is awaited
//!     driver-side, the request settles with the awaited value.
//!   - emit_return's OP_await of a return completion before finally unwinding
//!     (quickjs.c:28404) executes in bytecode.
//! yield* needs no extra action: the parser's expanded lowering already
//! contains the qjs-shaped in-bytecode awaits (parser.zig emitYieldStarDelegation).

const std = @import("std");

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const call_runtime = @import("call_runtime.zig");
const exception_ops = @import("vm_exception_ops.zig");
const exceptions = @import("exceptions.zig");
const object_ops = @import("object_ops.zig");
const promise_ops = @import("promise_ops.zig");
const builtin_glue = @import("builtin_glue.zig");

const HostError = exceptions.HostError;
const AsyncGeneratorRequest = core.object.AsyncGeneratorRequest;

/// Mirrors JSAsyncGeneratorStateEnum (quickjs.c:21345).
pub const State = enum(u8) {
    suspended_start = 0,
    suspended_yield = 1,
    suspended_yield_star = 2,
    executing = 3,
    awaiting_return = 4,
    completed = 5,
};

/// Trampoline discriminator. `.await_resume` and `.awaiting_return` are the
/// qjs magic 0/1 and 2/3 cases (quickjs.c:21670); `.yield_operand` carries
/// the yield-operand await described above.
pub const ResolveAction = enum(u8) {
    none = 0,
    await_resume = 1,
    yield_operand = 2,
    awaiting_return = 4,
};

fn state(gen: *core.Object) State {
    return @enumFromInt(gen.asyncGeneratorStateSlot().*);
}

fn setState(gen: *core.Object, s: State) void {
    gen.asyncGeneratorStateSlot().* = @intFromEnum(s);
}

// ---------------------------------------------------------------------------
// Request queue (mirrors the intrusive list JSAsyncGeneratorData.queue)
// ---------------------------------------------------------------------------

fn pushRequest(rt: *core.JSRuntime, gen: *core.Object, req: AsyncGeneratorRequest) !void {
    const queue = gen.asyncGeneratorQueue();
    const capacity = gen.asyncGeneratorQueueCapacitySlot().*;
    if (queue.len == capacity) {
        const next_capacity: usize = if (capacity == 0) 4 else capacity * 2;
        const next = try rt.memory.alloc(AsyncGeneratorRequest, next_capacity);
        @memcpy(next[0..queue.len], queue);
        if (capacity != 0) rt.memory.free(AsyncGeneratorRequest, queue.ptr[0..capacity]);
        gen.asyncGeneratorQueueSlot().* = next[0..queue.len];
        gen.asyncGeneratorQueueCapacitySlot().* = next_capacity;
    }
    const slot = gen.asyncGeneratorQueueSlot();
    slot.*.ptr[slot.len] = req;
    slot.* = slot.*.ptr[0 .. slot.len + 1];
}

/// Pop the queue head (mirrors list_del in js_async_generator_resolve_or_reject,
/// quickjs.c:21489 — the head leaves the queue BEFORE its resolving function
/// runs, so reentrant next() during settlement sees the shortened queue).
fn takeHeadRequest(gen: *core.Object) ?AsyncGeneratorRequest {
    const queue = gen.asyncGeneratorQueue();
    if (queue.len == 0) return null;
    const head = queue[0];
    const slot = gen.asyncGeneratorQueueSlot();
    std.mem.copyForwards(AsyncGeneratorRequest, queue[0 .. queue.len - 1], queue[1..]);
    slot.* = slot.*.ptr[0 .. queue.len - 1];
    return head;
}

fn freeRequest(rt: *core.JSRuntime, req: *const AsyncGeneratorRequest) void {
    req.result.free(rt);
    req.promise.free(rt);
    req.resolve.free(rt);
    req.reject.free(rt);
}

// ---------------------------------------------------------------------------
// Settlement (mirrors js_async_generator_resolve_or_reject / _resolve / _reject,
// quickjs.c:21481-21518)
// ---------------------------------------------------------------------------

fn settleHead(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    gen: *core.Object,
    result_value: core.JSValue,
    is_reject: bool,
) HostError!void {
    var req = takeHeadRequest(gen) orelse return;
    defer freeRequest(ctx.runtime, &req);
    // The popped request's values live only in this native frame while the
    // resolving function runs; root them (and the settlement value) so a
    // forced GC inside the call cannot reclaim symbol-backed values.
    var rooted_result = result_value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_result },
        .{ .value = &req.result },
        .{ .value = &req.promise },
        .{ .value = &req.resolve },
        .{ .value = &req.reject },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;
    const settle_fn = if (is_reject) req.reject else req.resolve;
    const call_result = try call_runtime.callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), settle_fn, &.{rooted_result}, null, null);
    call_result.free(ctx.runtime);
}

/// resolve with a fresh {value, done} iterator result per request
/// (js_async_generator_resolve, quickjs.c:21503).
fn resolveHead(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    gen: *core.Object,
    value: core.JSValue,
    done: bool,
) HostError!void {
    const iterator_result = try call_runtime.createIteratorResult(ctx.runtime, global, value, done);
    defer iterator_result.free(ctx.runtime);
    try settleHead(ctx, output, global, gen, iterator_result, false);
}

// ---------------------------------------------------------------------------
// Completion (mirrors js_async_generator_complete, quickjs.c:21520: state to
// COMPLETED and the saved frame freed eagerly — async_func_free)
// ---------------------------------------------------------------------------

fn complete(ctx: *core.JSContext, gen: *core.Object) void {
    if (state(gen) == .completed) return;
    setState(gen, .completed);
    gen.completeGeneratorExecution(ctx.runtime);
}

// ---------------------------------------------------------------------------
// Await plumbing (mirrors js_async_generator_await, quickjs.c:21446:
// PromiseResolve(%Promise%, value) + perform_promise_then onto trampolines
// with the qjs UNDEFINED-capability extension)
// ---------------------------------------------------------------------------

fn resolveFunction(
    rt: *core.JSRuntime,
    global: *core.Object,
    gen: *core.Object,
    action: ResolveAction,
    is_reject: bool,
) !core.JSValue {
    const callback = try builtin_glue.qjsCreateDataFunction(rt, global, "", 1);
    errdefer callback.free(rt);
    const callback_object = object_ops.objectFromValue(callback) orelse return error.TypeError;
    try callback_object.setInternalCallableTag(rt, .async_generator_resolve);
    try callback_object.setOptionalValueSlot(rt, try callback_object.functionAsyncContinuationSlot(rt), gen.value().dup());
    (try callback_object.functionAsyncContinuationRejectedSlot(rt)).* = is_reject;
    (try callback_object.functionAsyncGeneratorActionSlot(rt)).* = @intFromEnum(action);
    return callback;
}

fn asyncGeneratorAwait(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    gen: *core.Object,
    value: core.JSValue,
    action: ResolveAction,
) HostError!void {
    const promise_constructor = try promise_ops.qjsPromiseDefaultConstructor(ctx, global);
    defer promise_constructor.free(ctx.runtime);
    const promise = try promise_ops.qjsPromiseStaticCall(ctx, output, global, promise_constructor, &.{value}, .resolve, null, null);
    defer promise.free(ctx.runtime);
    const on_fulfilled = try resolveFunction(ctx.runtime, global, gen, action, false);
    defer on_fulfilled.free(ctx.runtime);
    const on_rejected = try resolveFunction(ctx.runtime, global, gen, action, true);
    defer on_rejected.free(ctx.runtime);
    // "no need to create 'thrownawayCapability' as in the spec" (quickjs.c:21464)
    try promise_ops.qjsPerformPromiseThen(ctx, output, global, promise, on_fulfilled, on_rejected, core.JSValue.undefinedValue(), core.JSValue.undefinedValue());
}

/// Mirrors js_async_generator_completed_return (quickjs.c:21532), including
/// the poisoned-Promise.constructor edge: if PromiseResolve throws, the error
/// travels to the request promise as a rejection through the magic-3 path.
fn completedReturn(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    gen: *core.Object,
    value: core.JSValue,
) HostError!void {
    const promise_constructor = try promise_ops.qjsPromiseDefaultConstructor(ctx, global);
    defer promise_constructor.free(ctx.runtime);
    const promise = promise_ops.qjsPromiseStaticCall(ctx, output, global, promise_constructor, &.{value}, .resolve, null, null) catch |err| blk: {
        switch (err) {
            error.OutOfMemory, error.ProcessExit, error.StackOverflow => return err,
            else => {},
        }
        const reason = if (ctx.hasException()) ctx.takeException() else try exception_ops.qjsPromiseErrorValue(ctx, global, err);
        defer reason.free(ctx.runtime);
        break :blk try core.promise.rejectedWithPrototype(ctx.runtime, reason, promise_ops.promisePrototypeFromGlobal(ctx.runtime, global));
    };
    defer promise.free(ctx.runtime);
    const on_fulfilled = try resolveFunction(ctx.runtime, global, gen, .awaiting_return, false);
    defer on_fulfilled.free(ctx.runtime);
    const on_rejected = try resolveFunction(ctx.runtime, global, gen, .awaiting_return, true);
    defer on_rejected.free(ctx.runtime);
    try promise_ops.qjsPerformPromiseThen(ctx, output, global, promise, on_fulfilled, on_rejected, core.JSValue.undefinedValue(), core.JSValue.undefinedValue());
}

// ---------------------------------------------------------------------------
// Body execution (mirrors the resume_exec block of
// js_async_generator_resume_next, quickjs.c:21621-21660)
// ---------------------------------------------------------------------------

const ResumeArg = union(enum) {
    /// SUSPENDED_START + NEXT: run from the initial pc, nothing pushed
    /// (exec_no_arg, quickjs.c:21585).
    start,
    /// One-slot value resume at a yield/await suspension.
    next: core.JSValue,
    /// Throw-into-frame (qjs throw_flag=TRUE + JS_Throw, quickjs.c:21596).
    throw_: core.JSValue,
    /// Return completion injected at a plain yield. The parser's `if_false`
    /// continuation consumes completion magic 1 and runs bytecode-level
    /// iterator/finally cleanup before OP_return_async.
    return_: core.JSValue,
    /// Two-slot resume at a yield* suspension: value + completion int
    /// (quickjs.c:21611-21614); the compiled yield* loop dispatches on it.
    yield_star: struct { value: core.JSValue, completion: i32 },
};

const ExecOutcome = enum { parked, settled };

fn resumeBodyValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    gen: *core.Object,
    resume_value: ?core.JSValue,
    stop_before_pc: ?usize,
) HostError!core.JSValue {
    const function_value = gen.generatorFunctionBytecode() orelse return error.TypeError;
    const stored_current = if (gen.generatorCurrentFunction()) |value| value.dup() else null;
    defer if (stored_current) |value| value.free(ctx.runtime);
    const current_function_value = stored_current orelse gen.value();
    gen.generatorExecutingSlot().* = true;
    defer gen.generatorExecutingSlot().* = false;
    return call_runtime.callFunctionBytecodeModeState(
        ctx,
        function_value,
        current_function_value,
        gen.generatorThis() orelse core.JSValue.undefinedValue(),
        gen.generatorArgs(),
        gen.generatorCaptures(),
        output,
        global,
        false,
        gen,
        resume_value,
        stop_before_pc,
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
    );
}

/// Resume the body once and dispatch the outcome (settle / park / recurse for
/// the qjs `throw_flag=TRUE; goto resume_exec` retry, quickjs.c:21651).
///
/// Completion values and gosub return PCs remain on the suspended operand
/// stack, so yields inside a finalizer need no driver-side pending state.
fn execBody(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    gen: *core.Object,
    arg: ResumeArg,
) HostError!ExecOutcome {
    const rt = ctx.runtime;

    setState(gen, .executing);
    var resume_value: ?core.JSValue = null;
    switch (arg) {
        .start => {},
        .next => |value| {
            try call_runtime.setGeneratorResumeCompletionType(rt, gen, 0);
            resume_value = value;
        },
        .throw_ => |value| {
            try call_runtime.setGeneratorResumeCompletionType(rt, gen, 2);
            resume_value = value;
        },
        .return_ => |value| {
            try call_runtime.setGeneratorResumeCompletionType(rt, gen, 1);
            resume_value = value;
        },
        .yield_star => |ys| {
            try call_runtime.setGeneratorResumeCompletionType(rt, gen, ys.completion);
            resume_value = ys.value;
        },
    }
    const result = resumeBodyValue(ctx, output, global, gen, resume_value, null) catch |err| {
        switch (err) {
            error.OutOfMemory, error.ProcessExit => return err,
            else => {},
        }
        // exception completion: complete then reject with the pending
        // exception (quickjs.c:21624-21628)
        const reason = try exception_ops.qjsPromiseErrorValue(ctx, global, err);
        defer reason.free(rt);
        complete(ctx, gen);
        try settleHead(ctx, output, global, gen, reason, true);
        return .settled;
    };
    defer result.free(rt);

    const suspended = gen.generatorJustYielded() and !gen.generatorDone();
    if (!suspended) {
        complete(ctx, gen);
        try resolveHead(ctx, output, global, gen, result, true);
        return .settled;
    }

    switch (gen.generatorSuspendKind()) {
        .await_op => {
            // FUNC_RET_AWAIT (quickjs.c:21646-21654)
            asyncGeneratorAwait(ctx, output, global, gen, result, .await_resume) catch |err| {
                switch (err) {
                    error.OutOfMemory, error.ProcessExit => return err,
                    else => {},
                }
                // qjs: throw_flag=TRUE; goto resume_exec
                const reason = if (ctx.hasException()) ctx.takeException() else try exception_ops.qjsPromiseErrorValue(ctx, global, err);
                defer reason.free(rt);
                return try execBody(ctx, output, global, gen, .{ .throw_ = reason });
            };
            return .parked;
        },
        .yield => {
            // zjs adaptation of the compiler-emitted OP_await before OP_yield
            // (quickjs.c:28134): await the yield operand; the fulfilled value
            // settles the head request as {value, done:false}.
            asyncGeneratorAwait(ctx, output, global, gen, result, .yield_operand) catch |err| {
                switch (err) {
                    error.OutOfMemory, error.ProcessExit => return err,
                    else => {},
                }
                const reason = if (ctx.hasException()) ctx.takeException() else try exception_ops.qjsPromiseErrorValue(ctx, global, err);
                defer reason.free(rt);
                return try execBody(ctx, output, global, gen, .{ .throw_ = reason });
            };
            return .parked;
        },
        .yield_star => {
            // FUNC_RET_YIELD_STAR (quickjs.c:21638-21645): the value was
            // already awaited by the compiled yield* loop; resolve directly.
            setState(gen, .suspended_yield_star);
            try resolveHead(ctx, output, global, gen, result, false);
            return .settled;
        },
        .none => {
            // A generator body suspension always records a kind; reaching here
            // means the save-site bookkeeping broke.
            std.debug.assert(false);
            return error.TypeError;
        },
    }
}

// ---------------------------------------------------------------------------
// The FIFO drain loop (mirrors js_async_generator_resume_next, quickjs.c:21568)
// ---------------------------------------------------------------------------

pub fn resumeNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    gen: *core.Object,
) HostError!void {
    while (true) {
        const queue = gen.asyncGeneratorQueue();
        if (queue.len == 0) return;
        const head_completion = queue[0].completion_type;
        const head_result = queue[0].result.dup();
        defer head_result.free(ctx.runtime);
        switch (state(gen)) {
            // Parked at an await: only the resume trampoline re-enters
            // (quickjs.c:21580 resume_exec is trampoline-driven; enqueue
            // guards on state != EXECUTING).
            .executing => return,
            .awaiting_return => return,
            .suspended_start => {
                if (head_completion == 0) {
                    switch (try execBody(ctx, output, global, gen, .start)) {
                        .parked => return,
                        .settled => continue,
                    }
                } else {
                    // return/throw before start: complete, then the same
                    // request re-dispatches in the COMPLETED state
                    // (quickjs.c:21588-21590).
                    complete(ctx, gen);
                    continue;
                }
            },
            .completed => {
                if (head_completion == 0) {
                    try resolveHead(ctx, output, global, gen, core.JSValue.undefinedValue(), true);
                } else if (head_completion == 1) {
                    setState(gen, .awaiting_return);
                    try completedReturn(ctx, output, global, gen, head_result);
                } else {
                    try settleHead(ctx, output, global, gen, head_result, true);
                }
                // quickjs.c:21607 `goto done`: exactly one request is
                // processed per resume_next entry in the COMPLETED state
                // (verified against the qjs binary; remaining requests drain
                // on later next()/return()/throw() calls).
                return;
            },
            .suspended_yield => {
                if (head_completion == 2) {
                    switch (try execBody(ctx, output, global, gen, .{ .throw_ = head_result })) {
                        .parked => return,
                        .settled => continue,
                    }
                } else if (head_completion == 1) {
                    switch (try execBody(ctx, output, global, gen, .{ .return_ = head_result })) {
                        .parked => return,
                        .settled => continue,
                    }
                } else {
                    switch (try execBody(ctx, output, global, gen, .{ .next = head_result })) {
                        .parked => return,
                        .settled => continue,
                    }
                }
            },
            .suspended_yield_star => {
                // All three completions resume the compiled yield* loop with
                // the two-slot (value, completion) push (quickjs.c:21611).
                switch (try execBody(ctx, output, global, gen, .{ .yield_star = .{ .value = head_result, .completion = head_completion } })) {
                    .parked => return,
                    .settled => continue,
                }
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Enqueue (mirrors js_async_generator_next, quickjs.c:21706; magic:
// next=0 / return=1 / throw=2)
// ---------------------------------------------------------------------------

pub fn asyncGeneratorEnqueue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    gen: *core.Object,
    args: []const core.JSValue,
    magic: i32,
) HostError!core.JSValue {
    const rt = ctx.runtime;
    const gen_global = object_ops.objectRealmGlobal(gen) orelse global;
    // Capability FIRST (observable via then-getter ticks; quickjs.c:21713).
    const promise = try core.promise.constructWithPrototype(rt, promise_ops.promisePrototypeFromGlobal(rt, gen_global));
    errdefer promise.free(rt);
    const resolving = try promise_ops.createPromiseResolvingPair(rt, gen_global, promise);
    var resolving_owned = true;
    errdefer if (resolving_owned) {
        resolving.resolve.free(rt);
        resolving.reject.free(rt);
    };
    const arg = if (args.len > 0) args[0] else core.JSValue.undefinedValue();
    const req = AsyncGeneratorRequest{
        .completion_type = magic,
        .result = arg.dup(),
        .promise = promise.dup(),
        .resolve = resolving.resolve,
        .reject = resolving.reject,
    };
    pushRequest(rt, gen, req) catch |err| {
        req.result.free(rt);
        req.promise.free(rt);
        return err;
    };
    resolving_owned = false;
    if (state(gen) != .executing) {
        try resumeNext(ctx, output, gen_global, gen);
    }
    return promise;
}

// ---------------------------------------------------------------------------
// Trampoline dispatch (mirrors js_async_generator_resolve_function,
// quickjs.c:21670)
// ---------------------------------------------------------------------------

pub fn qjsAsyncGeneratorResolveFunctionCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    args: []const core.JSValue,
) HostError!?core.JSValue {
    const gen_value = function_object.functionAsyncContinuation() orelse return null;
    const gen = object_ops.objectFromValue(gen_value) orelse return error.TypeError;
    const is_reject = function_object.functionAsyncContinuationRejected();
    const action: ResolveAction = @enumFromInt(function_object.functionAsyncGeneratorAction());
    const arg = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const gen_global = object_ops.objectRealmGlobal(gen) orelse global;
    switch (action) {
        .none => return null,
        .awaiting_return => {
            // magic >= 2 (quickjs.c:21681-21689): settle the head, state to
            // COMPLETED, and — verified qjs divergence from the spec's
            // AsyncGeneratorDrainQueue — NO resume_next afterwards.
            const st = state(gen);
            if (st != .awaiting_return and st != .completed) return core.JSValue.undefinedValue();
            setState(gen, .completed);
            if (is_reject) {
                try settleHead(ctx, output, gen_global, gen, arg, true);
            } else {
                try resolveHead(ctx, output, gen_global, gen, arg, true);
            }
            return core.JSValue.undefinedValue();
        },
        .await_resume => {
            // magic 0/1 (quickjs.c:21690-21701), stale-trampoline guard.
            if (state(gen) != .executing) return core.JSValue.undefinedValue();
            if (is_reject) {
                _ = try execBody(ctx, output, gen_global, gen, .{ .throw_ = arg });
            } else {
                _ = try execBody(ctx, output, gen_global, gen, .{ .next = arg });
            }
            try resumeNext(ctx, output, gen_global, gen);
            return core.JSValue.undefinedValue();
        },
        .yield_operand => {
            if (state(gen) != .executing) return core.JSValue.undefinedValue();
            if (is_reject) {
                // Rejected yield operand: thrown at the yield site, catchable
                // in the body (qjs: the compiled OP_await rejects there).
                _ = try execBody(ctx, output, gen_global, gen, .{ .throw_ = arg });
            } else {
                setState(gen, .suspended_yield);
                try resolveHead(ctx, output, gen_global, gen, arg, false);
            }
            try resumeNext(ctx, output, gen_global, gen);
            return core.JSValue.undefinedValue();
        },
    }
}
