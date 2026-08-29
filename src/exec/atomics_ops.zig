//! The Atomics domain: namespace registration, typed memory operations, and
//! synchronous/Promise-backed waiter lifecycle.
//!
//! The bodies lived in `call_runtime.zig` until 2026-08-20 (backlog H1): a
//! thousand lines of a self-contained domain -- waiter registry, typed
//! read-modify-write, the `*ForAtomics` coercions -- in the file that owns the
//! call chain. `atomics_wait.zig` owns the platform wait primitives and
//! method-id enum; Promise construction/settlement is borrowed through the
//! narrow compatibility seam in `promise_ops.zig`.

const std = @import("std");
const atomics_ops = @This();
const core = @import("../core/root.zig");
const jobs_mod = core.jobs;
const atomics_wait = @import("atomics_wait.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const call_runtime = @import("call_runtime.zig");
const exception_ops = @import("exception_ops.zig");
const array_ops = @import("array_ops.zig");
const coercion_ops = @import("coercion_ops.zig");
const frame_mod = @import("frame.zig");
const bytecode = @import("../bytecode.zig");
const object_ops = @import("object_ops.zig");
const promise_ops = @import("promise_ops.zig");
const value_ops = @import("value_ops.zig");
const HostError = @import("exceptions.zig").HostError;
const atomicsBufferObject = object_ops.atomicsBufferObject;
const atomicsTypedArray = array_ops.atomicsTypedArray;
const atomicsTypedArrayIsBigInt = array_ops.atomicsTypedArrayIsBigInt;
const defineValueProperty = object_ops.defineValueProperty;
const objectFromValue = object_ops.objectFromValue;
const promisePrototypeFromGlobal = promise_ops.promisePrototypeFromGlobal;

pub const StaticMethod = atomics_wait.StaticMethod;

pub fn methodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "isLockFree")) return @intFromEnum(StaticMethod.is_lock_free);
    if (std.mem.eql(u8, name, "load")) return @intFromEnum(StaticMethod.load);
    if (std.mem.eql(u8, name, "store")) return @intFromEnum(StaticMethod.store);
    if (std.mem.eql(u8, name, "add")) return @intFromEnum(StaticMethod.add);
    if (std.mem.eql(u8, name, "sub")) return @intFromEnum(StaticMethod.sub);
    if (std.mem.eql(u8, name, "and")) return @intFromEnum(StaticMethod.@"and");
    if (std.mem.eql(u8, name, "or")) return @intFromEnum(StaticMethod.@"or");
    if (std.mem.eql(u8, name, "xor")) return @intFromEnum(StaticMethod.xor);
    if (std.mem.eql(u8, name, "exchange")) return @intFromEnum(StaticMethod.exchange);
    if (std.mem.eql(u8, name, "compareExchange")) return @intFromEnum(StaticMethod.compare_exchange);
    if (std.mem.eql(u8, name, "wait")) return @intFromEnum(StaticMethod.wait);
    if (std.mem.eql(u8, name, "waitAsync")) return @intFromEnum(StaticMethod.wait_async);
    if (std.mem.eql(u8, name, "notify")) return @intFromEnum(StaticMethod.notify);
    if (std.mem.eql(u8, name, "pause")) return @intFromEnum(StaticMethod.pause);
    return null;
}

/// QuickJS-style function-list entries for every `Atomics.*` method installed
/// by `standard_globals`. The domain uses one typed generic+magic handler; the
/// method id is carried as `magic` and selects the existing exec-owned body.
pub const internal_entries = [_]core.host_function.InternalEntry{
    atomicsEntry("add", 3, .add),
    atomicsEntry("and", 3, .@"and"),
    atomicsEntry("compareExchange", 4, .compare_exchange),
    atomicsEntry("exchange", 3, .exchange),
    atomicsEntry("isLockFree", 1, .is_lock_free),
    atomicsEntry("load", 2, .load),
    atomicsEntry("notify", 3, .notify),
    atomicsEntry("or", 3, .@"or"),
    atomicsEntry("pause", 0, .pause),
    atomicsEntry("store", 3, .store),
    atomicsEntry("sub", 3, .sub),
    atomicsEntry("wait", 4, .wait),
    atomicsEntry("waitAsync", 4, .wait_async),
    atomicsEntry("xor", 3, .xor),
};

fn atomicsEntry(
    comptime name: []const u8,
    comptime length: u8,
    comptime method: StaticMethod,
) core.host_function.InternalEntry {
    const id: u32 = @intFromEnum(method);
    return .{
        .name = name,
        .length = length,
        .id = id,
        .magic = @intCast(id),
        .cproto = .generic_magic,
        .native_function = builtin_dispatch.genericMagicFunction(&atomicsCall),
    };
}

fn atomicsCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const realm = try builtin_dispatch.callableRealm(host_call);
    std.debug.assert(realm.realm == host_call.ctx);
    return atomicsCallForNativeRecord(
        host_call.ctx,
        host_call.output,
        realm.global,
        host_call.magic,
        host_call.args,
        builtin_dispatch.callerBytecode(host_call),
        builtin_dispatch.callerFrame(host_call),
    );
}

pub const AtomicsReadModifyOp = enum {
    add,
    @"and",
    compareExchange,
    exchange,
    load,
    @"or",
    sub,
    xor,
};

pub const AtomicsWaiterKey = struct {
    store: ?*core.object.SharedBufferStore = null,
    offset_or_ptr: usize,
};

pub const AtomicsWaiterCompletion = enum {
    waiting,
    notified,
    timed_out,
};

pub const AtomicsWaiter = struct {
    key: AtomicsWaiterKey,
    /// Protected by atomics_waiter_mutex. Foreign threads may only move this
    /// scalar out of `waiting` and signal the condition; the Runtime owner is
    /// the sole consumer allowed to touch the Promise/RealmRef.
    completion: AtomicsWaiterCompletion = .waiting,
    linked: bool = false,
    cond: std.Io.Condition = .init,
    promise: ?core.JSValue = null,
    /// Present only for heap-backed waitAsync nodes. The synchronous waiter is
    /// stack-local and leaves this empty.
    realm: core.RealmRef = .{},
    deadline: ?std.Io.Timestamp = null,
    next: ?*AtomicsWaiter = null,
};

pub var atomics_waiter_mutex: std.Io.Mutex = .init;
pub var atomics_waiters: ?*AtomicsWaiter = null;

