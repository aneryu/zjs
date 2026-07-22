const std = @import("std");

const core = @import("../core/root.zig");
const exec = @import("../exec/root.zig");
const zjs = @import("../binding/root.zig");

const libc = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("poll.h");
    @cInclude("signal.h");
});

extern "c" fn signal(signum: c_int, handler: usize) usize;

pub const Options = struct {
    output: ?*std.Io.Writer = null,
};

pub const RunResult = struct {
    has_pending_exception: bool = false,
    has_unhandled_rejection: bool = false,

    pub fn hasPendingError(self: RunResult) bool {
        return self.has_pending_exception or self.has_unhandled_rejection;
    }
};

pub const EventLoop = struct {
    context: *core.JSContext,
    realm: core.RealmRef,
    output: ?*std.Io.Writer = null,
    timers: []Timer = &.{},
    timers_capacity: usize = 0,
    rw_handlers: []RwHandler = &.{},
    rw_handlers_capacity: usize = 0,
    signal_handlers: []SignalHandler = &.{},
    signal_handlers_capacity: usize = 0,
    next_timer_id: i64 = 1,
    exit_code: ?u8 = null,
    installed: bool = false,

    pub inline fn init(context: *zjs.JSContext, options: Options) EventLoop {
        return initCore(context.core, options);
    }

    pub inline fn initCore(context: *core.JSContext, options: Options) EventLoop {
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
        const timers = self.timers;
        const timers_capacity = self.timers_capacity;
        self.timers = &.{};
        self.timers_capacity = 0;
        for (timers) |timer| timer.deinit(rt);
        if (timers_capacity != 0) rt.memory.free(Timer, timers.ptr[0..timers_capacity]);

        const rw_handlers = self.rw_handlers;
        const rw_handlers_capacity = self.rw_handlers_capacity;
        self.rw_handlers = &.{};
        self.rw_handlers_capacity = 0;
        for (rw_handlers) |handler| handler.deinit(rt);
        if (rw_handlers_capacity != 0) rt.memory.free(RwHandler, rw_handlers.ptr[0..rw_handlers_capacity]);

        const signal_handlers = self.signal_handlers;
        const signal_handlers_capacity = self.signal_handlers_capacity;
        self.signal_handlers = &.{};
        self.signal_handlers_capacity = 0;
        for (signal_handlers) |handler| handler.deinit(rt);
        if (signal_handlers_capacity != 0) rt.memory.free(SignalHandler, signal_handlers.ptr[0..signal_handlers_capacity]);
        self.realm.deinit();
    }

    pub fn runUntilIdle(self: *EventLoop) !RunResult {
        self.context.runtime.job_queue.runAll();
        const global = try self.context.globalObject();
        exec.zjs_vm.drainPendingPromiseJobs(self.context, self.output, global) catch |err| {
            if (!self.context.hasException() and !self.context.hasUnhandledRejection()) return err;
        };
        return self.result();
    }

    pub fn result(self: *const EventLoop) RunResult {
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
        for (self.timers) |*timer| {
            try timer.traceRoots(visitor);
        }
        for (self.rw_handlers) |*handler| {
            try handler.traceRoots(visitor);
        }
        for (self.signal_handlers) |*handler| {
            try handler.traceRoots(visitor);
        }
    }

    fn takeNextTimerId(self: *EventLoop) i64 {
        const id = self.next_timer_id;
        self.next_timer_id += 1;
        if (self.next_timer_id > 9007199254740991) self.next_timer_id = 1;
        return id;
    }

    fn ensureTimerCapacity(self: *EventLoop, ctx: *core.JSContext, min_capacity: usize) !void {
        if (self.timers_capacity >= min_capacity) return;
        var next_capacity = if (self.timers_capacity == 0) @as(usize, 2) else self.timers_capacity * 2;
        while (next_capacity < min_capacity) : (next_capacity *= 2) {}
        const rt = ctx.runtimePtr();
        const next = try rt.memory.alloc(Timer, next_capacity);
        errdefer rt.memory.free(Timer, next);
        const old_timers = self.timers;
        const old_capacity = self.timers_capacity;
        @memcpy(next[0..old_timers.len], old_timers);
        self.timers = next[0..old_timers.len];
        self.timers_capacity = next_capacity;
        if (old_capacity != 0) {
            rt.memory.free(Timer, old_timers.ptr[0..old_capacity]);
        }
    }

    pub fn enqueueTimer(self: *EventLoop, ctx: *core.JSContext, id: i64, callback: zjs.JSValue, delay_ms: u64, repeats: bool) !void {
        const index = self.timers.len;
        try self.ensureTimerCapacity(ctx, index + 1);
        const timer = try Timer.init(ctx, id, callback, nowMs() + delay_ms, delay_ms, repeats);
        self.timers = self.timers.ptr[0 .. index + 1];
        self.timers[index] = timer;
    }

    fn clearTimer(self: *EventLoop, ctx: *core.JSContext, id: i64) void {
        if (id <= 0) return;
        var index: usize = 0;
        while (index < self.timers.len) : (index += 1) {
            if (self.timers[index].id != id) continue;
            self.removeTimerAt(ctx, index);
            return;
        }
    }

    fn removeTimerAt(self: *EventLoop, ctx: *core.JSContext, index: usize) void {
        std.debug.assert(index < self.timers.len);
        const old_len = self.timers.len;
        const removed = self.timers[index];
        if (index + 1 < old_len) {
            @memmove(self.timers[index .. old_len - 1], self.timers[index + 1 .. old_len]);
        }
        self.timers = self.timers.ptr[0 .. old_len - 1];
        if (self.timers.len == 0 and self.timers_capacity != 0) {
            const old_timers = self.timers.ptr[0..self.timers_capacity];
            self.timers = &.{};
            self.timers_capacity = 0;
            ctx.runtimePtr().memory.free(Timer, old_timers);
        }
        removed.deinit(ctx.runtimePtr());
    }

    fn runNextTimer(self: *EventLoop, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) !bool {
        if (self.timers.len == 0) return false;
        const rt = ctx.runtimePtr();
        const now = nowMs();
        var next_delay: u64 = std.math.maxInt(u64);
        for (self.timers, 0..) |timer, index| {
            if (timer.timeout_ms > now) {
                next_delay = @min(next_delay, timer.timeout_ms - now);
                continue;
            }
            var callback = timer.callback.dup();
            defer callback.free(rt);
            var callback_root_values = [_]core.runtime.ValueRootValue{
                .{ .value = &callback },
            };
            const callback_root_frame = core.runtime.ValueRootFrame{
                .previous = rt.active_value_roots,
                .values = &callback_root_values,
            };
            rt.active_value_roots = &callback_root_frame;
            defer rt.active_value_roots = callback_root_frame.previous;
            const timer_id = timer.id;
            const repeats = timer.repeats;
            const delay = timer.delay_ms;
            if (repeats) {
                self.timers[index].timeout_ms = now + delay;
            } else {
                self.removeTimerAt(ctx, index);
            }
            if (exec.object_ops.objectFromValue(callback)) |promise| {
                if (promise.class_id == core.class.ids.promise) {
                    if (promise.promiseResultSlot().* == null) {
                        try promise.setPromiseResult(rt, zjs.JSValue.undefinedValue());
                    }
                    try exec.promise_ops.settlePendingPromiseReaction(ctx, output, global, promise);
                    return true;
                }
            }
            const call_result = try exec.call_runtime.callValueOrBytecode(ctx, output, global, global.value(), callback, &.{}, null, null);
            call_result.free(rt);
            if (repeats and !self.timerExists(timer_id)) return true;
            return true;
        }
        if (next_delay != std.math.maxInt(u64)) {
            const sleep_ms: i64 = @intCast(@min(next_delay, @as(u64, @intCast(std.math.maxInt(i64)))));
            std.Io.sleep(hostTimerIo(), std.Io.Duration.fromMilliseconds(sleep_ms), .awake) catch {};
            return true;
        }
        return false;
    }

    fn timerExists(self: *const EventLoop, id: i64) bool {
        for (self.timers) |timer| {
            if (timer.id == id) return true;
        }
        return false;
    }

    fn ensureRwHandlerCapacity(self: *EventLoop, ctx: *core.JSContext, min_capacity: usize) !void {
        if (self.rw_handlers_capacity >= min_capacity) return;
        var next_capacity = if (self.rw_handlers_capacity == 0) @as(usize, 2) else self.rw_handlers_capacity * 2;
        while (next_capacity < min_capacity) : (next_capacity *= 2) {}
        const rt = ctx.runtimePtr();
        const next = try rt.memory.alloc(RwHandler, next_capacity);
        errdefer rt.memory.free(RwHandler, next);
        const old_handlers = self.rw_handlers;
        const old_capacity = self.rw_handlers_capacity;
        @memcpy(next[0..old_handlers.len], old_handlers);
        self.rw_handlers = next[0..old_handlers.len];
        self.rw_handlers_capacity = next_capacity;
        if (old_capacity != 0) {
            rt.memory.free(RwHandler, old_handlers.ptr[0..old_capacity]);
        }
    }

    fn setRwHandler(self: *EventLoop, ctx: *core.JSContext, fd: i32, write_handler: bool, callback: zjs.JSValue) !void {
        const rt = ctx.runtimePtr();
        for (self.rw_handlers) |*handler| {
            if (handler.fd != fd) continue;
            try handler.setCallback(rt, write_handler, callback);
            return;
        }
        const index = self.rw_handlers.len;
        try self.ensureRwHandlerCapacity(ctx, index + 1);
        var handler = RwHandler{
            .fd = fd,
        };
        errdefer handler.deinit(rt);
        try handler.setCallback(rt, write_handler, callback);
        self.rw_handlers = self.rw_handlers.ptr[0 .. index + 1];
        self.rw_handlers[index] = handler;
    }

    fn clearRwHandler(self: *EventLoop, ctx: *core.JSContext, fd: i32, write_handler: bool) void {
        var index: usize = 0;
        while (index < self.rw_handlers.len) : (index += 1) {
            if (self.rw_handlers[index].fd != fd) continue;
            self.rw_handlers[index].clearCallback(ctx.runtimePtr(), write_handler);
            if (self.rw_handlers[index].read_callback.isNull() and self.rw_handlers[index].write_callback.isNull()) {
                self.removeRwHandlerAt(ctx, index);
            }
            return;
        }
    }

    fn removeRwHandlerAt(self: *EventLoop, ctx: *core.JSContext, index: usize) void {
        std.debug.assert(index < self.rw_handlers.len);
        const old_len = self.rw_handlers.len;
        const removed = self.rw_handlers[index];
        if (index + 1 < old_len) {
            @memmove(self.rw_handlers[index .. old_len - 1], self.rw_handlers[index + 1 .. old_len]);
        }
        self.rw_handlers = self.rw_handlers.ptr[0 .. old_len - 1];
        if (self.rw_handlers.len == 0 and self.rw_handlers_capacity != 0) {
            const old_handlers = self.rw_handlers.ptr[0..self.rw_handlers_capacity];
            self.rw_handlers = &.{};
            self.rw_handlers_capacity = 0;
            ctx.runtimePtr().memory.free(RwHandler, old_handlers);
        }
        removed.deinit(ctx.runtimePtr());
    }

    fn runNextRwHandler(self: *EventLoop, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) !bool {
        if (self.rw_handlers.len == 0) return false;
        const rt = ctx.runtimePtr();
        var pollfds = try rt.memory.alloc(libc.struct_pollfd, self.rw_handlers.len);
        defer rt.memory.free(libc.struct_pollfd, pollfds);
        var count: usize = 0;
        for (self.rw_handlers) |handler| {
            var events: c_short = 0;
            if (!handler.read_callback.isNull()) events |= libc.POLLIN;
            if (!handler.write_callback.isNull()) events |= libc.POLLOUT;
            if (events == 0) continue;
            pollfds[count] = .{ .fd = handler.fd, .events = events, .revents = 0 };
            count += 1;
        }
        if (count == 0) return false;
        var timeout_ms: c_int = 0;
        const has_pending_jobs = (ctx.peekPendingPromiseJobSequence() != null or rt.peekPendingFinalizationJobSequence() != null);
        if (!has_pending_jobs) {
            if (self.timers.len == 0) {
                timeout_ms = -1;
            } else {
                const now = nowMs();
                var next_delay: u64 = std.math.maxInt(u64);
                for (self.timers) |timer| {
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
            var handler_index: usize = 0;
            while (handler_index < self.rw_handlers.len) : (handler_index += 1) {
                if (self.rw_handlers[handler_index].fd != pollfd.fd) continue;
                const handler = self.rw_handlers[handler_index];
                if ((pollfd.revents & (libc.POLLIN | libc.POLLERR | libc.POLLHUP)) != 0 and !handler.read_callback.isNull()) {
                    const callback = handler.read_callback.dup();
                    defer callback.free(rt);
                    const call_result = try exec.call_runtime.callValueOrBytecode(ctx, output, global, global.value(), callback, &.{}, null, null);
                    call_result.free(rt);
                    return true;
                }
                if ((pollfd.revents & (libc.POLLOUT | libc.POLLERR | libc.POLLHUP)) != 0 and !handler.write_callback.isNull()) {
                    const callback = handler.write_callback.dup();
                    defer callback.free(rt);
                    const call_result = try exec.call_runtime.callValueOrBytecode(ctx, output, global, global.value(), callback, &.{}, null, null);
                    call_result.free(rt);
                    return true;
                }
            }
        }
        return false;
    }

    fn ensureSignalHandlerCapacity(self: *EventLoop, ctx: *core.JSContext, min_capacity: usize) !void {
        if (self.signal_handlers_capacity >= min_capacity) return;
        var next_capacity = if (self.signal_handlers_capacity == 0) @as(usize, 2) else self.signal_handlers_capacity * 2;
        while (next_capacity < min_capacity) : (next_capacity *= 2) {}
        const rt = ctx.runtimePtr();
        const next = try rt.memory.alloc(SignalHandler, next_capacity);
        errdefer rt.memory.free(SignalHandler, next);
        const old_handlers = self.signal_handlers;
        const old_capacity = self.signal_handlers_capacity;
        @memcpy(next[0..old_handlers.len], old_handlers);
        self.signal_handlers = next[0..old_handlers.len];
        self.signal_handlers_capacity = next_capacity;
        if (old_capacity != 0) {
            rt.memory.free(SignalHandler, old_handlers.ptr[0..old_capacity]);
        }
    }

    fn setSignalHandler(self: *EventLoop, ctx: *core.JSContext, sig: u32, callback: zjs.JSValue) !void {
        const rt = ctx.runtimePtr();
        for (self.signal_handlers) |*handler| {
            if (handler.sig != sig) continue;
            try handler.setCallback(rt, callback);
            _ = signal(@intCast(sig), @intFromPtr(&osSignalHandler));
            return;
        }
        const index = self.signal_handlers.len;
        try self.ensureSignalHandlerCapacity(ctx, index + 1);
        const handler = try SignalHandler.init(ctx, sig, callback);
        self.signal_handlers = self.signal_handlers.ptr[0 .. index + 1];
        self.signal_handlers[index] = handler;
        _ = signal(@intCast(sig), @intFromPtr(&osSignalHandler));
    }

    fn clearSignalHandler(self: *EventLoop, ctx: *core.JSContext, sig: u32, disposition: core.context.SignalDisposition) void {
        var index: usize = 0;
        while (index < self.signal_handlers.len) : (index += 1) {
            if (self.signal_handlers[index].sig != sig) continue;
            self.removeSignalHandlerAt(ctx, index);
            break;
        }
        _ = signal(@intCast(sig), switch (disposition) {
            .default => 0,
            .ignore => 1,
        });
    }

    fn removeSignalHandlerAt(self: *EventLoop, ctx: *core.JSContext, index: usize) void {
        std.debug.assert(index < self.signal_handlers.len);
        const old_len = self.signal_handlers.len;
        const removed = self.signal_handlers[index];
        if (index + 1 < old_len) {
            @memmove(self.signal_handlers[index .. old_len - 1], self.signal_handlers[index + 1 .. old_len]);
        }
        self.signal_handlers = self.signal_handlers.ptr[0 .. old_len - 1];
        if (self.signal_handlers.len == 0 and self.signal_handlers_capacity != 0) {
            const old_handlers = self.signal_handlers.ptr[0..self.signal_handlers_capacity];
            self.signal_handlers = &.{};
            self.signal_handlers_capacity = 0;
            ctx.runtimePtr().memory.free(SignalHandler, old_handlers);
        }
        removed.deinit(ctx.runtimePtr());
    }

    fn runNextSignalHandler(self: *EventLoop, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) !bool {
        if (os_pending_signals == 0) return false;
        const rt = ctx.runtimePtr();
        for (self.signal_handlers) |handler| {
            const mask = @as(u64, 1) << @intCast(handler.sig);
            if ((os_pending_signals & mask) == 0) continue;
            os_pending_signals &= ~mask;
            const callback = handler.callback.dup();
            defer callback.free(rt);
            const call_result = try exec.call_runtime.callValueOrBytecode(ctx, output, global, zjs.JSValue.undefinedValue(), callback, &.{}, null, null);
            call_result.free(rt);
            return true;
        }
        return false;
    }
};

pub fn runUntilIdle(context: *zjs.JSContext, options: Options) !RunResult {
    var loop = EventLoop.init(context, options);
    loop.install();
    defer loop.deinit();
    return loop.runUntilIdle();
}

const Timer = struct {
    id: i64,
    callback: zjs.JSValue,
    timeout_ms: u64,
    delay_ms: u64,
    repeats: bool,
    callback_symbol_rooted: bool = false,

    fn init(ctx: *core.JSContext, id: i64, callback: zjs.JSValue, timeout_ms: u64, delay_ms: u64, repeats: bool) !Timer {
        const rt = ctx.runtimePtr();
        var timer = Timer{
            .id = id,
            .callback = callback.dup(),
            .timeout_ms = timeout_ms,
            .delay_ms = delay_ms,
            .repeats = repeats,
        };
        errdefer timer.callback.free(rt);
        timer.callback_symbol_rooted = try rt.registerExternalValueSymbolRoot(callback);
        return timer;
    }

    fn deinit(self: Timer, rt: *zjs.JSRuntime) void {
        if (self.callback_symbol_rooted) rt.unregisterExternalValueSymbolRoot(self.callback);
        self.callback.free(rt);
    }

    fn traceRoots(self: *Timer, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
        try visitor.value(&self.callback);
    }
};

const RwHandler = struct {
    fd: i32,
    read_callback: zjs.JSValue = zjs.JSValue.nullValue(),
    write_callback: zjs.JSValue = zjs.JSValue.nullValue(),
    symbol_root_mask: u2 = 0,

    fn deinit(self: RwHandler, rt: *zjs.JSRuntime) void {
        if ((self.symbol_root_mask & 0b01) != 0) rt.unregisterExternalValueSymbolRoot(self.read_callback);
        if ((self.symbol_root_mask & 0b10) != 0) rt.unregisterExternalValueSymbolRoot(self.write_callback);
        self.read_callback.free(rt);
        self.write_callback.free(rt);
    }

    fn setCallback(self: *RwHandler, rt: *zjs.JSRuntime, write_handler: bool, callback: zjs.JSValue) !void {
        const next_callback = callback.dup();
        var next_rooted = false;
        errdefer next_callback.free(rt);
        next_rooted = try rt.registerExternalValueSymbolRoot(callback);
        errdefer if (next_rooted) rt.unregisterExternalValueSymbolRoot(next_callback);

        const bit: u2 = if (write_handler) 0b10 else 0b01;
        const slot = if (write_handler) &self.write_callback else &self.read_callback;
        const old_callback = slot.*;
        const old_rooted = (self.symbol_root_mask & bit) != 0;
        slot.* = next_callback;
        if (next_rooted) {
            self.symbol_root_mask |= bit;
        } else {
            self.symbol_root_mask &= ~bit;
        }
        if (old_rooted) rt.unregisterExternalValueSymbolRoot(old_callback);
        old_callback.free(rt);
    }

    fn clearCallback(self: *RwHandler, rt: *zjs.JSRuntime, write_handler: bool) void {
        const bit: u2 = if (write_handler) 0b10 else 0b01;
        const slot = if (write_handler) &self.write_callback else &self.read_callback;
        const old_callback = slot.*;
        const old_rooted = (self.symbol_root_mask & bit) != 0;
        slot.* = zjs.JSValue.nullValue();
        self.symbol_root_mask &= ~bit;
        if (old_rooted) rt.unregisterExternalValueSymbolRoot(old_callback);
        old_callback.free(rt);
    }

    fn traceRoots(self: *RwHandler, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
        try visitor.value(&self.read_callback);
        try visitor.value(&self.write_callback);
    }
};

const SignalHandler = struct {
    sig: u32,
    callback: zjs.JSValue,
    callback_symbol_rooted: bool = false,

    fn init(ctx: *core.JSContext, sig: u32, callback: zjs.JSValue) !SignalHandler {
        const rt = ctx.runtimePtr();
        var handler = SignalHandler{
            .sig = sig,
            .callback = callback.dup(),
        };
        errdefer handler.callback.free(rt);
        handler.callback_symbol_rooted = try rt.registerExternalValueSymbolRoot(callback);
        return handler;
    }

    fn deinit(self: SignalHandler, rt: *zjs.JSRuntime) void {
        if (self.callback_symbol_rooted) rt.unregisterExternalValueSymbolRoot(self.callback);
        self.callback.free(rt);
    }

    fn setCallback(self: *SignalHandler, rt: *zjs.JSRuntime, callback: zjs.JSValue) !void {
        const next_callback = callback.dup();
        var next_rooted = false;
        errdefer next_callback.free(rt);
        next_rooted = try rt.registerExternalValueSymbolRoot(callback);
        errdefer if (next_rooted) rt.unregisterExternalValueSymbolRoot(next_callback);

        const old_callback = self.callback;
        const old_rooted = self.callback_symbol_rooted;
        self.callback = next_callback;
        self.callback_symbol_rooted = next_rooted;
        if (old_rooted) rt.unregisterExternalValueSymbolRoot(old_callback);
        old_callback.free(rt);
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

fn enqueueTimer(ptr: *anyopaque, core_ctx: *core.context.JSContext, id: i64, callback: zjs.JSValue, delay_ms: u64, repeats: bool) !void {
    const ctx = fromOpaque(ptr).context;
    std.debug.assert(ctx == core_ctx);
    try fromOpaque(ptr).enqueueTimer(ctx, id, callback, delay_ms, repeats);
}

fn clearTimer(ptr: *anyopaque, core_ctx: *core.context.JSContext, id: i64) void {
    const ctx = fromOpaque(ptr).context;
    std.debug.assert(ctx == core_ctx);
    fromOpaque(ptr).clearTimer(ctx, id);
}

fn runNextTimer(ptr: *anyopaque, core_ctx: *core.context.JSContext, output: ?*std.Io.Writer, global: *core.Object) !bool {
    const ctx = fromOpaque(ptr).context;
    std.debug.assert(ctx == core_ctx);
    return fromOpaque(ptr).runNextTimer(ctx, output, global);
}

fn setRwHandler(ptr: *anyopaque, core_ctx: *core.context.JSContext, fd: i32, write_handler: bool, callback: zjs.JSValue) !void {
    const ctx = fromOpaque(ptr).context;
    std.debug.assert(ctx == core_ctx);
    try fromOpaque(ptr).setRwHandler(ctx, fd, write_handler, callback);
}

fn clearRwHandler(ptr: *anyopaque, core_ctx: *core.context.JSContext, fd: i32, write_handler: bool) void {
    const ctx = fromOpaque(ptr).context;
    std.debug.assert(ctx == core_ctx);
    fromOpaque(ptr).clearRwHandler(ctx, fd, write_handler);
}

fn runNextRwHandler(ptr: *anyopaque, core_ctx: *core.context.JSContext, output: ?*std.Io.Writer, global: *core.Object) !bool {
    const ctx = fromOpaque(ptr).context;
    std.debug.assert(ctx == core_ctx);
    return fromOpaque(ptr).runNextRwHandler(ctx, output, global);
}

fn setSignalHandler(ptr: *anyopaque, core_ctx: *core.context.JSContext, sig: u32, callback: zjs.JSValue) !void {
    const ctx = fromOpaque(ptr).context;
    std.debug.assert(ctx == core_ctx);
    try fromOpaque(ptr).setSignalHandler(ctx, sig, callback);
}

fn clearSignalHandler(ptr: *anyopaque, core_ctx: *core.context.JSContext, sig: u32, disposition: core.context.SignalDisposition) void {
    const ctx = fromOpaque(ptr).context;
    std.debug.assert(ctx == core_ctx);
    fromOpaque(ptr).clearSignalHandler(ctx, sig, disposition);
}

fn runNextSignalHandler(ptr: *anyopaque, core_ctx: *core.context.JSContext, output: ?*std.Io.Writer, global: *core.Object) !bool {
    const ctx = fromOpaque(ptr).context;
    std.debug.assert(ctx == core_ctx);
    return fromOpaque(ptr).runNextSignalHandler(ctx, output, global);
}

var os_pending_signals: u64 = 0;

fn osSignalHandler(sig: c_int) callconv(.c) void {
    if (sig < 0 or sig >= 64) return;
    os_pending_signals |= @as(u64, 1) << @intCast(sig);
}

fn nowMs() u64 {
    const ns = std.Io.Clock.Timestamp.now(hostTimerIo(), .awake).raw.toNanoseconds();
    return @intCast(@divTrunc(ns, std.time.ns_per_ms));
}

fn hostTimerIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "EventLoop drains queued JS callbacks" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();
    var loop = EventLoop.init(ctx, .{});
    loop.install();
    defer loop.deinit();

    const callback = try ctx.eval(
        \\globalThis.__zjs_runtime_event_loop_hit = 0;
        \\(() => { globalThis.__zjs_runtime_event_loop_hit = 7; })
    , .{});
    defer callback.free(rt);

    try exec.call_runtime.enqueuePendingMicrotask(ctx.core, callback);

    const result = try loop.runUntilIdle();
    try std.testing.expect(!result.hasPendingError());

    const hit = try ctx.eval("globalThis.__zjs_runtime_event_loop_hit;", .{});
    defer hit.free(rt);
    try std.testing.expectEqual(@as(?i32, 7), hit.asInt32());
}

test "EventLoop removes timers without allocation" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    var loop = EventLoop.init(ctx, .{});
    defer loop.deinit();

    try loop.ensureTimerCapacity(ctx.core, 2);
    loop.timers = loop.timers.ptr[0..2];
    loop.timers[0] = .{
        .id = 10,
        .callback = zjs.JSValue.int32(1),
        .timeout_ms = 100,
        .delay_ms = 0,
        .repeats = false,
    };
    loop.timers[1] = .{
        .id = 11,
        .callback = zjs.JSValue.int32(2),
        .timeout_ms = 200,
        .delay_ms = 5,
        .repeats = true,
    };

    const old_bytes = rt.memory.allocated_bytes;
    const old_allocations = rt.memory.allocation_count;
    rt.setMemoryLimit(old_bytes);
    loop.removeTimerAt(ctx.core, 0);
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(@as(usize, 1), loop.timers.len);
    try std.testing.expectEqual(@as(usize, 2), loop.timers_capacity);
    try std.testing.expectEqual(@as(i64, 11), loop.timers[0].id);
    try std.testing.expectEqual(old_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(old_allocations, rt.memory.allocation_count);

    loop.removeTimerAt(ctx.core, 0);
    try std.testing.expectEqual(@as(usize, 0), loop.timers.len);
    try std.testing.expectEqual(@as(usize, 0), loop.timers_capacity);
}

test "EventLoop removes rw handlers without allocation" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    var loop = EventLoop.init(ctx, .{});
    defer loop.deinit();

    try loop.ensureRwHandlerCapacity(ctx.core, 2);
    loop.rw_handlers = loop.rw_handlers.ptr[0..2];
    loop.rw_handlers[0] = .{
        .fd = 10,
        .read_callback = zjs.JSValue.int32(1),
        .write_callback = zjs.JSValue.nullValue(),
    };
    loop.rw_handlers[1] = .{
        .fd = 11,
        .read_callback = zjs.JSValue.int32(2),
        .write_callback = zjs.JSValue.nullValue(),
    };

    const old_bytes = rt.memory.allocated_bytes;
    const old_allocations = rt.memory.allocation_count;
    rt.setMemoryLimit(old_bytes);
    loop.removeRwHandlerAt(ctx.core, 0);
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(@as(usize, 1), loop.rw_handlers.len);
    try std.testing.expectEqual(@as(usize, 2), loop.rw_handlers_capacity);
    try std.testing.expectEqual(@as(i32, 11), loop.rw_handlers[0].fd);
    try std.testing.expectEqual(old_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(old_allocations, rt.memory.allocation_count);

    loop.removeRwHandlerAt(ctx.core, 0);
    try std.testing.expectEqual(@as(usize, 0), loop.rw_handlers.len);
    try std.testing.expectEqual(@as(usize, 0), loop.rw_handlers_capacity);
}

test "EventLoop removes signal handlers without allocation" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    var loop = EventLoop.init(ctx, .{});
    defer loop.deinit();

    try loop.ensureSignalHandlerCapacity(ctx.core, 2);
    loop.signal_handlers = loop.signal_handlers.ptr[0..2];
    loop.signal_handlers[0] = .{
        .sig = 1,
        .callback = zjs.JSValue.int32(1),
    };
    loop.signal_handlers[1] = .{
        .sig = 2,
        .callback = zjs.JSValue.int32(2),
    };

    const old_bytes = rt.memory.allocated_bytes;
    const old_allocations = rt.memory.allocation_count;
    rt.setMemoryLimit(old_bytes);
    loop.removeSignalHandlerAt(ctx.core, 0);
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(@as(usize, 1), loop.signal_handlers.len);
    try std.testing.expectEqual(@as(usize, 2), loop.signal_handlers_capacity);
    try std.testing.expectEqual(@as(u32, 2), loop.signal_handlers[0].sig);
    try std.testing.expectEqual(old_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(old_allocations, rt.memory.allocation_count);

    loop.removeSignalHandlerAt(ctx.core, 0);
    try std.testing.expectEqual(@as(usize, 0), loop.signal_handlers.len);
    try std.testing.expectEqual(@as(usize, 0), loop.signal_handlers_capacity);
}

test "EventLoop keeps host-held unique symbol atoms until release" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    var loop = EventLoop.init(ctx, .{});
    loop.install();
    defer loop.deinit();

    const timer_symbol = try rt.atoms.newValueSymbol("gc-event-loop-timer-symbol");
    const timer_value = try rt.symbolValue(timer_symbol);
    try loop.enqueueTimer(ctx.core, 1, timer_value, 0, false);
    timer_value.free(rt);

    const rw_read_symbol = try rt.atoms.newValueSymbol("gc-event-loop-rw-read-symbol");
    const rw_write_symbol = try rt.atoms.newValueSymbol("gc-event-loop-rw-write-symbol");
    const rw_read_value = try rt.symbolValue(rw_read_symbol);
    try loop.setRwHandler(ctx.core, 1, false, rw_read_value);
    rw_read_value.free(rt);
    const rw_write_value = try rt.symbolValue(rw_write_symbol);
    try loop.setRwHandler(ctx.core, 1, true, rw_write_value);
    rw_write_value.free(rt);

    try loop.ensureSignalHandlerCapacity(ctx.core, 1);
    loop.signal_handlers = loop.signal_handlers.ptr[0..1];
    const signal_symbol = try rt.atoms.newValueSymbol("gc-event-loop-signal-symbol");
    const signal_value = try rt.symbolValue(signal_symbol);
    loop.signal_handlers[0] = try SignalHandler.init(ctx.core, 2, signal_value);
    signal_value.free(rt);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(timer_symbol) != null);
    try std.testing.expect(rt.atoms.name(rw_read_symbol) != null);
    try std.testing.expect(rt.atoms.name(rw_write_symbol) != null);
    try std.testing.expect(rt.atoms.name(signal_symbol) != null);

    loop.clearTimer(ctx.core, 1);
    loop.clearRwHandler(ctx.core, 1, false);
    loop.clearRwHandler(ctx.core, 1, true);
    loop.removeSignalHandlerAt(ctx.core, 0);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(timer_symbol) == null);
    try std.testing.expect(rt.atoms.name(rw_read_symbol) == null);
    try std.testing.expect(rt.atoms.name(rw_write_symbol) == null);
    try std.testing.expect(rt.atoms.name(signal_symbol) == null);
}

