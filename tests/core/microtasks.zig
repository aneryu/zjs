//! Core integration tests: microtasks.
const std = @import("std");
const zjs = @import("zjs");
const core = zjs.core;

const MicrotaskContractProbe = struct {
    ran: usize = 0,
    reported: usize = 0,
    fail_handler: bool = false,
    reentry_rejected: bool = false,

    fn fail(ctx: *core.JSContext, _: []const core.JSValue) core.JSValue {
        return ctx.throwValue(core.JSValue.int32(73));
    }

    fn succeed(ctx: *core.JSContext, _: []const core.JSValue) core.JSValue {
        const ptr: *@This() = @ptrCast(@alignCast(ctx.runtime.microtasks.userdata.?));
        ptr.ran += 1;
        return core.JSValue.undefinedValue();
    }

    fn report(rt: *core.JSRuntime, value: core.JSValue, data: ?*anyopaque) core.errors.HostError!void {
        const self: *@This() = @ptrCast(@alignCast(data.?));
        self.reported += 1;
        if (value.asNumber().? != 73) return error.SystemError;
        rt.runMicrotasks() catch |err| {
            if (err != error.MicrotaskReentry) return err;
            self.reentry_rejected = true;
        };
        if (self.fail_handler) return error.SystemError;
    }

    fn enqueueSuccess(self: *@This(), ctx: *core.JSContext) !void {
        ctx.runtime.microtasks.userdata = self;
        try ctx.runtime.job_queue.enqueueFunc(ctx, succeed, &.{});
    }
};

test "microtask checkpoint explicit failure preserves tail and handler failure remains visible" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{ .microtask_policy = .explicit });
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    var probe: MicrotaskContractProbe = .{};
    try rt.job_queue.enqueueFunc(ctx.core, MicrotaskContractProbe.fail, &.{});
    try probe.enqueueSuccess(ctx.core);
    try std.testing.expectError(error.JSException, rt.runMicrotasks());
    try std.testing.expectEqual(@as(usize, 0), probe.ran);
    try std.testing.expect(rt.job_queue.hasJobs());
    try std.testing.expectEqual(@as(f64, 73), ctx.takeException().asNumber().?);
    try rt.runMicrotasks();
    try std.testing.expectEqual(@as(usize, 1), probe.ran);

    rt.setMicrotaskExceptionHandler(MicrotaskContractProbe.report, &probe);
    try rt.job_queue.enqueueFunc(ctx.core, MicrotaskContractProbe.fail, &.{});
    try probe.enqueueSuccess(ctx.core);
    try rt.runMicrotasks();
    try std.testing.expectEqual(@as(usize, 2), probe.ran);
    try std.testing.expectEqual(@as(usize, 1), probe.reported);
    try std.testing.expect(probe.reentry_rejected);
    try std.testing.expect(!ctx.hasException());

    probe.fail_handler = true;
    try rt.job_queue.enqueueFunc(ctx.core, MicrotaskContractProbe.fail, &.{});
    try probe.enqueueSuccess(ctx.core);
    try std.testing.expectError(error.SystemError, rt.runMicrotasks());
    try std.testing.expect(rt.job_queue.hasJobs());
    try std.testing.expectEqual(@as(usize, 2), probe.ran);
    try std.testing.expectEqual(@as(f64, 73), ctx.takeException().asNumber().?);
    probe.fail_handler = false;
    try rt.runMicrotasks();
    try std.testing.expectEqual(@as(usize, 3), probe.ran);
}

test "microtask checkpoint explicit and nested scoped policies defer automatic eval drain" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{ .microtask_policy = .explicit });
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    _ = try ctx.eval("globalThis.order = 0; Promise.resolve().then(() => { order = 1; });", .{});
    try std.testing.expectEqual(@as(f64, 0), (try ctx.eval("order", .{})).asNumber().?);
    try rt.runMicrotasks();
    try std.testing.expectEqual(@as(f64, 1), (try ctx.eval("order", .{})).asNumber().?);

    rt.microtasks.policy = .scoped;
    var outer = try rt.enterMicrotaskScope();
    var inner = try rt.enterMicrotaskScope();
    _ = try ctx.eval("Promise.resolve().then(() => { order = 2; });", .{});
    try rt.runMicrotasks();
    try std.testing.expectEqual(@as(f64, 1), (try ctx.eval("order", .{})).asNumber().?);
    try std.testing.expectError(error.InvalidMicrotaskScope, outer.finish());
    try inner.finish();
    try std.testing.expectEqual(@as(f64, 1), (try ctx.eval("order", .{})).asNumber().?);
    try outer.finish();
    try std.testing.expectEqual(@as(f64, 2), (try ctx.eval("order", .{})).asNumber().?);
    try std.testing.expectError(error.InvalidMicrotaskScope, outer.finish());
}