pub fn atomicsCallForNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const atomics_mod = atomics_wait;
    return switch (id) {
        @intFromEnum(atomics_mod.StaticMethod.is_lock_free) => try atomicsIsLockFree(ctx, output, global, args, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.pause) => try atomicsPause(ctx, output, global, args, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.notify) => try atomicsNotify(ctx, output, global, args, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.wait) => try atomicsWait(ctx, output, global, args, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.wait_async) => try promise_ops.atomicsWaitAsync(ctx, output, global, args, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.store) => try atomicsStore(ctx, output, global, args, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.load) => try atomicsReadModifyWrite(ctx, output, global, args, .load, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.add) => try atomicsReadModifyWrite(ctx, output, global, args, .add, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.@"and") => try atomicsReadModifyWrite(ctx, output, global, args, .@"and", caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.@"or") => try atomicsReadModifyWrite(ctx, output, global, args, .@"or", caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.sub) => try atomicsReadModifyWrite(ctx, output, global, args, .sub, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.xor) => try atomicsReadModifyWrite(ctx, output, global, args, .xor, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.exchange) => try atomicsReadModifyWrite(ctx, output, global, args, .exchange, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.compare_exchange) => try atomicsReadModifyWrite(ctx, output, global, args, .compareExchange, caller_function, caller_frame),
        else => error.TypeError,
    };
}

pub fn atomicsIsLockFree(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const size_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const size = try toInt32ForAtomics(ctx, output, global, size_value, caller_function, caller_frame);
    return core.JSValue.boolean(size == 1 or size == 2 or size == 4 or size == 8);
}

pub fn atomicsPause(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = ctx;
    _ = output;
    _ = global;
    _ = caller_function;
    _ = caller_frame;
    if (args.len >= 1 and !args[0].isUndefined()) {
        if (!args[0].isNumber()) return error.TypeError;
        const number = value_ops.numberValue(args[0]) orelse std.math.nan(f64);
        if (!std.math.isFinite(number) or @trunc(number) != number) return error.TypeError;
    }
    return core.JSValue.undefinedValue();
}

pub fn atomicsReadModifyWrite(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    atomic_op: AtomicsReadModifyOp,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const view_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const view = try array_ops.atomicsTypedArray(view_value, false);
    if (atomic_op != .load) try core.object.typedArrayRejectImmutableBuffer(ctx.runtime, view);
    const index_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const index = try atomicsGetBufIndex(ctx, output, global, view, index_value, caller_function, caller_frame);

    const is_bigint = array_ops.atomicsTypedArrayIsBigInt(view);
    const value_arg = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
    const replacement_arg = if (args.len >= 4) args[3] else core.JSValue.undefinedValue();
    const operand = if (atomic_op == .load) @as(u64, 0) else if (is_bigint)
        try toBigIntBitsForAtomics(ctx, output, global, value_arg, caller_function, caller_frame)
    else
        try toUint32ForAtomics(ctx, output, global, value_arg, caller_function, caller_frame);
    const replacement = if (atomic_op == .compareExchange) blk: {
        break :blk if (is_bigint)
            try toBigIntBitsForAtomics(ctx, output, global, replacement_arg, caller_function, caller_frame)
        else
            try toUint32ForAtomics(ctx, output, global, replacement_arg, caller_function, caller_frame);
    } else @as(u64, 0);
    // js_atomics_op (quickjs.c:60604): LOAD coerces no operand, so qjs skips
    // the post-coercion re-check for it; every other op re-validates after
    // the operand conversions ran user code.
    if (atomic_op != .load) try atomicsRevalidateIndex(ctx.runtime, view, index);

    const bytes = try atomicsElementBytes(view, index);
    // One atomic instruction per op (qjs js_atomics_op, quickjs.c:60637-60697);
    // a plain read/compute/write here loses concurrent RMW updates.
    const old = atomicsReadModifyWriteBits(view, bytes, atomic_op, operand, replacement);
    return atomicsValueFromBits(ctx.runtime, view, old);
}

pub fn atomicsStore(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const view_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const view = try array_ops.atomicsTypedArray(view_value, false);
    try core.object.typedArrayRejectImmutableBuffer(ctx.runtime, view);
    const index_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const index = try atomicsGetBufIndex(ctx, output, global, view, index_value, caller_function, caller_frame);

    const value_arg = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
    const is_bigint = array_ops.atomicsTypedArrayIsBigInt(view);
    const stored_value = if (is_bigint)
        try toBigIntValueForAtomics(ctx, output, global, value_arg, caller_function, caller_frame)
    else
        try toIntegerValueForAtomics(ctx, output, global, value_arg, caller_function, caller_frame);
    errdefer stored_value.free(ctx.runtime);
    const bits = if (is_bigint)
        try bigintBitsForAtomics(ctx.runtime, stored_value)
    else
        try uint32FromIntegerValueForAtomics(ctx.runtime, stored_value);
    // Mirrors js_atomics_store (quickjs.c:60770-60773): re-check
    // typed_array_is_oob (TypeError) then the fresh count (RangeError) after
    // the value coercion ran user code.
    try atomicsRevalidateIndex(ctx.runtime, view, index);
    const bytes = try atomicsElementBytes(view, index);
    atomicsWriteBits(view, bytes, bits);
    return stored_value;
}

pub fn atomicsNotify(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const view_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const view = try array_ops.atomicsTypedArray(view_value, true);
    const buffer = try object_ops.atomicsBufferObject(view);
    if (buffer.class_id != core.class.ids.shared_array_buffer and buffer.arrayBufferDetached()) return error.TypeError;
    const index_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const index = try atomicsValidateAccess(ctx, output, global, view, index_value, caller_function, caller_frame);
    const count = try atomicsNotifyCount(ctx, output, global, args, caller_function, caller_frame);
    if (buffer.class_id != core.class.ids.shared_array_buffer or count == 0) return core.JSValue.int32(0);
    try atomicsValidateIndex(ctx.runtime, view, index);
    const bytes = try atomicsElementBytes(view, index);
    const key = try atomicsWaiterKey(view, bytes);
    return core.JSValue.int32(@intCast(atomicsWakeWaiters(key, count)));
}

pub fn atomicsWait(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const view_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const view = try array_ops.atomicsTypedArray(view_value, true);
    if ((try object_ops.atomicsBufferObject(view)).class_id != core.class.ids.shared_array_buffer) return error.TypeError;
    const index_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const index = try atomicsValidateAccess(ctx, output, global, view, index_value, caller_function, caller_frame);
    const expected_arg = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
    const expected = if (array_ops.atomicsTypedArrayIsBigInt(view))
        try toBigIntBitsForAtomics(ctx, output, global, expected_arg, caller_function, caller_frame)
    else
        try toInt32BitsForAtomics(ctx, output, global, expected_arg, caller_function, caller_frame);
    const timeout_arg = if (args.len >= 4) args[3] else core.JSValue.float64(std.math.inf(f64));
    const timeout = try toNumberForAtomics(ctx, output, global, timeout_arg, caller_function, caller_frame);
    // Mirrors js_atomics_wait (quickjs.c:60900-60901): the can-block check
    // runs after the operand coercions but BEFORE the memory load/compare, so
    // a non-blockable thread throws TypeError instead of returning
    // "not-equal".
    if (!ctx.runtime.canBlock()) return exception_ops.throwTypeErrorMessage(ctx, global, "cannot block in this thread");
    try atomicsValidateIndex(ctx.runtime, view, index);
    const bytes = try atomicsElementBytes(view, index);
    const current = atomicsReadBits(view, bytes);
    if (current != atomicsMaskBits(view, expected)) return value_ops.createStringValue(ctx.runtime, "not-equal");
    const wait_ms = atomicsWaitTimeoutMilliseconds(timeout);
    if (wait_ms == 0) return value_ops.createStringValue(ctx.runtime, "timed-out");
    const key = try atomicsWaiterKey(view, bytes);
    return atomicsWaitForNotification(ctx.runtime, key, wait_ms);
}

