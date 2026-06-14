const core = @import("../core/root.zig");
const builtin_dispatch = @import("../exec/builtin_dispatch.zig");
const call = @import("../exec/call.zig");
const call_runtime = @import("../exec/call_runtime.zig");
const exceptions = @import("../exec/exceptions.zig");
const object_ops = @import("../exec/object_ops.zig");
const string_ops = @import("../exec/string_ops.zig");

const HostError = exceptions.HostError;
const InternalCall = core.host_function.InternalCall;

pub const ErrorObject = struct {
    name: []const u8 = "Error",
    message: []const u8 = "",
};

pub const PrototypeMethod = core.host_function.builtin_method_ids.error_object.PrototypeMethod;

/// Shares the `.error_object` native-builtin id space with
/// `PrototypeMethod`; keep the values disjoint.
pub const StaticMethod = enum(u32) {
    capture_stack_trace = 10,
};

pub fn create(message: []const u8) ErrorObject {
    return .{ .message = message };
}

/// Declaration + dispatch table for the `.error_object` native-builtin domain.
/// Covers only the methods reachable through native-function dispatch:
/// `Error.prototype.toString`, the `stack` accessor pair, and the static
/// `Error.captureStackTrace`. The error constructors (Error/AggregateError/
/// SuppressedError/native subclasses) and `Error.isError` are dispatched
/// elsewhere (class-init opcode + the string-name builtin path), never through
/// this table, so they are not listed here. The actual implementations stay in
/// exec (string_ops/call_runtime) because the VM's prototype-method fast path
/// also calls them; `errorCall` is a thin entry that delegates. `length`
/// values match the registry's `error_prototype`/`error_static` tables. None
/// are prepared-call eligible (`prepared_call_ok = false`).
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

/// Shared record handler for the `.error_object` domain. Mirrors the retired
/// `call.zig` `callErrorNativeFunctionRecord`: `captureStackTrace` keeps the
/// receiver/constructor gates before delegating, the prototype `toString` and
/// the `stack` getter/setter resolve the active realm global and call the exec
/// ops that remain authoritative for the VM's own dispatch paths.
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