test "microtask checkpoint termination discards old tasks and recovery accepts new ones" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{ .microtask_policy = .explicit });
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    var probe: MicrotaskContractProbe = .{};
    try probe.enqueueSuccess(ctx.core);
    rt.terminateExecution();
    try std.testing.expectError(error.Interrupted, rt.runMicrotasks());
    try std.testing.expect(!rt.job_queue.hasJobs());
    try std.testing.expectEqual(@as(usize, 0), probe.ran);
    try rt.cancelTerminateExecution();
    try probe.enqueueSuccess(ctx.core);
    try rt.runMicrotasks();
    try std.testing.expectEqual(@as(usize, 1), probe.ran);
}

test "microtask checkpoint roots notified exception through precise collection" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{ .microtask_policy = .explicit });
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const Probe = struct {
        observed: bool = false,
        fn fail(context: *core.JSContext, args: []const core.JSValue) core.JSValue {
            return context.throwValue(args[0]);
        }
        fn report(runtime: *core.JSRuntime, value: core.JSValue, raw: ?*anyopaque) core.errors.HostError!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = runtime.collectForTest() catch return error.SystemError;
            const object = core.Object.expect(value) catch return error.SystemError;
            if (!runtime.ownsObject(object)) return error.SystemError;
            self.observed = true;
        }
    };
    var probe: Probe = .{};
    rt.setMicrotaskExceptionHandler(Probe.report, &probe);
    try rt.job_queue.enqueueFunc(ctx.core, Probe.fail, &.{try ctx.createObject()});
    try rt.runMicrotasks();
    try std.testing.expect(probe.observed);
    try std.testing.expect(!ctx.hasException());
}

test "microtask checkpoint nested entry is noop and newly queued tasks run before completion" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{ .microtask_policy = .explicit });
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const Probe = struct {
        order: usize = 0,
        fn first(context: *core.JSContext, _: []const core.JSValue) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(context.runtime.microtasks.userdata.?));
            context.runtime.runMicrotasks() catch return context.throwValue(core.JSValue.int32(-1));
            if (self.order != 0) return context.throwValue(core.JSValue.int32(-2));
            self.order = 1;
            context.runtime.job_queue.enqueueFunc(context, last, &.{}) catch return context.throwValue(core.JSValue.int32(-3));
            return core.JSValue.undefinedValue();
        }
        fn last(context: *core.JSContext, _: []const core.JSValue) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(context.runtime.microtasks.userdata.?));
            if (self.order != 1) return context.throwValue(core.JSValue.int32(-4));
            self.order = 2;
            return core.JSValue.undefinedValue();
        }
    };
    var probe: Probe = .{};
    rt.microtasks.userdata = &probe;
    try rt.job_queue.enqueueFunc(ctx.core, Probe.first, &.{});
    try rt.runMicrotasks();
    try std.testing.expectEqual(@as(usize, 2), probe.order);
    try std.testing.expect(!rt.job_queue.hasJobs());
}

test "microtask checkpoint termination inside a native job discards tail before recovery" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{ .microtask_policy = .explicit });
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const Stop = struct {
        fn run(context: *core.JSContext, _: []const core.JSValue) core.JSValue {
            context.runtime.terminateExecution();
            return core.JSValue.undefinedValue();
        }
    };
    var probe: MicrotaskContractProbe = .{};
    try rt.job_queue.enqueueFunc(ctx.core, Stop.run, &.{});
    try probe.enqueueSuccess(ctx.core);
    try std.testing.expectError(error.Interrupted, rt.runMicrotasks());
    try std.testing.expect(!rt.job_queue.hasJobs());
    try std.testing.expectEqual(@as(usize, 0), probe.ran);
    try rt.cancelTerminateExecution();
    try probe.enqueueSuccess(ctx.core);
    try rt.runMicrotasks();
    try std.testing.expectEqual(@as(usize, 1), probe.ran);
}

