//! Realm-aware adapter for the core collection callback protocol.
//!
//! Callback, receiver, arguments, and legacy global slots are borrowed;
//! successful heap results are owned by the caller. The explicit `JSContext`
//! is the error realm authority: ordinary engine failures become a pending JS
//! exception here, while only the seven hard/control outcomes cross the core
//! callback seam. Synthetic `c_closure` bodies live in `closure.zig`; the
//! collection algorithms remain in `collection_ops.zig`.

const core = @import("../core/root.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const closure_mod = @import("closure.zig");
const globals_mod = core.global_slots;

const CallbackHost = core.host_function.CallbackHost;
const CallbackError = core.host_function.CallbackError;

pub fn host(ctx: *core.JSContext, globals: []globals_mod.Slot) CallbackHost {
    return .{
        .ctx = ctx,
        .globals = globals,
        .call = callWithThis,
    };
}

fn callWithThis(
    ctx: *core.JSContext,
    callback: core.JSValue,
    this_value: core.JSValue,
    args: []const core.JSValue,
    globals: []globals_mod.Slot,
) CallbackError!core.JSValue {
    return closure_mod.callWithThis(ctx.runtime, callback, this_value, args, globals) catch |err|
        return narrowCallbackError(ctx, err);
}

fn narrowCallbackError(ctx: *core.JSContext, err: anytype) CallbackError {
    return switch (@as(anyerror, err)) {
        error.OutOfMemory => error.OutOfMemory,
        error.Interrupted => error.Interrupted,
        error.ProcessExit => error.ProcessExit,
        error.StackOverflow => error.StackOverflow,
        error.Timeout => error.Timeout,
        error.UnhandledPromiseRejection => error.UnhandledPromiseRejection,
        error.JSException => if (ctx.hasException()) error.JSException else blk: {
            _ = builtin_dispatch.nativeFromHostError(ctx, ctx.global, err);
            break :blk error.JSException;
        },
        else => blk: {
            _ = builtin_dispatch.nativeFromHostError(ctx, ctx.global, err);
            break :blk error.JSException;
        },
    };
}
