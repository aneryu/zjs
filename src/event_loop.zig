//! Host event loop for timers, fd readiness, signals, and job draining.
//!
//! The loop owns callback JSValues and a retained realm reference; handler
//! removal/deinit releases them, while `output` remains borrowed from the host.
//! JS call/job semantics stay in exec and the public adapter stays in js_context:
//! this module is only the scheduling seam. Host topology follows QuickJS libc
//! read/write handlers, signals, timers, and poll loop at
//! quickjs-libc.c:2014-2175 and quickjs-libc.c:2422-2627.
//!
//! This file is the public `zjs.EventLoop` type. It must not grow into an
//! Engine facade or re-export exec helpers. The in-tree engine root still
//! re-exports this module as `runtime`.

const std = @import("std");
const builtin = @import("builtin");

const core = @import("core/root.zig");
const exec = @import("exec/root.zig");
const platform_clock = @import("platform_clock.zig");
const js_context = @import("js_context.zig");

const libc = if (builtin.os.tag == .windows)
    struct {}
else
    @cImport({
        // glibc's fortified poll.h adds bits/poll2.h redirect/inline wrappers;
        // keep them out of this translation unit to avoid translate-c conflicts.
        @cUndef("_FORTIFY_SOURCE");
        @cDefine("_FORTIFY_SOURCE", "0");
        @cInclude("poll.h");
        @cInclude("signal.h");
    });

const windows_api = struct {
    const windows = std.os.windows;
    const std_input_handle: u32 = @bitCast(@as(i32, -10));
    const infinite: u32 = std.math.maxInt(u32);
    const wait_object_0: u32 = 0;

    extern "kernel32" fn GetStdHandle(n_std_handle: u32) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn WaitForSingleObject(handle: windows.HANDLE, milliseconds: u32) callconv(.winapi) u32;
};

extern "c" fn signal(signum: c_int, handler: usize) usize;

pub const EventLoopOptions = struct {
    output: ?*std.Io.Writer = null,
};

pub const EventLoopRunResult = struct {
    has_pending_exception: bool = false,
    has_unhandled_rejection: bool = false,

    pub fn hasPendingError(self: EventLoopRunResult) bool {
        return self.has_pending_exception or self.has_unhandled_rejection;
    }
};

/// Growable host-owned callback list. `items.len` is the live count; allocation
/// is `items.ptr[0..capacity]`. Removal of the last entry frees the buffer.
fn HostList(comptime T: type) type {
    return struct {
        items: []T = &.{},
        capacity: usize = 0,

        fn deinit(self: *@This(), rt: *core.JSRuntime) void {
            const items = self.items;
            const capacity = self.capacity;
            self.items = &.{};
            self.capacity = 0;
            if (capacity != 0) rt.memory.free(T, items.ptr[0..capacity]);
        }

        fn ensureCapacity(self: *@This(), ctx: *core.JSContext, min_capacity: usize) !void {
            if (self.capacity >= min_capacity) return;
            var next_capacity = if (self.capacity == 0) @as(usize, 2) else self.capacity * 2;
            while (next_capacity < min_capacity) : (next_capacity *= 2) {}
            const rt = ctx.runtimePtr();
            const next = try rt.memory.alloc(T, next_capacity);
            errdefer rt.memory.free(T, next);
            const old_items = self.items;
            const old_capacity = self.capacity;
            @memcpy(next[0..old_items.len], old_items);
            self.items = next[0..old_items.len];
            self.capacity = next_capacity;
            if (old_capacity != 0) {
                rt.memory.free(T, old_items.ptr[0..old_capacity]);
            }
        }

        fn append(self: *@This(), ctx: *core.JSContext, item: T) !void {
            const index = self.items.len;
            try self.ensureCapacity(ctx, index + 1);
            self.items = self.items.ptr[0 .. index + 1];
            self.items[index] = item;
        }

        fn removeAt(self: *@This(), ctx: *core.JSContext, index: usize) void {
            std.debug.assert(index < self.items.len);
            const old_len = self.items.len;
            if (index + 1 < old_len) {
                @memmove(self.items[index .. old_len - 1], self.items[index + 1 .. old_len]);
            }
            self.items = self.items.ptr[0 .. old_len - 1];
            if (self.items.len == 0 and self.capacity != 0) {
                const old = self.items.ptr[0..self.capacity];
                self.items = &.{};
                self.capacity = 0;
                ctx.runtimePtr().memory.free(T, old);
            }
        }
    };
}

