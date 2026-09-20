//! Async-generator request queue + state machine.
//!
//! Mirrors the qjs AsyncGenerator machinery (quickjs.c @ 04be246):
//! - JSAsyncGeneratorStateEnum quickjs.c
//! - JSAsyncGeneratorRequest/Data quickjs.c (zjs: GeneratorPayload
//!     async_queue/async_state — the side data lives in the generator object's
//!     payload instead of an opaque struct; GC tracing in object.zig mirrors
//! js_async_generator_mark quickjs.c)
//! - js_async_generator_next quickjs.c (asyncGeneratorEnqueue)
//! - js_async_generator_resume_next quickjs.c (resumeNext + execBody)
//! - js_async_generator_await quickjs.c (asyncGeneratorAwait)
//! - js_async_generator_resolve_function quickjs.c (asyncGeneratorResolveFunctionCall)
//! - js_async_generator_complete quickjs.c (complete)
//! - js_async_generator_completed_return quickjs.c (completedReturn)
//!
//! Frame-model adaptation: qjs resumes a
//! heap-saved JSAsyncFunctionState in-place; zjs re-enters the body via
//! callFunctionBytecodeModeState with the generator object's preserved
//! buffers. The parser compiles the return-path awaits and cleanup into the
//! body; the yield-operand await remains a driver trampoline:
//! - OP_await before OP_yield: carried here by the
//!     `.yield_operand` trampoline action — the yield operand is awaited
//!     driver-side, the request settles with the awaited value.
//!   - emit_return's OP_await of a return completion before finally unwinding
//! executes in bytecode.
//! yield* needs no extra action: the parser's expanded lowering already
//! contains the qjs-shaped in-bytecode awaits (parser.zig emitYieldStarDelegation).

const std = @import("std");
const iterator_ops = @import("iterator_ops.zig");

const core = @import("../core/root.zig");
const call_runtime = @import("call_runtime.zig");
const exception_ops = @import("exception_ops.zig");
const exceptions = @import("exceptions.zig");
const object_ops = @import("object_ops.zig");
const promise_ops = @import("promise_ops.zig");
const builtin_glue = @import("builtin_glue.zig");

const HostError = exceptions.HostError;
const AsyncGeneratorRequest = core.object.AsyncGeneratorRequest;

pub const State = core.generator_state.AsyncGeneratorState;
const ResumeCompletion = core.generator_state.ResumeCompletion;

/// Trampoline discriminator. `.await_resume` and `.awaiting_return` are the
/// qjs magic 0/1 and 2/3 cases; `.yield_operand` carries
/// the yield-operand await described above.
pub const ResolveAction = enum(u8) {
    none = 0,
    await_resume = 1,
    yield_operand = 2,
    awaiting_return = 4,
};

fn state(gen: *core.Object) State {
    return gen.asyncGeneratorStateSlot().*;
}

fn setState(gen: *core.Object, s: State) void {
    gen.asyncGeneratorStateSlot().* = s;
}

// ---------------------------------------------------------------------------
// Request queue (mirrors the intrusive list JSAsyncGeneratorData.queue)
// ---------------------------------------------------------------------------

fn pushRequest(rt: *core.JSRuntime, gen: *core.Object, req: AsyncGeneratorRequest) !void {
    try gen.asyncGeneratorQueueSlot().append(rt.memory.persistent_allocator, req);
    // The request's four values live in the generator's payload queue, so the
    // generator owns them: a long-lived async generator queuing a freshly made
    // promise and its resolving functions is an old-to-young edge.
    rt.gc.generationalBarrier(gen.gcHeader(), req.result.cycleMarkHeader());
    rt.gc.generationalBarrier(gen.gcHeader(), req.promise.cycleMarkHeader());
    rt.gc.generationalBarrier(gen.gcHeader(), req.resolve.cycleMarkHeader());
    rt.gc.generationalBarrier(gen.gcHeader(), req.reject.cycleMarkHeader());
}