pub fn atomicsNotifyCount(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !usize {
    if (args.len < 3 or args[2].isUndefined()) return std.math.maxInt(usize);
    const count_value = try toIntegerValueForAtomics(ctx, output, global, args[2], caller_function, caller_frame);
    defer count_value.free(ctx.runtime);
    const count_number = value_ops.numberValue(count_value) orelse return 0;
    if (std.math.isNan(count_number) or count_number <= 0) return 0;
    if (!std.math.isFinite(count_number)) return std.math.maxInt(usize);
    return @intFromFloat(@min(count_number, @as(f64, @floatFromInt(std.math.maxInt(i32)))));
}

pub fn atomicsWaitTimeoutMilliseconds(timeout: f64) ?i64 {
    if (std.math.isNan(timeout) or !std.math.isFinite(timeout)) return null;
    if (timeout <= 0) return 0;
    return @intFromFloat(@min(timeout, @as(f64, @floatFromInt(std.math.maxInt(i64)))));
}

pub fn atomicsWaiterKey(view: *core.Object, bytes: []const u8) !AtomicsWaiterKey {
    const buffer = try object_ops.atomicsBufferObject(view);
    if (buffer.class_id == core.class.ids.shared_array_buffer) {
        if (buffer.sharedByteStorageStore()) |store| {
            const base = @intFromPtr(buffer.byteStorage().ptr);
            const ptr = @intFromPtr(bytes.ptr);
            return .{ .store = store, .offset_or_ptr = ptr - base };
        }
    }
    return .{ .offset_or_ptr = @intFromPtr(bytes.ptr) };
}

pub fn atomicsWaiterKeysEqual(a: AtomicsWaiterKey, b: AtomicsWaiterKey) bool {
    return a.store == b.store and a.offset_or_ptr == b.offset_or_ptr;
}

pub fn atomicsRetainWaiterKey(key: AtomicsWaiterKey) void {
    if (key.store) |store| store.retain();
}

pub fn atomicsReleaseWaiterKey(key: *AtomicsWaiterKey) void {
    if (key.store) |store| {
        store.release();
        key.store = null;
    }
}

pub fn atomicsWakeWaiters(key: AtomicsWaiterKey, count: usize) usize {
    const io = atomicsWaiterIo();
    atomics_waiter_mutex.lockUncancelable(io);
    defer atomics_waiter_mutex.unlock(io);

    var woken: usize = 0;
    var cursor = atomics_waiters;
    while (cursor) |waiter| {
        const next = waiter.next;
        if (!atomicsWaiterKeysEqual(waiter.key, key) or waiter.completion != .waiting) {
            cursor = next;
            continue;
        }
        // This function may run on a foreign Runtime thread. Publish only a
        // no-allocation scalar completion and wake the appropriate owner. A
        // synchronous stack waiter uses its condition; a heap waitAsync node
        // signals the owning Runtime's host-completion event. Neither path
        // touches the JS heap or allocator.
        waiter.completion = .notified;
        waiter.cond.signal(io);
        if (waiter.promise != null) {
            if (waiter.realm.borrow()) |waiter_ctx| {
                waiter_ctx.runtime.signalHostCompletion(io);
            }
        }
        woken += 1;
        if (woken == count) break;
        cursor = next;
    }
    return woken;
}

pub fn processExpiredAtomicsWaiters(ctx: *core.JSContext) !void {
    ctx.runtime.assertOwnerThread();
    const io = atomicsWaiterIo();
    while (true) {
        const now = std.Io.Timestamp.now(io, .awake);
        atomics_waiter_mutex.lockUncancelable(io);

        var ready: ?*AtomicsWaiter = null;
        var previous: ?*AtomicsWaiter = null;
        var cursor = atomics_waiters;
        while (cursor) |waiter| : (cursor = waiter.next) {
            const waiter_ctx = waiter.realm.borrow() orelse {
                previous = waiter;
                continue;
            };
            if (waiter_ctx.runtime != ctx.runtime or waiter.promise == null) {
                previous = waiter;
                continue;
            }
            if (waiter.completion == .waiting) {
                const deadline = waiter.deadline orelse {
                    previous = waiter;
                    continue;
                };
                if (now.nanoseconds < deadline.nanoseconds) {
                    previous = waiter;
                    continue;
                }
                // Freeze the timeout winner before detaching. If settlement
                // runs out of memory, relinking this node preserves that winner
                // and prevents a later notify from changing the result.
                waiter.completion = .timed_out;
            }
            const next = waiter.next;
            if (previous) |prev| {
                prev.next = next;
            } else {
                atomics_waiters = next;
            }
            waiter.linked = false;
            waiter.next = null;
            ready = waiter;
            break;
        }
        atomics_waiter_mutex.unlock(io);

        const waiter = ready orelse return;
        const waiter_ctx = waiter.realm.borrow() orelse unreachable;
        waiter_ctx.runtime.job_queue.enqueueAtomicsWaiter(
            waiter_ctx,
            waiter,
            waiter.promise.?,
            promise_ops.atomicsRunAsyncWaiterCompletion,
            promise_ops.atomicsDestroyAsyncWaiterOpaque,
        ) catch |err| {
            // Entry preparation may allocate or run GC. Retry the same frozen
            // completion later, but never while the global waiter mutex is
            // held and never after publishing Promise state.
            atomics_waiter_mutex.lockUncancelable(io);
            atomicsLinkWaiter(waiter);
            atomics_waiter_mutex.unlock(io);
            return err;
        };
    }
}

fn atomicsAsyncWaiterRuntime(waiter: *const AtomicsWaiter) ?*core.JSRuntime {
    if (waiter.promise == null) return null;
    const waiter_ctx = waiter.realm.borrow() orelse return null;
    return waiter_ctx.runtime;
}

/// Whether this Runtime owns a linked waitAsync node. This is host scheduling
/// state only: callers use it to avoid blocking an OS poll that cannot observe
/// the Runtime's allocation-free completion signal.
pub fn atomicsRuntimeHasPendingAsyncWaiters(rt: *core.JSRuntime) bool {
    const io = atomicsWaiterIo();
    atomics_waiter_mutex.lockUncancelable(io);
    defer atomics_waiter_mutex.unlock(io);
    var cursor = atomics_waiters;
    while (cursor) |waiter| : (cursor = waiter.next) {
        if (atomicsAsyncWaiterRuntime(waiter) == rt) return true;
    }
    return false;
}

/// Wait for either a foreign waitAsync notification, the earliest finite
/// waitAsync deadline, or an earlier host deadline supplied by the event loop.
/// The event is reset while holding the same mutex used by every notifier, so
/// a notification cannot be lost between the readiness scan and the wait.
/// Returns false only when this Runtime has no linked async waiter, or when all
/// of its waiters are infinite and `block_indefinite` is false.
pub fn waitForAtomicsHostSignalUntil(
    rt: *core.JSRuntime,
    external_deadline: ?std.Io.Timestamp,
    block_indefinite: bool,
) bool {
    rt.assertOwnerThread();
    const io = atomicsWaiterIo();
    atomics_waiter_mutex.lockUncancelable(io);

    var found = false;
    var deadline = external_deadline;
    const now = std.Io.Timestamp.now(io, .awake);
    var cursor = atomics_waiters;
    while (cursor) |waiter| : (cursor = waiter.next) {
        if (atomicsAsyncWaiterRuntime(waiter) != rt) continue;
        found = true;
        const candidate = if (waiter.completion != .waiting)
            now
        else
            waiter.deadline orelse continue;
        if (deadline == null or candidate.nanoseconds < deadline.?.nanoseconds) {
            deadline = candidate;
        }
    }
    if (!found or (deadline == null and !block_indefinite)) {
        atomics_waiter_mutex.unlock(io);
        return false;
    }

    rt.resetHostCompletionSignal();
    atomics_waiter_mutex.unlock(io);
    if (deadline) |limit| {
        _ = rt.waitForHostCompletionUntil(io, limit);
    } else {
        rt.waitForHostCompletion(io);
    }
    return true;
}

/// Advance the owner-runtime host clock/signal source once. Ready nodes are
/// only converted into typed FIFO jobs here; Promise settlement still happens
/// later in `drainOnePendingJob`.
pub fn runNextAtomicsHostCompletion(ctx: *core.JSContext, block_indefinite: bool) !bool {
    ctx.runtime.assertOwnerThread();
    const jobs_before = ctx.runtime.job_queue.jobs.len;
    try processExpiredAtomicsWaiters(ctx);
    if (ctx.runtime.job_queue.jobs.len != jobs_before) return true;
    if (!waitForAtomicsHostSignalUntil(ctx.runtime, null, block_indefinite)) return false;
    try processExpiredAtomicsWaiters(ctx);
    return true;
}

pub fn cleanupAtomicsWaitersForContext(ctx: *core.JSContext) void {
    ctx.runtime.assertOwnerThread();
    const io = atomicsWaiterIo();
    while (true) {
        atomics_waiter_mutex.lockUncancelable(io);
        var removed: ?*AtomicsWaiter = null;
        var previous: ?*AtomicsWaiter = null;
        var cursor = atomics_waiters;
        while (cursor) |waiter| : (cursor = waiter.next) {
            if (waiter.realm.borrow() != ctx) {
                previous = waiter;
                continue;
            }
            const next = waiter.next;
            if (previous) |prev| {
                prev.next = next;
            } else {
                atomics_waiters = next;
            }
            waiter.linked = false;
            waiter.next = null;
            removed = waiter;
            break;
        }
        atomics_waiter_mutex.unlock(io);

        const waiter = removed orelse return;
        promise_ops.atomicsDestroyAsyncWaiter(waiter);
    }
}

pub fn atomicsWaitForNotification(rt: *core.JSRuntime, key: AtomicsWaiterKey, timeout_ms: ?i64) !core.JSValue {
    rt.assertOwnerThread();
    atomicsRetainWaiterKey(key);
    var retained_key = key;
    defer atomicsReleaseWaiterKey(&retained_key);

    var waiter = AtomicsWaiter{ .key = retained_key };
    const io = atomicsWaiterIo();
    atomics_waiter_mutex.lockUncancelable(io);
    atomicsLinkWaiter(&waiter);

    if (timeout_ms == null) {
        while (waiter.completion == .waiting) waiter.cond.waitUncancelable(io, &atomics_waiter_mutex);
    } else {
        const deadline = std.Io.Timestamp.now(io, .awake).addDuration(std.Io.Duration.fromMilliseconds(timeout_ms.?));
        while (waiter.completion == .waiting) {
            const now = std.Io.Timestamp.now(io, .awake);
            if (now.nanoseconds >= deadline.nanoseconds) break;
            atomics_waiter_mutex.unlock(io);
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
            atomics_waiter_mutex.lockUncancelable(io);
        }
    }
    const was_notified = waiter.completion == .notified;
    atomicsUnlinkWaiter(&waiter);
    atomics_waiter_mutex.unlock(io);
    // String creation can allocate and collect; the waiter registry lock is
    // deliberately released before entering the Runtime heap.
    return value_ops.createStringValue(rt, if (was_notified) "ok" else "timed-out");
}

pub fn atomicsLinkWaiter(waiter: *AtomicsWaiter) void {
    waiter.linked = true;
    waiter.next = null;
    if (atomics_waiters == null) {
        atomics_waiters = waiter;
        return;
    }
    var tail = atomics_waiters.?;
    while (tail.next) |next| tail = next;
    tail.next = waiter;
}

pub fn atomicsUnlinkWaiter(waiter: *AtomicsWaiter) void {
    if (!waiter.linked) return;
    var previous: ?*AtomicsWaiter = null;
    var cursor = atomics_waiters;
    while (cursor) |current| : (cursor = current.next) {
        if (current != waiter) {
            previous = current;
            continue;
        }
        if (previous) |prev| {
            prev.next = current.next;
        } else {
            atomics_waiters = current.next;
        }
        current.next = null;
        current.linked = false;
        return;
    }
}

test "foreign Atomics notify only publishes a no-allocation completion" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const key = AtomicsWaiterKey{ .offset_or_ptr = @intFromPtr(ctx) };
    const waiter = try rt.memory.create(AtomicsWaiter);
    waiter.* = .{
        .key = key,
        .promise = core.JSValue.int32(73),
        .realm = core.RealmRef.retain(ctx),
    };
    promise_ops.atomicsLinkAsyncWaiter(waiter);
    var waiter_live = true;
    defer if (waiter_live) cleanupAtomicsWaitersForContext(ctx);

    const Attempt = struct {
        key: AtomicsWaiterKey,
        woken: usize = 0,

        fn run(self: *@This()) void {
            self.woken = atomicsWakeWaiters(self.key, 1);
        }
    };
    const memory_before = rt.memory.allocated_bytes;
    var attempt = Attempt{ .key = key };
    const thread = try std.Thread.spawn(.{}, Attempt.run, .{&attempt});
    thread.join();

    try std.testing.expectEqual(@as(usize, 1), attempt.woken);
    try std.testing.expectEqual(memory_before, rt.memory.allocated_bytes);
    try std.testing.expect(waiter.linked);
    try std.testing.expectEqual(AtomicsWaiterCompletion.notified, waiter.completion);
    try std.testing.expectEqual(@as(?i32, 73), waiter.promise.?.asInt32());
    try std.testing.expectEqual(ctx, waiter.realm.borrow().?);

    cleanupAtomicsWaitersForContext(ctx);
    waiter_live = false;
}

