//! Host event loop for timers and job draining.
//!
//! The loop traces its timer callbacks and holds a retained realm reference;
//! removing a timer stops tracing its callback. `output` stays borrowed from
//! the host. JS call/job semantics stay in exec and the public adapter stays
//! in js_context: this module is only the scheduling seam.
//!
//! Internal bundled host implementation; the engine does not import it.

const std = @import("std");

const zjs = @import("zjs");
const core = zjs.core;
const exec = zjs.exec;
const clock = @import("clock.zig");
const js_context = zjs;

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
            if (capacity != 0) rt.nativeAllocator().free(items.ptr[0..capacity]);
        }

        fn ensureCapacity(self: *@This(), ctx: *core.JSContext, min_capacity: usize) !void {
            if (self.capacity >= min_capacity) return;
            var next_capacity = if (self.capacity == 0) @as(usize, 2) else self.capacity * 2;
            while (next_capacity < min_capacity) : (next_capacity *= 2) {}
            const rt = ctx.runtimePtr();
            const next = try rt.nativeAllocator().alloc(T, next_capacity);
            errdefer rt.nativeAllocator().free(next);
            const old_items = self.items;
            const old_capacity = self.capacity;
            @memcpy(next[0..old_items.len], old_items);
            self.items = next[0..old_items.len];
            self.capacity = next_capacity;
            if (old_capacity != 0) {
                rt.nativeAllocator().free(old_items.ptr[0..old_capacity]);
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
                ctx.runtimePtr().nativeAllocator().free(old);
            }
        }
    };
}

pub const EventLoop = struct {
    context: *core.JSContext,
    realm: core.RealmRef,
    output: ?*std.Io.Writer = null,
    timers: HostList(Timer) = .{},
    next_timer_id: i64 = 1,
    installed: bool = false,

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

    /// Only recover this implementation after checking the callback identity.
    pub fn fromContext(ctx: *core.JSContext) ?*EventLoop {
        const scheduler = ctx.hostScheduler() orelse return null;
        if (scheduler.poll != pollHost) return null;
        return @ptrCast(@alignCast(scheduler.ptr));
    }

    pub fn install(self: *EventLoop) void {
        self.context.setHostScheduler(.{
            .ptr = self,
            .traceRoots = traceHostRoots,
            .poll = pollHost,
        });
        self.installed = true;
    }

    pub fn deinit(self: *EventLoop) void {
        if (self.installed) {
            self.context.clearHostScheduler(self);
            self.installed = false;
        }
        const rt = self.context.runtimePtr();
        self.timers.deinit(rt);
        self.realm.deinit();
    }

    pub fn drain(self: *EventLoop) !EventLoopRunResult {
        const global = try self.context.globalObject();
        while (true) {
            try exec.atomics_ops.processExpiredAtomicsWaiters(self.context);
            try exec.zjs_vm.drainPendingPromiseJobs(self.context, self.output, global);
            if (try self.runNextTimer(self.context, self.output, global)) continue;
            if (try exec.atomics_ops.runNextAtomicsHostCompletion(self.context, false)) continue;
            break;
        }
        return self.result();
    }

    pub fn result(self: *const EventLoop) EventLoopRunResult {
        return .{
            .has_pending_exception = self.context.hasException(),
            .has_unhandled_rejection = self.context.hasUnhandledRejection(),
        };
    }

    fn traceRoots(self: *EventLoop, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
        for (self.timers.items) |*timer| {
            try timer.traceRoots(visitor);
        }
    }

    pub fn takeNextTimerId(self: *EventLoop) i64 {
        const id = self.next_timer_id;
        self.next_timer_id += 1;
        if (self.next_timer_id > 9007199254740991) self.next_timer_id = 1;
        return id;
    }

    /// Schedule `callback`, which the caller has checked is callable, to run
    /// once on the loop after `delay_ms`.
    pub fn enqueueTimer(self: *EventLoop, ctx: *core.JSContext, id: i64, callback: core.JSValue, delay_ms: u64) !void {
        try self.timers.append(ctx, .{ .id = id, .callback = callback, .timeout_ms = nowMs() + delay_ms });
    }

    pub fn clearTimer(self: *EventLoop, ctx: *core.JSContext, id: i64) void {
        if (id <= 0) return;
        for (self.timers.items, 0..) |timer, index| {
            if (timer.id != id) continue;
            self.timers.removeAt(ctx, index);
            return;
        }
    }

    pub fn runNextTimer(self: *EventLoop, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) !bool {
        if (self.timers.items.len == 0) return false;
        const rt = ctx.runtimePtr();
        const now = nowMs();
        var next_delay: u64 = std.math.maxInt(u64);
        // Run the expired timer with the earliest deadline; equal deadlines
        // keep insertion order.
        var due: ?usize = null;
        for (self.timers.items, 0..) |timer, index| {
            if (timer.timeout_ms > now) {
                next_delay = @min(next_delay, timer.timeout_ms - now);
            } else if (due == null or timer.timeout_ms < self.timers.items[due.?].timeout_ms) {
                due = index;
            }
        }
        if (due) |index| {
            const timer = self.timers.items[index];
            const callback = timer.callback;
            // The timer leaves the EventLoop RootProvider before call dispatch
            // reaches its pre-invocation interrupt/GC poll. Publish the
            // detached callback as a native window; scalar root scopes are
            // intentionally erased in production tracing builds.
            var callback_root_values = [_]core.JSValue{callback};
            var callback_root_slices = [_]core.runtime.ValueRootSlice{.{ .borrowed = &callback_root_values }};
            var callback_root_frame = core.runtime.ValueRootFrame{ .slices = &callback_root_slices };
            callback_root_frame.activate(rt);
            defer callback_root_frame.deactivate(rt);
            self.timers.removeAt(ctx, index);
            _ = try exec.call_runtime.callValueOrBytecodeRoot(ctx, output, global, global.value(), callback, &.{}, null, null);
            return true;
        }
        if (next_delay != std.math.maxInt(u64)) {
            const sleep_ms: i64 = @intCast(@min(next_delay, @as(u64, @intCast(std.math.maxInt(i64)))));
            const deadline = std.Io.Timestamp.now(clock.io(), .awake).addDuration(std.Io.Duration.fromMilliseconds(sleep_ms));
            // A foreign waitAsync notification cannot wake a blind timer
            // sleep. Wait on the Runtime completion event instead
            // whenever such a node exists; the helper also shortens this wait
            // to the earliest waitAsync deadline.
            if (exec.atomics_ops.waitForAtomicsHostSignalUntil(rt, deadline, false)) return true;
            std.Io.sleep(clock.io(), std.Io.Duration.fromMilliseconds(sleep_ms), .awake) catch {};
            return true;
        }
        return false;
    }
};

