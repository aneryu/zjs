//! Test262 host hooks and the `$262.agent` coordinator.
//!
//! Keep the runner-facing interface limited to global installation, agent
//! cleanup, and the assertion helper reused by engine integration tests.

const std = @import("std");
const test262_root = @import("zjs");

const zjs = test262_root.binding_root;
const runtime_layer = test262_root.runtime;

pub fn assertSameValue(actual: zjs.JSValue, expected: zjs.JSValue) !zjs.JSValue {
    if (!actual.sameValue(expected)) return error.JSException;
    return zjs.JSValue.undefinedValue();
}

fn test262EvalScript(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: *zjs.Object,
    function_object: *zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    if (args.len == 0) return zjs.JSValue.undefinedValue();
    if (!args[0].isString()) return error.TypeError;
    const eval_global = (try ctx.functionRealmGlobal(function_object.value())) orelse global;
    return ctx.evalScriptValue(args[0], .{
        .output = output,
        .realm_global = eval_global,
        .filename = "<evalScript>",
    });
}

const Test262Agent = struct {
    source: []u8,
    owner_runtime: *zjs.JSRuntime,
    agent_runtime: ?*zjs.JSRuntime = null,
    broadcast_buffer: ?zjs.SharedArrayBufferRef = null,
    done: bool = false,
    thread_done: bool = false,
};

const Test262AgentReportEntry = struct {
    owner_runtime: *zjs.JSRuntime,
    bytes: []u8,
};

const Test262AgentCoordinator = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    agents: []*Test262Agent = &.{},
    agents_capacity: usize = 0,
    reports: []Test262AgentReportEntry = &.{},
    reports_capacity: usize = 0,
};

var test262_agents = Test262AgentCoordinator{};
threadlocal var current_test262_agent: ?*Test262Agent = null;
var test262_external_host_context: u8 = 0;

var test262_gpa = std.heap.DebugAllocator(.{
    .safety = false,
    .stack_trace_frames = 0,
    .thread_safe = true,
    .retain_metadata = true,
}){};

fn test262PageAllocator() std.mem.Allocator {
    return test262_gpa.allocator();
}

fn test262AgentIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn test262AgentAppend(agent: *Test262Agent) !void {
    const io = test262AgentIo();
    test262_agents.mutex.lockUncancelable(io);
    defer test262_agents.mutex.unlock(io);
    _ = test262AgentSweepCompletedLocked(agent.owner_runtime);
    try test262AgentEnsureAgentCapacityLocked(test262_agents.agents.len + 1);
    test262_agents.agents = test262_agents.agents.ptr[0 .. test262_agents.agents.len + 1];
    test262_agents.agents[test262_agents.agents.len - 1] = agent;
}

fn test262AgentEnqueueReport(owner_runtime: *zjs.JSRuntime, bytes: []u8) !void {
    const io = test262AgentIo();
    test262_agents.mutex.lockUncancelable(io);
    defer test262_agents.mutex.unlock(io);
    try test262AgentEnsureReportCapacityLocked(test262_agents.reports.len + 1);
    test262_agents.reports = test262_agents.reports.ptr[0 .. test262_agents.reports.len + 1];
    test262_agents.reports[test262_agents.reports.len - 1] = .{ .owner_runtime = owner_runtime, .bytes = bytes };
    test262_agents.cond.broadcast(io);
}

fn test262AgentDestroy(agent: *Test262Agent) void {
    const allocator = test262PageAllocator();
    allocator.free(agent.source);
    if (agent.broadcast_buffer) |*buffer| {
        buffer.release();
        agent.broadcast_buffer = null;
    }
    allocator.destroy(agent);
}

fn test262AgentEnsureAgentCapacityLocked(min_capacity: usize) !void {
    if (test262_agents.agents_capacity >= min_capacity) return;
    const allocator = test262PageAllocator();
    var next_capacity = if (test262_agents.agents_capacity == 0) @as(usize, 4) else test262_agents.agents_capacity * 2;
    while (next_capacity < min_capacity) : (next_capacity *= 2) {}
    const next = try allocator.alloc(*Test262Agent, next_capacity);
    @memcpy(next[0..test262_agents.agents.len], test262_agents.agents);
    if (test262_agents.agents_capacity != 0) allocator.free(test262_agents.agents.ptr[0..test262_agents.agents_capacity]);
    test262_agents.agents = next[0..test262_agents.agents.len];
    test262_agents.agents_capacity = next_capacity;
}

fn test262AgentEnsureReportCapacityLocked(min_capacity: usize) !void {
    if (test262_agents.reports_capacity >= min_capacity) return;
    const allocator = test262PageAllocator();
    var next_capacity = if (test262_agents.reports_capacity == 0) @as(usize, 4) else test262_agents.reports_capacity * 2;
    while (next_capacity < min_capacity) : (next_capacity *= 2) {}
    const next = try allocator.alloc(Test262AgentReportEntry, next_capacity);
    @memcpy(next[0..test262_agents.reports.len], test262_agents.reports);
    if (test262_agents.reports_capacity != 0) allocator.free(test262_agents.reports.ptr[0..test262_agents.reports_capacity]);
    test262_agents.reports = next[0..test262_agents.reports.len];
    test262_agents.reports_capacity = next_capacity;
}