test "waitAsync finite deadline is driven by the owner host clock queue" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const promise = try core.Object.create(rt, core.class.ids.promise, null);
    defer promise.value().free(rt);

    const io = atomicsWaiterIo();
    const waiter = try rt.memory.create(AtomicsWaiter);
    waiter.* = .{
        .key = .{ .offset_or_ptr = @intFromPtr(promise) },
        .promise = promise.value().dup(),
        .realm = core.RealmRef.retain(ctx),
        .deadline = std.Io.Timestamp.now(io, .awake).addDuration(std.Io.Duration.fromMilliseconds(1)),
    };
    promise_ops.atomicsLinkAsyncWaiter(waiter);
    var waiter_linked = true;
    defer if (waiter_linked) cleanupAtomicsWaitersForContext(ctx);

    try std.testing.expect(try runNextAtomicsHostCompletion(ctx, false));
    waiter_linked = false;
    try std.testing.expectEqual(AtomicsWaiterCompletion.timed_out, waiter.completion);
    try std.testing.expectEqual(@as(usize, 1), rt.job_queue.jobs.len);
    try std.testing.expect(std.meta.activeTag(rt.job_queue.jobs[0].payload) == .atomics_waiter);
    try std.testing.expect(promise.promiseResult() == null);

    // The host clock only publishes a typed job. Dropping that job owns and
    // releases the detached waiter exactly once without touching the Promise.
    var job = rt.job_queue.takeFirst().?;
    job.deinit();
}

