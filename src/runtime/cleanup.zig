const exec = @import("../exec/root.zig");
const zjs = @import("../binding/root.zig");

pub fn cleanupAtomicsWaitersForContext(ctx: *zjs.JSContext) void {
    exec.zjs_vm.cleanupAtomicsWaitersForContext(&ctx.core);
}

pub fn wakeAtomicsWaitersForRuntimes(primary: *zjs.JSRuntime, related: []const *zjs.JSRuntime) void {
    const call_runtime = exec.call_runtime;
    const io = call_runtime.atomicsWaiterIo();
    call_runtime.atomics_waiter_mutex.lockUncancelable(io);
    defer call_runtime.atomics_waiter_mutex.unlock(io);

    var cursor = call_runtime.atomics_waiters;
    while (cursor) |waiter| {
        if (waiter.ctx) |ctx| {
            if (ctx.runtime == primary or runtimeListContains(related, ctx.runtime)) {
                waiter.notified = true;
                waiter.cond.broadcast(io);
            }
        }
        cursor = waiter.next;
    }
}

fn runtimeListContains(list: []const *zjs.JSRuntime, runtime: *zjs.JSRuntime) bool {
    for (list) |candidate| {
        if (candidate == runtime) return true;
    }
    return false;
}