test "runtime root tracer visits EventLoop host roots" {
    var rt: zjs.JSRuntime = undefined;
    try rt.init(std.testing.allocator, .{});
    defer rt.deinit();

    var ctx: zjs.JSContext = undefined;
    try ctx.init(&rt, .{});
    defer ctx.deinit();

    var loop = EventLoop.init(&ctx, .{});
    loop.install();
    defer loop.deinit();

    try loop.enqueueTimer(ctx.core, 1, zjs.JSValue.int32(102), 0, false);
    try loop.setRwHandler(ctx.core, 1, false, zjs.JSValue.int32(103));
    try loop.setRwHandler(ctx.core, 1, true, zjs.JSValue.int32(104));
    try loop.ensureSignalHandlerCapacity(ctx.core, 1);
    loop.signal_handlers = loop.signal_handlers.ptr[0..1];
    loop.signal_handlers[0] = try SignalHandler.init(ctx.core, 2, zjs.JSValue.int32(105));

    const Counter = struct {
        count: usize = 0,

        fn visitValue(context: *anyopaque, slot: *zjs.JSValue) core.runtime.RootTraceError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (slot.asInt32()) |value| {
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

test "EventLoop roots one-shot function bytecode timer callback after dequeue" {
    const bytecode = @import("../bytecode.zig");

    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    const ctx = try zjs.JSContext.create(rt);
    const global = try ctx.globalObject();
    defer {
        ctx.destroy();
        rt.destroy();
    }

    var loop = EventLoop.init(ctx, .{});
    defer loop.deinit();

    const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    fb.flags.func_kind = .generator;
    core.gc.retain(&global.header);
    fb.realm_global_header = &global.header;
    try rt.gc.add(&fb.header);

    {
        const __cp = try rt.memory.alloc(zjs.JSValue, 1);
        fb.cpool = __cp.ptr;
        fb.cpool_count = @intCast(__cp.len);
    }
    const symbol_atom = try rt.atoms.newValueSymbol("gc-timer-bytecode-symbol");
    fb.cpool[0] = try rt.symbolValue(symbol_atom);
    fb.cpool_count = 1;

    var callback = zjs.JSValue.functionBytecode(&fb.header);
    var callback_alive = true;
    defer if (callback_alive) callback.free(rt);

    try loop.enqueueTimer(ctx.core, 1, callback, 0, false);
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);
    try std.testing.expect(try loop.runNextTimer(ctx.core, null, global));

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);

    callback.free(rt);
    callback_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}
