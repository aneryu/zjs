const builtins = @import("../builtins/root.zig");
const core = @import("../core/root.zig");
const closure_mod = @import("closure.zig");
const globals_mod = @import("globals.zig");

pub fn host(globals: []globals_mod.Slot) builtins.collection.CallbackHost {
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
) builtins.collection.CallbackError!core.JSValue {
    return closure_mod.callWithThis(rt, callback, this_value, args, globals) catch |err| return @errorCast(err);
}

fn closureKind(rt: *core.JSRuntime, callback: core.JSValue) builtins.collection.CallbackError!i32 {
    return closure_mod.closureKind(rt, callback) catch |err| return @errorCast(err);
}