pub const EventLoop = struct {
    pub const Options = EventLoopOptions;
    pub const RunResult = EventLoopRunResult;

    context: *core.JSContext,
    realm: core.RealmRef,
    output: ?*std.Io.Writer = null,
    timers: HostList(Timer) = .{},
    rw_handlers: HostList(RwHandler) = .{},
    signal_handlers: HostList(SignalHandler) = .{},
    next_timer_id: i64 = 1,
    exit_code: ?u8 = null,
    installed: bool = false,

    /// One-shot helper: create, install, drain jobs, then deinit.
    pub fn runUntilIdle(context: *js_context.JSContext, options: Options) !RunResult {
        var loop = init(context, options);
        loop.install();
        defer loop.deinit();
        return loop.drain();
    }

    pub inline fn init(context: *js_context.JSContext, options: EventLoopOptions) EventLoop {
        return initCore(context.core, options);
    }

    pub inline fn initCore(context: *core.JSContext, options: EventLoopOptions) EventLoop {
        return .{
            .context = context,
            .realm = core.RealmRef.retain(context),
            .output = options.output,
        };
    }

    pub fn install(self: *EventLoop) void {
        self.context.setHostEventLoop(.{
            .ptr = self,
            .vtable = &vtable,
        });
        self.installed = true;
    }

    pub fn deinit(self: *EventLoop) void {
        if (self.installed) {
            self.context.clearHostEventLoop(self);
            self.installed = false;
        }
        const rt = self.context.runtimePtr();
        self.timers.deinit(rt);
        self.rw_handlers.deinit(rt);
        self.signal_handlers.deinit(rt);
        self.realm.deinit();
    }

    pub fn drain(self: *EventLoop) !EventLoopRunResult {
        const global = try self.context.globalObject();
        exec.zjs_vm.drainPendingPromiseJobs(self.context, self.output, global) catch |err| {
            if (!self.context.hasException() and !self.context.hasUnhandledRejection()) return err;
        };
        return self.result();
    }

    pub fn result(self: *const EventLoop) EventLoopRunResult {
        return .{
            .has_pending_exception = self.context.hasException(),
            .has_unhandled_rejection = self.context.hasUnhandledRejection(),
        };
    }

    pub fn setExitCode(self: *EventLoop, code: u8) void {
        self.exit_code = code;
    }

    pub fn exitCode(self: *const EventLoop) ?u8 {
        return self.exit_code;
    }

    fn traceRoots(self: *EventLoop, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
        for (self.timers.items) |*timer| {
            try timer.traceRoots(visitor);
        }
        for (self.rw_handlers.items) |*handler| {
            try handler.traceRoots(visitor);
        }
        for (self.signal_handlers.items) |*handler| {
            try handler.traceRoots(visitor);
        }
    }

    fn takeNextTimerId(self: *EventLoop) i64 {
        const id = self.next_timer_id;
        self.next_timer_id += 1;
        if (self.next_timer_id > 9007199254740991) self.next_timer_id = 1;
        return id;
    }

    pub fn enqueueTimer(self: *EventLoop, ctx: *core.JSContext, id: i64, callback: core.JSValue, delay_ms: u64, repeats: bool) !void {
        try self.timers.append(ctx, Timer.init(id, callback, nowMs() + delay_ms, delay_ms, repeats));
    }

    fn clearTimer(self: *EventLoop, ctx: *core.JSContext, id: i64) void {
        if (id <= 0) return;
        for (self.timers.items, 0..) |timer, index| {
            if (timer.id != id) continue;
            self.timers.removeAt(ctx, index);
            return;
        }
    }

    fn runNextTimer(self: *EventLoop, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) !bool {
        if (self.timers.items.len == 0) return false;
        const rt = ctx.runtimePtr();
        const now = nowMs();
        var next_delay: u64 = std.math.maxInt(u64);
        for (self.timers.items, 0..) |timer, index| {
            if (timer.timeout_ms > now) {
                next_delay = @min(next_delay, timer.timeout_ms - now);
                continue;
            }
            const callback = timer.callback;
            // A one-shot timer leaves the EventLoop RootProvider before call
            // dispatch reaches its pre-invocation interrupt/GC poll. Publish
            // the detached callback as a native window; scalar root scopes
            // are intentionally erased in production tracing builds.
            var callback_root_values = [_]core.JSValue{callback};
            var callback_root_slices = [_]core.runtime.ValueRootSlice{.{ .borrowed = &callback_root_values }};
            var callback_root_frame = core.runtime.ValueRootFrame{ .slices = &callback_root_slices };
            callback_root_frame.activate(rt);
            defer callback_root_frame.deactivate(rt);
            const timer_id = timer.id;
            const repeats = timer.repeats;
            const delay = timer.delay_ms;
            if (repeats) {
                self.timers.items[index].timeout_ms = now + delay;
            } else {
                self.timers.removeAt(ctx, index);
            }
            if (exec.object_ops.objectFromValue(callback)) |promise| {
                if (promise.class_id == core.class.ids.promise) {
                    if (promise.promiseResultSlot().* == null) {
                        try promise.setPromiseResult(rt, core.JSValue.undefinedValue());
                    }
                    try exec.promise_ops.settlePendingPromiseReaction(ctx, output, global, promise);
                    return true;
                }
            }
            _ = try exec.call_runtime.callValueOrBytecodeRoot(ctx, output, global, global.value(), callback, &.{}, null, null);
            if (repeats and !self.timerExists(timer_id)) return true;
            return true;
        }
        if (next_delay != std.math.maxInt(u64)) {
            const sleep_ms: i64 = @intCast(@min(next_delay, @as(u64, @intCast(std.math.maxInt(i64)))));
            const deadline = std.Io.Timestamp.now(hostTimerIo(), .awake).addDuration(std.Io.Duration.fromMilliseconds(sleep_ms));
            // A foreign waitAsync notification cannot wake libc.poll or a
            // blind timer sleep. Wait on the Runtime completion event instead
            // whenever such a node exists; the helper also shortens this wait
            // to the earliest waitAsync deadline.
            if (exec.atomics_ops.waitForAtomicsHostSignalUntil(rt, deadline, false)) return true;
            std.Io.sleep(hostTimerIo(), std.Io.Duration.fromMilliseconds(sleep_ms), .awake) catch {};
            return true;
        }
        return false;
    }

    fn timerExists(self: *const EventLoop, id: i64) bool {
        for (self.timers.items) |timer| {
            if (timer.id == id) return true;
        }
        return false;
    }

    fn setRwHandler(self: *EventLoop, ctx: *core.JSContext, fd: i32, write_handler: bool, callback: core.JSValue) !void {
        for (self.rw_handlers.items) |*handler| {
            if (handler.fd != fd) continue;
            handler.setCallback(write_handler, callback);
            return;
        }
        var handler = RwHandler{ .fd = fd };
        handler.setCallback(write_handler, callback);
        try self.rw_handlers.append(ctx, handler);
    }

    fn clearRwHandler(self: *EventLoop, ctx: *core.JSContext, fd: i32, write_handler: bool) void {
        for (self.rw_handlers.items, 0..) |*handler, index| {
            if (handler.fd != fd) continue;
            handler.clearCallback(write_handler);
            if (handler.read_callback.is(.null_value) and handler.write_callback.is(.null_value)) {
                self.rw_handlers.removeAt(ctx, index);
            }
            return;
        }
    }

    fn runNextRwHandler(self: *EventLoop, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) !bool {
        return if (comptime builtin.os.tag == .windows)
            self.runNextRwHandlerWindows(ctx, output, global)
        else
            self.runNextRwHandlerPosix(ctx, output, global);
    }

    /// QuickJS's Windows event loop waits only for a readable stdin CRT fd;
    /// arbitrary CRT descriptors are not waitable HANDLEs. Timers and pending
    /// jobs are handled by the adjacent event-loop arms before this hook.
    fn runNextRwHandlerWindows(self: *EventLoop, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) !bool {
        if (self.rw_handlers.items.len == 0) return false;
        var callback = core.JSValue.nullValue();
        for (self.rw_handlers.items) |handler| {
            if (handler.fd == 0 and !handler.read_callback.is(.null_value)) {
                callback = handler.read_callback;
                break;
            }
        }
        if (callback.is(.null_value)) return false;

        const rt = ctx.runtimePtr();
        var timeout_ms: u32 = 0;
        const has_pending_jobs = rt.job_queue.jobs.len != 0;
        const has_pending_host_completion = exec.atomics_ops.atomicsRuntimeHasPendingAsyncWaiters(rt);
        if (!has_pending_jobs and !has_pending_host_completion) {
            timeout_ms = if (self.timers.items.len == 0) windows_api.infinite else blk: {
                const now = nowMs();
                var next_delay: u64 = std.math.maxInt(u64);
                for (self.timers.items) |timer| {
                    next_delay = @min(next_delay, if (timer.timeout_ms > now) timer.timeout_ms - now else 0);
                }
                break :blk @intCast(@min(next_delay, @as(u64, windows_api.infinite - 1)));
            };
        }

        const handle = windows_api.GetStdHandle(windows_api.std_input_handle) orelse return false;
        if (handle == std.os.windows.INVALID_HANDLE_VALUE) return false;
        if (windows_api.WaitForSingleObject(handle, timeout_ms) != windows_api.wait_object_0) return false;

        const retained_callback = callback;
        _ = try exec.call_runtime.callValueOrBytecodeRoot(ctx, output, global, global.value(), retained_callback, &.{}, null, null);
        return true;
    }

    fn runNextRwHandlerPosix(self: *EventLoop, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) !bool {
        if (self.rw_handlers.items.len == 0) return false;
        const rt = ctx.runtimePtr();
        var pollfds = try rt.memory.alloc(libc.struct_pollfd, self.rw_handlers.items.len);
        defer rt.memory.free(libc.struct_pollfd, pollfds);
        var count: usize = 0;
        for (self.rw_handlers.items) |handler| {
            var events: c_short = 0;
            if (!handler.read_callback.is(.null_value)) events |= libc.POLLIN;
            if (!handler.write_callback.is(.null_value)) events |= libc.POLLOUT;
            if (events == 0) continue;
            pollfds[count] = .{ .fd = handler.fd, .events = events, .revents = 0 };
            count += 1;
        }
        if (count == 0) return false;
        var timeout_ms: c_int = 0;
        const has_pending_jobs = rt.job_queue.jobs.len != 0;
        const has_pending_host_completion = exec.atomics_ops.atomicsRuntimeHasPendingAsyncWaiters(rt);
        if (!has_pending_jobs and !has_pending_host_completion) {
            if (self.timers.items.len == 0) {
                timeout_ms = -1;
            } else {
                const now = nowMs();
                var next_delay: u64 = std.math.maxInt(u64);
                for (self.timers.items) |timer| {
                    if (timer.timeout_ms > now) {
                        next_delay = @min(next_delay, timer.timeout_ms - now);
                    } else {
                        next_delay = 0;
                    }
                }
                if (next_delay == std.math.maxInt(u64)) {
                    timeout_ms = -1;
                } else {
                    timeout_ms = @intCast(@min(next_delay, @as(u64, @intCast(std.math.maxInt(c_int)))));
                }
            }
        }
        const ready = libc.poll(pollfds.ptr, @intCast(count), timeout_ms);
        if (ready <= 0) return false;
        for (pollfds[0..count]) |pollfd| {
            if (pollfd.revents == 0) continue;
            for (self.rw_handlers.items) |handler| {
                if (handler.fd != pollfd.fd) continue;
                if ((pollfd.revents & (libc.POLLIN | libc.POLLERR | libc.POLLHUP)) != 0 and !handler.read_callback.is(.null_value)) {
                    const callback = handler.read_callback;
                    _ = try exec.call_runtime.callValueOrBytecodeRoot(ctx, output, global, global.value(), callback, &.{}, null, null);
                    return true;
                }
                if ((pollfd.revents & (libc.POLLOUT | libc.POLLERR | libc.POLLHUP)) != 0 and !handler.write_callback.is(.null_value)) {
                    const callback = handler.write_callback;
                    _ = try exec.call_runtime.callValueOrBytecodeRoot(ctx, output, global, global.value(), callback, &.{}, null, null);
                    return true;
                }
            }
        }
        return false;
    }

    fn setSignalHandler(self: *EventLoop, ctx: *core.JSContext, sig: u32, callback: core.JSValue) !void {
        for (self.signal_handlers.items) |*handler| {
            if (handler.sig != sig) continue;
            handler.setCallback(callback);
            _ = signal(@intCast(sig), @intFromPtr(&osSignalHandler));
            return;
        }
        try self.signal_handlers.append(ctx, SignalHandler.init(sig, callback));
        _ = signal(@intCast(sig), @intFromPtr(&osSignalHandler));
    }

    fn clearSignalHandler(self: *EventLoop, ctx: *core.JSContext, sig: u32, disposition: core.context.SignalDisposition) void {
        for (self.signal_handlers.items, 0..) |handler, index| {
            if (handler.sig != sig) continue;
            self.signal_handlers.removeAt(ctx, index);
            break;
        }
        _ = signal(@intCast(sig), switch (disposition) {
            .default => 0,
            .ignore => 1,
        });
    }

    fn runNextSignalHandler(self: *EventLoop, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) !bool {
        const pending = os_pending_signals.load(.monotonic);
        if (pending == 0) return false;
        _ = ctx.runtimePtr();
        for (self.signal_handlers.items) |handler| {
            const mask = @as(u64, 1) << @intCast(handler.sig);
            if ((pending & mask) == 0) continue;
            _ = os_pending_signals.fetchAnd(~mask, .monotonic);
            const callback = handler.callback;
            _ = try exec.call_runtime.callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), callback, &.{}, null, null);
            return true;
        }
        return false;
    }
};

