//! The Atomics domain: namespace registration, typed memory operations, and
//! synchronous/Promise-backed waiter lifecycle.
//!
//! The bodies lived in `call_runtime.zig` until 2026-08-20 (backlog H1): a
//! thousand lines of a self-contained domain -- waiter registry, typed
//! read-modify-write, the `*ForAtomics` coercions -- in the file that owns the
//! call chain. Method IDs, wait primitives, and the waitAsync Promise
//! lifecycle live with their handlers here.

const std = @import("std");
const core = @import("../core/root.zig");
const jobs_mod = core.jobs;
const builtin_dispatch = @import("builtin_dispatch.zig");
const exception_ops = @import("exception_ops.zig");
const bytecode = @import("../bytecode.zig");
const object_ops = @import("object_ops.zig");
const promise_ops = @import("promise_ops.zig");
const value_ops = @import("value_ops.zig");
const HostError = exception_ops.HostError;
const defineValueProperty = object_ops.defineValueProperty;
const objectFromValue = object_ops.objectFromValue;
const promisePrototypeFromGlobal = promise_ops.promisePrototypeFromGlobal;

pub const StaticMethod = enum(u32) {
    add = 1,
    @"and" = 2,
    compare_exchange = 3,
    exchange = 4,
    is_lock_free = 5,
    load = 6,
    notify = 7,
    @"or" = 8,
    pause = 9,
    store = 10,
    sub = 11,
    wait = 12,
    wait_async = 13,
    xor = 14,
};

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
    );
}

const AtomicsReadModifyOp = enum {
    add,
    @"and",
    compareExchange,
    exchange,
    load,
    @"or",
    sub,
    xor,
};

const AtomicsWaiterKey = struct {
    store: ?*core.object.SharedBufferStore = null,
    offset_or_ptr: usize,
};

const AtomicsWaiterCompletion = enum {
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

var atomics_waiter_mutex: std.Io.Mutex = .init;
var atomics_waiters: ?*AtomicsWaiter = null;

fn atomicsCallForNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    id: u32,
    args: []const core.JSValue,
) !core.JSValue {
    return switch (std.enums.fromInt(StaticMethod, id) orelse return error.TypeError) {
        .is_lock_free => try atomicsIsLockFree(ctx, output, global, args),
        .pause => try atomicsPause(ctx, output, global, args),
        .notify => try atomicsNotify(ctx, output, global, args),
        .wait => try atomicsWait(ctx, output, global, args),
        .wait_async => try atomicsWaitAsync(ctx, output, global, args),
        .store => try atomicsStore(ctx, output, global, args),
        .load => try atomicsReadModifyWrite(ctx, output, global, args, .load),
        .add => try atomicsReadModifyWrite(ctx, output, global, args, .add),
        .@"and" => try atomicsReadModifyWrite(ctx, output, global, args, .@"and"),
        .@"or" => try atomicsReadModifyWrite(ctx, output, global, args, .@"or"),
        .sub => try atomicsReadModifyWrite(ctx, output, global, args, .sub),
        .xor => try atomicsReadModifyWrite(ctx, output, global, args, .xor),
        .exchange => try atomicsReadModifyWrite(ctx, output, global, args, .exchange),
        .compare_exchange => try atomicsReadModifyWrite(ctx, output, global, args, .compareExchange),
    };
}

fn atomicsIsLockFree(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    const size_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    // ToIntegerOrInfinity, not ToInt32: 2^32 + 4 is not a lock-free size.
    const size = @trunc(try toNumberForAtomics(ctx, output, global, size_value));
    return core.JSValue.boolean(size == 1 or size == 2 or size == 4 or size == 8);
}

fn atomicsPause(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    _ = output;
    if (args.len >= 1 and !args[0].is(.undefined_value)) {
        const number = value_ops.numberValue(args[0]) orelse return throwAtomicsTypeError(ctx, global, "not an integral number");
        if (!std.math.isFinite(number) or @trunc(number) != number) return throwAtomicsTypeError(ctx, global, "not an integral number");
    }
    return core.JSValue.undefinedValue();
}

fn atomicsReadModifyWrite(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    atomic_op: AtomicsReadModifyOp,
) !core.JSValue {
    const view_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const view = try atomicsTypedArray(ctx, global, view_value, false);
    const index_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const index = try atomicsGetBufIndex(ctx, output, global, view, index_value);

    const is_bigint = view.typedArrayKind().isBigInt();
    const value_arg = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
    const replacement_arg = if (args.len >= 4) args[3] else core.JSValue.undefinedValue();
    const operand = if (atomic_op == .load) @as(u64, 0) else if (is_bigint)
        try toBigIntBitsForAtomics(ctx, output, global, value_arg)
    else
        try toUint32ForAtomics(ctx, output, global, value_arg);
    const replacement = if (atomic_op == .compareExchange) blk: {
        break :blk if (is_bigint)
            try toBigIntBitsForAtomics(ctx, output, global, replacement_arg)
        else
            try toUint32ForAtomics(ctx, output, global, replacement_arg);
    } else @as(u64, 0);
    // js_atomics_op: LOAD coerces no operand, so qjs skips
    // the post-coercion re-check for it; every other op re-validates after
    // the operand conversions ran user code.
    if (atomic_op != .load) try atomicsRevalidateIndex(ctx.runtime, view, index);

    const bytes = try atomicsElementBytes(view, index);
    // One atomic instruction per op (qjs js_atomics_op, quickjs.c);
    // a plain read/compute/write here loses concurrent RMW updates.
    const old = atomicsReadModifyWriteBits(view, bytes, atomic_op, operand, replacement);
    return atomicsValueFromBits(ctx.runtime, view, old);
}

fn atomicsStore(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    const view_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const view = try atomicsTypedArray(ctx, global, view_value, false);
    const index_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const index = try atomicsGetBufIndex(ctx, output, global, view, index_value);

    const value_arg = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
    const is_bigint = view.typedArrayKind().isBigInt();
    const stored_value = if (is_bigint)
        try toBigIntValueForAtomics(ctx, output, global, value_arg)
    else
        try toIntegerValueForAtomics(ctx, output, global, value_arg);
    const bits = if (is_bigint)
        try bigintBitsForAtomics(ctx.runtime, stored_value)
    else
        uint32FromIntegerValueForAtomics(stored_value);
    // Mirrors js_atomics_store: re-check
    // typed_array_is_oob (TypeError) then the fresh count (RangeError) after
    // the value coercion ran user code.
    try atomicsRevalidateIndex(ctx.runtime, view, index);
    const bytes = try atomicsElementBytes(view, index);
    atomicsWriteBits(view, bytes, bits);
    return stored_value;
}

fn atomicsNotify(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    const view_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const view = try atomicsTypedArray(ctx, global, view_value, true);
    const buffer = try object_ops.atomicsBufferObject(view);
    const index_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const index = try atomicsValidateAccess(ctx, output, global, view, index_value);
    const count = try atomicsNotifyCount(ctx, output, global, args);
    if (buffer.class_id != core.class.ids.shared_array_buffer or count == 0) return core.JSValue.int32(0);
    try atomicsValidateIndex(ctx.runtime, view, index);
    const bytes = try atomicsElementBytes(view, index);
    const key = try atomicsWaiterKey(view, bytes);
    return core.JSValue.int32(@intCast(atomicsWakeWaiters(key, count)));
}

