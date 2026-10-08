//! The runtime's side of the regexp library: its host callbacks.

const regexp_lib = @import("../libs/regexp.zig");
const JSRuntime = @import("../runtime.zig").JSRuntime;

/// The runtime as the regexp library's host: its native-stack guard for the
/// pattern compiler and its interrupt poll as the executor's timeout check.
/// The timeout check stays installed for cross-thread termination requests.
pub fn libraryHost(rt: *JSRuntime) regexp_lib.Host {
    return .{
        .context = rt,
        .interrupt_counter = &rt.regexp_interrupt_counter,
        .checkStackOverflow = checkRuntimeStackOverflow,
        .checkTimeout = checkRuntimeTimeout,
    };
}

fn checkRuntimeStackOverflow(context: ?*anyopaque, alloca_size: usize) bool {
    const rt: *JSRuntime = @ptrCast(@alignCast(context orelse return false));
    return rt.checkNativeStackOverflow(alloca_size);
}

fn checkRuntimeTimeout(context: ?*anyopaque) bool {
    const rt: *JSRuntime = @ptrCast(@alignCast(context orelse return false));
    return rt.runInterruptHandler();
}