pub fn runUntilIdle(context: *js_context.JSContext, options: EventLoopOptions) !EventLoopRunResult {
    return EventLoop.runUntilIdle(context, options);
}

const Timer = struct {
    id: i64,
    callback: core.JSValue,
    timeout_ms: u64,
    delay_ms: u64,
    repeats: bool,

    fn init(id: i64, callback: core.JSValue, timeout_ms: u64, delay_ms: u64, repeats: bool) Timer {
        return .{
            .id = id,
            .callback = callback,
            .timeout_ms = timeout_ms,
            .delay_ms = delay_ms,
            .repeats = repeats,
        };
    }

    fn traceRoots(self: *Timer, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
        try visitor.value(&self.callback);
    }
};

const RwHandler = struct {
    fd: i32,
    read_callback: core.JSValue = core.JSValue.nullValue(),
    write_callback: core.JSValue = core.JSValue.nullValue(),

    fn setCallback(self: *RwHandler, write_handler: bool, callback: core.JSValue) void {
        const slot = if (write_handler) &self.write_callback else &self.read_callback;
        slot.* = callback;
    }

    fn clearCallback(self: *RwHandler, write_handler: bool) void {
        const slot = if (write_handler) &self.write_callback else &self.read_callback;
        slot.* = core.JSValue.nullValue();
    }

    fn traceRoots(self: *RwHandler, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
        try visitor.value(&self.read_callback);
        try visitor.value(&self.write_callback);
    }
};

