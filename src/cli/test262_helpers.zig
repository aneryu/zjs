const std = @import("std");
const builtins = @import("../builtins/root.zig");
const core = @import("../core/root.zig");
const frontend = @import("../frontend/root.zig");
const value_ops = @import("../exec/value_ops.zig");
const stack_mod = @import("../exec/stack.zig");
const zjs_vm = @import("../exec/zjs_vm.zig");
const shared_vm = @import("../exec/shared.zig");
const call_vm = @import("../exec/call.zig");

pub const ErrorKind = enum {
    test262,
    eval,
    reference,
    syntax,
    range,
};

pub fn raise(kind: ErrorKind) error{ Test262Error, EvalError, ReferenceError, SyntaxError, RangeError } {
    return switch (kind) {
        .test262 => error.Test262Error,
        .eval => error.EvalError,
        .reference => error.ReferenceError,
        .syntax => error.SyntaxError,
        .range => error.RangeError,
    };
}

pub fn assertSameValue(actual: core.JSValue, expected: core.JSValue) !core.JSValue {
    if (!builtins.object.sameValue(actual, expected)) return error.Test262Error;
    return core.JSValue.undefinedValue();
}

pub fn qjsTest262EvalScript(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len == 0) return core.JSValue.undefinedValue();
    if (!args[0].isString()) return error.TypeError;
    const eval_global = shared_vm.objectRealmGlobal(function_object) orelse global;
    var source = std.ArrayList(u8).empty;
    defer source.deinit(ctx.runtime.memory.allocator);
    try shared_vm.appendSourceStringUtf8(ctx.runtime, &source, args[0]);
    return qjsEvalGlobalScriptSource(ctx, output, eval_global, source.items, "<evalScript>");
}

pub fn qjsEvalGlobalScriptSource(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    source: []const u8,
    filename: []const u8,
) !core.JSValue {
    var compiled = try frontend.parser.parse(ctx.runtime, source, .{ .mode = .script, .filename = filename, .strict = false, .return_completion = true });
    defer compiled.deinit();
    if (compiled.syntax_error != null) return error.SyntaxError;
    var nested_stack = stack_mod.Stack.init(&ctx.runtime.memory, ctx.runtime.stack_size);
    defer nested_stack.deinit(ctx.runtime);
    return zjs_vm.runWithArgsState(ctx, &nested_stack, &compiled.function, global.value(), &.{}, &.{}, output, global, true, false, false, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, null, null, null, core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), false, false, core.JSValue.undefinedValue(), true, false) catch |err| {
        return shared_vm.normalizeEvalRuntimeError(err);
    };
}

pub const Test262Agent = struct {
    source: []u8,
    owner_runtime: *core.JSRuntime,
    agent_runtime: ?*core.JSRuntime = null,
    broadcast_store: ?*core.object.SharedBufferStore = null,
    broadcast_max_byte_length: ?usize = null,
    done: bool = false,
    thread_done: bool = false,
};

pub const Test262AgentReportEntry = struct {
    owner_runtime: *core.JSRuntime,
    bytes: []u8,
};

pub const Test262AgentCoordinator = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    agents: []*Test262Agent = &.{},
    agents_capacity: usize = 0,
    reports: []Test262AgentReportEntry = &.{},
    reports_capacity: usize = 0,
};

pub var test262_agents = Test262AgentCoordinator{};
pub threadlocal var current_test262_agent: ?*Test262Agent = null;

pub var test262_gpa = std.heap.DebugAllocator(.{
    .safety = false,
    .stack_trace_frames = 0,
    .thread_safe = true,
    .retain_metadata = true,
}){};

pub fn test262PageAllocator() std.mem.Allocator {
    return test262_gpa.allocator();
}

pub fn test262AgentIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn test262AgentAppend(agent: *Test262Agent) !void {
    const io = test262AgentIo();
    test262_agents.mutex.lockUncancelable(io);
    defer test262_agents.mutex.unlock(io);
    _ = test262AgentSweepCompletedLocked(agent.owner_runtime);
    try test262AgentEnsureAgentCapacityLocked(test262_agents.agents.len + 1);
    test262_agents.agents = test262_agents.agents.ptr[0 .. test262_agents.agents.len + 1];
    test262_agents.agents[test262_agents.agents.len - 1] = agent;
}