fn atomicsWait(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    const view_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const view = try atomicsTypedArray(ctx, global, view_value, true);
    if ((try object_ops.atomicsBufferObject(view)).class_id != core.class.ids.shared_array_buffer) return throwAtomicsTypeError(ctx, global, "not a SharedArrayBuffer TypedArray");
    const index_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const index = try atomicsValidateAccess(ctx, output, global, view, index_value);
    const expected_arg = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
    const expected = if (view.typedArrayKind().isBigInt())
        try toBigIntBitsForAtomics(ctx, output, global, expected_arg)
    else
        try toUint32ForAtomics(ctx, output, global, expected_arg);
    const timeout_arg = if (args.len >= 4) args[3] else core.JSValue.float64(std.math.inf(f64));
    const timeout = try toNumberForAtomics(ctx, output, global, timeout_arg);
    // Mirrors js_atomics_wait: the can-block check
    // runs after the operand coercions but BEFORE the memory load/compare, so
    // a non-blockable thread throws TypeError instead of returning
    // "not-equal".
    if (!ctx.runtime.host_wait.can_block) return exception_ops.throwTypeErrorMessage(ctx, global, "cannot block in this thread");
    try atomicsValidateIndex(ctx.runtime, view, index);
    const bytes = try atomicsElementBytes(view, index);
    const current = atomicsReadBits(view, bytes);
    if (current != atomicsMaskBits(view, expected)) return value_ops.createStringValue(ctx.runtime, "not-equal");
    const wait_ms = atomicsWaitTimeoutMilliseconds(timeout);
    if (wait_ms == 0) return value_ops.createStringValue(ctx.runtime, "timed-out");
    const key = try atomicsWaiterKey(view, bytes);
    return atomicsWaitForNotification(ctx.runtime, key, wait_ms);
}