fn test262AgentRemoveAtLocked(index: usize) void {
    std.debug.assert(index < test262_agents.agents.len);
    const agent = test262_agents.agents[index];
    const old_len = test262_agents.agents.len;
    if (index + 1 < old_len) {
        @memmove(test262_agents.agents[index .. old_len - 1], test262_agents.agents[index + 1 .. old_len]);
    }
    test262_agents.agents = test262_agents.agents.ptr[0 .. old_len - 1];
    if (test262_agents.agents.len == 0 and test262_agents.agents_capacity != 0) {
        const allocator = test262PageAllocator();
        allocator.free(test262_agents.agents.ptr[0..test262_agents.agents_capacity]);
        test262_agents.agents = &.{};
        test262_agents.agents_capacity = 0;
    }
    test262AgentDestroy(agent);
}

fn test262AgentRemove(agent: *Test262Agent) void {
    const io = test262AgentIo();
    test262_agents.mutex.lockUncancelable(io);
    defer test262_agents.mutex.unlock(io);
    var index: usize = 0;
    while (index < test262_agents.agents.len) : (index += 1) {
        if (test262_agents.agents[index] != agent) continue;
        test262AgentRemoveAtLocked(index);
        return;
    }
}

fn test262AgentSweepCompletedLocked(rt: *zjs.JSRuntime) usize {
    var removed: usize = 0;
    var index: usize = 0;
    while (index < test262_agents.agents.len) {
        const agent = test262_agents.agents[index];
        if (agent.owner_runtime != rt) {
            index += 1;
            continue;
        }
        if (!agent.thread_done) {
            index += 1;
            continue;
        }
        test262AgentRemoveAtLocked(index);
        removed += 1;
    }
    return removed;
}

fn test262AgentTakeReportLocked(rt: *zjs.JSRuntime) ?[]u8 {
    for (test262_agents.reports, 0..) |entry, index| {
        if (entry.owner_runtime == rt) {
            const report = entry.bytes;
            const old_len = test262_agents.reports.len;
            if (old_len == 1) {
                const allocator = test262PageAllocator();
                allocator.free(test262_agents.reports.ptr[0..test262_agents.reports_capacity]);
                test262_agents.reports = &.{};
                test262_agents.reports_capacity = 0;
                return report;
            }
            if (index + 1 < old_len) {
                @memmove(test262_agents.reports[index .. old_len - 1], test262_agents.reports[index + 1 .. old_len]);
            }
            test262_agents.reports = test262_agents.reports.ptr[0 .. old_len - 1];
            return report;
        }
    }
    return null;
}

fn test262AgentSweepReportsLocked(rt: *zjs.JSRuntime) void {
    const allocator = test262PageAllocator();
    var index: usize = 0;
    while (index < test262_agents.reports.len) {
        const entry = test262_agents.reports[index];
        if (entry.owner_runtime == rt) {
            allocator.free(entry.bytes);
            const old_len = test262_agents.reports.len;
            if (old_len == 1) {
                allocator.free(test262_agents.reports.ptr[0..test262_agents.reports_capacity]);
                test262_agents.reports = &.{};
                test262_agents.reports_capacity = 0;
                break;
            }
            if (index + 1 < old_len) {
                @memmove(test262_agents.reports[index .. old_len - 1], test262_agents.reports[index + 1 .. old_len]);
            }
            test262_agents.reports = test262_agents.reports.ptr[0 .. old_len - 1];
        } else {
            index += 1;
        }
    }
}

pub fn cleanupTest262Agents(rt: *zjs.JSRuntime) usize {
    const io = test262AgentIo();

    var agent_runtimes_buf: [16]*zjs.JSRuntime = undefined;
    var agent_runtimes_count: usize = 0;

    test262_agents.mutex.lockUncancelable(io);
    for (test262_agents.agents) |agent| {
        if (agent.owner_runtime == rt) {
            agent.done = true;
            if (agent.agent_runtime) |art| {
                if (agent_runtimes_count < agent_runtimes_buf.len) {
                    agent_runtimes_buf[agent_runtimes_count] = art;
                    agent_runtimes_count += 1;
                }
            }
        }
    }
    test262_agents.cond.broadcast(io);
    test262_agents.mutex.unlock(io);

    runtime_layer.wakeAtomicsWaitersForRuntimes(rt, agent_runtimes_buf[0..agent_runtimes_count]);

    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        test262_agents.mutex.lockUncancelable(io);
        var all_done = true;
        for (test262_agents.agents) |agent| {
            if (agent.owner_runtime == rt and !agent.thread_done) {
                all_done = false;
                break;
            }
        }
        test262_agents.mutex.unlock(io);
        if (all_done) break;
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }

    test262_agents.mutex.lockUncancelable(io);
    defer test262_agents.mutex.unlock(io);
    test262AgentSweepReportsLocked(rt);
    return test262AgentSweepCompletedLocked(rt);
}