/// A one-shot timer: the loop removes it before running its callback.
const Timer = struct {
    id: i64,
    callback: core.JSValue,
    timeout_ms: u64,

    fn traceRoots(self: *Timer, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
        try visitor.value(&self.callback);
    }
};

fn traceHostRoots(ptr: *anyopaque, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
    const loop: *EventLoop = @ptrCast(@alignCast(ptr));
    try loop.traceRoots(visitor);
}

fn pollHost(ptr: *anyopaque, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) !bool {
    const loop: *EventLoop = @ptrCast(@alignCast(ptr));
    std.debug.assert(loop.context == ctx);
    return loop.runNextTimer(ctx, output, global);
}

fn nowMs() u64 {
    return clock.monotonicNanos() / std.time.ns_per_ms;
}

pub const tests = if (@import("builtin").is_test) struct {
    pub fn case0() !void {
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

    pub fn case1() !void {
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
        };
        loop.timers.items[1] = .{
            .id = 11,
            .callback = core.JSValue.int32(2),
            .timeout_ms = 200,
        };

        const old_bytes = rt.allocation_diagnostics.allocated_bytes;
        const old_allocations = rt.allocation_diagnostics.allocation_count;
        rt.setNativeBytesLimitForTest(old_bytes);
        loop.timers.removeAt(ctx.core, 0);
        rt.setNativeBytesLimitForTest(null);

        try std.testing.expectEqual(@as(usize, 1), loop.timers.items.len);
        try std.testing.expectEqual(@as(usize, 2), loop.timers.capacity);
        try std.testing.expectEqual(@as(i64, 11), loop.timers.items[0].id);
        try std.testing.expectEqual(old_bytes, rt.allocation_diagnostics.allocated_bytes);
        try std.testing.expectEqual(old_allocations, rt.allocation_diagnostics.allocation_count);

        loop.timers.removeAt(ctx.core, 0);
        try std.testing.expectEqual(@as(usize, 0), loop.timers.items.len);
        try std.testing.expectEqual(@as(usize, 0), loop.timers.capacity);
    }

    pub fn case2() !void {
        const rt = try core.JSRuntime.create(std.testing.allocator, .{});
        defer rt.destroy();
        const ctx = try js_context.JSContext.create(rt, .{});
        defer ctx.destroy();

        var loop = EventLoop.init(ctx, .{});
        loop.install();
        defer loop.deinit();

        const timer_symbol = try rt.atoms.newValueSymbol("gc-event-loop-timer-symbol");
        const timer_value = try rt.symbolValue(timer_symbol);
        try loop.enqueueTimer(ctx.core, 1, timer_value, 0);

        _ = try rt.collectForTest();
        try std.testing.expect(rt.atoms.name(timer_symbol) != null);

        loop.clearTimer(ctx.core, 1);

        _ = try rt.collectForTest();
        try std.testing.expect(rt.atoms.name(timer_symbol) == null);
    }

    pub fn case3() !void {
        const rt = try core.JSRuntime.create(std.testing.allocator, .{});
        defer rt.destroy();

        var ctx: js_context.JSContext = undefined;
        try ctx.init(rt, .{});
        defer ctx.deinit();

        var loop = EventLoop.init(&ctx, .{});
        loop.install();
        defer loop.deinit();

        try loop.enqueueTimer(ctx.core, 1, core.JSValue.int32(102), 0);

        const Counter = struct {
            count: usize = 0,

            fn visitValue(context: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void {
                const self: *@This() = @ptrCast(@alignCast(context));
                if (slot.as(.int)) |value| {
                    if (value == 102) self.count += 1;
                }
            }

            fn visitObject(context: *anyopaque, slot: *?*core.Object) core.runtime.RootTraceError!void {
                _ = context;
                _ = slot;
            }
        };
        var counter = Counter{};
        var visitor = core.runtime.RootVisitor{
            .readonly = .observe,
            .context = &counter,
            .visit_value = Counter.visitValue,
            .visit_object = Counter.visitObject,
        };
        try rt.traceActiveRoots(&visitor);

        try std.testing.expectEqual(@as(usize, 1), counter.count);
    }

    pub fn case4() !void {
        const bytecode = zjs.bytecode;

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
        }, &.{try rt.symbolValue(symbol_atom)});

        const callback = core.JSValue.functionBytecode(&fb.header);

        try loop.enqueueTimer(ctx.core, 1, callback, 0);
        const old_threshold = rt.gcThreshold();
        rt.setGCThreshold(0);
        defer rt.setGCThreshold(old_threshold);
        try std.testing.expect(try loop.runNextTimer(ctx.core, null, global));

        try std.testing.expect(rt.atoms.name(symbol_atom) != null);

        _ = try rt.collectForTest();
        try std.testing.expect(rt.atoms.name(symbol_atom) == null);
    }

    pub fn case5() !void {
        const host_root = @import("root.zig");
        try std.testing.expect(!@hasDecl(host_root, "event_loop"));
        try std.testing.expect(!@hasDecl(host_root, "cleanup"));
        try std.testing.expect(!@hasDecl(host_root, "modules"));
        try std.testing.expect(!@hasDecl(host_root, "plugin"));
        try std.testing.expect(!@hasDecl(host_root, "buffer"));
        try std.testing.expect(!@hasDecl(host_root, "Engine"));
        try std.testing.expect(!@hasDecl(host_root, "JSRuntime"));
        try std.testing.expect(!@hasDecl(host_root, "JSContext"));
        try std.testing.expect(!@hasDecl(host_root, "JSValue"));
        try std.testing.expect(!@hasDecl(host_root, "Object"));
        try std.testing.expect(!@hasDecl(host_root, "binding"));
        try std.testing.expect(!@hasDecl(host_root, "ffi"));
    }
} else struct {};