fn atomicsNotifyCount(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !usize {
    if (args.len < 3 or args[2].is(.undefined_value)) return std.math.maxInt(usize);
    const count_value = try toIntegerValueForAtomics(ctx, output, global, args[2]);
    // toIntegerValueForAtomics yields a non-NaN number.
    const count_number = value_ops.numberValue(count_value).?;
    if (count_number <= 0) return 0;
    if (!std.math.isFinite(count_number)) return std.math.maxInt(usize);
    return @intFromFloat(@min(count_number, @as(f64, @floatFromInt(std.math.maxInt(i32)))));
}

/// DoWait steps 7-8: NaN and +Infinity wait forever; -Infinity and negative
/// timeouts do not wait. Saturates at the largest i64 milliseconds.
fn atomicsWaitTimeoutMilliseconds(timeout: f64) ?i64 {
    if (std.math.isNan(timeout) or timeout == std.math.inf(f64)) return null;
    if (timeout <= 0) return 0;
    // maxInt(i64) is not representable in f64; 0x1p63 is the first f64 past it.
    if (timeout >= 0x1p63) return std.math.maxInt(i64);
    return @intFromFloat(timeout);
}

fn atomicsWaiterKey(view: *core.Object, bytes: []const u8) !AtomicsWaiterKey {
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

fn atomicsWaiterKeysEqual(a: AtomicsWaiterKey, b: AtomicsWaiterKey) bool {
    return a.store == b.store and a.offset_or_ptr == b.offset_or_ptr;
}

fn atomicsRetainWaiterKey(key: AtomicsWaiterKey) void {
    if (key.store) |store| store.retain();
}

fn atomicsReleaseWaiterKey(key: *AtomicsWaiterKey) void {
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
                waiter_ctx.runtime.host_wait.signal(io);
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
    ctx.runtime.roots.assertMutable();
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
        const waiter_ctx = waiter.realm.borrow().?;
        waiter_ctx.runtime.job_queue.enqueueAtomicsWaiter(
            waiter_ctx,
            waiter,
            &waiter.promise.?,
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

    rt.host_wait.reset();
    atomics_waiter_mutex.unlock(io);
    if (deadline) |limit| {
        _ = rt.host_wait.waitUntil(io, limit);
    } else {
        rt.host_wait.wait(io);
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
    removeAsyncWaiters(ctx.runtime, .{ .context = ctx });
}

/// Runtime teardown: unlink and free every waitAsync node of `rt`, whatever
/// realm issued it. Child realms (`createRealm`) have no host Context whose
/// `deinit` would remove their waiters, and a node left in the process-wide
/// list would point into the destroyed Runtime.
pub fn retireAtomicsWaitersForRuntime(rt: *core.JSRuntime) void {
    if (!rt.execution.wait_async_used) return;
    removeAsyncWaiters(rt, .runtime);
}

const AsyncWaiterOwner = union(enum) {
    context: *core.JSContext,
    runtime,
};

fn removeAsyncWaiters(rt: *core.JSRuntime, owner: AsyncWaiterOwner) void {
    rt.assertOwnerThread();
    rt.roots.assertMutable();
    const io = atomicsWaiterIo();
    while (true) {
        atomics_waiter_mutex.lockUncancelable(io);
        var removed: ?*AtomicsWaiter = null;
        var previous: ?*AtomicsWaiter = null;
        var cursor = atomics_waiters;
        while (cursor) |waiter| : (cursor = waiter.next) {
            const owned = switch (owner) {
                .context => |ctx| waiter.realm.borrow() == ctx,
                .runtime => atomicsAsyncWaiterRuntime(waiter) == rt,
            };
            if (!owned) {
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
        atomicsDestroyAsyncWaiter(waiter);
    }
}

fn atomicsWaitForNotification(rt: *core.JSRuntime, key: AtomicsWaiterKey, timeout_ms: ?i64) !core.JSValue {
    rt.assertOwnerThread();
    atomicsRetainWaiterKey(key);
    var retained_key = key;
    defer atomicsReleaseWaiterKey(&retained_key);

    var waiter = AtomicsWaiter{ .key = retained_key };
    const io = atomicsWaiterIo();
    atomics_waiter_mutex.lockUncancelable(io);
    atomicsLinkWaiter(&waiter);

    // Waits in 1 ms slices so the interrupt handler and terminateExecution
    // are observed while blocked (contract C8); a notification is seen at
    // the next slice.
    const deadline: ?std.Io.Timestamp = if (timeout_ms) |ms|
        std.Io.Timestamp.now(io, .awake).addDuration(std.Io.Duration.fromMilliseconds(ms))
    else
        null;
    while (waiter.completion == .waiting) {
        if (deadline) |limit| {
            if (std.Io.Timestamp.now(io, .awake).nanoseconds >= limit.nanoseconds) break;
        }
        atomics_waiter_mutex.unlock(io);
        const interrupted = rt.interrupt.poll();
        if (!interrupted) std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
        atomics_waiter_mutex.lockUncancelable(io);
        if (interrupted and waiter.completion == .waiting) {
            atomicsUnlinkWaiter(&waiter);
            atomics_waiter_mutex.unlock(io);
            return error.Interrupted;
        }
    }
    const was_notified = waiter.completion == .notified;
    atomicsUnlinkWaiter(&waiter);
    atomics_waiter_mutex.unlock(io);
    // String creation can allocate and collect; the waiter registry lock is
    // deliberately released before entering the Runtime heap.
    return value_ops.createStringValue(rt, if (was_notified) "ok" else "timed-out");
}

fn atomicsLinkWaiter(waiter: *AtomicsWaiter) void {
    if (atomicsAsyncWaiterRuntime(waiter)) |rt| {
        rt.assertOwnerThread();
        rt.roots.assertMutable();
    }
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

fn atomicsUnlinkWaiter(waiter: *AtomicsWaiter) void {
    if (atomicsAsyncWaiterRuntime(waiter)) |rt| {
        rt.assertOwnerThread();
        rt.roots.assertMutable();
    }
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

test "Atomics wait timeout follows DoWait and saturates" {
    try std.testing.expectEqual(@as(?i64, null), atomicsWaitTimeoutMilliseconds(std.math.nan(f64)));
    try std.testing.expectEqual(@as(?i64, null), atomicsWaitTimeoutMilliseconds(std.math.inf(f64)));
    try std.testing.expectEqual(@as(?i64, 0), atomicsWaitTimeoutMilliseconds(-std.math.inf(f64)));
    try std.testing.expectEqual(@as(?i64, 0), atomicsWaitTimeoutMilliseconds(-1));
    try std.testing.expectEqual(@as(?i64, 5), atomicsWaitTimeoutMilliseconds(5.9));
    try std.testing.expectEqual(@as(?i64, std.math.maxInt(i64)), atomicsWaitTimeoutMilliseconds(1e300));
}

test "foreign Atomics notify only publishes a no-allocation completion" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    const key = AtomicsWaiterKey{ .offset_or_ptr = @intFromPtr(ctx) };
    const waiter = try rt.nativeAllocator().create(AtomicsWaiter);
    waiter.* = .{
        .key = key,
        .promise = core.JSValue.int32(73),
        .realm = core.RealmRef.retain(ctx),
    };
    atomicsLinkAsyncWaiter(waiter);
    var waiter_live = true;
    defer if (waiter_live) cleanupAtomicsWaitersForContext(ctx);

    const Attempt = struct {
        key: AtomicsWaiterKey,
        woken: usize = 0,

        fn run(self: *@This()) void {
            self.woken = atomicsWakeWaiters(self.key, 1);
        }
    };
    const memory_before = rt.allocation_diagnostics.allocated_bytes;
    var attempt = Attempt{ .key = key };
    const thread = try std.Thread.spawn(.{}, Attempt.run, .{&attempt});
    thread.join();

    try std.testing.expectEqual(@as(usize, 1), attempt.woken);
    try std.testing.expectEqual(memory_before, rt.allocation_diagnostics.allocated_bytes);
    try std.testing.expect(waiter.linked);
    try std.testing.expectEqual(AtomicsWaiterCompletion.notified, waiter.completion);
    try std.testing.expectEqual(@as(?i32, 73), waiter.promise.?.as(.int));
    try std.testing.expectEqual(ctx, waiter.realm.borrow().?);

    cleanupAtomicsWaitersForContext(ctx);
    waiter_live = false;
}

test "waitAsync finite deadline is driven by the owner host clock queue" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const promise = try core.Object.create(rt, core.class.ids.promise, null);

    const io = atomicsWaiterIo();
    const waiter = try rt.nativeAllocator().create(AtomicsWaiter);
    waiter.* = .{
        .key = .{ .offset_or_ptr = @intFromPtr(promise) },
        .promise = promise.value(),
        .realm = core.RealmRef.retain(ctx),
        .deadline = std.Io.Timestamp.now(io, .awake).addDuration(std.Io.Duration.fromMilliseconds(1)),
    };
    atomicsLinkAsyncWaiter(waiter);
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
    const rt = try core.JSRuntime.create(failing_allocator.allocator(), .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;
    const promise = try core.Object.create(rt, core.class.ids.promise, null);

    const key = AtomicsWaiterKey{ .offset_or_ptr = @intFromPtr(promise) };
    const waiter = try rt.nativeAllocator().create(AtomicsWaiter);
    waiter.* = .{
        .key = key,
        .completion = .notified,
        .promise = promise.value(),
        .realm = core.RealmRef.retain(ctx),
    };
    atomicsLinkAsyncWaiter(waiter);
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
    const saved_trigger = rt.gc.heap_budget.installProbe(.{ .run = Probe.trigger, .context = &probe });
    defer rt.gc.heap_budget.restoreProbe(saved_trigger);
    // Fill the first 4-job window (320 bytes with 8-byte JSValue) so
    // settlement growth is 8 jobs / 640 bytes and misses the small-object
    // slab. A warm 320-class pop never reaches the backing allocator, so
    // fail_index would not fire on an empty queue.
    var filler: usize = 0;
    while (filler < 4) : (filler += 1) {
        try rt.job_queue.enqueuePromise(ctx, core.JSValue.int32(@intCast(filler)));
    }
    // Fail in the backing allocator, after the runtime allocator has invoked
    // the GC trigger. A hard runtime allocation limit is rejected before that trigger and
    // therefore cannot prove that the allocation site is outside the mutex.
    failing_allocator.fail_index = failing_allocator.alloc_index;

    try std.testing.expectError(error.OutOfMemory, processExpiredAtomicsWaiters(ctx));
    try std.testing.expect(probe.mutex_was_free);
    try std.testing.expect(waiter.linked);
    try std.testing.expectEqual(AtomicsWaiterCompletion.notified, waiter.completion);
    try std.testing.expectEqual(ctx, waiter.realm.borrow().?);
    try std.testing.expect(promise.promiseResult() == null);

    failing_allocator.fail_index = std.math.maxInt(usize);
    rt.gc.heap_budget.restoreProbe(saved_trigger);
    try processExpiredAtomicsWaiters(ctx);
    while (rt.job_queue.jobs.len > 1) {
        var filler_job = rt.job_queue.takeFirst().?;
        filler_job.deinit();
    }
    waiter_live = false;
    try std.testing.expect(promise.promiseResult() == null);
    try std.testing.expect((try promise_ops.drainOnePendingJob(ctx, null)) == .success);
    try std.testing.expect(promise.promiseResult() != null);
    try std.testing.expect(!promise.promiseIsRejected());
}

fn atomicsWaiterIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn atomicsValidateAccess(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    index_value: core.JSValue,
) !usize {
    const length = try core.object.typedArrayLength(ctx.runtime, object);
    const index = try toIndexForAtomics(ctx, output, global, index_value);
    if (index >= length) {
        _ = try exception_ops.throwRangeErrorMessage(ctx, global, "out-of-bound access");
        unreachable;
    }
    return index;
}

fn atomicsValidateIndex(rt: *core.JSRuntime, object: *core.Object, index: usize) !void {
    const length = try core.object.typedArrayLength(rt, object);
    if (index >= length) return error.InvalidArrayIndex;
}

/// Mirrors js_atomics_get_buf for the non-waitable Atomics
/// ops (is_waitable == 0): the caller's atomicsTypedArray already threw
/// TypeError for a detached buffer BEFORE ToIndex; the view length is captured BEFORE ToIndex
/// (`old_len`) so an index-coercion side effect that grows a length-tracking
/// view cannot legitimize an index that was out of bounds at validation time
/// (`idx >= old_len` -> RangeError); then RevalidateAtomicAccess re-checks
/// typed_array_is_oob (-> TypeError) and the fresh count (-> RangeError).
fn atomicsGetBufIndex(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    view: *core.Object,
    index_value: core.JSValue,
) !usize {
    const old_len = try core.object.typedArrayLength(ctx.runtime, view);
    const index = try toIndexForAtomics(ctx, output, global, index_value);
    if (index >= old_len) {
        _ = try exception_ops.throwRangeErrorMessage(ctx, global, "out-of-bound access");
        unreachable;
    }
    try atomicsRevalidateIndex(ctx.runtime, view, index);
    return index;
}

/// Mirrors the js_atomics_op / js_atomics_store
/// post-coercion re-check: typed_array_is_oob (detached or shrunk-resizable)
/// -> TypeError, then the fresh count -> RangeError.
fn atomicsRevalidateIndex(rt: *core.JSRuntime, view: *core.Object, index: usize) !void {
    if (try core.object.typedArrayDetached(view) or try core.object.typedArrayOutOfBounds(view)) return error.TypedArrayOutOfBounds;
    try atomicsValidateIndex(rt, view, index);
}

fn atomicsElementBytes(object: *core.Object, index: usize) ![]u8 {
    const buffer = try object_ops.atomicsBufferObject(object);
    if (buffer.arrayBufferDetached()) return error.TypeError;
    const offset = object.typedArrayByteOffset() + index * object.typedArrayElementSize();
    if (offset + object.typedArrayElementSize() > buffer.byteStorage().len) return error.RangeError;
    return buffer.byteStorage()[offset..][0..object.typedArrayElementSize()];
}

/// Seq-cst atomic element load (qjs js_atomics_op ATOMICS_OP_LOAD,
/// quickjs.c; js_atomics_wait's value probe is likewise an
/// atomic_load). Element pointers are naturally aligned: a typed array's
/// byteOffset is a multiple of the element size and the backing allocation is
/// at least 8-aligned.
fn atomicsReadBits(object: *core.Object, bytes: []const u8) u64 {
    return switch (object.typedArrayElementSize()) {
        1 => @atomicLoad(u8, &bytes[0], .seq_cst),
        2 => @atomicLoad(u16, @as(*const u16, @ptrCast(@alignCast(bytes.ptr))), .seq_cst),
        4 => @atomicLoad(u32, @as(*const u32, @ptrCast(@alignCast(bytes.ptr))), .seq_cst),
        8 => @atomicLoad(u64, @as(*const u64, @ptrCast(@alignCast(bytes.ptr))), .seq_cst),
        else => 0,
    };
}

/// Seq-cst atomic element store (qjs js_atomics_store, quickjs.c
/// atomic_store per width).
fn atomicsWriteBits(object: *core.Object, bytes: []u8, value: u64) void {
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
/// plus the LOAD and COMPARE_EXCHANGE arms. Each op is one atomic builtin so
/// concurrent agents' updates cannot interleave.
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
        // expected operand (qjs returns `v1` unchanged on success).
        .compareExchange => @cmpxchgStrong(T, ptr, op_bits, @as(T, @truncate(replacement)), .seq_cst, .seq_cst) orelse op_bits,
    };
}

/// Width-dispatched atomic RMW; returns the previous element value
/// zero-extended to u64 (the same convention as `atomicsReadBits`).
fn atomicsReadModifyWriteBits(
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

fn atomicsMaskBits(object: *core.Object, value: u64) u64 {
    return switch (object.typedArrayElementSize()) {
        1 => value & 0xff,
        2 => value & 0xffff,
        4 => value & 0xffff_ffff,
        else => value,
    };
}

fn atomicsValueFromBits(rt: *core.JSRuntime, object: *core.Object, bits: u64) !core.JSValue {
    return switch (object.typedArrayKind()) {
        .int8 => core.JSValue.int32(@as(i8, @bitCast(@as(u8, @truncate(bits))))),
        .uint8 => core.JSValue.int32(@as(u8, @truncate(bits))),
        .int16 => core.JSValue.int32(@as(i16, @bitCast(@as(u16, @truncate(bits))))),
        .uint16 => core.JSValue.int32(@as(u16, @truncate(bits))),
        .int32 => core.JSValue.int32(@as(i32, @bitCast(@as(u32, @truncate(bits))))),
        .uint32 => value_ops.numberToValue(@floatFromInt(@as(u32, @truncate(bits)))),
        .bigint64 => value_ops.createBigIntI128(rt, @as(i64, @bitCast(bits))),
        .biguint64 => value_ops.createBigIntI128(rt, @as(i128, bits)),
        else => error.TypeError,
    };
}

fn toIndexForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !usize {
    const number = try toNumberForAtomics(ctx, output, global, value);
    if (std.math.isNan(number)) return 0;
    const truncated = @trunc(number);
    // ToIndex: RangeError outside [0, 2^53 - 1]; this also bounds the cast.
    if (!(truncated >= 0 and truncated <= std.math.maxInt(u53))) {
        _ = try exception_ops.throwRangeErrorMessage(ctx, global, "invalid array index");
        unreachable;
    }
    return @intFromFloat(truncated);
}

/// Install a TypeError with `message` and return the error to propagate.
fn throwAtomicsTypeError(ctx: *core.JSContext, global: *core.Object, message: []const u8) HostError {
    _ = try exception_ops.throwTypeErrorMessage(ctx, global, message);
    unreachable;
}

/// ValidateIntegerTypedArray (25.4.3.1), plus the waitable restriction to
/// Int32Array / BigInt64Array.
fn atomicsTypedArray(ctx: *core.JSContext, global: *core.Object, value: core.JSValue, waitable: bool) !*core.Object {
    const object = objectFromValue(value) orelse return throwAtomicsTypeError(ctx, global, "integer TypedArray expected");
    if (!core.object.isTypedArrayObject(object)) return throwAtomicsTypeError(ctx, global, "integer TypedArray expected");
    const kind = object.typedArrayKind();
    const ok = if (waitable)
        kind == .int32 or kind == .bigint64
    else
        (kind.isInteger() and kind != .uint8_clamped) or kind.isBigInt();
    if (!ok) return throwAtomicsTypeError(ctx, global, "integer TypedArray expected");
    // ValidateTypedArray step 4: out of bounds (or detached) is a TypeError
    // before the index is converted.
    if (try core.object.typedArrayDetached(object)) return throwAtomicsTypeError(ctx, global, "ArrayBuffer is detached");
    if (try core.object.typedArrayOutOfBounds(object)) return throwAtomicsTypeError(ctx, global, "TypedArray is out of bounds");
    return object;
}

fn toNumberForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !f64 {
    const primitive = try value_ops.toPrimitiveForNumber(ctx, output, global, value);
    if (primitive.isBigInt()) return throwAtomicsTypeError(ctx, global, "cannot convert bigint to number");
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    return value_ops.numberValue(number_value) orelse std.math.nan(f64);
}

fn toUint32ForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !u64 {
    return value_ops.toUint32Number(try toNumberForAtomics(ctx, output, global, value));
}

fn toIntegerValueForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !core.JSValue {
    const number = try toNumberForAtomics(ctx, output, global, value);
    if (std.math.isNan(number) or number == 0) return core.JSValue.int32(0);
    if (!std.math.isFinite(number)) return core.JSValue.float64(number);
    return value_ops.numberToValue(@trunc(number));
}

fn uint32FromIntegerValueForAtomics(value: core.JSValue) u64 {
    return value_ops.toUint32Number(value_ops.numberValue(value) orelse return 0);
}

fn toBigIntValueForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !core.JSValue {
    const primitive = try value_ops.toPrimitiveForNumber(ctx, output, global, value);
    var big = value_ops.toBigIntValue(ctx.runtime, primitive) catch |err| switch (err) {
        error.TypeError => return throwAtomicsTypeError(ctx, global, "cannot convert to BigInt"),
        else => return err,
    };
    defer big.deinit();
    return value_ops.createBigIntValue(ctx.runtime, big);
}

fn toBigIntBitsForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !u64 {
    const bigint_value = try toBigIntValueForAtomics(ctx, output, global, value);
    return bigintBitsForAtomics(ctx.runtime, bigint_value);
}

fn bigintBitsForAtomics(rt: *core.JSRuntime, value: core.JSValue) !u64 {
    var big = try value_ops.toBigIntValue(rt, value);
    defer big.deinit();
    // ToBigInt64/ToBigUint64: the value modulo 2^64 (limbs are 64-bit).
    const low: u64 = if (big.limbs.len != 0) big.limbs[0] else 0;
    return if (big.negative) 0 -% low else low;
}

fn atomicsDestroyAsyncWaiter(waiter: *AtomicsWaiter) void {
    const ctx = waiter.realm.borrow().?;
    const rt = ctx.runtime;
    rt.assertOwnerThread();
    rt.roots.assertMutable();
    atomicsReleaseWaiterKey(&waiter.key);
    waiter.realm.deinit();
    rt.nativeAllocator().destroy(waiter);
}

pub const destroyAsyncWaiter = atomicsDestroyAsyncWaiter;

/// Run one owner-thread waitAsync completion. `drainOnePendingJob` reserves the
/// unlinked entry's queue slot before calling this function. Every failure is
/// before Promise publication and leaves that reservation untouched so the
/// typed completion can be restored at the FIFO head. Success fulfills the
/// promise like any other (its reactions are queued) and releases the
/// reservation.
pub fn atomicsRunAsyncWaiterCompletion(
    ctx: *core.JSContext,
    payload: *const jobs_mod.AtomicsWaiterPayload,
) core.errors.RuntimeError!void {
    return runAsyncWaiterCompletionRooted(ctx, payload) catch |err| switch (err) {
        error.RootGenerationExhausted => error.OutOfMemory,
        error.RootAlreadyActive, error.RootMutationDuringCollection, error.WrongRuntime, error.InactiveRoot, error.InvalidRootIndex => std.debug.panic("waitAsync completion root contract: {s}", .{@errorName(err)}),
        else => |other| other,
    };
}

fn runAsyncWaiterCompletionRooted(ctx: *core.JSContext, payload: *const jobs_mod.AtomicsWaiterPayload) !void {
    const waiter: *AtomicsWaiter = @ptrCast(@alignCast(payload.waiter));
    std.debug.assert(waiter.realm.borrow() == ctx);
    ctx.runtime.assertOwnerThread();
    var roots = core.runtime.ExactValueRoots(2){};
    try roots.activate(ctx.runtime);
    defer roots.deactivate();
    const promise_root = try roots.ref(0);
    const result_root = try roots.ref(1);
    try promise_root.set(ctx.runtime, payload.promise);
    var promise_object = objectFromValue(try promise_root.get(ctx.runtime)) orelse return error.TypeError;
    if (promise_object.class_id != core.class.ids.promise) return error.TypeError;
    if (promise_object.promiseResultSlot().* != null) {
        ctx.runtime.job_queue.releaseUnlinkedEntrySlot();
        return;
    }
    const result = if (waiter.completion == .notified) "ok" else "timed-out";
    try result_root.set(ctx.runtime, try value_ops.createStringValue(ctx.runtime, result));
    // End the borrowed object view at string allocation, then derive it from
    // the collector-updated root before touching any Promise fields.
    promise_object = objectFromValue(try promise_root.get(ctx.runtime)) orelse return error.TypeError;
    try promise_ops.promiseSettleValue(ctx, promise_object, try result_root.get(ctx.runtime), false);
    ctx.runtime.job_queue.releaseUnlinkedEntrySlot();
}

fn atomicsWaitAsync(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    return waitAsyncRooted(ctx, output, global, args) catch |err| switch (err) {
        error.RootGenerationExhausted => error.OutOfMemory,
        error.RootAlreadyActive, error.RootMutationDuringCollection, error.WrongRuntime, error.InactiveRoot, error.InvalidRootIndex => std.debug.panic("waitAsync input root contract: {s}", .{@errorName(err)}),
        else => |other| other,
    };
}

fn waitAsyncRooted(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    const rt = ctx.runtime;
    var roots = core.runtime.ExactValueRoots(6){};
    try roots.activate(rt);
    defer roots.deactivate();
    const global_root = try roots.ref(0);
    const view_root = try roots.ref(1);
    const index_root = try roots.ref(2);
    const expected_root = try roots.ref(3);
    const timeout_root = try roots.ref(4);
    const promise_root = try roots.ref(5);
    try global_root.set(rt, global.value());
    try view_root.set(rt, if (args.len >= 1) args[0] else core.JSValue.undefinedValue());
    try index_root.set(rt, if (args.len >= 2) args[1] else core.JSValue.undefinedValue());
    try expected_root.set(rt, if (args.len >= 3) args[2] else core.JSValue.undefinedValue());
    try timeout_root.set(rt, if (args.len >= 4) args[3] else core.JSValue.float64(std.math.nan(f64)));
    var view = try atomicsTypedArray(ctx, objectFromValue(try global_root.get(rt)).?, try view_root.get(rt), true);
    if ((try object_ops.atomicsBufferObject(view)).class_id != core.class.ids.shared_array_buffer) return throwAtomicsTypeError(ctx, objectFromValue(try global_root.get(rt)).?, "not a SharedArrayBuffer TypedArray");
    const index = try atomicsValidateAccess(ctx, output, objectFromValue(try global_root.get(rt)).?, view, try index_root.get(rt));
    view = try atomicsTypedArray(ctx, objectFromValue(try global_root.get(rt)).?, try view_root.get(rt), true);
    const expected_arg = try expected_root.get(rt);
    const expected = if (view.typedArrayKind().isBigInt())
        try toBigIntBitsForAtomics(ctx, output, objectFromValue(try global_root.get(rt)).?, expected_arg)
    else
        try toUint32ForAtomics(ctx, output, objectFromValue(try global_root.get(rt)).?, expected_arg);
    const timeout = try toNumberForAtomics(ctx, output, objectFromValue(try global_root.get(rt)).?, try timeout_root.get(rt));
    view = try atomicsTypedArray(ctx, objectFromValue(try global_root.get(rt)).?, try view_root.get(rt), true);
    try atomicsValidateIndex(ctx.runtime, view, index);
    const bytes = try atomicsElementBytes(view, index);
    const current = atomicsReadBits(view, bytes);
    if (current != atomicsMaskBits(view, expected)) {
        const result = try value_ops.createStringValue(ctx.runtime, "not-equal");
        return atomicsWaitAsyncResult(ctx, false, result);
    }
    if (timeout <= 0 and !std.math.isNan(timeout)) {
        const result = try value_ops.createStringValue(ctx.runtime, "timed-out");
        return atomicsWaitAsyncResult(ctx, false, result);
    }

    // Finish the byte-view borrow before Promise allocation. The retained
    // shared-store identity and offset remain valid independently of the view.
    var key = try atomicsWaiterKey(view, bytes);
    atomicsRetainWaiterKey(key);
    var key_owned = true;
    defer if (key_owned) atomicsReleaseWaiterKey(&key);
    const promise = try core.promise.constructWithPrototype(ctx, promisePrototypeFromGlobal(rt, objectFromValue(try global_root.get(rt)).?));
    try promise_root.set(rt, promise);
    const deadline = if (atomicsWaitTimeoutMilliseconds(timeout)) |timeout_ms|
        std.Io.Timestamp.now(atomicsWaiterIo(), .awake).addDuration(std.Io.Duration.fromMilliseconds(timeout_ms))
    else
        null;
    const waiter = try ctx.runtime.nativeAllocator().create(AtomicsWaiter);
    waiter.* = .{
        .key = key,
        .promise = try promise_root.get(rt),
        .realm = core.RealmRef.retain(ctx),
        .deadline = deadline,
    };
    key_owned = false;
    var waiter_owned = true;
    errdefer if (waiter_owned) atomicsDestroyAsyncWaiter(waiter);

    // The result wrapper is observable publication of this wait. Finish every
    // fallible allocation before linking the node into the cross-runtime
    // waiter registry; otherwise an OOM here leaves an unreachable Promise and
    // RealmRef behind until context teardown.
    const result = try atomicsWaitAsyncResult(ctx, true, try promise_root.get(rt));
    waiter.promise = try promise_root.get(rt);
    atomicsLinkAsyncWaiter(waiter);
    waiter_owned = false;
    return result;
}

pub fn atomicsLinkAsyncWaiter(waiter: *AtomicsWaiter) void {
    const ctx = waiter.realm.borrow().?;
    ctx.runtime.assertOwnerThread();
    ctx.runtime.roots.assertMutable();
    // Sticky: from here on this Runtime's root walk visits the registry.
    ctx.runtime.execution.noteWaitAsyncUsed();
    const io = atomicsWaiterIo();
    atomics_waiter_mutex.lockUncancelable(io);
    defer atomics_waiter_mutex.unlock(io);
    atomicsLinkWaiter(waiter);
}

test "waitAsync completion remembers a newly allocated result on an aged promise" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    var roots = core.runtime.ExactValueRoots(1){};
    try roots.activate(rt);
    defer roots.deactivate();
    const promise_root = try roots.ref(0);
    const promise = try core.Object.create(rt, core.class.ids.promise, null);
    try promise_root.set(rt, promise.value());
    _ = try core.gc_trace_stw.collectMinor(rt, .declared_only);
    try std.testing.expect(!promise.gcHeader().metaConst().flags.young);
    const waiter = try rt.nativeAllocator().create(AtomicsWaiter);
    waiter.* = .{ .key = .{ .offset_or_ptr = 0 }, .promise = promise.value(), .realm = core.RealmRef.retain(ctx), .completion = .timed_out };
    defer atomicsDestroyAsyncWaiter(waiter);
    try rt.job_queue.enqueuePromise(ctx, core.JSValue.int32(0));
    var placeholder = rt.job_queue.takeFirst().?;
    placeholder.deinit();
    rt.job_queue.reserveUnlinkedEntrySlot();
    const payload = jobs_mod.AtomicsWaiterPayload{
        .waiter = waiter,
        .promise = promise.value(),
    };
    try atomicsRunAsyncWaiterCompletion(ctx, &payload);
    const result_header = promise.promiseResult().?.cycleMarkHeader().?;
    try std.testing.expect(result_header.metaConst().flags.young);
    _ = try core.gc_trace_stw.collectMinor(rt, .declared_only);
    try std.testing.expect(rt.gc.containsHeader(result_header));
    try std.testing.expect(promise.promiseResult().?.asStringBodyRaw().?.eqlBytes("timed-out"));
}

test "waitAsync detached handoff remains rooted during queue allocation" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const promise = try core.Object.create(rt, core.class.ids.promise, null);
    const header = promise.gcHeader();
    const waiter = try rt.nativeAllocator().create(AtomicsWaiter);
    waiter.* = .{ .key = .{ .offset_or_ptr = @intFromPtr(ctx) }, .promise = promise.value(), .realm = core.RealmRef.retain(ctx), .completion = .notified };
    atomicsLinkAsyncWaiter(waiter);
    defer cleanupAtomicsWaitersForContext(ctx);
    const Probe = struct {
        rt: *core.JSRuntime,
        called: bool = false,
        failed: bool = false,
        fn collect(raw: ?*anyopaque, _: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.called) return;
            self.called = true;
            _ = self.rt.collectForTest() catch {
                self.failed = true;
            };
        }
    };
    var probe = Probe{ .rt = rt };
    const previous_probe = rt.gc.heap_budget.installProbe(.{ .run = Probe.collect, .context = &probe });
    defer rt.gc.heap_budget.restoreProbe(previous_probe);
    try processExpiredAtomicsWaiters(ctx);
    const alive = rt.gc.containsHeader(header);
    var job = rt.job_queue.takeFirst().?;
    job.deinit();
    try std.testing.expect(probe.called and !probe.failed);
    try std.testing.expect(alive);
}

test "waitAsync failed handoff relinks a relocated value then retries" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const rt = try core.JSRuntime.create(failing.allocator(), .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    for (0..4) |index| try rt.job_queue.enqueuePromise(ctx, core.JSValue.int32(@intCast(index)));
    rt.gc.nursery.enabled = true;
    // Promise's current variable-size carrier does not use the nursery.
    // Exercise this generic root slot with a movable Object; drop the typed
    // job after handoff rather than running Promise settlement on that object.
    const promise = try core.Object.createPlainObject(rt, null);
    try std.testing.expect(core.gc.Registry.isNurseryHeader(promise.gcHeader()));
    const before = @intFromPtr(promise.gcHeader());
    const waiter = try rt.nativeAllocator().create(AtomicsWaiter);
    waiter.* = .{ .key = .{ .offset_or_ptr = @intFromPtr(ctx) }, .promise = promise.value(), .realm = core.RealmRef.retain(ctx), .completion = .notified };
    atomicsLinkAsyncWaiter(waiter);
    defer cleanupAtomicsWaitersForContext(ctx);
    const Probe = struct {
        rt: *core.JSRuntime,
        failing: *std.testing.FailingAllocator,
        called: bool = false,
        failed: bool = false,
        fn collect(raw: ?*anyopaque, _: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.called) return;
            self.called = true;
            _ = core.gc_trace_stw.collectMinor(self.rt, .declared_only) catch {
                self.failed = true;
                return;
            };
            // Fail queue backing allocation only after relocation completed.
            self.failing.fail_index = self.failing.alloc_index;
        }
    };
    var probe = Probe{ .rt = rt, .failing = &failing };
    const previous_probe = rt.gc.heap_budget.installProbe(.{ .run = Probe.collect, .context = &probe });
    defer {
        failing.fail_index = std.math.maxInt(usize);
        rt.gc.heap_budget.restoreProbe(previous_probe);
    }
    try std.testing.expectError(error.OutOfMemory, processExpiredAtomicsWaiters(ctx));
    failing.fail_index = std.math.maxInt(usize);
    rt.gc.heap_budget.restoreProbe(previous_probe);
    try std.testing.expect(probe.called and !probe.failed);
    try std.testing.expect(waiter.linked);
    try std.testing.expectEqual(AtomicsWaiterCompletion.notified, waiter.completion);
    const moved = waiter.promise.?.heapReference().?;
    try std.testing.expect(@intFromPtr(moved) != before);
    try std.testing.expect(rt.gc.containsHeader(waiter.promise.?.cycleMarkHeader().?));
    try std.testing.expectEqual(@as(usize, 4), rt.job_queue.jobs.len);
    try processExpiredAtomicsWaiters(ctx);
    try std.testing.expectEqual(@as(usize, 5), rt.job_queue.jobs.len);
    try std.testing.expectEqual(moved, rt.job_queue.jobs[4].payload.atomics_waiter.promise.heapReference().?);
    while (rt.job_queue.takeFirst()) |job_value| {
        var job = job_value;
        job.deinit();
    }
}

test "waitAsync root trace repairs original slots outside the waiter lock" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const other_rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer other_rt.destroy();
    const other_ctx = try core.JSContext.create(other_rt, .{});
    defer other_ctx.destroy();
    var expected: [17]*core.JSValue = undefined;
    var first_waiter: ?*AtomicsWaiter = null;
    defer cleanupAtomicsWaitersForContext(ctx);
    defer cleanupAtomicsWaitersForContext(other_ctx);
    for (&expected, 0..) |*slot, index| {
        const waiter = try rt.nativeAllocator().create(AtomicsWaiter);
        waiter.* = .{ .key = .{ .offset_or_ptr = @intFromPtr(ctx) }, .promise = core.JSValue.int32(@intCast(index)), .realm = core.RealmRef.retain(ctx) };
        atomicsLinkAsyncWaiter(waiter);
        slot.* = &waiter.promise.?;
        if (index == 0) first_waiter = waiter;
    }
    const foreign = try other_rt.nativeAllocator().create(AtomicsWaiter);
    foreign.* = .{ .key = .{ .offset_or_ptr = @intFromPtr(other_ctx) }, .promise = core.JSValue.int32(99), .realm = core.RealmRef.retain(other_ctx) };
    atomicsLinkAsyncWaiter(foreign);
    const Probe = struct {
        expected: []const *core.JSValue,
        ctx: *core.JSContext,
        waiter: *AtomicsWaiter,
        visits: usize = 0,
        slots_match: bool = true,
        lock_free: bool = true,
        fail_after: ?usize = null,
        fail_header: bool = false,
        fn header(raw: *anyopaque, _: *const core.gc.Header) core.runtime.RootTraceError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (!atomics_waiter_mutex.tryLock()) return error.PayloadMarkFailed;
            atomics_waiter_mutex.unlock(atomicsWaiterIo());
            if (self.fail_header) return error.OutOfMemory;
        }
        fn value(raw: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (std.c.getenv("ZJS_WAITER_TRACE_INJECT")) |raw_mode| {
                const mode = std.fmt.parseInt(u8, std.mem.span(raw_mode), 10) catch 0;
                switch (mode) {
                    1 => cleanupAtomicsWaitersForContext(self.ctx),
                    2 => processExpiredAtomicsWaiters(self.ctx) catch return error.PayloadMarkFailed,
                    3 => atomicsUnlinkWaiter(self.waiter),
                    4 => atomicsDestroyAsyncWaiter(self.waiter),
                    5 => atomicsLinkAsyncWaiter(self.waiter),
                    6 => atomicsLinkWaiter(self.waiter),
                    else => {},
                }
            }
            self.slots_match = self.slots_match and self.visits < self.expected.len and slot == self.expected[self.visits];
            if (atomics_waiter_mutex.tryLock()) {
                atomics_waiter_mutex.unlock(atomicsWaiterIo());
            } else self.lock_free = false;
            self.visits += 1;
            slot.* = core.JSValue.int32(73);
            if (self.fail_after == self.visits) return error.OutOfMemory;
        }
        fn object(_: *anyopaque, _: *?*core.Object) core.runtime.RootTraceError!void {}
    };
    var probe = Probe{ .expected = &expected, .ctx = ctx, .waiter = first_waiter.? };
    var visitor = core.runtime.RootVisitor{ .readonly = .observe, .context = &probe, .visit_value = Probe.value, .visit_object = Probe.object, .visit_header = Probe.header };
    try traceWaitAsyncRoots(rt, &visitor);
    try std.testing.expectEqual(expected.len, probe.visits);
    try std.testing.expect(probe.slots_match);
    try std.testing.expect(probe.lock_free);
    for (expected) |slot| try std.testing.expectEqual(@as(?i32, 73), slot.as(.int));
    try std.testing.expectEqual(@as(?i32, 99), foreign.promise.?.as(.int));
    const native_before = rt.allocation_diagnostics.allocated_bytes;
    for (expected) |slot| slot.* = core.JSValue.int32(0);
    probe.visits = 0;
    probe.fail_after = 3;
    try std.testing.expectError(error.OutOfMemory, traceWaitAsyncRoots(rt, &visitor));
    try std.testing.expectEqual(@as(usize, 3), probe.visits);
    try std.testing.expectEqual(native_before, rt.allocation_diagnostics.allocated_bytes);
    try std.testing.expect(!rt.roots.isTracing());
    for (expected, 0..) |slot, index| try std.testing.expectEqual(@as(?i32, if (index < 3) 73 else 0), slot.as(.int));
    probe.visits = 0;
    probe.fail_header = true;
    try std.testing.expectError(error.OutOfMemory, traceWaitAsyncRoots(rt, &visitor));
    try std.testing.expectEqual(@as(usize, 0), probe.visits);
    try std.testing.expect(!rt.roots.isTracing());
    try std.testing.expectEqual(native_before, rt.allocation_diagnostics.allocated_bytes);
    probe.fail_header = false;
    rt.setNativeBytesLimitForTest(native_before);
    defer rt.setNativeBytesLimitForTest(null);
    try std.testing.expectError(error.OutOfMemory, traceWaitAsyncRoots(rt, &visitor));
    try std.testing.expectEqual(@as(usize, 0), probe.visits);
    try std.testing.expect(!rt.roots.isTracing());
    try std.testing.expectEqual(native_before, rt.allocation_diagnostics.allocated_bytes);
}

test "waitAsync registry tracing is enabled per Runtime on first link" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const other = try core.JSRuntime.create(std.testing.allocator, .{});
    defer other.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    try std.testing.expect(!rt.execution.wait_async_used);
    const promise = try core.Object.createPlainObject(rt, null);
    const waiter = try rt.nativeAllocator().create(AtomicsWaiter);
    waiter.* = .{ .key = .{ .offset_or_ptr = @intFromPtr(ctx) }, .promise = promise.value(), .realm = core.RealmRef.retain(ctx) };
    atomicsLinkAsyncWaiter(waiter);
    defer cleanupAtomicsWaitersForContext(ctx);
    try std.testing.expect(rt.execution.wait_async_used);
    // A Runtime that never linked a waiter keeps skipping the global registry.
    try std.testing.expect(!other.execution.wait_async_used);
    _ = try other.collectForTest();
    // The linked waiter's Promise is rooted only through the registry walk.
    _ = try rt.collectForTest();
    try std.testing.expect(rt.gc.containsHeader(waiter.promise.?.cycleMarkHeader().?));
}