const SignalHandler = struct {
    sig: u32,
    callback: core.JSValue,

    fn init(sig: u32, callback: core.JSValue) SignalHandler {
        return .{
            .sig = sig,
            .callback = callback,
        };
    }

    fn setCallback(self: *SignalHandler, callback: core.JSValue) void {
        self.callback = callback;
    }

    fn traceRoots(self: *SignalHandler, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
        try visitor.value(&self.callback);
    }
};

const vtable = core.context.HostEventLoop.VTable{
    .traceRoots = traceRoots,
    .setExitCode = setExitCode,
    .exitCode = exitCode,
    .nextTimerId = nextTimerId,
    .enqueueTimer = enqueueTimer,
    .clearTimer = clearTimer,
    .runNextTimer = runNextTimer,
    .setRwHandler = setRwHandler,
    .clearRwHandler = clearRwHandler,
    .runNextRwHandler = runNextRwHandler,
    .setSignalHandler = setSignalHandler,
    .clearSignalHandler = clearSignalHandler,
    .runNextSignalHandler = runNextSignalHandler,
};

fn fromOpaque(ptr: *anyopaque) *EventLoop {
    return @ptrCast(@alignCast(ptr));
}

fn installedLoop(ptr: *anyopaque, core_ctx: *core.context.JSContext) *EventLoop {
    const loop = fromOpaque(ptr);
    std.debug.assert(loop.context == core_ctx);
    return loop;
}