fn test262AgentInterruptHandler(rt: *zjs.JSRuntime, context: ?*anyopaque) bool {
    _ = rt;
    const agent: *Test262Agent = @ptrCast(@alignCast(context orelse return false));
    return agent.done;
}

fn test262AgentRun(agent: *Test262Agent) void {
    current_test262_agent = agent;
    defer current_test262_agent = null;
    defer {
        const io = test262AgentIo();
        test262_agents.mutex.lockUncancelable(io);
        agent.done = true;
        agent.thread_done = true;
        if (agent.broadcast_buffer) |*buffer| {
            buffer.release();
            agent.broadcast_buffer = null;
        }
        test262_agents.cond.broadcast(io);
        test262_agents.mutex.unlock(io);
    }

    const allocator = test262PageAllocator();
    const rt = zjs.JSRuntime.create(allocator) catch return;
    defer rt.destroy();
    rt.setCanBlock(true);
    rt.setInterruptHandler(test262AgentInterruptHandler, agent);

    {
        const io = test262AgentIo();
        test262_agents.mutex.lockUncancelable(io);
        agent.agent_runtime = rt;
        test262_agents.mutex.unlock(io);
    }

    const ctx = zjs.JSContext.create(rt) catch return;
    defer ctx.destroy();
    var event_loop = runtime_layer.EventLoop.init(ctx, .{});
    event_loop.install();
    defer event_loop.deinit();
    defer runtime_layer.cleanupAtomicsWaitersForContext(ctx);
    const global = ctx.globalObject() catch return;
    installTest262Globals(rt, ctx, global) catch return;
    const result = ctx.eval(agent.source, .{
        .mode = .script,
        .filename = "<test262-agent>",
        .discard_script_result = true,
    }) catch return;
    result.free(rt);
    ctx.runJobs(null) catch {};
    while (!test262AgentIsDone(agent)) {
        std.Io.sleep(test262AgentIo(), std.Io.Duration.fromMilliseconds(1), .awake) catch {};
        ctx.runJobs(null) catch return;
    }
}

fn test262AgentIsDone(agent: *Test262Agent) bool {
    const io = test262AgentIo();
    test262_agents.mutex.lockUncancelable(io);
    defer test262_agents.mutex.unlock(io);
    return agent.done;
}

fn test262AgentStart(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    if (args.len == 0) return error.TypeError;
    const source = try test262AgentStringValue(ctx, args[0]);
    var source_owned = true;
    errdefer if (source_owned) test262PageAllocator().free(source);
    const agent = try test262PageAllocator().create(Test262Agent);
    agent.* = .{ .source = source, .owner_runtime = ctx.runtimePtr() };
    source_owned = false;
    var agent_owned = true;
    var agent_registered = false;
    errdefer if (agent_registered) {
        test262AgentRemove(agent);
    } else if (agent_owned) {
        test262AgentDestroy(agent);
    };
    try test262AgentAppend(agent);
    agent_registered = true;
    const thread = try std.Thread.spawn(.{}, test262AgentRun, .{agent});
    thread.detach();
    agent_owned = false;
    agent_registered = false;
    return zjs.JSValue.undefinedValue();
}

fn test262AgentBroadcast(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    if (args.len == 0) return error.TypeError;
    var shared_buffer = try ctx.retainSharedArrayBuffer(args[0]);
    defer shared_buffer.release();
    const io = test262AgentIo();
    test262_agents.mutex.lockUncancelable(io);
    defer test262_agents.mutex.unlock(io);
    _ = test262AgentSweepCompletedLocked(ctx.runtimePtr());
    for (test262_agents.agents) |agent| {
        if (agent.owner_runtime != ctx.runtimePtr()) continue;
        if (agent.done) continue;
        if (agent.broadcast_buffer) |*old| old.release();
        agent.broadcast_buffer = shared_buffer.retain();
    }
    test262_agents.cond.broadcast(io);
    return zjs.JSValue.undefinedValue();
}

fn test262AgentReceiveBroadcast(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    const agent = current_test262_agent orelse return error.TypeError;
    if (args.len == 0 or !ctx.isCallable(args[0])) return error.TypeError;

    const io = test262AgentIo();
    test262_agents.mutex.lockUncancelable(io);
    while (agent.broadcast_buffer == null and !agent.done) {
        test262_agents.cond.waitUncancelable(io, &test262_agents.mutex);
    }
    var shared_buffer = agent.broadcast_buffer orelse {
        test262_agents.mutex.unlock(io);
        return zjs.JSValue.undefinedValue();
    };
    agent.broadcast_buffer = null;
    test262_agents.mutex.unlock(io);
    defer shared_buffer.release();

    const sab = try ctx.sharedArrayBufferFromRef(shared_buffer);
    defer sab.free(ctx.runtimePtr());
    const callback_result = try ctx.callFunction(args[0], &.{sab}, .{
        .output = output,
        .realm_global = global,
    });
    callback_result.free(ctx.runtimePtr());
    return zjs.JSValue.undefinedValue();
}