test "waitAsync owner settlement OOM relinks the frozen completion outside the waiter mutex" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const rt = try core.JSRuntime.create(failing_allocator.allocator());
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;
    const promise = try core.Object.create(rt, core.class.ids.promise, null);
    defer promise.value().free(rt);

    const key = AtomicsWaiterKey{ .offset_or_ptr = @intFromPtr(promise) };
    const waiter = try rt.memory.create(AtomicsWaiter);
    waiter.* = .{
        .key = key,
        .completion = .notified,
        .promise = promise.value().dup(),
        .realm = core.RealmRef.retain(ctx),
    };
    promise_ops.atomicsLinkAsyncWaiter(waiter);
    var waiter_live = true;
    defer if (waiter_live) cleanupAtomicsWaitersForContext(ctx);

    const Probe = struct {
        mutex_was_free: bool = false,

        fn trigger(raw: ?*anyopaque, _: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (!atomics_waiter_mutex.tryLock()) return;
            self.mutex_was_free = true;
            atomics_waiter_mutex.unlock(atomicsWaiterIo());
        }
    };
    var probe = Probe{};
    const saved_trigger = rt.memory.trigger_gc_fn;
    const saved_trigger_context = rt.memory.trigger_gc_ctx;
    defer {
        rt.memory.trigger_gc_fn = saved_trigger;
        rt.memory.trigger_gc_ctx = saved_trigger_context;
    }
    rt.memory.trigger_gc_fn = Probe.trigger;
    rt.memory.trigger_gc_ctx = &probe;
    // Fail in the backing allocator, after MemoryAccount has invoked the GC
    // trigger. A hard MemoryAccount limit is rejected before that trigger and
    // therefore cannot prove that the allocation site is outside the mutex.
    failing_allocator.fail_index = failing_allocator.alloc_index;

    try std.testing.expectError(error.OutOfMemory, processExpiredAtomicsWaiters(ctx));
    try std.testing.expect(probe.mutex_was_free);
    try std.testing.expect(waiter.linked);
    try std.testing.expectEqual(AtomicsWaiterCompletion.notified, waiter.completion);
    try std.testing.expectEqual(ctx, waiter.realm.borrow().?);
    try std.testing.expect(promise.promiseResult() == null);

    failing_allocator.fail_index = std.math.maxInt(usize);
    rt.memory.trigger_gc_fn = saved_trigger;
    rt.memory.trigger_gc_ctx = saved_trigger_context;
    try processExpiredAtomicsWaiters(ctx);
    waiter_live = false;
    try std.testing.expect(promise.promiseResult() == null);
    try std.testing.expect((try promise_ops.drainOnePendingJob(ctx, null, global)) == .success);
    try std.testing.expect(promise.promiseResult() != null);
    try std.testing.expect(!promise.promiseIsRejected());
}