/// Pop the queue head (mirrors list_del in js_async_generator_resolve_or_reject,
/// quickjs.c — the head leaves the queue BEFORE its resolving function
/// runs, so reentrant next() during settlement sees the shortened queue).
fn takeHeadRequest(gen: *core.Object) ?AsyncGeneratorRequest {
    const queue = gen.asyncGeneratorQueueSlot();
    if (queue.items.len == 0) return null;
    return queue.orderedRemove(0);
}

// ---------------------------------------------------------------------------
// Settlement (mirrors js_async_generator_resolve_or_reject / _resolve / _reject,
// quickjs.c)
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
    // The popped request's values live only in this native frame while the
    // resolving function runs; root them (and the settlement value) so a
    // forced GC inside the call cannot reclaim symbol-backed values.
    var rooted_result = result_value;
    var root_frame = core.runtime.rootValues(.{
        &rooted_result,
        &req.result,
        &req.promise,
        &req.resolve,
        &req.reject,
    });
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);
    const settle_fn = if (is_reject) req.reject else req.resolve;
    _ = try call_runtime.callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), settle_fn, &.{rooted_result}, null, null);
}

/// resolve with a fresh {value, done} iterator result per request
/// (js_async_generator_resolve, quickjs.c).
fn resolveHead(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    gen: *core.Object,
    value: core.JSValue,
    done: bool,
) HostError!void {
    const iterator_result = try iterator_ops.createIteratorResult(ctx.runtime, global, value, done);
    try settleHead(ctx, output, global, gen, iterator_result, false);
}

// ---------------------------------------------------------------------------
// Completion (mirrors js_async_generator_complete, quickjs.c: state to
// COMPLETED and the saved frame freed eagerly — async_func_free)
// ---------------------------------------------------------------------------

fn complete(ctx: *core.JSContext, gen: *core.Object) void {
    if (state(gen) == .completed) return;
    setState(gen, .completed);
    gen.completeGeneratorExecution(ctx.runtime);
}

// ---------------------------------------------------------------------------
// Await plumbing (mirrors js_async_generator_await, quickjs.c:
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
    const callback = try builtin_glue.createDataFunction(rt, global, "", 1);
    const callback_object = object_ops.objectFromValue(callback) orelse return error.TypeError;
    try callback_object.setInternalCallableTag(rt, .async_generator_resolve);
    try callback_object.setOptionalValueSlot(rt, try callback_object.functionAsyncContinuationSlot(rt), gen.value());
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
    const promise_constructor = try promise_ops.promiseDefaultConstructor(ctx, global);
    const promise = try promise_ops.promiseStaticCall(ctx, output, global, promise_constructor, &.{value}, .resolve, null, null);
    const on_fulfilled = try resolveFunction(ctx.runtime, global, gen, action, false);
    const on_rejected = try resolveFunction(ctx.runtime, global, gen, action, true);
    // "no need to create 'thrownawayCapability' as in the spec"
    try promise_ops.performPromiseThen(ctx, output, global, promise, on_fulfilled, on_rejected, core.JSValue.undefinedValue(), core.JSValue.undefinedValue());
}

/// Mirrors js_async_generator_completed_return, including
/// the poisoned-Promise.constructor edge: if PromiseResolve throws, the error
/// travels to the request promise as a rejection through the magic-3 path.
fn completedReturn(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    gen: *core.Object,
    value: core.JSValue,
) HostError!void {
    const promise_constructor = try promise_ops.promiseDefaultConstructor(ctx, global);
    const promise = promise_ops.promiseStaticCall(ctx, output, global, promise_constructor, &.{value}, .resolve, null, null) catch |err| blk: {
        switch (err) {
            error.OutOfMemory, error.ProcessExit, error.StackOverflow => return err,
            else => {},
        }
        const reason = if (ctx.hasException()) ctx.takeException() else try exception_ops.promiseErrorValue(ctx, global, err);
        break :blk try core.promise.rejectedWithPrototype(ctx, reason, promise_ops.promisePrototypeFromGlobal(ctx.runtime, global));
    };
    const on_fulfilled = try resolveFunction(ctx.runtime, global, gen, .awaiting_return, false);
    const on_rejected = try resolveFunction(ctx.runtime, global, gen, .awaiting_return, true);
    try promise_ops.performPromiseThen(ctx, output, global, promise, on_fulfilled, on_rejected, core.JSValue.undefinedValue(), core.JSValue.undefinedValue());
}