fn traceRoots(ptr: *anyopaque, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
    try fromOpaque(ptr).traceRoots(visitor);
}

fn setExitCode(ptr: *anyopaque, code: u8) void {
    fromOpaque(ptr).setExitCode(code);
}

fn exitCode(ptr: *anyopaque) ?u8 {
    return fromOpaque(ptr).exitCode();
}

fn nextTimerId(ptr: *anyopaque) i64 {
    return fromOpaque(ptr).takeNextTimerId();
}

fn enqueueTimer(ptr: *anyopaque, core_ctx: *core.context.JSContext, id: i64, callback: core.JSValue, delay_ms: u64, repeats: bool) !void {
    try installedLoop(ptr, core_ctx).enqueueTimer(core_ctx, id, callback, delay_ms, repeats);
}

fn clearTimer(ptr: *anyopaque, core_ctx: *core.context.JSContext, id: i64) void {
    installedLoop(ptr, core_ctx).clearTimer(core_ctx, id);
}

fn runNextTimer(ptr: *anyopaque, core_ctx: *core.context.JSContext, output: ?*std.Io.Writer, global: *core.Object) !bool {
    return installedLoop(ptr, core_ctx).runNextTimer(core_ctx, output, global);
}

fn setRwHandler(ptr: *anyopaque, core_ctx: *core.context.JSContext, fd: i32, write_handler: bool, callback: core.JSValue) !void {
    try installedLoop(ptr, core_ctx).setRwHandler(core_ctx, fd, write_handler, callback);
}