test "waitAsync root trace follows nursery relocation and foreign notification" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    rt.gc.nursery.enabled = true;
    const promise = try core.Object.createPlainObject(rt, null);
    const before = @intFromPtr(promise.gcHeader());
    try std.testing.expect(core.gc.Registry.isNurseryHeader(promise.gcHeader()));
    const waiter = try rt.nativeAllocator().create(AtomicsWaiter);
    waiter.* = .{ .key = .{ .offset_or_ptr = @intFromPtr(ctx) }, .promise = promise.value(), .realm = core.RealmRef.retain(ctx) };
    atomicsLinkAsyncWaiter(waiter);
    defer cleanupAtomicsWaitersForContext(ctx);
    _ = try core.gc_trace_stw.collectMinor(rt, .declared_only);
    const moved = waiter.promise.?.heapReference().?;
    try std.testing.expect(@intFromPtr(moved) != before);
    try std.testing.expect(rt.gc.containsHeader(waiter.promise.?.cycleMarkHeader().?));
    const Probe = struct {
        key: AtomicsWaiterKey,
        notified: usize = 0,
        fn notify(self: *@This()) void {
            self.notified = atomicsWakeWaiters(self.key, 1);
        }
        fn value(raw: *anyopaque, _: *core.JSValue) core.runtime.RootTraceError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (!atomics_waiter_mutex.tryLock()) return error.PayloadMarkFailed;
            atomics_waiter_mutex.unlock(atomicsWaiterIo());
            const thread = std.Thread.spawn(.{}, notify, .{self}) catch return error.PayloadMarkFailed;
            thread.join();
        }
        fn object(_: *anyopaque, _: *?*core.Object) core.runtime.RootTraceError!void {}
    };
    var probe = Probe{ .key = waiter.key };
    var visitor = core.runtime.RootVisitor{ .readonly = .observe, .context = &probe, .visit_value = Probe.value, .visit_object = Probe.object };
    try traceWaitAsyncRoots(rt, &visitor);
    try std.testing.expectEqual(@as(usize, 1), probe.notified);
    try std.testing.expectEqual(AtomicsWaiterCompletion.notified, waiter.completion);
    try std.testing.expectEqual(moved, waiter.promise.?.heapReference().?);
}