test "microtask checkpoint WeakRef kept-alive spans jobs and clears only on completion" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{ .microtask_policy = .explicit });
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const Probe = struct {
        object: ?*core.Object = null,
        observed: bool = false,
        fn keep(context: *core.JSContext, args: []const core.JSValue) core.JSValue {
            const identity = (core.Object.weakIdentityFromValue(context.runtime, args[0]) catch null) orelse return context.throwValue(core.JSValue.int32(-1));
            context.runtime.microtasks.keepAlive(context.runtime.nativeAllocator(), identity, args[0]) catch return context.throwValue(core.JSValue.int32(-1));
            return core.JSValue.undefinedValue();
        }
        fn collect(context: *core.JSContext, _: []const core.JSValue) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(context.runtime.microtasks.userdata.?));
            _ = context.runtime.collectForTest() catch return context.throwValue(core.JSValue.int32(-1));
            self.observed = context.runtime.ownsObject(self.object.?);
            return core.JSValue.undefinedValue();
        }
    };
    var probe: Probe = .{ .object = try core.Object.expect(try ctx.createObject()) };
    rt.microtasks.userdata = &probe;
    try rt.job_queue.enqueueFunc(ctx.core, Probe.keep, &.{probe.object.?.value()});
    try rt.job_queue.enqueueFunc(ctx.core, Probe.collect, &.{});
    try rt.runMicrotasks();
    try std.testing.expect(probe.observed);
    try std.testing.expectEqual(@as(usize, 0), rt.microtasks.weakref_kept_alive.items.len);
    _ = try rt.collectForTest();
    try std.testing.expect(!rt.ownsObject(probe.object.?));
}

test "microtask checkpoint auto drains outermost callFunction and newly enqueued jobs" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const callback = try ctx.eval("globalThis.order = ''; (() => { Promise.resolve().then(() => { order += 'a'; Promise.resolve().then(() => { order += 'b'; }); }); return 42; })", .{});
    const result = try ctx.callFunction(callback, &.{}, .{});
    try std.testing.expectEqual(@as(f64, 42), result.asNumber().?);
    try std.testing.expect(!rt.job_queue.hasJobs());
    const ok = try ctx.eval("order === 'ab'", .{});
    try std.testing.expect(ok.as(.boolean).?);
}

test "microtask policy boundaries preserve OOM classification and ordinary exception continuation" {
    const Dispatch = struct {
        fn run(ctx: *zjs.Context, policy: zjs.MicrotaskPolicy) !void {
            switch (policy) {
                .auto => {
                    _ = try ctx.eval("0", .{});
                },
                .explicit => try ctx.core.runtime.runMicrotasks(),
                .scoped => {
                    var scope = try ctx.core.runtime.enterMicrotaskScope();
                    try scope.finish();
                },
            }
        }
        fn oom(ctx: *core.JSContext, _: []const core.JSValue) core.JSValue {
            const rt = ctx.runtime;
            rt.setNativeBytesLimitForTest(0);
            defer rt.setNativeBytesLimitForTest(null);
            const bytes = rt.nativeAllocator().alloc(u8, 16) catch {
                const result = ctx.throwValue(ctx.preallocated_oom_error.?);
                ctx.markExceptionOutOfMemory();
                return result;
            };
            rt.nativeAllocator().free(bytes);
            return core.JSValue.undefinedValue();
        }
    };
    inline for (.{ zjs.MicrotaskPolicy.auto, .explicit, .scoped }) |policy| {
        const rt = try core.JSRuntime.create(std.testing.allocator, .{ .microtask_policy = policy });
        defer rt.destroy();
        const ctx = try zjs.Context.create(rt, .{});
        defer ctx.destroy();
        var probe: MicrotaskContractProbe = .{};
        rt.setMicrotaskExceptionHandler(MicrotaskContractProbe.report, &probe);
        try rt.job_queue.enqueueFunc(ctx.core, Dispatch.oom, &.{});
        try probe.enqueueSuccess(ctx.core);
        try std.testing.expectError(error.OutOfMemory, Dispatch.run(ctx, policy));
        try std.testing.expectEqual(@as(usize, 0), probe.reported);
        try std.testing.expectEqual(@as(usize, 0), probe.ran);
        try std.testing.expect(rt.job_queue.hasJobs());
        _ = ctx.takeException();
        try Dispatch.run(ctx, policy);
        try std.testing.expectEqual(@as(usize, 1), probe.ran);
        try rt.job_queue.enqueueFunc(ctx.core, MicrotaskContractProbe.fail, &.{});
        try probe.enqueueSuccess(ctx.core);
        try Dispatch.run(ctx, policy);
        try std.testing.expectEqual(@as(usize, 1), probe.reported);
        try std.testing.expectEqual(@as(usize, 2), probe.ran);
    }
}

