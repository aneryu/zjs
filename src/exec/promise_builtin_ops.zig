//! Internal-record declarations for Promise static methods.
//!
//! QuickJS stores `js_promise_resolve` directly in the `resolve`
//! `JSCFunctionListEntry`. Promise is still a transitional zjs domain overall;
//! this first per-method record removes the VM name/realm revalidation tower
//! for `Promise.resolve` while retaining its full observable constructor and
//! property semantics in `promise_ops.qjsPromiseResolveStaticCall`.

const core = @import("../core/root.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const promise_ops = @import("promise_ops.zig");

const HostError = @import("exceptions.zig").HostError;
const InternalCall = core.host_function.InternalCall;
const StaticMethod = core.host_function.builtin_method_ids.promise.LegacyStaticMethod;

pub const internal_entries = [_]core.host_function.InternalEntry{
    .{
        .name = "resolve",
        .length = 1,
        .id = @intFromEnum(StaticMethod.resolve),
        .magic = @intFromEnum(StaticMethod.resolve),
        .prepared_call_ok = false,
        .call = &promiseResolveCall,
    },
};

fn promiseResolveCall(host_call: InternalCall) HostError!core.JSValue {
    const global = host_call.global orelse return error.TypeError;
    return promise_ops.qjsPromiseResolveStaticCall(
        host_call.ctx,
        host_call.output,
        global,
        host_call.this_value,
        host_call.args,
        builtin_dispatch.callerBytecode(host_call),
        builtin_dispatch.callerFrame(host_call),
    );
}