fn test262AgentReport(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    const value = if (args.len >= 1) args[0] else zjs.JSValue.undefinedValue();
    const bytes = try test262AgentStringValue(ctx, value);
    errdefer test262PageAllocator().free(bytes);
    const owner_runtime = if (current_test262_agent) |agent| agent.owner_runtime else ctx.runtimePtr();
    try test262AgentEnqueueReport(owner_runtime, bytes);
    return zjs.JSValue.undefinedValue();
}

fn test262AgentGetReport(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    _ = args;
    const allocator = test262PageAllocator();
    const io = test262AgentIo();
    test262_agents.mutex.lockUncancelable(io);
    _ = test262AgentSweepCompletedLocked(ctx.runtimePtr());
    const report = test262AgentTakeReportLocked(ctx.runtimePtr()) orelse {
        test262_agents.mutex.unlock(io);
        return zjs.JSValue.nullValue();
    };
    test262_agents.mutex.unlock(io);
    defer allocator.free(report);
    return ctx.createString(report);
}

fn test262AgentLeaving(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = ctx;
    _ = output;
    _ = global;
    _ = args;
    if (current_test262_agent) |agent| {
        const io = test262AgentIo();
        test262_agents.mutex.lockUncancelable(io);
        agent.done = true;
        test262_agents.cond.broadcast(io);
        test262_agents.mutex.unlock(io);
    }
    return zjs.JSValue.undefinedValue();
}

fn test262AgentSleep(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    const value = if (args.len >= 1) args[0] else zjs.JSValue.int32(0);
    const number = value.asNumber() orelse 0;
    if (number > 0) {
        const ms: i64 = @intFromFloat(@min(number, 60_000));
        std.Io.sleep(test262AgentIo(), std.Io.Duration.fromMilliseconds(ms), .awake) catch {};
    }
    _ = ctx;
    return zjs.JSValue.undefinedValue();
}

fn test262AgentMonotonicNow(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = ctx;
    _ = output;
    _ = global;
    _ = args;
    const now = std.Io.Timestamp.now(test262AgentIo(), .awake);
    return zjs.JSValue.float64(@as(f64, @floatFromInt(now.nanoseconds)) / std.time.ns_per_ms);
}

pub fn installTest262Globals(rt: *zjs.JSRuntime, ctx: *zjs.JSContext, global: *zjs.Object) !void {
    try defineGlobalExternalHostFunction(rt, ctx, global, "Test262Error", 1, wrapExternal(hostCallTest262Error), true);
    try defineGlobalExternalHostFunction(rt, ctx, global, "verifyProperty", 3, wrapExternal(hostCallVerifyProperty), false);
    try defineGlobalExternalHostFunction(rt, ctx, global, "verifyCallableProperty", 4, wrapExternal(hostCallVerifyCallableProperty), false);
    try defineGlobalExternalHostFunction(rt, ctx, global, "verifyNotWritable", 2, wrapExternal(hostCallVerifyNotWritable), false);
    try defineGlobalExternalHostFunction(rt, ctx, global, "verifyNotEnumerable", 2, wrapExternal(hostCallVerifyNotEnumerable), false);
    try defineGlobalExternalHostFunction(rt, ctx, global, "verifyConfigurable", 2, wrapExternal(hostCallVerifyConfigurable), false);
    try defineGlobalExternalHostFunction(rt, ctx, global, "isConstructor", 1, wrapExternal(hostCallIsConstructor), false);
    try defineGlobalExternalHostFunction(rt, ctx, global, "setTimeout", 2, wrapExternal(hostCallSetTimeout), false);
    try installAssertObject(rt, ctx, global);

    const ns_val = try ctx.getProperty(global.value(), "$262");
    defer ns_val.free(rt);

    var created_ns = false;
    const ns_target = if (ns_val.isObject()) ns_val else result: {
        const obj_val = try ctx.createObject();
        try ctx.defineDataProperty(global.value(), "$262", obj_val, .{ .enumerable = true });
        created_ns = true;
        break :result obj_val;
    };
    defer if (created_ns) ns_target.free(rt);

    const agent_val = try ctx.createObject();
    defer agent_val.free(rt);

    const agent_methods = [_]struct {
        name: []const u8,
        length: i32,
        call: zjs.ExternalHostCallFn,
    }{
        .{ .name = "start", .length = 1, .call = wrapExternal(test262AgentStart) },
        .{ .name = "broadcast", .length = 1, .call = wrapExternal(test262AgentBroadcast) },
        .{ .name = "receiveBroadcast", .length = 0, .call = wrapExternal(test262AgentReceiveBroadcast) },
        .{ .name = "report", .length = 1, .call = wrapExternal(test262AgentReport) },
        .{ .name = "getReport", .length = 0, .call = wrapExternal(test262AgentGetReport) },
        .{ .name = "leaving", .length = 0, .call = wrapExternal(test262AgentLeaving) },
        .{ .name = "sleep", .length = 1, .call = wrapExternal(test262AgentSleep) },
        .{ .name = "monotonicNow", .length = 0, .call = wrapExternal(test262AgentMonotonicNow) },
    };

    inline for (agent_methods) |m| {
        const func_val = try createExternalHostFunction(rt, ctx, m.name, m.length, m.call);
        defer func_val.free(rt);
        try ctx.defineDataProperty(agent_val, m.name, func_val, .{ .enumerable = false });
    }

    try ctx.defineDataProperty(ns_target, "agent", agent_val, .{ .enumerable = false });

    // Register evalScript on $262
    {
        const func_val = try createExternalHostFunction(rt, ctx, "evalScript", 1, wrapExternalWithFunc(test262EvalScript));
        defer func_val.free(rt);
        try ctx.defineDataProperty(ns_target, "evalScript", func_val, .{ .enumerable = false });
    }

    // Register IsHTMLDDA on $262
    {
        const func_val = try createExternalHostFunction(rt, ctx, "IsHTMLDDA", 0, wrapExternal(hostCallIsHtmlDda));
        defer func_val.free(rt);
        const is_html_dda_obj = test262InternalObjectFromValue(func_val).?;
        is_html_dda_obj.flags.is_html_dda = true;

        try ctx.defineDataProperty(ns_target, "IsHTMLDDA", func_val, .{ .enumerable = false });
    }

    // Register createRealm on $262
    {
        const func_val = try createExternalHostFunction(rt, ctx, "createRealm", 0, wrapExternal(test262CreateRealm));
        defer func_val.free(rt);
        try ctx.defineDataProperty(ns_target, "createRealm", func_val, .{ .enumerable = false });
    }

    // Register detachArrayBuffer on $262
    {
        const func_val = try createExternalHostFunction(rt, ctx, "detachArrayBuffer", 1, wrapExternal(test262DetachArrayBuffer));
        defer func_val.free(rt);
        try ctx.defineDataProperty(ns_target, "detachArrayBuffer", func_val, .{ .enumerable = false });
    }

    // Register gc on $262
    {
        const func_val = try createExternalHostFunction(rt, ctx, "gc", 0, wrapExternal(test262Gc));
        defer func_val.free(rt);
        try ctx.defineDataProperty(ns_target, "gc", func_val, .{ .enumerable = false });
    }
}

