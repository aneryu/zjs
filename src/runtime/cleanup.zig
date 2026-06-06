const exec = @import("../exec/root.zig");
const zjs = @import("../kernel/root.zig");

pub fn cleanupAtomicsWaitersForContext(ctx: *zjs.JSContext) void {
    exec.zjs_vm.cleanupAtomicsWaitersForContext(ctx);
}

pub fn wakeAtomicsWaitersForRuntimes(primary: *zjs.JSRuntime, related: []const *zjs.JSRuntime) void {
    const shared = exec.shared;
    const io = shared.atomicsWaiterIo();
    shared.atomics_waiter_mutex.lockUncancelable(io);
    defer shared.atomics_waiter_mutex.unlock(io);

    var cursor = shared.atomics_waiters;
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

pub fn cleanupWorkersForRuntime(rt: *zjs.JSRuntime) void {
    exec.zjs_vm.cleanupWorkersForRuntime(rt);
}

fn runtimeListContains(list: []const *zjs.JSRuntime, runtime: *zjs.JSRuntime) bool {
    for (list) |candidate| {
        if (candidate == runtime) return true;
    }
    return false;
}
