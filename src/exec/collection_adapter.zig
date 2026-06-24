const core = @import("../core/root.zig");
const closure_mod = @import("closure.zig");
const globals_mod = core.global_slots;

const CallbackHost = core.host_function.CallbackHost;
const CallbackError = core.host_function.CallbackError;

pub fn host(globals: []globals_mod.Slot) CallbackHost {
    return .{
        .globals = globals,
        .call = callWithThis,
        .kind = closureKind,
    };
}

fn callWithThis(
    rt: *core.JSRuntime,
    callback: core.JSValue,
    this_value: core.JSValue,
    args: []const core.JSValue,
    globals: []globals_mod.Slot,
) CallbackError!core.JSValue {
    return closure_mod.callWithThis(rt, callback, this_value, args, globals) catch |err| return @errorCast(err);
}

fn closureKind(rt: *core.JSRuntime, callback: core.JSValue) CallbackError!i32 {
    return closure_mod.closureKind(rt, callback) catch |err| return @errorCast(err);
}