fn clearRwHandler(ptr: *anyopaque, core_ctx: *core.context.JSContext, fd: i32, write_handler: bool) void {
    installedLoop(ptr, core_ctx).clearRwHandler(core_ctx, fd, write_handler);
}

fn runNextRwHandler(ptr: *anyopaque, core_ctx: *core.context.JSContext, output: ?*std.Io.Writer, global: *core.Object) !bool {
    return installedLoop(ptr, core_ctx).runNextRwHandler(core_ctx, output, global);
}

fn setSignalHandler(ptr: *anyopaque, core_ctx: *core.context.JSContext, sig: u32, callback: core.JSValue) !void {
    try installedLoop(ptr, core_ctx).setSignalHandler(core_ctx, sig, callback);
}

fn clearSignalHandler(ptr: *anyopaque, core_ctx: *core.context.JSContext, sig: u32, disposition: core.context.SignalDisposition) void {
    installedLoop(ptr, core_ctx).clearSignalHandler(core_ctx, sig, disposition);
}

fn runNextSignalHandler(ptr: *anyopaque, core_ctx: *core.context.JSContext, output: ?*std.Io.Writer, global: *core.Object) !bool {
    return installedLoop(ptr, core_ctx).runNextSignalHandler(core_ctx, output, global);
}

/// Set from the signal handler, consumed by `runNextSignalHandler` on the
/// loop thread; both sides go through atomics so a signal landing between the
/// reader's load and store cannot be lost.
var os_pending_signals = std.atomic.Value(u64).init(0);

fn osSignalHandler(sig: c_int) callconv(.c) void {
    if (sig < 0 or sig >= 64) return;
    _ = os_pending_signals.fetchOr(@as(u64, 1) << @intCast(sig), .monotonic);
}

fn nowMs() u64 {
    return platform_clock.monotonicNanos() / std.time.ns_per_ms;
}

fn hostTimerIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "runtime.EventLoop drains queued JS callbacks" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try js_context.JSContext.create(rt, .{});
    defer ctx.destroy();
    var loop = EventLoop.init(ctx, .{});
    loop.install();
    defer loop.deinit();

    const callback = try ctx.eval(
        \\globalThis.__zjs_runtime_event_loop_hit = 0;
        \\(() => { globalThis.__zjs_runtime_event_loop_hit = 7; })
    , .{});

    try exec.call_runtime.enqueuePendingMicrotask(ctx.core, callback);

    const result = try loop.drain();
    try std.testing.expect(!result.hasPendingError());

    const hit = try ctx.eval("globalThis.__zjs_runtime_event_loop_hit;", .{});
    try std.testing.expectEqual(@as(?i32, 7), hit.as(.int));
}

test "runtime.EventLoop removes timers without allocation" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try js_context.JSContext.create(rt, .{});
    defer ctx.destroy();

    var loop = EventLoop.init(ctx, .{});
    defer loop.deinit();

    try loop.timers.ensureCapacity(ctx.core, 2);
    loop.timers.items = loop.timers.items.ptr[0..2];
    loop.timers.items[0] = .{
        .id = 10,
        .callback = core.JSValue.int32(1),
        .timeout_ms = 100,
        .delay_ms = 0,
        .repeats = false,
    };
    loop.timers.items[1] = .{
        .id = 11,
        .callback = core.JSValue.int32(2),
        .timeout_ms = 200,
        .delay_ms = 5,
        .repeats = true,
    };

    const old_bytes = rt.memory.allocated_bytes;
    const old_allocations = rt.memory.allocation_count;
    rt.setMemoryLimit(old_bytes);
    loop.timers.removeAt(ctx.core, 0);
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(@as(usize, 1), loop.timers.items.len);
    try std.testing.expectEqual(@as(usize, 2), loop.timers.capacity);
    try std.testing.expectEqual(@as(i64, 11), loop.timers.items[0].id);
    try std.testing.expectEqual(old_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(old_allocations, rt.memory.allocation_count);

    loop.timers.removeAt(ctx.core, 0);
    try std.testing.expectEqual(@as(usize, 0), loop.timers.items.len);
    try std.testing.expectEqual(@as(usize, 0), loop.timers.capacity);
}