pub fn atomicsWaiterIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn atomicsValidateAccess(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    index_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !usize {
    const length = try core.object.typedArrayLength(ctx.runtime, object);
    const index = try toIndexForAtomics(ctx, output, global, index_value, caller_function, caller_frame);
    if (index >= length) return error.RangeError;
    return index;
}

pub fn atomicsValidateIndex(rt: *core.JSRuntime, object: *core.Object, index: usize) !void {
    const length = try core.object.typedArrayLength(rt, object);
    if (index >= length) return error.RangeError;
}

/// Mirrors js_atomics_get_buf (quickjs.c:60526) for the non-waitable Atomics
/// ops (is_waitable == 0): after the class check, a detached non-shared buffer
/// throws TypeError BEFORE ToIndex; the view length is captured BEFORE ToIndex
/// (`old_len`) so an index-coercion side effect that grows a length-tracking
/// view cannot legitimize an index that was out of bounds at validation time
/// (`idx >= old_len` -> RangeError); then RevalidateAtomicAccess re-checks
/// typed_array_is_oob (-> TypeError) and the fresh count (-> RangeError).
pub fn atomicsGetBufIndex(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    view: *core.Object,
    index_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !usize {
    const buffer = try object_ops.atomicsBufferObject(view);
    if (buffer.class_id != core.class.ids.shared_array_buffer and buffer.arrayBufferDetached()) return error.TypeError;
    const old_len = try core.object.typedArrayLength(ctx.runtime, view);
    const index = try toIndexForAtomics(ctx, output, global, index_value, caller_function, caller_frame);
    if (index >= old_len) return error.RangeError;
    try atomicsRevalidateIndex(ctx.runtime, view, index);
    return index;
}

/// Mirrors the js_atomics_op (quickjs.c:60628-60631) / js_atomics_store
/// post-coercion re-check: typed_array_is_oob (detached or shrunk-resizable)
/// -> TypeError, then the fresh count -> RangeError.
pub fn atomicsRevalidateIndex(rt: *core.JSRuntime, view: *core.Object, index: usize) !void {
    if (try core.object.typedArrayDetached(view) or try core.object.typedArrayOutOfBounds(view)) return error.TypeError;
    try atomicsValidateIndex(rt, view, index);
}

pub fn atomicsElementBytes(object: *core.Object, index: usize) ![]u8 {
    const buffer = try object_ops.atomicsBufferObject(object);
    if (buffer.arrayBufferDetached()) return error.TypeError;
    const offset = object.typedArrayByteOffset() + index * object.typedArrayElementSize();
    if (offset + object.typedArrayElementSize() > buffer.byteStorage().len) return error.RangeError;
    return buffer.byteStorage()[offset..][0..object.typedArrayElementSize()];
}

/// Seq-cst atomic element load (qjs js_atomics_op ATOMICS_OP_LOAD,
/// quickjs.c:60659-60669; js_atomics_wait's value probe is likewise an
/// atomic_load). Element pointers are naturally aligned: a typed array's
/// byteOffset is a multiple of the element size and the backing allocation is
/// at least 8-aligned.
pub fn atomicsReadBits(object: *core.Object, bytes: []const u8) u64 {
    return switch (object.typedArrayElementSize()) {
        1 => @atomicLoad(u8, &bytes[0], .seq_cst),
        2 => @atomicLoad(u16, @as(*const u16, @ptrCast(@alignCast(bytes.ptr))), .seq_cst),
        4 => @atomicLoad(u32, @as(*const u32, @ptrCast(@alignCast(bytes.ptr))), .seq_cst),
        8 => @atomicLoad(u64, @as(*const u64, @ptrCast(@alignCast(bytes.ptr))), .seq_cst),
        else => 0,
    };
}

/// Seq-cst atomic element store (qjs js_atomics_store, quickjs.c:60778-60790
/// atomic_store per width).
pub fn atomicsWriteBits(object: *core.Object, bytes: []u8, value: u64) void {
    switch (object.typedArrayElementSize()) {
        1 => @atomicStore(u8, &bytes[0], @truncate(value), .seq_cst),
        2 => @atomicStore(u16, @as(*u16, @ptrCast(@alignCast(bytes.ptr))), @truncate(value), .seq_cst),
        4 => @atomicStore(u32, @as(*u32, @ptrCast(@alignCast(bytes.ptr))), @truncate(value), .seq_cst),
        8 => @atomicStore(u64, @as(*u64, @ptrCast(@alignCast(bytes.ptr))), value, .seq_cst),
        else => {},
    }
}

/// Single-instruction atomic read-modify-write on one typed-array element,
/// mirroring qjs js_atomics_op's per-width `OP(...)` atomic builtins
/// (quickjs.c:60637-60656) plus the LOAD (60659-60669) and COMPARE_EXCHANGE
/// (60671-60697) arms. The pre-fix read/compute/write sequence lost concurrent
/// updates (two agents' Atomics.add could interleave), deadlocking the
/// multi-agent test262 wait protocols.
fn atomicsRmwTyped(
    comptime T: type,
    ptr: *T,
    atomic_op: AtomicsReadModifyOp,
    operand: u64,
    replacement: u64,
) u64 {
    const op_bits: T = @truncate(operand);
    return switch (atomic_op) {
        .load => @atomicLoad(T, ptr, .seq_cst),
        .add => @atomicRmw(T, ptr, .Add, op_bits, .seq_cst),
        .@"and" => @atomicRmw(T, ptr, .And, op_bits, .seq_cst),
        .@"or" => @atomicRmw(T, ptr, .Or, op_bits, .seq_cst),
        .sub => @atomicRmw(T, ptr, .Sub, op_bits, .seq_cst),
        .xor => @atomicRmw(T, ptr, .Xor, op_bits, .seq_cst),
        .exchange => @atomicRmw(T, ptr, .Xchg, op_bits, .seq_cst),
        // A successful cmpxchg returns null; the old value then equals the
        // expected operand (qjs returns `v1` unchanged on success, 60675).
        .compareExchange => @cmpxchgStrong(T, ptr, op_bits, @as(T, @truncate(replacement)), .seq_cst, .seq_cst) orelse op_bits,
    };
}

/// Width-dispatched atomic RMW; returns the previous element value
/// zero-extended to u64 (the same convention as `atomicsReadBits`).
pub fn atomicsReadModifyWriteBits(
    object: *core.Object,
    bytes: []u8,
    atomic_op: AtomicsReadModifyOp,
    operand: u64,
    replacement: u64,
) u64 {
    return switch (object.typedArrayElementSize()) {
        1 => atomicsRmwTyped(u8, &bytes[0], atomic_op, operand, replacement),
        2 => atomicsRmwTyped(u16, @ptrCast(@alignCast(bytes.ptr)), atomic_op, operand, replacement),
        4 => atomicsRmwTyped(u32, @ptrCast(@alignCast(bytes.ptr)), atomic_op, operand, replacement),
        8 => atomicsRmwTyped(u64, @ptrCast(@alignCast(bytes.ptr)), atomic_op, operand, replacement),
        else => 0,
    };
}

pub fn atomicsMaskBits(object: *core.Object, value: u64) u64 {
    return switch (object.typedArrayElementSize()) {
        1 => value & 0xff,
        2 => value & 0xffff,
        4 => value & 0xffff_ffff,
        else => value,
    };
}

pub fn atomicsValueFromBits(rt: *core.JSRuntime, object: *core.Object, bits: u64) !core.JSValue {
    return switch (object.typedArrayKind()) {
        1 => core.JSValue.int32(@as(i8, @bitCast(@as(u8, @truncate(bits))))),
        2 => core.JSValue.int32(@as(u8, @truncate(bits))),
        4 => core.JSValue.int32(@as(i16, @bitCast(@as(u16, @truncate(bits))))),
        5 => core.JSValue.int32(@as(u16, @truncate(bits))),
        6 => core.JSValue.int32(@as(i32, @bitCast(@as(u32, @truncate(bits))))),
        7 => atomicsNumberResult(@floatFromInt(@as(u32, @truncate(bits)))),
        11 => value_ops.createBigIntI128(rt, @as(i64, @bitCast(bits))),
        12 => value_ops.createBigIntI128(rt, @as(i128, bits)),
        else => error.TypeError,
    };
}

pub fn toIndexForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !usize {
    const number = try toNumberForAtomics(ctx, output, global, value, caller_function, caller_frame);
    if (std.math.isNan(number)) return 0;
    if (!std.math.isFinite(number)) return error.RangeError;
    const truncated = @trunc(number);
    if (truncated < 0) return error.RangeError;
    return @intFromFloat(truncated);
}

pub fn toNumberForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !f64 {
    _ = caller_function;
    _ = caller_frame;
    const primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, value);
    defer primitive.free(ctx.runtime);
    if (primitive.isBigInt()) return error.TypeError;
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    defer number_value.free(ctx.runtime);
    return value_ops.numberValue(number_value) orelse std.math.nan(f64);
}

pub fn toInt32ForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !i32 {
    const bits = try toUint32ForAtomics(ctx, output, global, value, caller_function, caller_frame);
    return @bitCast(@as(u32, @truncate(bits)));
}

pub fn toInt32BitsForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !u64 {
    const int_value = try toInt32ForAtomics(ctx, output, global, value, caller_function, caller_frame);
    return @as(u32, @bitCast(int_value));
}

pub fn toUint32ForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !u64 {
    const number = try toNumberForAtomics(ctx, output, global, value, caller_function, caller_frame);
    if (!std.math.isFinite(number) or std.math.isNan(number)) return 0;
    const two32 = 4294967296.0;
    var modulo = @mod(@trunc(number), two32);
    if (modulo < 0) modulo += two32;
    return @intFromFloat(modulo);
}

pub fn toIntegerValueForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const number = try toNumberForAtomics(ctx, output, global, value, caller_function, caller_frame);
    if (std.math.isNan(number) or number == 0) return core.JSValue.int32(0);
    if (!std.math.isFinite(number)) return core.JSValue.float64(number);
    return atomicsNumberResult(@trunc(number));
}