pub fn test262AgentEnqueueReport(owner_runtime: *core.JSRuntime, bytes: []u8) !void {
    const io = test262AgentIo();
    test262_agents.mutex.lockUncancelable(io);
    defer test262_agents.mutex.unlock(io);
    try test262AgentEnsureReportCapacityLocked(test262_agents.reports.len + 1);
    test262_agents.reports = test262_agents.reports.ptr[0 .. test262_agents.reports.len + 1];
    test262_agents.reports[test262_agents.reports.len - 1] = .{ .owner_runtime = owner_runtime, .bytes = bytes };
    test262_agents.cond.broadcast(io);
}

pub fn test262AgentDestroy(agent: *Test262Agent) void {
    const allocator = test262PageAllocator();
    allocator.free(agent.source);
    if (agent.broadcast_store) |store| {
        store.release();
        agent.broadcast_store = null;
    }
    allocator.destroy(agent);
}

pub fn test262AgentEnsureAgentCapacityLocked(min_capacity: usize) !void {
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

pub fn test262AgentEnsureReportCapacityLocked(min_capacity: usize) !void {
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

pub fn test262AgentRemoveAtLocked(index: usize) void {
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

pub fn test262AgentRemove(agent: *Test262Agent) void {
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

pub fn test262AgentSweepCompletedLocked(rt: *core.JSRuntime) usize {
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

pub fn test262AgentTakeReportLocked(rt: *core.JSRuntime) ?[]u8 {
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

pub fn test262AgentSweepReportsLocked(rt: *core.JSRuntime) void {
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

pub fn cleanupTest262Agents(rt: *core.JSRuntime) usize {
    const io = test262AgentIo();

    var agent_runtimes_buf: [16]*core.JSRuntime = undefined;
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

    const waiter_io = shared_vm.atomicsWaiterIo();
    shared_vm.atomics_waiter_mutex.lockUncancelable(waiter_io);
    var cursor = shared_vm.atomics_waiters;
    while (cursor) |waiter| {
        if (waiter.ctx) |w_ctx| {
            var wake_up = false;
            if (w_ctx.runtime == rt) {
                wake_up = true;
            } else {
                for (agent_runtimes_buf[0..agent_runtimes_count]) |art| {
                    if (w_ctx.runtime == art) {
                        wake_up = true;
                        break;
                    }
                }
            }
            if (wake_up) {
                waiter.notified = true;
                waiter.cond.broadcast(waiter_io);
            }
        }
        cursor = waiter.next;
    }
    shared_vm.atomics_waiter_mutex.unlock(waiter_io);

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

pub fn test262AgentRecordCountForTests() usize {
    const io = test262AgentIo();
    test262_agents.mutex.lockUncancelable(io);
    defer test262_agents.mutex.unlock(io);
    return test262_agents.agents.len;
}

pub fn test262AgentInterruptHandler(rt: *core.JSRuntime, context: ?*anyopaque) bool {
    _ = rt;
    const agent: *Test262Agent = @ptrCast(@alignCast(context orelse return false));
    return agent.done;
}

pub fn test262AgentRun(agent: *Test262Agent) void {
    current_test262_agent = agent;
    defer current_test262_agent = null;
    defer {
        const io = test262AgentIo();
        test262_agents.mutex.lockUncancelable(io);
        agent.done = true;
        agent.thread_done = true;
        if (agent.broadcast_store) |store| {
            store.release();
            agent.broadcast_store = null;
        }
        test262_agents.cond.broadcast(io);
        test262_agents.mutex.unlock(io);
    }

    const allocator = test262PageAllocator();
    const rt = core.JSRuntime.create(allocator) catch return;
    defer rt.destroy();
    rt.setCanBlock(true);
    rt.setInterruptHandler(test262AgentInterruptHandler, agent);

    {
        const io = test262AgentIo();
        test262_agents.mutex.lockUncancelable(io);
        agent.agent_runtime = rt;
        test262_agents.mutex.unlock(io);
    }

    const ctx = core.JSContext.create(rt) catch return;
    defer ctx.destroy();
    defer zjs_vm.cleanupAtomicsWaitersForContext(ctx);
    const global = zjs_vm.contextGlobal(ctx) catch return;
    const call_mod = @import("../exec/call.zig");
    call_mod.installTest262Globals(rt, global) catch return;
    installTest262AgentGlobals(rt, ctx, global) catch return;
    var compiled = frontend.parser.parse(rt, agent.source, .{ .mode = .script, .filename = "<test262-agent>" }) catch return;
    defer compiled.deinit();
    if (compiled.syntax_error != null) return;
    var stack = stack_mod.Stack.init(&rt.memory, rt.stack_size);
    defer stack.deinit(rt);
    const result = zjs_vm.runWithOutput(ctx, &stack, &compiled.function, null) catch return;
    result.free(rt);
    shared_vm.drainPendingPromiseJobs(ctx, null, global) catch {};
    while (!test262AgentIsDone(agent)) {
        std.Io.sleep(test262AgentIo(), std.Io.Duration.fromMilliseconds(1), .awake) catch {};
        shared_vm.drainPendingPromiseJobs(ctx, null, global) catch return;
    }
}

pub fn test262AgentIsDone(agent: *Test262Agent) bool {
    const io = test262AgentIo();
    test262_agents.mutex.lockUncancelable(io);
    defer test262_agents.mutex.unlock(io);
    return agent.done;
}

pub fn qjsTest262AgentStart(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    _ = output;
    _ = global;
    if (args.len == 0) return error.TypeError;
    const source = try test262AgentStringValue(ctx.runtime, args[0]);
    var source_owned = true;
    errdefer if (source_owned) test262PageAllocator().free(source);
    const agent = try test262PageAllocator().create(Test262Agent);
    agent.* = .{ .source = source, .owner_runtime = ctx.runtime };
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
    return core.JSValue.undefinedValue();
}

pub fn qjsTest262AgentBroadcast(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    _ = output;
    _ = global;
    if (args.len == 0) return error.TypeError;
    const buffer = shared_vm.objectFromValue(args[0]) orelse return error.TypeError;
    if (buffer.class_id != core.class.ids.shared_array_buffer) return error.TypeError;
    const store = buffer.sharedByteStorageStore() orelse return error.TypeError;
    const max_byte_length = buffer.arrayBufferMaxByteLength();
    const io = test262AgentIo();
    test262_agents.mutex.lockUncancelable(io);
    defer test262_agents.mutex.unlock(io);
    _ = test262AgentSweepCompletedLocked(ctx.runtime);
    for (test262_agents.agents) |agent| {
        if (agent.owner_runtime != ctx.runtime) continue;
        if (agent.done) continue;
        if (agent.broadcast_store) |old| old.release();
        store.retain();
        agent.broadcast_store = store;
        agent.broadcast_max_byte_length = max_byte_length;
    }
    test262_agents.cond.broadcast(io);
    return core.JSValue.undefinedValue();
}

pub fn qjsTest262AgentReceiveBroadcast(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    const agent = current_test262_agent orelse return error.TypeError;
    if (args.len == 0 or !shared_vm.isCallableValue(args[0])) return error.TypeError;

    const io = test262AgentIo();
    test262_agents.mutex.lockUncancelable(io);
    while (agent.broadcast_store == null and !agent.done) {
        test262_agents.cond.waitUncancelable(io, &test262_agents.mutex);
    }
    const store = agent.broadcast_store orelse {
        test262_agents.mutex.unlock(io);
        return core.JSValue.undefinedValue();
    };
    const max_byte_length = agent.broadcast_max_byte_length;
    agent.broadcast_store = null;
    agent.broadcast_max_byte_length = null;
    test262_agents.mutex.unlock(io);
    defer store.release();

    const sab = try builtins.buffer.sharedArrayBufferFromStore(ctx.runtime, store, max_byte_length, null);
    defer sab.free(ctx.runtime);
    const callback_result = try shared_vm.callValueOrBytecode(ctx, output, global orelse try zjs_vm.contextGlobal(ctx), core.JSValue.undefinedValue(), args[0], &.{sab}, null, null);
    callback_result.free(ctx.runtime);
    return core.JSValue.undefinedValue();
}

pub fn qjsTest262AgentReport(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    _ = output;
    _ = global;
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const bytes = try test262AgentStringValue(ctx.runtime, value);
    errdefer test262PageAllocator().free(bytes);
    const owner_runtime = if (current_test262_agent) |agent| agent.owner_runtime else ctx.runtime;
    try test262AgentEnqueueReport(owner_runtime, bytes);
    return core.JSValue.undefinedValue();
}

pub fn qjsTest262AgentGetReport(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    _ = output;
    _ = global;
    _ = args;
    const allocator = test262PageAllocator();
    const io = test262AgentIo();
    test262_agents.mutex.lockUncancelable(io);
    _ = test262AgentSweepCompletedLocked(ctx.runtime);
    const report = test262AgentTakeReportLocked(ctx.runtime) orelse {
        test262_agents.mutex.unlock(io);
        return core.JSValue.nullValue();
    };
    test262_agents.mutex.unlock(io);
    defer allocator.free(report);
    return value_ops.createStringValue(ctx.runtime, report);
}

pub fn qjsTest262AgentLeaving(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    args: []const core.JSValue,
) !core.JSValue {
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
    return core.JSValue.undefinedValue();
}

pub fn qjsTest262AgentSleep(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    _ = output;
    _ = global;
    const value = if (args.len >= 1) args[0] else core.JSValue.int32(0);
    const number = value_ops.numberValue(value) orelse 0;
    if (number > 0) {
        const ms: i64 = @intFromFloat(@min(number, 60_000));
        std.Io.sleep(test262AgentIo(), std.Io.Duration.fromMilliseconds(ms), .awake) catch {};
    }
    _ = ctx;
    return core.JSValue.undefinedValue();
}

pub fn qjsTest262AgentMonotonicNow(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    _ = ctx;
    _ = output;
    _ = global;
    _ = args;
    const now = std.Io.Timestamp.now(test262AgentIo(), .awake);
    return core.JSValue.float64(@as(f64, @floatFromInt(now.nanoseconds)) / std.time.ns_per_ms);
}

pub fn installTest262AgentGlobals(rt: *core.JSRuntime, ctx: *core.JSContext, global: *core.Object) !void {
    const ns_key = try rt.internAtom("$262");
    defer rt.atoms.free(ns_key);

    const ns_val = global.getProperty(ns_key);
    defer ns_val.free(rt);

    const ns_obj = if (ns_val.isObject())
        shared_vm.objectFromValue(ns_val).?
    else result: {
        const obj = try core.Object.create(rt, core.class.ids.object, null);
        try global.defineOwnProperty(rt, ns_key, core.Descriptor.data(obj.value(), true, true, true));
        break :result obj;
    };

    const agent_obj = try core.Object.create(rt, core.class.ids.object, null);
    const agent_val = agent_obj.value();
    defer agent_val.free(rt);

    const agent_methods = [_]struct {
        name: []const u8,
        length: i32,
        call: core.host_function.ExternalCallFn,
    }{
        .{ .name = "start", .length = 1, .call = wrapExternal(qjsTest262AgentStart) },
        .{ .name = "broadcast", .length = 1, .call = wrapExternal(qjsTest262AgentBroadcast) },
        .{ .name = "receiveBroadcast", .length = 0, .call = wrapExternal(qjsTest262AgentReceiveBroadcast) },
        .{ .name = "report", .length = 1, .call = wrapExternal(qjsTest262AgentReport) },
        .{ .name = "getReport", .length = 0, .call = wrapExternal(qjsTest262AgentGetReport) },
        .{ .name = "leaving", .length = 0, .call = wrapExternal(qjsTest262AgentLeaving) },
        .{ .name = "sleep", .length = 1, .call = wrapExternal(qjsTest262AgentSleep) },
        .{ .name = "monotonicNow", .length = 0, .call = wrapExternal(qjsTest262AgentMonotonicNow) },
    };

    inline for (agent_methods) |m| {
        const func_val = try createExternalHostFunction(rt, ctx, m.name, m.length, m.call);
        defer func_val.free(rt);
        const name_key = try rt.internAtom(m.name);
        defer rt.atoms.free(name_key);
        try agent_obj.defineOwnProperty(rt, name_key, core.Descriptor.data(func_val, true, false, true));
    }

    const agent_key = try rt.internAtom("agent");
    defer rt.atoms.free(agent_key);
    try ns_obj.defineOwnProperty(rt, agent_key, core.Descriptor.data(agent_val, true, false, true));

    // Register evalScript on $262
    {
        const func_val = try createExternalHostFunction(rt, ctx, "evalScript", 1, wrapExternalWithFunc(qjsTest262EvalScript));
        defer func_val.free(rt);
        const eval_key = try rt.internAtom("evalScript");
        defer rt.atoms.free(eval_key);
        try ns_obj.defineOwnProperty(rt, eval_key, core.Descriptor.data(func_val, true, false, true));
    }

    // Register IsHTMLDDA on $262
    {
        const func_val = try createExternalHostFunction(rt, ctx, "IsHTMLDDA", 0, wrapExternal(hostCallIsHtmlDda));
        defer func_val.free(rt);
        const is_html_dda_obj = shared_vm.objectFromValue(func_val).?;
        is_html_dda_obj.is_html_dda = true;

        const key = try rt.internAtom("IsHTMLDDA");
        defer rt.atoms.free(key);
        try ns_obj.defineOwnProperty(rt, key, core.Descriptor.data(func_val, true, false, true));
    }

    // Register createRealm on $262
    {
        const func_val = try createExternalHostFunction(rt, ctx, "createRealm", 0, wrapExternal(qjsTest262CreateRealm));
        defer func_val.free(rt);
        const key = try rt.internAtom("createRealm");
        defer rt.atoms.free(key);
        try ns_obj.defineOwnProperty(rt, key, core.Descriptor.data(func_val, true, false, true));
    }

    // Register detachArrayBuffer on $262
    {
        const func_val = try createExternalHostFunction(rt, ctx, "detachArrayBuffer", 1, wrapExternal(qjsTest262DetachArrayBuffer));
        defer func_val.free(rt);
        const key = try rt.internAtom("detachArrayBuffer");
        defer rt.atoms.free(key);
        try ns_obj.defineOwnProperty(rt, key, core.Descriptor.data(func_val, true, false, true));
    }

    // Register gc on $262
    {
        const func_val = try createExternalHostFunction(rt, ctx, "gc", 0, wrapExternal(qjsTest262Gc));
        defer func_val.free(rt);
        const key = try rt.internAtom("gc");
        defer rt.atoms.free(key);
        try ns_obj.defineOwnProperty(rt, key, core.Descriptor.data(func_val, true, false, true));
    }
}

fn hostCallIsHtmlDda(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    _ = ctx;
    _ = output;
    _ = global;
    _ = args;
    return core.JSValue.undefinedValue();
}

fn qjsTest262CreateRealm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    _ = output;
    _ = global;
    _ = args;
    return try call_vm.hostCreateRealm(ctx.runtime);
}

fn qjsTest262DetachArrayBuffer(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    _ = output;
    _ = global;
    if (args.len < 1) return error.TypeError;
    return try builtins.buffer.detachArrayBuffer(ctx.runtime, args[0]);
}

fn qjsTest262Gc(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    _ = output;
    _ = global;
    _ = args;
    _ = ctx.runtime.runObjectCycleRemoval();
    return core.JSValue.undefinedValue();
}

fn wrapExternal(comptime f: anytype) core.host_function.ExternalCallFn {
    return struct {
        fn call(ptr: *anyopaque, c: core.host_function.ExternalCall) anyerror!core.JSValue {
            _ = ptr;
            const ctx: *core.JSContext = @ptrCast(@alignCast(c.ctx));
            return try f(ctx, c.output, c.global, c.args);
        }
    }.call;
}

fn wrapExternalWithFunc(comptime f: anytype) core.host_function.ExternalCallFn {
    return struct {
        fn call(ptr: *anyopaque, c: core.host_function.ExternalCall) anyerror!core.JSValue {
            _ = ptr;
            const ctx: *core.JSContext = @ptrCast(@alignCast(c.ctx));
            const global = c.global orelse c.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
            return try f(ctx, c.output, global, c.func_obj, c.args);
        }
    }.call;
}

fn createExternalHostFunction(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    name: []const u8,
    length: i32,
    call: core.host_function.ExternalCallFn,
) !core.JSValue {
    const id = try runtime.registerExternalHostFunction(.{
        .ptr = undefined,
        .call = call,
        .finalizer = null,
    });
    const function_value = try builtins.function.nativeFunction(runtime, name, length);
    errdefer function_value.free(runtime);

    const function_object = try @import("../exec/property_ops.zig").expectObject(function_value);
    function_object.hostFunctionKindSlot().* = core.host_function.ids.external_host;
    function_object.externalHostFunctionIdSlot().* = id;
    const global_object = try @import("../exec/zjs_vm.zig").contextGlobal(context);
    try function_object.setFunctionRealmGlobalPtr(runtime, global_object);
    return function_value;
}

fn test262AgentStringArg(rt: *core.JSRuntime, value: core.JSValue) ![]u8 {
    var bytes = std.ArrayList(u8).empty;
    errdefer bytes.deinit(rt.memory.allocator);
    try value_ops.appendValueString(rt, &bytes, value);
    return bytes.toOwnedSlice(rt.memory.allocator);
}

pub fn test262AgentStringValue(rt: *core.JSRuntime, value: core.JSValue) ![]u8 {
    const local = try test262AgentStringArg(rt, value);
    defer rt.memory.allocator.free(local);
    return try test262PageAllocator().dupe(u8, local);
}
