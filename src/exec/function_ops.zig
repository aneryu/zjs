const core = @import("../core/root.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const call = @import("call.zig");
const call_runtime = @import("call_runtime.zig");
const exceptions = @import("exceptions.zig");

const HostError = exceptions.HostError;
const InternalCall = core.host_function.InternalCall;

pub const PrototypeMethod = enum(u32) {
    to_string = 1,
    bind = 2,
    call = 3,
    apply = 4,
};

/// Declaration + dispatch table for the `.function` native-builtin domain
/// (QuickJS `js_function_proto_funcs` analogue).
pub const internal_entries = [_]core.host_function.InternalEntry{
    functionEntry("call", 1, @intFromEnum(PrototypeMethod.call)),
    functionEntry("apply", 2, @intFromEnum(PrototypeMethod.apply)),
    functionEntry("toString", 0, @intFromEnum(PrototypeMethod.to_string)),
    functionEntry("bind", 1, @intFromEnum(PrototypeMethod.bind)),
};

fn functionEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{ .name = name, .length = length, .id = id, .magic = @intCast(id), .prepared_call_ok = false, .call = &functionCall };
}

/// Shared record handler for the `.function` domain. The bodies stay in exec
/// because the Function prototype methods read engine call/frame internals.
fn functionCall(host_call: InternalCall) HostError!core.JSValue {
    const ctx = host_call.ctx;
    const id: u32 = host_call.magic;
    return switch (id) {
        @intFromEnum(PrototypeMethod.to_string) => call.functionToStringValue(ctx.runtime, host_call.this_value),
        @intFromEnum(PrototypeMethod.bind) => call.qjsFunctionBindCall(ctx, host_call.output, host_call.global, host_call.globals, host_call.this_value, host_call.args),
        @intFromEnum(PrototypeMethod.call) => call_runtime.qjsFunctionCallCall(
            ctx,
            host_call.output,
            host_call.global orelse return error.TypeError,
            host_call.this_value,
            host_call.func_obj orelse return error.TypeError,
            host_call.args,
            builtin_dispatch.callerBytecode(host_call),
            builtin_dispatch.callerFrame(host_call),
        ),
        @intFromEnum(PrototypeMethod.apply) => call_runtime.qjsFunctionApplyCall(
            ctx,
            host_call.output,
            host_call.global orelse return error.TypeError,
            host_call.this_value,
            host_call.func_obj orelse return error.TypeError,
            host_call.args,
            builtin_dispatch.callerBytecode(host_call),
            builtin_dispatch.callerFrame(host_call),
        ),
        else => error.TypeError,
    };
}