test "dynamic import job wrapper propagates checkpoint exceptions and handler failures" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{ .microtask_policy = .explicit });
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    var state = zjs.exec.module_graph.DynamicImportState{
        .runtime = rt,
        .output = null,
        .env = .{ .io = std.testing.io, .allocator = std.testing.allocator, .max_source_size = 4096 },
    };
    defer state.deinit();
    var probe: MicrotaskContractProbe = .{};
    try rt.job_queue.enqueueFunc(ctx.core, MicrotaskContractProbe.fail, &.{});
    try probe.enqueueSuccess(ctx.core);
    try std.testing.expectError(error.JSException, state.runJobs(ctx.core));
    try std.testing.expectEqual(@as(usize, 0), probe.ran);
    try std.testing.expectEqual(@as(f64, 73), ctx.takeException().asNumber().?);
    try state.runJobs(ctx.core);
    try std.testing.expectEqual(@as(usize, 1), probe.ran);

    rt.setMicrotaskExceptionHandler(MicrotaskContractProbe.report, &probe);
    try rt.job_queue.enqueueFunc(ctx.core, MicrotaskContractProbe.fail, &.{});
    try probe.enqueueSuccess(ctx.core);
    try state.runJobs(ctx.core);
    try std.testing.expectEqual(@as(usize, 1), probe.reported);
    try std.testing.expectEqual(@as(usize, 2), probe.ran);
    try std.testing.expect(probe.reentry_rejected);

    probe.fail_handler = true;
    try rt.job_queue.enqueueFunc(ctx.core, MicrotaskContractProbe.fail, &.{});
    try probe.enqueueSuccess(ctx.core);
    try std.testing.expectError(error.SystemError, state.runJobs(ctx.core));
    try std.testing.expect(rt.job_queue.hasJobs());
    try std.testing.expectEqual(@as(usize, 2), probe.ran);
    try std.testing.expectEqual(@as(f64, 73), ctx.takeException().asNumber().?);
    probe.fail_handler = false;
    try state.runJobs(ctx.core);
    try std.testing.expectEqual(@as(usize, 3), probe.ran);
}

test "runtime review module scheduler rejects termination and preserves nested checkpoint ordering" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{ .microtask_policy = .explicit });
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    var state = zjs.exec.module_graph.DynamicImportState{
        .runtime = rt,
        .output = null,
        .env = .{ .io = std.testing.io, .allocator = std.testing.allocator, .max_source_size = 4096 },
    };
    defer state.deinit();
    const Probe = struct {
        phase: usize = 0,
        observed: usize = 0,
        fn first(c: *core.JSContext, _: []const core.JSValue) core.JSValue {
            const p: *@This() = @ptrCast(@alignCast(c.runtime.microtasks.userdata.?));
            p.phase = 1;
            c.runtime.runMicrotasks() catch return c.throwValue(core.JSValue.int32(90));
            p.phase = 2;
            return core.JSValue.undefinedValue();
        }
        fn tail(c: *core.JSContext, _: []const core.JSValue) core.JSValue {
            const p: *@This() = @ptrCast(@alignCast(c.runtime.microtasks.userdata.?));
            p.observed = p.phase;
            return core.JSValue.undefinedValue();
        }
    };
    var probe: Probe = .{};
    rt.microtasks.userdata = &probe;
    try rt.job_queue.enqueueFunc(ctx.core, Probe.first, &.{});
    try rt.job_queue.enqueueFunc(ctx.core, Probe.tail, &.{});
    try state.runJobs(ctx.core);
    try std.testing.expectEqual(@as(usize, 2), probe.observed);

    probe.observed = 0;
    try rt.job_queue.enqueueFunc(ctx.core, Probe.tail, &.{});
    var scope = try rt.enterMicrotaskScope();
    try state.runJobs(ctx.core);
    try std.testing.expectEqual(@as(usize, 0), probe.observed);
    try std.testing.expect(rt.job_queue.hasJobs());
    try scope.finish();
    try state.runJobs(ctx.core);
    try std.testing.expectEqual(@as(usize, 2), probe.observed);

    probe.observed = 0;
    try rt.job_queue.enqueueFunc(ctx.core, Probe.tail, &.{});
    rt.terminateExecution();
    try std.testing.expectError(error.Interrupted, state.runJobs(ctx.core));
    try std.testing.expectEqual(@as(usize, 0), probe.observed);
    try std.testing.expect(!rt.job_queue.hasJobs());
    try rt.cancelTerminateExecution();
}

test "runtime review handler installed OOM keeps its failure classification" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{ .microtask_policy = .explicit });
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const Handler = struct {
        fn report(r: *core.JSRuntime, _: core.JSValue, _: ?*anyopaque) core.errors.HostError!void {
            r.exception.install(core.JSValue.int32(99));
            r.exception.out_of_memory = true;
        }
    };
    rt.setMicrotaskExceptionHandler(Handler.report, null);
    try rt.job_queue.enqueueFunc(ctx.core, MicrotaskContractProbe.fail, &.{});
    try std.testing.expectError(error.OutOfMemory, rt.runMicrotasks());
    try std.testing.expectEqual(@as(f64, 99), ctx.takeException().asNumber().?);
}