pub fn traceWaitAsyncRoots(rt: *core.JSRuntime, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
    rt.assertOwnerThread();
    rt.roots.beginTrace();
    defer rt.roots.endTrace();
    const io = atomicsWaiterIo();
    var storage: [16]*AtomicsWaiter = undefined;

    atomics_waiter_mutex.lockUncancelable(io);
    var count: usize = 0;
    var cursor = atomics_waiters;
    while (cursor) |waiter| : (cursor = waiter.next) {
        if (atomicsAsyncWaiterRuntime(waiter) == rt) count += 1;
    }
    atomics_waiter_mutex.unlock(io);
    if (count == 0) return;

    // This allocator does not invoke GC/probes. Only this Runtime's owner
    // can add/remove its async nodes, and the trace window rejects reentry.
    const extra: []*AtomicsWaiter = if (count > storage.len)
        try rt.nativeAllocator().alloc(*AtomicsWaiter, count)
    else
        &.{};
    defer if (extra.len != 0) rt.nativeAllocator().free(extra);
    const buf = if (extra.len != 0) extra else storage[0..count];

    atomics_waiter_mutex.lockUncancelable(io);
    var filled: usize = 0;
    cursor = atomics_waiters;
    while (cursor) |waiter| : (cursor = waiter.next) {
        if (atomicsAsyncWaiterRuntime(waiter) != rt) continue;
        // Snapshot nodes, never next pointers or copied values: foreign
        // runtimes may change the global list as soon as we release its lock.
        if (filled == buf.len) @panic("async waiter population changed during tracing");
        buf[filled] = waiter;
        filled += 1;
    }
    atomics_waiter_mutex.unlock(io);

    if (filled != count) @panic("async waiter population changed during tracing");
    for (buf[0..filled]) |waiter| {
        // Realm allocations are currently stable. The Promise may move, so
        // report the actual node slot. No callback runs under the list lock.
        try visitor.constHeader(&waiter.realm.borrow().?.header);
        try visitor.value(&waiter.promise.?);
    }
}