fn installAssertObject(rt: *zjs.JSRuntime, ctx: *zjs.JSContext, global: *zjs.Object) !void {
    const assert_val = try createExternalHostFunction(rt, ctx, "assert", 1, wrapExternal(hostCallAssertTrue));
    defer assert_val.free(rt);
    const methods = [_]struct {
        name: []const u8,
        length: i32,
        call: zjs.ExternalHostCallFn,
    }{
        .{ .name = "sameValue", .length = 2, .call = wrapExternal(hostCallAssertSameValue) },
        .{ .name = "notSameValue", .length = 2, .call = wrapExternal(hostCallAssertNotSameValue) },
        .{ .name = "compareArray", .length = 2, .call = wrapExternal(hostCallCompareArray) },
        .{ .name = "throws", .length = 2, .call = wrapExternal(hostCallAssertThrows) },
    };
    inline for (methods) |method| {
        const method_val = try createExternalHostFunction(rt, ctx, method.name, method.length, method.call);
        defer method_val.free(rt);
        try ctx.defineDataProperty(assert_val, method.name, method_val, .{});
    }
    try ctx.defineDataProperty(global.value(), "assert", assert_val, .{});
}

fn defineGlobalExternalHostFunction(
    rt: *zjs.JSRuntime,
    ctx: *zjs.JSContext,
    global: *zjs.Object,
    name: []const u8,
    length: i32,
    call: zjs.ExternalHostCallFn,
    with_prototype: bool,
) !void {
    const func_val = try createExternalHostFunctionWithRealm(rt, ctx, name, length, call, with_prototype, global);
    defer func_val.free(rt);
    try ctx.defineDataProperty(global.value(), name, func_val, .{});
}

fn hostCallTest262Error(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    const message = if (args.len > 0) try stringBytes(ctx, args[0]) else "";
    defer if (args.len > 0) ctx.runtimePtr().memory.allocator.free(message);
    return createTest262ErrorValue(ctx, global, message);
}

fn hostCallAssertSameValue(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = ctx;
    _ = output;
    _ = global;
    return assertSameValueArgs(args);
}

fn hostCallAssertTrue(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = ctx;
    _ = output;
    _ = global;
    if (args.len < 1 or args[0].asBool() != true) return error.JSException;
    return zjs.JSValue.undefinedValue();
}

fn hostCallAssertNotSameValue(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = ctx;
    _ = output;
    _ = global;
    if (args.len < 2) return error.TypeError;
    if (args[0].sameValue(args[1])) return error.JSException;
    return zjs.JSValue.undefinedValue();
}

