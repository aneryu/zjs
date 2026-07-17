//! Typed standard-native record for the `performance` namespace.
//!
//! QuickJS does not provide this Web-compatible namespace, but zjs still routes
//! its native method through the same cproto/magic/function-pointer boundary as
//! the ECMAScript standard globals.

const std = @import("std");
const core = @import("../core/root.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const HostError = @import("exceptions.zig").HostError;

pub const now_id: u32 = 1;

pub const internal_entries = [_]core.host_function.InternalEntry{
    .{
        .name = "now",
        .length = 0,
        .id = now_id,
        .magic = now_id,
        .prepared_call_ok = true,
        .cproto = .generic_magic,
        .native_function = builtin_dispatch.genericMagicFunction(&performanceNowCall),
    },
};

fn performanceNowCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    if (host_call.magic != now_id) return error.TypeError;
    return core.JSValue.float64(performanceNowMs() - host_call.ctx.runtime.performance_time_origin_ms);
}

fn performanceNowMs() f64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const ns = std.Io.Clock.Timestamp.now(io, .awake).raw.toNanoseconds();
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}