pub fn atomicsWaitAsyncResult(ctx: *core.JSContext, is_async: bool, value: core.JSValue) !core.JSValue {
    return waitAsyncResultRooted(ctx, is_async, value) catch |err| switch (err) {
        error.RootGenerationExhausted => error.OutOfMemory,
        error.RootAlreadyActive, error.RootMutationDuringCollection, error.WrongRuntime, error.InactiveRoot, error.InvalidRootIndex => std.debug.panic("waitAsync result root contract: {s}", .{@errorName(err)}),
        else => |other| other,
    };
}

fn waitAsyncResultRooted(ctx: *core.JSContext, is_async: bool, value: core.JSValue) !core.JSValue {
    var roots = core.runtime.ExactValueRoots(2){};
    try roots.activate(ctx.runtime);
    defer roots.deactivate();
    const input = try roots.ref(0);
    const output = try roots.ref(1);
    try input.set(ctx.runtime, value);
    const result = try core.Object.create(ctx.runtime, core.class.ids.object, ctx.classPrototypeObject(core.class.ids.object));
    try output.set(ctx.runtime, result.value());
    errdefer core.Object.destroyFromHeader(ctx.runtime, result.gcHeader());
    // Property definition still borrows its receiver and descriptor across
    // allocation. Pin this window until that lower-level API accepts roots.
    var pin = try core.runtime.NativePin.initHeader(ctx.runtime, result.gcHeader());
    defer pin.deinit();
    var input_pin = try core.runtime.NativePin.initValue(ctx.runtime, try input.get(ctx.runtime));
    defer if (input_pin) |*held| held.deinit();
    try defineValueProperty(ctx.runtime, result, core.atom.ids.async_, core.JSValue.boolean(is_async));
    try defineValueProperty(ctx.runtime, result, core.atom.ids.value, try input.get(ctx.runtime));
    return output.get(ctx.runtime);
}