fn hostCallAssertThrows(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    if (args.len < 2) return error.TypeError;
    const expected_name = try ctx.functionName(args[0], ctx.runtimePtr().memory.allocator);
    defer ctx.runtimePtr().memory.allocator.free(expected_name);
    const result = ctx.callFunction(args[1], &.{}, .{
        .output = output,
        .realm_global = global,
    }) catch |err| {
        if (err == error.JSException and ctx.hasException()) {
            if (try ctx.consumePendingExceptionIfErrorName(expected_name)) {
                return zjs.JSValue.undefinedValue();
            }
            return error.JSException;
        }
        if (ctx.runtimeErrorMatchesErrorName(err, expected_name)) {
            ctx.clearException();
            return zjs.JSValue.undefinedValue();
        }
        return error.JSException;
    };
    defer result.free(ctx.runtimePtr());
    return error.JSException;
}

fn hostCallVerifyProperty(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    return hostVerifyProperty(ctx, args, false);
}

fn hostCallVerifyCallableProperty(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    return hostVerifyProperty(ctx, args, true);
}

fn hostCallIsConstructor(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    if (args.len < 1) return error.TypeError;
    return zjs.JSValue.boolean(ctx.isConstructor(args[0]));
}

fn hostCallVerifyNotWritable(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    return hostVerifyPropertyFlag(ctx, args, .not_writable);
}

fn hostCallVerifyNotEnumerable(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    return hostVerifyPropertyFlag(ctx, args, .not_enumerable);
}

fn hostCallVerifyConfigurable(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    return hostVerifyPropertyFlag(ctx, args, .configurable);
}

fn hostCallCompareArray(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    if (args.len < 2) return error.TypeError;
    if (!try ctx.isArray(args[0]) or !try ctx.isArray(args[1])) return error.JSException;
    const actual_length = try ctx.arrayLength(args[0]);
    if (actual_length != try ctx.arrayLength(args[1])) return error.JSException;
    var index: u32 = 0;
    while (index < actual_length) : (index += 1) {
        const lhs = try ctx.getIndex(args[0], index);
        defer lhs.free(ctx.runtimePtr());
        const rhs = try ctx.getIndex(args[1], index);
        defer rhs.free(ctx.runtimePtr());
        if (!lhs.sameValue(rhs)) return error.JSException;
    }
    return zjs.JSValue.undefinedValue();
}

fn hostCallSetTimeout(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    const active_global = global orelse try ctx.globalObject();
    const callback = if (args.len >= 1) args[0] else zjs.JSValue.undefinedValue();
    if (!ctx.isCallable(callback)) return try ctx.throwError("TypeError", "not a function", .{ .realm_global = active_global });
    var delay = try test262Int64Arg(ctx, args, 1);
    if (delay < 1) delay = 1;
    const host_event_loop = ctx.hostEventLoop() orelse return error.TypeError;
    const id = host_event_loop.nextTimerId();
    try host_event_loop.enqueueTimer(ctx.core, id, callback, @intCast(delay), false);
    return int64ResultValue(id);
}

fn assertSameValueArgs(values: []const zjs.JSValue) !zjs.JSValue {
    if (values.len < 2) return error.TypeError;
    if (!values[0].sameValue(values[1])) return error.JSException;
    return zjs.JSValue.undefinedValue();
}

fn hostVerifyProperty(ctx: *zjs.JSContext, values: []const zjs.JSValue, callable: bool) !zjs.JSValue {
    const rt = ctx.runtimePtr();
    const desc_index: usize = if (callable) 4 else 2;
    if ((!callable and values.len <= desc_index) or (callable and values.len < 4)) return error.TypeError;

    var original = (try ctx.ownPropertyDescriptor(values[0], values[1], .{})) orelse {
        if (values[desc_index].isUndefined()) return zjs.JSValue.boolean(true);
        return error.JSException;
    };
    defer original.destroy(rt);

    if (callable) {
        const actual = try ctx.getPropertyKey(values[0], values[1], .{});
        defer actual.free(rt);
        if (!ctx.isCallable(actual)) return error.JSException;
        const expected_name = try stringBytes(ctx, values[2]);
        defer rt.memory.allocator.free(expected_name);
        const actual_name = try ctx.functionName(actual, rt.memory.allocator);
        defer rt.memory.allocator.free(actual_name);
        if (!std.mem.eql(u8, expected_name, actual_name)) return error.JSException;
        const expected_length = values[3].asInt32() orelse return error.JSException;
        const length_value = try ctx.getProperty(actual, "length");
        defer length_value.free(rt);
        if (length_value.asInt32() != expected_length) return error.JSException;
        if (values.len <= desc_index or values[desc_index].isUndefined()) return zjs.JSValue.boolean(true);
    }

    try verifyDescriptorObject(ctx, original, values[desc_index]);
    return zjs.JSValue.boolean(true);
}

const VerifyFlag = enum {
    not_writable,
    not_enumerable,
    configurable,
};

