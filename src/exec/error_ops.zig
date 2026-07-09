const core = @import("../core/root.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const call = @import("call.zig");
const call_runtime = @import("call_runtime.zig");
const exceptions = @import("exceptions.zig");
const object_ops = @import("object_ops.zig");
const string_ops = @import("string_ops.zig");

const HostError = exceptions.HostError;
const InternalCall = core.host_function.InternalCall;

pub const PrototypeMethod = core.host_function.builtin_method_ids.error_object.PrototypeMethod;

/// Shares the `.error_object` native-builtin id space with `PrototypeMethod`;
/// keep the values disjoint.
pub const StaticMethod = enum(u32) {
    capture_stack_trace = 10,
};

/// Declaration + dispatch table for the `.error_object` native-builtin domain.
/// Covers `Error.prototype.toString`, the `stack` accessor pair, and
/// `Error.captureStackTrace`; constructors are handled by class-init/construct
/// paths, not this record table.
pub const internal_entries = errorEntries: {
    const Entry = core.host_function.InternalEntry;
    break :errorEntries [_]Entry{
        errorEntry("toString", 0, @intFromEnum(PrototypeMethod.to_string)),
        errorEntry("get stack", 1, @intFromEnum(PrototypeMethod.stack_getter)),
        errorEntry("set stack", 1, @intFromEnum(PrototypeMethod.stack_setter)),
        errorEntry("captureStackTrace", 1, @intFromEnum(StaticMethod.capture_stack_trace)),
    };
};

fn errorEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{ .name = name, .length = length, .id = id, .magic = @intCast(id), .prepared_call_ok = false, .call = &errorCall };
}

fn errorCall(host_call: InternalCall) HostError!core.JSValue {
    const ctx = host_call.ctx;
    const output = host_call.output;
    const id: u32 = host_call.magic;
    const args = host_call.args;
    const this_value = host_call.this_value;
    const caller_function = builtin_dispatch.callerBytecode(host_call);
    const caller_frame = builtin_dispatch.callerFrame(host_call);

    if (id == @intFromEnum(StaticMethod.capture_stack_trace)) {
        const receiver = call.thisObject(this_value) orelse return error.TypeError;
        if (!call_runtime.isCallableValue(this_value)) return error.TypeError;
        if (!try call_runtime.constructorNameEqlLocal(ctx.runtime, receiver, "Error")) return error.TypeError;
        const global_object = (try call.activeGlobalObject(ctx.runtime, host_call.global, host_call.globals)) orelse return error.TypeError;
        return call_runtime.qjsErrorCaptureStackTrace(ctx, output, global_object, args);
    }

    const func_obj = host_call.func_obj;
    const active_global = host_call.global orelse realmGlobalFor(ctx, func_obj) orelse return error.TypeError;
    return switch (id) {
        @intFromEnum(PrototypeMethod.to_string) => string_ops.qjsErrorToStringCall(ctx, output, active_global, this_value, caller_function, caller_frame),
        @intFromEnum(PrototypeMethod.stack_getter) => call_runtime.qjsErrorStackGetter(ctx, output, active_global, this_value),
        @intFromEnum(PrototypeMethod.stack_setter) => blk: {
            const setter_func = func_obj orelse return error.TypeError;
            break :blk call_runtime.qjsErrorStackSetter(ctx, output, active_global, this_value, setter_func, args, caller_function, caller_frame);
        },
        else => error.TypeError,
    };
}

fn realmGlobalFor(ctx: *core.JSContext, func_obj: ?*core.Object) ?*core.Object {
    if (func_obj) |obj| {
        if (object_ops.objectRealmGlobal(obj)) |realm_global| return realm_global;
    }
    return ctx.global;
}