test "waitAsync result construction roots and pins survive allocation GC" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    rt.gc.nursery.enabled = true;
    const input = try core.Object.createPlainObject(rt, null);
    const before_pins = rt.gc.pins.count();
    const Probe = struct {
        rt: *core.JSRuntime,
        calls: usize = 0,
        busy: bool = false,
        failed: bool = false,
        fn collect(raw: ?*anyopaque, _: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.busy) return;
            self.busy = true;
            defer self.busy = false;
            self.calls += 1;
            _ = self.rt.collectForTest() catch {
                self.failed = true;
            };
        }
    };
    var probe = Probe{ .rt = rt };
    const old_probe = rt.gc.heap_budget.installProbe(.{ .run = Probe.collect, .context = &probe });
    defer rt.gc.heap_budget.restoreProbe(old_probe);
    const result_value = try atomicsWaitAsyncResult(ctx, true, input.value());
    const result = objectFromValue(result_value).?;
    const stored = try result.getProperty(core.atom.ids.value);
    try std.testing.expect(probe.calls > 0 and !probe.failed);
    try std.testing.expect(rt.gc.containsHeader(stored.cycleMarkHeader().?));
    try std.testing.expectEqual(@as(?bool, true), (try result.getProperty(core.atom.ids.async_)).as(.boolean));
    try std.testing.expectEqual(before_pins, rt.gc.pins.count());
    try std.testing.expect(rt.roots.active_exact_roots == null);
}

