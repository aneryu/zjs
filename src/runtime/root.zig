const std = @import("std");

const core = @import("../core/root.zig");
const exec = @import("../exec/root.zig");
const zjs = @import("../binding/root.zig");

pub const event_loop = @import("event_loop.zig");
pub const plugin = @import("plugin.zig");

pub const EventLoop = event_loop.EventLoop;
pub const EventLoopOptions = event_loop.Options;
pub const EventLoopRunResult = event_loop.RunResult;
pub const runUntilIdle = event_loop.runUntilIdle;
pub const Plugin = plugin.Plugin;
pub const PluginInstallOptions = plugin.InstallOptions;

pub fn cleanupAtomicsWaitersForContext(ctx: *zjs.JSContext) void {
    exec.zjs_vm.cleanupAtomicsWaitersForContext(ctx.core);
}

pub fn wakeAtomicsWaitersForRuntimes(primary: *zjs.JSRuntime, related: []const *zjs.JSRuntime) void {
    const call_runtime = exec.call_runtime;
    const io = call_runtime.atomicsWaiterIo();
    call_runtime.atomics_waiter_mutex.lockUncancelable(io);
    defer call_runtime.atomics_waiter_mutex.unlock(io);

    var cursor = call_runtime.atomics_waiters;
    while (cursor) |waiter| {
        if (waiter.realm.borrow()) |ctx| {
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

pub fn detachArrayBuffer(ctx: *core.JSContext, value: core.JSValue) !core.JSValue {
    return exec.buffer_ops.detachArrayBuffer(ctx.runtimePtr(), value);
}

pub fn evalFileModuleGraphWithOutput(
    ctx: *zjs.JSContext,
    source_text: []const u8,
    output: *std.Io.Writer,
    filename: []const u8,
    io: std.Io,
    allocator: std.mem.Allocator,
    max_source_size: usize,
) !zjs.JSValue {
    return exec.module_graph.evalFileModuleGraphWithOutput(ctx.runtimePtr(), ctx.core, source_text, output, filename, io, allocator, max_source_size);
}

pub fn resolveModuleSpecifier(allocator: std.mem.Allocator, referrer_path: []const u8, specifier: []const u8) ![]const u8 {
    return exec.module.resolveModuleSpecifier(allocator, referrer_path, specifier);
}

test {
    _ = event_loop;
    _ = plugin;
    _ = cleanupAtomicsWaitersForContext;
    _ = wakeAtomicsWaitersForRuntimes;
    _ = detachArrayBuffer;
    _ = evalFileModuleGraphWithOutput;
    _ = resolveModuleSpecifier;
}