pub fn uint32FromIntegerValueForAtomics(rt: *core.JSRuntime, value: core.JSValue) !u64 {
    _ = rt;
    const number = value_ops.numberValue(value) orelse return 0;
    if (!std.math.isFinite(number) or std.math.isNan(number)) return 0;
    const two32 = 4294967296.0;
    var modulo = @mod(@trunc(number), two32);
    if (modulo < 0) modulo += two32;
    return @intFromFloat(modulo);
}

pub fn toBigIntValueForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = caller_function;
    _ = caller_frame;
    const primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, value);
    defer primitive.free(ctx.runtime);
    var big = try value_ops.toBigIntValue(ctx.runtime, primitive);
    defer big.deinit();
    return value_ops.createBigIntValue(ctx.runtime, big);
}

pub fn toBigIntBitsForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !u64 {
    const bigint_value = try toBigIntValueForAtomics(ctx, output, global, value, caller_function, caller_frame);
    defer bigint_value.free(ctx.runtime);
    return bigintBitsForAtomics(ctx.runtime, bigint_value);
}

pub fn atomicsNumberResult(value: f64) core.JSValue {
    if (std.math.isFinite(value) and @floor(value) == value and value >= @as(f64, @floatFromInt(std.math.minInt(i32))) and value <= @as(f64, @floatFromInt(std.math.maxInt(i32))) and !std.math.isNegativeZero(value)) {
        return core.JSValue.int32(@intFromFloat(value));
    }
    return core.JSValue.float64(value);
}

pub fn bigintBitsForAtomics(rt: *core.JSRuntime, value: core.JSValue) !u64 {
    var big = try value_ops.toBigIntValue(rt, value);
    defer big.deinit();
    var low: u64 = 0;
    if (big.limbs.len >= 1) low |= big.limbs[0];
    if (big.limbs.len >= 2) low |= @as(u64, big.limbs[1]) << 32;
    return if (big.negative) 0 -% low else low;
}

pub fn atomicsDestroyAsyncWaiter(waiter: *AtomicsWaiter) void {
    const ctx = waiter.realm.borrow().?;
    const rt = ctx.runtime;
    rt.assertOwnerThread();
    if (waiter.promise) |promise| promise.free(rt);
    atomicsReleaseWaiterKey(&waiter.key);
    waiter.realm.deinit();
    rt.memory.destroy(AtomicsWaiter, waiter);
}

pub fn atomicsDestroyAsyncWaiterOpaque(raw_waiter: *anyopaque) void {
    const waiter: *AtomicsWaiter = @ptrCast(@alignCast(raw_waiter));
    atomicsDestroyAsyncWaiter(waiter);
}

/// Run one owner-thread waitAsync completion. `drainOnePendingJob` reserves the
/// unlinked entry's queue slot before calling this function. Every failure is
/// before Promise publication and leaves that reservation untouched so the
/// typed completion can be restored at the FIFO head. Success consumes the
/// reservation with the follow-up Promise job as its final no-fail step.
pub fn atomicsRunAsyncWaiterCompletion(
    ctx: *core.JSContext,
    payload: *const jobs_mod.AtomicsWaiterPayload,
) core.errors.RuntimeError!void {
    const waiter: *AtomicsWaiter = @ptrCast(@alignCast(payload.waiter));
    std.debug.assert(waiter.realm.borrow() == ctx);
    ctx.runtime.assertOwnerThread();
    const promise = payload.promise;
    const promise_object = objectFromValue(promise) orelse return error.TypeError;
    if (promise_object.class_id != core.class.ids.promise) return error.TypeError;
    if (promise_object.promiseResultSlot().* != null) {
        ctx.runtime.job_queue.releaseUnlinkedEntrySlot();
        return;
    }
    const result = if (waiter.completion == .notified) "ok" else "timed-out";
    const result_value = try value_ops.createStringValue(ctx.runtime, result);
    var result_value_owned = true;
    errdefer if (result_value_owned) result_value.free(ctx.runtime);
    var prepared_job = jobs_mod.Job.initPromise(ctx, promise);
    var prepared_job_owned = true;
    errdefer if (prepared_job_owned) prepared_job.deinit();

    const result_slot = promise_object.promiseResultSlot();

    var reaction_arg_value: ?core.JSValue = null;
    errdefer if (reaction_arg_value) |value| value.free(ctx.runtime);
    const reaction_arg_slot = promise_object.promiseReactionArgSlot();
    const needs_reaction_arg = promise_object.promiseReactionCallback() != null and promise_object.promiseReactionArg() == null;
    if (needs_reaction_arg) {
        reaction_arg_value = result_value.dup();
    }

    if (promise_object.promiseReactionCallback() != null) {
        // A .then/await already installed the lazy single reaction callback.
        // Leave the promise result unset: settlePendingPromiseReaction runs that
        // callback and then fires this promise's reaction list (which settles the
        // chained .then promise). Pre-setting the result here would make that
        // drain early-return (promiseResult != null) and drop the chain after the
        // first reaction. The callback receives the settle value via the reaction
        // arg below; free the now-unused result_value.
        result_value.free(ctx.runtime);
        result_value_owned = false;
    } else {
        const old_result = result_slot.*;
        result_slot.* = result_value;
        result_value_owned = false;
        promise_object.promiseIsRejectedSlot().* = false;
        if (old_result) |stored| stored.free(ctx.runtime);
    }
    if (reaction_arg_value) |value| {
        const old_reaction_arg = reaction_arg_slot.*;
        reaction_arg_slot.* = value;
        reaction_arg_value = null;
        if (old_reaction_arg) |stored| stored.free(ctx.runtime);
    }
    ctx.runtime.job_queue.enqueueUnlinkedEntrySlot(prepared_job);
    prepared_job_owned = false;
}