test "waitAsync result allocation failures unwind construction roots and pins" {
    var failures: usize = 0;
    var succeeded = false;
    for (0..128) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const rt = try core.JSRuntime.create(failing.allocator(), .{});
        defer rt.destroy();
        const ctx = try core.JSContext.create(rt, .{});
        defer ctx.destroy();
        var roots = core.runtime.ExactValueRoots(1){};
        try roots.activate(rt);
        defer roots.deactivate();
        const input = try roots.ref(0);
        try input.set(rt, (try core.Object.createPlainObject(rt, null)).value());
        const root_head = rt.active_value_roots;
        const pins_before = rt.gc.pins.count();
        failing.fail_index = failing.alloc_index + offset;
        const result = atomicsWaitAsyncResult(ctx, true, try input.get(rt));
        failing.fail_index = std.math.maxInt(usize);
        if (result) |_| {
            succeeded = true;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
        }
        try std.testing.expectEqual(pins_before, rt.gc.pins.count());
        try std.testing.expect(rt.active_value_roots == root_head);
        _ = try rt.collectForTest();
        try std.testing.expect(rt.gc.containsHeader((try input.get(rt)).cycleMarkHeader().?));
        if (succeeded) break;
    }
    try std.testing.expect(succeeded and failures > 0);
}

test "waitAsync result root admission failure leaves no pins or roots" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    rt.roots.exact_root_generation = std.math.maxInt(u64);
    const before_pins = rt.gc.pins.count();
    try std.testing.expectError(error.OutOfMemory, atomicsWaitAsyncResult(ctx, false, core.JSValue.int32(1)));
    try std.testing.expectEqual(before_pins, rt.gc.pins.count());
    try std.testing.expect(rt.roots.active_exact_roots == null);
}

test "atomicsWaitAsyncResult roots direct function bytecode value while creating result object" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-atomics-wait-async-result-bytecode-symbol");
    const fb = try bytecode.FunctionBytecode.createPublishedFixture(rt, .{ .cpool_count = 1 }, &.{try rt.symbolValue(symbol_atom)});

    const result_payload = core.JSValue.functionBytecode(&fb.header);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const result_value = try atomicsWaitAsyncResult(ctx, true, result_payload);
    const result = objectFromValue(result_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const value_key = try rt.internAtom("value");
    {
        const stored = try result.getProperty(value_key);
        try std.testing.expect(stored.same(result_payload));
    }

    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn wakeAtomicsWaitersForRuntimes(primary: *core.JSRuntime, related: []const *core.JSRuntime) void {
    const io = atomicsWaiterIo();
    atomics_waiter_mutex.lockUncancelable(io);
    defer atomics_waiter_mutex.unlock(io);

    var cursor = atomics_waiters;
    while (cursor) |waiter| {
        if (waiter.realm.borrow()) |ctx| {
            if (ctx.runtime == primary or runtimeListContains(related, ctx.runtime)) {
                if (waiter.completion != .waiting) {
                    cursor = waiter.next;
                    continue;
                }
                // May be called by a foreign test262 agent/coordinator thread:
                // publish only the mutex-protected scalar and signal. Promise,
                // RealmRef, allocator, and JS heap remain owner-thread-only.
                waiter.completion = .notified;
                waiter.cond.broadcast(io);
            }
        }
        cursor = waiter.next;
    }
}

fn runtimeListContains(list: []const *core.JSRuntime, runtime: *core.JSRuntime) bool {
    for (list) |candidate| {
        if (candidate == runtime) return true;
    }
    return false;
}
