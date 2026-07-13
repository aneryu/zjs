const std = @import("std");

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
    functionCallEntry(),
    functionEntry("apply", 2, @intFromEnum(PrototypeMethod.apply)),
    functionEntry("toString", 0, @intFromEnum(PrototypeMethod.to_string)),
    functionEntry("bind", 1, @intFromEnum(PrototypeMethod.bind)),
};

fn functionEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{ .name = name, .length = length, .id = id, .magic = @intCast(id), .prepared_call_ok = false, .call = &functionCall };
}

fn functionCallEntry() core.host_function.InternalEntry {
    const id = @intFromEnum(PrototypeMethod.call);
    return .{ .name = "call", .length = 1, .id = id, .magic = @intCast(id), .prepared_call_ok = false, .forwards_call = true, .call = &functionCallRecord };
}

test "Function.call has a dedicated native record handler" {
    var call_handler: ?core.host_function.InternalCallFn = null;
    for (internal_entries) |entry| {
        if (entry.id == @intFromEnum(PrototypeMethod.call)) call_handler = entry.call;
    }
    try std.testing.expect(call_handler != null);
    try std.testing.expect(call_handler.? == &functionCallRecord);
    for (internal_entries) |entry| {
        if (entry.id == @intFromEnum(PrototypeMethod.call)) {
            try std.testing.expect(entry.forwards_call);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

/// Shared record handler for the remaining `.function` methods. Function.call
/// uses its own qjs-style function-list entry because it is a hot forwarding
/// primitive; the bodies stay in exec because they read engine call/frame
/// internals.
fn functionCall(host_call: InternalCall) HostError!core.JSValue {
    const ctx = host_call.ctx;
    const id: u32 = host_call.magic;
    return switch (id) {
        @intFromEnum(PrototypeMethod.to_string) => call.functionToStringValue(ctx.runtime, host_call.this_value),
        @intFromEnum(PrototypeMethod.bind) => call.qjsFunctionBindCall(ctx, host_call.output, host_call.global, host_call.globals, host_call.this_value, host_call.args),
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

fn functionCallRecord(host_call: InternalCall) HostError!core.JSValue {
    return call_runtime.qjsFunctionCallCall(
        host_call.ctx,
        host_call.output,
        host_call.global orelse return error.TypeError,
        host_call.this_value,
        host_call.args,
        builtin_dispatch.callerBytecode(host_call),
        builtin_dispatch.callerFrame(host_call),
    );
}