test "runtime.EventLoop removes rw handlers without allocation" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try js_context.JSContext.create(rt, .{});
    defer ctx.destroy();

    var loop = EventLoop.init(ctx, .{});
    defer loop.deinit();

    try loop.rw_handlers.ensureCapacity(ctx.core, 2);
    loop.rw_handlers.items = loop.rw_handlers.items.ptr[0..2];
    loop.rw_handlers.items[0] = .{
        .fd = 10,
        .read_callback = core.JSValue.int32(1),
        .write_callback = core.JSValue.nullValue(),
    };
    loop.rw_handlers.items[1] = .{
        .fd = 11,
        .read_callback = core.JSValue.int32(2),
        .write_callback = core.JSValue.nullValue(),
    };

    const old_bytes = rt.memory.allocated_bytes;
    const old_allocations = rt.memory.allocation_count;
    rt.setMemoryLimit(old_bytes);
    loop.rw_handlers.removeAt(ctx.core, 0);
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(@as(usize, 1), loop.rw_handlers.items.len);
    try std.testing.expectEqual(@as(usize, 2), loop.rw_handlers.capacity);
    try std.testing.expectEqual(@as(i32, 11), loop.rw_handlers.items[0].fd);
    try std.testing.expectEqual(old_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(old_allocations, rt.memory.allocation_count);

    loop.rw_handlers.removeAt(ctx.core, 0);
    try std.testing.expectEqual(@as(usize, 0), loop.rw_handlers.items.len);
    try std.testing.expectEqual(@as(usize, 0), loop.rw_handlers.capacity);
}

test "runtime.EventLoop removes signal handlers without allocation" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try js_context.JSContext.create(rt, .{});
    defer ctx.destroy();

    var loop = EventLoop.init(ctx, .{});
    defer loop.deinit();

    try loop.signal_handlers.ensureCapacity(ctx.core, 2);
    loop.signal_handlers.items = loop.signal_handlers.items.ptr[0..2];
    loop.signal_handlers.items[0] = .{
        .sig = 1,
        .callback = core.JSValue.int32(1),
    };
    loop.signal_handlers.items[1] = .{
        .sig = 2,
        .callback = core.JSValue.int32(2),
    };

    const old_bytes = rt.memory.allocated_bytes;
    const old_allocations = rt.memory.allocation_count;
    rt.setMemoryLimit(old_bytes);
    loop.signal_handlers.removeAt(ctx.core, 0);
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(@as(usize, 1), loop.signal_handlers.items.len);
    try std.testing.expectEqual(@as(usize, 2), loop.signal_handlers.capacity);
    try std.testing.expectEqual(@as(u32, 2), loop.signal_handlers.items[0].sig);
    try std.testing.expectEqual(old_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(old_allocations, rt.memory.allocation_count);

    loop.signal_handlers.removeAt(ctx.core, 0);
    try std.testing.expectEqual(@as(usize, 0), loop.signal_handlers.items.len);
    try std.testing.expectEqual(@as(usize, 0), loop.signal_handlers.capacity);
}