// ---------------------------------------------------------------------------
// Body execution (mirrors the resume_exec block of
// js_async_generator_resume_next, quickjs.c)
// ---------------------------------------------------------------------------

const ResumeArg = union(enum) {
    /// SUSPENDED_START + NEXT: run from the initial pc, nothing pushed
    /// (exec_no_arg, quickjs.c).
    start,
    /// One-slot value resume at a yield/await suspension.
    next: core.JSValue,
    /// Throw-into-frame (qjs throw_flag=TRUE + JS_Throw, quickjs.c).
    throw_: core.JSValue,
    /// Return completion injected at a plain yield. The parser's `if_false`
    /// continuation consumes completion magic 1 and runs bytecode-level
    /// iterator/finally cleanup before OP_return_async.
    return_: core.JSValue,
    /// Two-slot resume at a yield* suspension: value + completion int
    ///; the compiled yield* loop dispatches on it.
    yield_star: struct { value: core.JSValue, completion: ResumeCompletion },
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
    const stored_current = if (gen.generatorCurrentFunction()) |value| value else null;
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
    );
}

/// Resume the body once and dispatch the outcome (settle / park / recurse for
/// the qjs `throw_flag=TRUE; goto resume_exec` retry, quickjs.c).
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
    setState(gen, .executing);
    var resume_value: ?core.JSValue = null;
    switch (arg) {
        .start => {},
        .next => |value| {
            call_runtime.setGeneratorResumeCompletion(gen, .next);
            resume_value = value;
        },
        .throw_ => |value| {
            call_runtime.setGeneratorResumeCompletion(gen, .throw);
            resume_value = value;
        },
        .return_ => |value| {
            call_runtime.setGeneratorResumeCompletion(gen, .return_);
            resume_value = value;
        },
        .yield_star => |ys| {
            call_runtime.setGeneratorResumeCompletion(gen, ys.completion);
            resume_value = ys.value;
        },
    }
    const result = resumeBodyValue(ctx, output, global, gen, resume_value, null) catch |err| {
        switch (err) {
            error.OutOfMemory, error.ProcessExit => return err,
            else => {},
        }
        // exception completion: complete then reject with the pending
        // exception
        const reason = try exception_ops.promiseErrorValue(ctx, global, err);
        complete(ctx, gen);
        try settleHead(ctx, output, global, gen, reason, true);
        return .settled;
    };

    const suspended = gen.generatorJustYielded() and !gen.generatorDone();
    if (!suspended) {
        complete(ctx, gen);
        try resolveHead(ctx, output, global, gen, result, true);
        return .settled;
    }

    switch (gen.generatorSuspendKind()) {
        .await_op => {
            // FUNC_RET_AWAIT
            asyncGeneratorAwait(ctx, output, global, gen, result, .await_resume) catch |err| {
                switch (err) {
                    error.OutOfMemory, error.ProcessExit => return err,
                    else => {},
                }
                // qjs: throw_flag=TRUE; goto resume_exec
                const reason = if (ctx.hasException()) ctx.takeException() else try exception_ops.promiseErrorValue(ctx, global, err);
                return try execBody(ctx, output, global, gen, .{ .throw_ = reason });
            };
            return .parked;
        },
        .yield => {
            // zjs adaptation of the compiler-emitted OP_await before OP_yield
            //: await the yield operand; the fulfilled value
            // settles the head request as {value, done:false}.
            asyncGeneratorAwait(ctx, output, global, gen, result, .yield_operand) catch |err| {
                switch (err) {
                    error.OutOfMemory, error.ProcessExit => return err,
                    else => {},
                }
                const reason = if (ctx.hasException()) ctx.takeException() else try exception_ops.promiseErrorValue(ctx, global, err);
                return try execBody(ctx, output, global, gen, .{ .throw_ = reason });
            };
            return .parked;
        },
        .yield_star => {
            // FUNC_RET_YIELD_STAR: the value was
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
// The FIFO drain loop (mirrors js_async_generator_resume_next, quickjs.c)
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
        const head_completion = queue[0].completion;
        const head_result = queue[0].result;
        switch (state(gen)) {
            // Parked at an await: only the resume trampoline re-enters
            // (quickjs.c resume_exec is trampoline-driven; enqueue
            // guards on state != EXECUTING).
            .executing => return,
            .awaiting_return => return,
            .suspended_start => {
                if (head_completion == .next) {
                    switch (try execBody(ctx, output, global, gen, .start)) {
                        .parked => return,
                        .settled => continue,
                    }
                } else {
                    // return/throw before start: complete, then the same
                    // request re-dispatches in the COMPLETED state
                    complete(ctx, gen);
                    continue;
                }
            },
            .completed => {
                if (head_completion == .next) {
                    try resolveHead(ctx, output, global, gen, core.JSValue.undefinedValue(), true);
                } else if (head_completion == .return_) {
                    setState(gen, .awaiting_return);
                    try completedReturn(ctx, output, global, gen, head_result);
                } else {
                    try settleHead(ctx, output, global, gen, head_result, true);
                }
                // quickjs.c `goto done`: exactly one request is
                // processed per resume_next entry in the COMPLETED state
                // (verified against the qjs binary; remaining requests drain
                // on later next()/return()/throw() calls).
                return;
            },
            .suspended_yield => {
                if (head_completion == .throw) {
                    switch (try execBody(ctx, output, global, gen, .{ .throw_ = head_result })) {
                        .parked => return,
                        .settled => continue,
                    }
                } else if (head_completion == .return_) {
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
                // the two-slot (value, completion) push.
                switch (try execBody(ctx, output, global, gen, .{ .yield_star = .{ .value = head_result, .completion = head_completion } })) {
                    .parked => return,
                    .settled => continue,
                }
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Enqueue (mirrors js_async_generator_next, quickjs.c; magic:
// next=0 / return=1 / throw=2)
// ---------------------------------------------------------------------------

pub fn asyncGeneratorEnqueue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    gen: *core.Object,
    args: []const core.JSValue,
    completion: ResumeCompletion,
) HostError!core.JSValue {
    const rt = ctx.runtime;
    const gen_global = gen.generatorFunctionRealmGlobalPtr() orelse global;
    // Capability FIRST (observable via then-getter ticks; quickjs.c).
    const promise = try core.promise.constructWithPrototype(ctx, promise_ops.promisePrototypeFromGlobal(rt, gen_global));
    const resolving = try promise_ops.createPromiseResolvingPair(rt, gen_global, promise);
    const arg = if (args.len > 0) args[0] else core.JSValue.undefinedValue();
    const req = AsyncGeneratorRequest{
        .completion = completion,
        .result = arg,
        .promise = promise,
        .resolve = resolving.resolve,
        .reject = resolving.reject,
    };
    pushRequest(rt, gen, req) catch |err| {
        return err;
    };
    if (state(gen) != .executing) {
        try resumeNext(ctx, output, gen_global, gen);
    }
    return promise;
}

// ---------------------------------------------------------------------------
// Trampoline dispatch (mirrors js_async_generator_resolve_function,
// quickjs.c)
// ---------------------------------------------------------------------------

pub fn asyncGeneratorResolveFunctionCall(
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
    const gen_global = gen.generatorFunctionRealmGlobalPtr() orelse global;
    switch (action) {
        .none => return null,
        .awaiting_return => {
            // magic >= 2: settle the head, state to
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
            // magic 0/1, stale-trampoline guard.
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