fn hostVerifyPropertyFlag(ctx: *zjs.JSContext, values: []const zjs.JSValue, flag: VerifyFlag) !zjs.JSValue {
    const rt = ctx.runtimePtr();
    if (values.len < 2) return error.TypeError;
    const desc = (try ctx.ownPropertyDescriptor(values[0], values[1], .{})) orelse return error.JSException;
    defer desc.destroy(rt);
    switch (flag) {
        .not_writable => if (desc.kind == .data and (desc.writable orelse false)) return error.JSException,
        .not_enumerable => if (desc.enumerable orelse false) return error.JSException,
        .configurable => if (!(desc.configurable orelse false)) return error.JSException,
    }
    return zjs.JSValue.undefinedValue();
}

fn verifyDescriptorObject(ctx: *zjs.JSContext, actual: zjs.PropertyDescriptor, expected: zjs.JSValue) !void {
    const rt = ctx.runtimePtr();
    if (try expectedHas(ctx, expected, "value")) {
        const expected_value = try expectedValue(ctx, expected, "value");
        defer expected_value.free(rt);
        if (!actual.value.sameValue(expected_value)) return error.JSException;
    }
    if (try expectedHas(ctx, expected, "writable")) {
        const writable_value = try expectedValue(ctx, expected, "writable");
        defer writable_value.free(rt);
        const expected_writable = writable_value.asBool() orelse return error.JSException;
        if (actual.writable != expected_writable) return error.JSException;
    }
    if (try expectedHas(ctx, expected, "enumerable")) {
        const enumerable_value = try expectedValue(ctx, expected, "enumerable");
        defer enumerable_value.free(rt);
        const expected_enumerable = enumerable_value.asBool() orelse return error.JSException;
        if (actual.enumerable != expected_enumerable) return error.JSException;
    }
    if (try expectedHas(ctx, expected, "configurable")) {
        const configurable_value = try expectedValue(ctx, expected, "configurable");
        defer configurable_value.free(rt);
        const expected_configurable = configurable_value.asBool() orelse return error.JSException;
        if (actual.configurable != expected_configurable) return error.JSException;
    }
    if (try expectedHas(ctx, expected, "get")) {
        const expected_getter = try expectedValue(ctx, expected, "get");
        defer expected_getter.free(rt);
        if (!actual.getter.sameValue(expected_getter)) return error.JSException;
    }
    if (try expectedHas(ctx, expected, "set")) {
        const expected_setter = try expectedValue(ctx, expected, "set");
        defer expected_setter.free(rt);
        if (!actual.setter.sameValue(expected_setter)) return error.JSException;
    }
}

fn expectedHas(ctx: *zjs.JSContext, object: zjs.JSValue, name: []const u8) !bool {
    return ctx.hasOwnProperty(object, name);
}

fn expectedValue(ctx: *zjs.JSContext, object: zjs.JSValue, name: []const u8) !zjs.JSValue {
    return try ctx.getProperty(object, name);
}

fn stringBytes(ctx: *zjs.JSContext, value: zjs.JSValue) ![]u8 {
    const string = value.asString() orelse return error.TypeError;
    return string.toOwnedUtf8(ctx.runtimePtr().memory.allocator);
}

fn test262Int64Arg(ctx: *zjs.JSContext, args: []const zjs.JSValue, index: usize) !i64 {
    const value = if (index < args.len) args[index] else zjs.JSValue.undefinedValue();
    const number = try ctx.toIntegerOrInfinity(value);
    if (!std.math.isFinite(number) or std.math.isNan(number)) return 0;
    return @intFromFloat(number);
}

fn int64ResultValue(value: i64) zjs.JSValue {
    return zjs.JSValue.number(@floatFromInt(value));
}

fn test262InternalObjectFromValue(value: zjs.JSValue) ?*zjs.Object {
    const header = value.refHeader() orelse return null;
    if (header.meta().flags.kind != .object) return null;
    return zjs.Object.fromHeader(header);
}

fn hostCallIsHtmlDda(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = ctx;
    _ = output;
    _ = global;
    _ = args;
    return zjs.JSValue.nullValue();
}

fn test262CreateRealm(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    _ = args;
    const realm_value = try ctx.createRealm();
    errdefer realm_value.free(ctx.runtimePtr());
    const realm_global = try ctx.realmGlobalObject(realm_value);
    const eval_func = try createExternalHostFunctionWithRealm(ctx.runtimePtr(), ctx, "evalScript", 1, wrapExternalWithFunc(test262EvalScript), false, realm_global);
    defer eval_func.free(ctx.runtimePtr());
    try ctx.defineDataProperty(realm_value, "evalScript", eval_func, .{});
    return realm_value;
}

fn test262DetachArrayBuffer(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    if (args.len < 1) return error.TypeError;
    return try runtime_layer.detachArrayBuffer(ctx.core, args[0]);
}

fn test262Gc(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    _ = args;
    _ = ctx.runtimePtr().runObjectCycleRemoval();
    return zjs.JSValue.undefinedValue();
}

fn wrapExternal(comptime f: anytype) zjs.ExternalHostCallFn {
    return struct {
        fn call(ptr: *anyopaque, c: zjs.ExternalHostCall) anyerror!zjs.JSValue {
            _ = ptr;
            var ctx = zjs.JSContext.borrowCore(c.realm);
            const global = c.realm.global;
            return f(&ctx, c.output, global, c.args) catch |err| {
                try ensureTest262HarnessException(&ctx, global, err);
                return err;
            };
        }
    }.call;
}