test "runtime.EventLoop keeps host-held unique symbol atoms until release" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try js_context.JSContext.create(rt, .{});
    defer ctx.destroy();

    var loop = EventLoop.init(ctx, .{});
    loop.install();
    defer loop.deinit();

    const timer_symbol = try rt.atoms.newValueSymbol("gc-event-loop-timer-symbol");
    const timer_value = try rt.takeSymbolValue(timer_symbol);
    try loop.enqueueTimer(ctx.core, 1, timer_value, 0, false);

    const rw_read_symbol = try rt.atoms.newValueSymbol("gc-event-loop-rw-read-symbol");
    const rw_write_symbol = try rt.atoms.newValueSymbol("gc-event-loop-rw-write-symbol");
    const rw_read_value = try rt.takeSymbolValue(rw_read_symbol);
    try loop.setRwHandler(ctx.core, 1, false, rw_read_value);
    const rw_write_value = try rt.takeSymbolValue(rw_write_symbol);
    try loop.setRwHandler(ctx.core, 1, true, rw_write_value);

    const signal_symbol = try rt.atoms.newValueSymbol("gc-event-loop-signal-symbol");
    const signal_value = try rt.takeSymbolValue(signal_symbol);
    try loop.signal_handlers.append(ctx.core, SignalHandler.init(2, signal_value));

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(timer_symbol) != null);
    try std.testing.expect(rt.atoms.name(rw_read_symbol) != null);
    try std.testing.expect(rt.atoms.name(rw_write_symbol) != null);
    try std.testing.expect(rt.atoms.name(signal_symbol) != null);

    loop.clearTimer(ctx.core, 1);
    loop.clearRwHandler(ctx.core, 1, false);
    loop.clearRwHandler(ctx.core, 1, true);
    loop.signal_handlers.removeAt(ctx.core, 0);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(timer_symbol) == null);
    try std.testing.expect(rt.atoms.name(rw_read_symbol) == null);
    try std.testing.expect(rt.atoms.name(rw_write_symbol) == null);
    try std.testing.expect(rt.atoms.name(signal_symbol) == null);
}

test "runtime.root tracer visits EventLoop host roots" {
    var rt: core.JSRuntime = undefined;
    try rt.init(std.testing.allocator, .{});
    defer rt.deinit();

    var ctx: js_context.JSContext = undefined;
    try ctx.init(&rt, .{});
    defer ctx.deinit();

    var loop = EventLoop.init(&ctx, .{});
    loop.install();
    defer loop.deinit();

    try loop.enqueueTimer(ctx.core, 1, core.JSValue.int32(102), 0, false);
    try loop.setRwHandler(ctx.core, 1, false, core.JSValue.int32(103));
    try loop.setRwHandler(ctx.core, 1, true, core.JSValue.int32(104));
    try loop.signal_handlers.append(ctx.core, SignalHandler.init(2, core.JSValue.int32(105)));

    const Counter = struct {
        count: usize = 0,

        fn visitValue(context: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (slot.as(.int)) |value| {
                if (value >= 102 and value <= 105) self.count += 1;
            }
        }

        fn visitObject(context: *anyopaque, slot: *?*core.Object) core.runtime.RootTraceError!void {
            _ = context;
            _ = slot;
        }
    };
    var counter = Counter{};
    var visitor = core.runtime.RootVisitor{
        .context = &counter,
        .visit_value = Counter.visitValue,
        .visit_object = Counter.visitObject,
    };
    try rt.traceActiveRoots(&visitor);

    try std.testing.expectEqual(@as(usize, 4), counter.count);
}

test "runtime.EventLoop roots one-shot function bytecode timer callback after dequeue" {
    const bytecode = @import("bytecode.zig");

    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    const ctx = try js_context.JSContext.create(rt, .{});
    const global = try js_context.globalObjectPtr(ctx);
    defer {
        ctx.destroy();
        rt.destroy();
    }

    var loop = EventLoop.init(ctx, .{});
    defer loop.deinit();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-timer-bytecode-symbol");
    const fb = try bytecode.FunctionBytecode.createPublishedFixture(rt, .{
        .realm = ctx.core,
        .flags = .{ .func_kind = .generator },
        .cpool_count = 1,
    }, &.{try rt.takeSymbolValue(symbol_atom)});

    const callback = core.JSValue.functionBytecode(&fb.header);

    try loop.enqueueTimer(ctx.core, 1, callback, 0, false);
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);
    try std.testing.expect(try loop.runNextTimer(ctx.core, null, global));

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "runtime.namespace does not expose internals or kernel primitives" {
    try std.testing.expect(!@hasDecl(@This(), "event_loop"));
    try std.testing.expect(!@hasDecl(@This(), "cleanup"));
    try std.testing.expect(!@hasDecl(@This(), "modules"));
    try std.testing.expect(!@hasDecl(@This(), "plugin"));
    try std.testing.expect(!@hasDecl(@This(), "buffer"));
    try std.testing.expect(!@hasDecl(@This(), "Engine"));
    try std.testing.expect(!@hasDecl(@This(), "JSRuntime"));
    try std.testing.expect(!@hasDecl(@This(), "JSContext"));
    try std.testing.expect(!@hasDecl(@This(), "JSValue"));
    try std.testing.expect(!@hasDecl(@This(), "Object"));
    try std.testing.expect(!@hasDecl(@This(), "binding"));
    try std.testing.expect(!@hasDecl(@This(), "ffi"));
}