pub fn atomicsWaitAsync(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const view_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const view = try atomicsTypedArray(view_value, true);
    if ((try atomicsBufferObject(view)).class_id != core.class.ids.shared_array_buffer) return error.TypeError;
    const index_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const index = try atomicsValidateAccess(ctx, output, global, view, index_value, caller_function, caller_frame);
    const expected_arg = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
    const expected = if (atomicsTypedArrayIsBigInt(view))
        try toBigIntBitsForAtomics(ctx, output, global, expected_arg, caller_function, caller_frame)
    else
        try toInt32BitsForAtomics(ctx, output, global, expected_arg, caller_function, caller_frame);
    const timeout_arg = if (args.len >= 4) args[3] else core.JSValue.float64(std.math.nan(f64));
    const timeout = try toNumberForAtomics(ctx, output, global, timeout_arg, caller_function, caller_frame);
    try atomicsValidateIndex(ctx.runtime, view, index);
    const bytes = try atomicsElementBytes(view, index);
    const current = atomicsReadBits(view, bytes);
    if (current != atomicsMaskBits(view, expected)) {
        const result = try value_ops.createStringValue(ctx.runtime, "not-equal");
        defer result.free(ctx.runtime);
        return atomicsWaitAsyncResult(ctx, false, result);
    }
    if (timeout <= 0 and !std.math.isNan(timeout)) {
        const result = try value_ops.createStringValue(ctx.runtime, "timed-out");
        defer result.free(ctx.runtime);
        return atomicsWaitAsyncResult(ctx, false, result);
    }

    const promise = try core.promise.constructWithPrototype(ctx, promisePrototypeFromGlobal(ctx.runtime, global));
    defer promise.free(ctx.runtime);
    if (objectFromValue(promise)) |promise_object| {
        promise_object.promiseAtomicsWaitAsyncSlot().* = true;
    }
    const deadline = if (atomicsWaitTimeoutMilliseconds(timeout)) |timeout_ms|
        std.Io.Timestamp.now(atomicsWaiterIo(), .awake).addDuration(std.Io.Duration.fromMilliseconds(timeout_ms))
    else
        null;
    const key = try atomicsWaiterKey(view, bytes);
    const waiter = try ctx.runtime.memory.create(AtomicsWaiter);
    atomicsRetainWaiterKey(key);
    waiter.* = .{
        .key = key,
        .promise = promise.dup(),
        .realm = core.RealmRef.retain(ctx),
        .deadline = deadline,
    };
    var waiter_owned = true;
    errdefer if (waiter_owned) atomicsDestroyAsyncWaiter(waiter);

    // The result wrapper is observable publication of this wait. Finish every
    // fallible allocation before linking the node into the cross-runtime
    // waiter registry; otherwise an OOM here leaves an unreachable Promise and
    // RealmRef behind until context teardown.
    const result = try atomicsWaitAsyncResult(ctx, true, promise);
    atomicsLinkAsyncWaiter(waiter);
    waiter_owned = false;
    return result;
}

pub fn atomicsLinkAsyncWaiter(waiter: *AtomicsWaiter) void {
    const ctx = waiter.realm.borrow().?;
    ctx.runtime.assertOwnerThread();
    if (comptime core.runtime.value_root_frames_enabled) installWaitAsyncRootAdapter();
    const io = atomicsWaiterIo();
    atomics_ops.atomics_waiter_mutex.lockUncancelable(io);
    defer atomics_ops.atomics_waiter_mutex.unlock(io);
    atomicsLinkWaiter(waiter);
}

fn installWaitAsyncRootAdapter() void {
    if (comptime !core.runtime.value_root_frames_enabled) return;
    if (core.runtime.trace_atomics_wait_async != null) return;
    core.runtime.trace_atomics_wait_async = traceWaitAsyncRoots;
}

fn traceWaitAsyncRoots(rt_opaque: *anyopaque, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
    const rt: *core.JSRuntime = @ptrCast(@alignCast(rt_opaque));
    const io = atomicsWaiterIo();
    var storage: [16]core.JSValue = undefined;

    atomics_ops.atomics_waiter_mutex.lockUncancelable(io);
    var count: usize = 0;
    var cursor = atomics_ops.atomics_waiters;
    while (cursor) |waiter| : (cursor = waiter.next) {
        if (atomicsAsyncWaiterRuntime(waiter) == rt and waiter.promise != null) count += 1;
    }
    atomics_ops.atomics_waiter_mutex.unlock(io);
    if (count == 0) return;

    const extra: []core.JSValue = if (count > storage.len)
        try rt.memory.alloc(core.JSValue, count)
    else
        &.{};
    defer if (extra.len != 0) rt.memory.free(core.JSValue, extra);
    const buf = if (extra.len != 0) extra else storage[0..count];

    atomics_ops.atomics_waiter_mutex.lockUncancelable(io);
    var filled: usize = 0;
    cursor = atomics_ops.atomics_waiters;
    while (cursor) |waiter| : (cursor = waiter.next) {
        if (atomicsAsyncWaiterRuntime(waiter) != rt) continue;
        const promise = waiter.promise orelse continue;
        if (filled == buf.len) break;
        buf[filled] = promise.dup();
        filled += 1;
    }
    atomics_ops.atomics_waiter_mutex.unlock(io);

    defer for (buf[0..filled]) |promise| promise.free(rt);
    for (buf[0..filled]) |*promise| try visitor.value(promise);
}

pub fn atomicsWaitAsyncResult(ctx: *core.JSContext, is_async: bool, value: core.JSValue) !core.JSValue {
    var rooted_value = value;
    var root_frame = core.runtime.rootValues(.{&rooted_value});
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    const result = try core.Object.create(ctx.runtime, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &result.header);
    try defineValueProperty(ctx.runtime, result, "async", core.JSValue.boolean(is_async));
    try defineValueProperty(ctx.runtime, result, "value", rooted_value);
    return result.value();
}

test "atomicsWaitAsyncResult roots direct function bytecode value while creating result object" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const fb = try bytecode.FunctionBytecode.createFixture(rt, .{ .cpool_count = 1 });
    var fb_published = false;
    errdefer if (!fb_published) fb.destroyUnpublishedFixture(rt);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-atomics-wait-async-result-bytecode-symbol");
    fb.cpoolSlice()[0] = try rt.symbolValue(symbol_atom);
    fb.publishFixtureNoFail(rt);
    fb_published = true;

    var result_payload = core.JSValue.functionBytecode(&fb.header);
    var payload_alive = true;
    defer if (payload_alive) result_payload.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const result_value = try atomicsWaitAsyncResult(ctx, true, result_payload);
    var result_alive = true;
    defer if (result_alive) result_value.free(rt);
    const result = objectFromValue(result_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const value_key = try rt.internAtom("value");
    defer rt.atoms.free(value_key);
    {
        const stored = try result.getProperty(value_key);
        defer stored.free(rt);
        try std.testing.expect(stored.same(result_payload));
    }

    result_value.free(rt);
    result_alive = false;
    result_payload.free(rt);
    payload_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn atomicsWaitAsyncPromise(rt: *core.JSRuntime, promise: *core.Object) bool {
    _ = rt;
    return promise.promiseAtomicsWaitAsync();
}