fn wrapExternalWithFunc(comptime f: anytype) zjs.ExternalHostCallFn {
    return struct {
        fn call(ptr: *anyopaque, c: zjs.ExternalHostCall) anyerror!zjs.JSValue {
            _ = ptr;
            var ctx = zjs.JSContext.borrowCore(c.realm);
            const global = c.realm.global orelse return error.TypeError;
            return f(&ctx, c.output, global, c.func_obj, c.args) catch |err| {
                try ensureTest262HarnessException(&ctx, global, err);
                return err;
            };
        }
    }.call;
}

fn ensureTest262HarnessException(ctx: *zjs.JSContext, global: ?*zjs.Object, err: anyerror) !void {
    if (err != error.JSException or ctx.hasException()) return;
    _ = throwTest262HarnessError(ctx, global, "") catch |throw_err| switch (throw_err) {
        error.JSException => return,
        else => return throw_err,
    };
}

fn throwTest262HarnessError(ctx: *zjs.JSContext, global: ?*zjs.Object, message: []const u8) !zjs.JSValue {
    return ctx.throwError("Test262Error", message, .{ .realm_global = global });
}

fn createTest262ErrorValue(ctx: *zjs.JSContext, global: ?*zjs.Object, message: []const u8) !zjs.JSValue {
    return ctx.createError("Test262Error", message, .{ .realm_global = global });
}

fn createExternalHostFunction(
    runtime: *zjs.JSRuntime,
    context: *zjs.JSContext,
    name: []const u8,
    length: i32,
    call: zjs.ExternalHostCallFn,
) !zjs.JSValue {
    return createExternalHostFunctionWithRealm(runtime, context, name, length, call, false, null);
}

fn createExternalHostFunctionWithRealm(
    runtime: *zjs.JSRuntime,
    context: *zjs.JSContext,
    name: []const u8,
    length: i32,
    call: zjs.ExternalHostCallFn,
    with_prototype: bool,
    realm_global: ?*zjs.Object,
) !zjs.JSValue {
    std.debug.assert(runtime == context.runtimePtr());
    return context.createExternalFunction(name, length, &test262_external_host_context, call, null, .{
        .with_prototype = with_prototype,
        .realm_global = realm_global,
    });
}

fn test262AgentStringValue(ctx: *zjs.JSContext, value: zjs.JSValue) ![]u8 {
    return ctx.toOwnedUtf8(value, test262PageAllocator());
}

test "test262 globals do not retain local namespace object reference" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();
    const global = try ctx.globalObject();

    try installTest262Globals(rt, ctx, global);

    const ns_key = try rt.internAtom("$262");
    defer rt.atoms.free(ns_key);
    const ns_val = try global.getProperty(ns_key);
    var weak = try rt.createWeakPersistentValue(ns_val, null, null);
    defer weak.deinit();
    ns_val.free(rt);

    try std.testing.expect(weak.isAlive());
    try std.testing.expect(try ctx.deleteProperty(global.value(), "$262"));
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(!weak.isAlive());
}

test "test262 evalScript uses the installed function realm" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();
    const global = try ctx.globalObject();

    const realm = try ctx.createRealm();
    defer realm.free(rt);
    const realm_global = try ctx.realmGlobal(realm);
    defer realm_global.free(rt);
    const realm_global_object = try ctx.realmGlobalObject(realm);
    try ctx.defineDataProperty(realm_global, "realmMarker", zjs.JSValue.int32(30), .{});

    const eval_func = try createExternalHostFunctionWithRealm(rt, ctx, "evalScript", 1, wrapExternalWithFunc(test262EvalScript), false, realm_global_object);
    defer eval_func.free(rt);

    const source = try ctx.createString("realmMarker + 12");
    defer source.free(rt);
    const result = try ctx.callFunction(eval_func, &.{source}, .{ .realm_global = global });
    defer result.free(rt);
    try std.testing.expectEqual(@as(?i32, 42), result.asInt32());
}

test "test262 agent string conversion follows JavaScript ToString" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const numeric = try test262AgentStringValue(ctx, zjs.JSValue.int32(123));
    defer test262PageAllocator().free(numeric);
    try std.testing.expectEqualStrings("123", numeric);

    const object = try ctx.eval("({ toString() { return 'agent-object-string'; } })", .{});
    defer object.free(rt);
    const object_text = try test262AgentStringValue(ctx, object);
    defer test262PageAllocator().free(object_text);
    try std.testing.expectEqualStrings("agent-object-string", object_text);
}

test "test262 timer integer conversion follows JavaScript ToNumber" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const object = try ctx.eval("({ valueOf() { return 7.9; } })", .{});
    defer object.free(rt);

    const converted = try test262Int64Arg(ctx, &.{ zjs.JSValue.undefinedValue(), object }, 1);
    try std.testing.expectEqual(@as(i64, 7), converted);
}
