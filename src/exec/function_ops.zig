const core = @import("../core/root.zig");
const call = @import("call.zig");
const exceptions = @import("exceptions.zig");

const HostError = exceptions.HostError;
const InternalCall = core.host_function.InternalCall;

pub const PrototypeMethod = enum(u32) {
    to_string = 1,
    bind = 2,
};

/// Declaration + dispatch table for the `.function` native-builtin domain
/// (QuickJS `js_function_proto_funcs` analogue). `call` / `apply` are still
/// handled by the VM/name-dispatch path; this record table covers only
/// `Function.prototype.toString` and `Function.prototype.bind`.
pub const internal_entries = [_]core.host_function.InternalEntry{
    functionEntry("toString", 0, @intFromEnum(PrototypeMethod.to_string)),
    functionEntry("bind", 1, @intFromEnum(PrototypeMethod.bind)),
};

fn functionEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{ .name = name, .length = length, .id = id, .magic = @intCast(id), .prepared_call_ok = false, .call = &functionCall };
}

/// Shared record handler for the `.function` domain. The bodies stay in exec
/// because `Function.prototype.toString` reads engine function internals and
/// `bind` builds bound-function exotics via call.zig helpers.
fn functionCall(host_call: InternalCall) HostError!core.JSValue {
    const ctx = host_call.ctx;
    const id: u32 = host_call.magic;
    return switch (id) {
        @intFromEnum(PrototypeMethod.to_string) => call.functionToStringValue(ctx.runtime, host_call.this_value),
        @intFromEnum(PrototypeMethod.bind) => call.qjsFunctionBindCall(ctx, host_call.output, host_call.global, host_call.globals, host_call.this_value, host_call.args),
        else => error.TypeError,
    };
}
