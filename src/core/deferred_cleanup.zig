//! Deferred native cleanups and class-payload finalizers.
//!
//! The queues stay on `JSRuntime` so auto-layout and `vm_stack` alignment
//! stay put. This module owns enqueue, reserve, drain, and the idle-only
//! payload callback boundary. Native cleanups and JS jobs are separate
//! lists. A payload callback does not run while GC is in progress.

const std = @import("std");
const class = @import("class.zig");
const host_function = @import("host_function.zig");
const Object = @import("object.zig").Object;
const runtime_mod = @import("runtime.zig");
const JSRuntime = runtime_mod.JSRuntime;

pub fn enqueueNative(rt: *JSRuntime, finalizer: host_function.ExternalFinalizer, ptr: *anyopaque) !void {
    try rt.deferred_native_cleanups.append(rt.nativeAllocator(), .{
        .finalizer = finalizer,
        .ptr = ptr,
    });
}

pub fn enqueueClassPayload(
    rt: *JSRuntime,
    class_id: class.ClassId,
    payload: class.Payload,
    payload_kind: class.PayloadKind,
    object_identity: usize,
) !bool {
    const definition = rt.classes.destructionPlan(class_id) orelse return false;
    try ensureClassPayloadCapacity(rt, rt.deferred_class_payload_finalizers.items.len + rt.reserved_deferred_class_payload_finalizer_slots + 1);
    const callbacks = rt.classes.pinDeferredPayloadCallbacks(class_id, definition.generation) orelse return false;
    rt.deferred_class_payload_finalizers.appendAssumeCapacity(.{
        .class_id = class_id,
        .generation = callbacks.generation,
        .finalizer = callbacks.finalizer,
        .mark = callbacks.mark,
        .payload = payload,
        .payload_kind = payload_kind,
        .object_identity = object_identity,
    });
    return true;
}

pub fn reserveClassPayloadSlot(rt: *JSRuntime) !void {
    try ensureClassPayloadCapacity(rt, rt.deferred_class_payload_finalizers.items.len + rt.reserved_deferred_class_payload_finalizer_slots + 1);
    errdefer releaseEmptyClassPayloadBuffer(rt);
    // The same reservation owns one entry in the pre-enqueue payload-root
    // registry. Reserve both allocations before publishing the wrapper's
    // payload so destruction can transfer ownership without failure.
    try ensureClassPayloadRootCapacity(rt, rt.reserved_deferred_class_payload_finalizer_slots + 1);
    rt.reserved_deferred_class_payload_finalizer_slots +|= 1;
}

pub fn releaseClassPayloadSlot(rt: *JSRuntime) void {
    std.debug.assert(rt.reserved_deferred_class_payload_finalizer_slots != 0);
    rt.reserved_deferred_class_payload_finalizer_slots -= 1;
    releaseEmptyClassPayloadBuffer(rt);
    releaseEmptyClassPayloadRootBuffer(rt);
}

pub fn registerReservedRoot(rt: *JSRuntime, object: *Object) void {
    std.debug.assert(rt.reserved_deferred_class_payload_finalizer_slots != 0);
    std.debug.assert(rt.deferred_class_payload_roots.items.len < rt.reserved_deferred_class_payload_finalizer_slots);
    rt.deferred_class_payload_roots.appendAssumeCapacity(object);
}

pub fn unregisterRoot(rt: *JSRuntime, object: *Object) void {
    var found: ?usize = null;
    for (rt.deferred_class_payload_roots.items, 0..) |registered, index| {
        if (registered == object) {
            found = index;
            break;
        }
    }
    const index = found.?;
    _ = rt.deferred_class_payload_roots.swapRemove(index);
    releaseEmptyClassPayloadRootBuffer(rt);
}

pub fn enqueueReservedClassPayload(
    rt: *JSRuntime,
    class_id: class.ClassId,
    generation: u64,
    payload: class.Payload,
    payload_kind: class.PayloadKind,
    object_identity: usize,
) bool {
    std.debug.assert(rt.reserved_deferred_class_payload_finalizer_slots != 0);
    rt.reserved_deferred_class_payload_finalizer_slots -= 1;

    const callbacks = rt.classes.pinDeferredPayloadCallbacks(class_id, generation) orelse {
        releaseEmptyClassPayloadBuffer(rt);
        return false;
    };
    rt.deferred_class_payload_finalizers.appendAssumeCapacity(.{
        .class_id = class_id,
        .generation = callbacks.generation,
        .finalizer = callbacks.finalizer,
        .mark = callbacks.mark,
        .payload = payload,
        .payload_kind = payload_kind,
        .object_identity = object_identity,
    });
    return true;
}

pub fn hasNative(rt: *const JSRuntime) bool {
    return rt.deferred_native_cleanups.items.len != 0 or rt.deferred_class_payload_finalizers.items.len != 0;
}

pub fn hasPendingClassPayload(rt: *const JSRuntime) bool {
    return rt.deferred_class_payload_finalizers.items.len != 0 or
        rt.active_deferred_class_payload_finalizer != null;
}

pub fn isActiveClassPayloadCallback(rt: *const JSRuntime, object_identity: *anyopaque) bool {
    const active = rt.active_deferred_class_payload_finalizer orelse return false;
    return object_identity == @as(*anyopaque, @ptrCast(&active.object_identity));
}

pub fn runNativeBudgeted(rt: *JSRuntime, max_jobs: usize) usize {
    if (max_jobs == 0) return 0;
    if (rt.draining_deferred_native_cleanups) return 0;
    rt.draining_deferred_native_cleanups = true;
    defer rt.draining_deferred_native_cleanups = false;

    var ran: usize = 0;
    while (ran < max_jobs and rt.deferred_native_cleanups.items.len != 0) : (ran += 1) {
        const job = rt.deferred_native_cleanups.orderedRemove(0);
        job.run();
        rt.deferred_native_cleanup_run_count +|= 1;
    }

    releaseEmptyNativeBuffer(rt);
    return ran;
}

pub fn runClassPayloadBudgeted(rt: *JSRuntime, max_jobs: usize) usize {
    if (max_jobs == 0) return 0;
    if (rt.draining_deferred_class_payload_finalizers) return 0;
    rt.draining_deferred_class_payload_finalizers = true;
    defer rt.draining_deferred_class_payload_finalizers = false;

    var ran: usize = 0;
    while (ran < max_jobs and rt.deferred_class_payload_finalizers.items.len != 0) : (ran += 1) {
        var job = rt.deferred_class_payload_finalizers.orderedRemove(0);
        runClassPayloadJob(rt, &job);
        rt.deferred_class_payload_finalizer_run_count +|= 1;
    }

    releaseEmptyClassPayloadBuffer(rt);
    return ran;
}

pub fn drainNative(rt: *JSRuntime) void {
    while (runNativeBudgeted(rt, std.math.maxInt(usize)) != 0) {}
    releaseEmptyNativeBuffer(rt);
}

pub fn drainClassPayload(rt: *JSRuntime) void {
    while (runClassPayloadBudgeted(rt, std.math.maxInt(usize)) != 0) {}
    releaseEmptyClassPayloadBuffer(rt);
}

/// User callbacks run only after the collector is idle. Reentry from the
/// callback is rejected by the active-job guard.
pub inline fn drainClassPayloadAtSafeBoundary(rt: *JSRuntime) void {
    if (rt.deferred_class_payload_finalizers.items.len == 0) return;
    if (rt.gc_running or rt.gc.hot.phase != .none) return;
    if (rt.draining_deferred_class_payload_finalizers) return;
    drainClassPayload(rt);
}

pub fn runClassPayloadJob(rt: *JSRuntime, job: *runtime_mod.DeferredClassPayloadFinalizer) void {
    std.debug.assert(rt.active_deferred_class_payload_finalizer == null);
    rt.active_deferred_class_payload_finalizer = job;
    defer rt.active_deferred_class_payload_finalizer = null;
    job.run(rt);
}

pub fn pendingNativeCount(rt: *const JSRuntime) usize {
    return rt.deferred_native_cleanups.items.len;
}

pub fn pendingClassPayloadCount(rt: *const JSRuntime) usize {
    return rt.deferred_class_payload_finalizers.items.len;
}

fn releaseEmptyNativeBuffer(rt: *JSRuntime) void {
    if (rt.deferred_native_cleanups.items.len != 0) return;
    rt.deferred_native_cleanups.clearAndFree(rt.nativeAllocator());
}

fn ensureClassPayloadCapacity(rt: *JSRuntime, min_capacity: usize) !void {
    try rt.deferred_class_payload_finalizers.ensureTotalCapacity(rt.nativeAllocator(), min_capacity);
}

fn ensureClassPayloadRootCapacity(rt: *JSRuntime, min_capacity: usize) !void {
    try rt.deferred_class_payload_roots.ensureTotalCapacity(rt.nativeAllocator(), min_capacity);
}

fn releaseEmptyClassPayloadBuffer(rt: *JSRuntime) void {
    if (rt.deferred_class_payload_finalizers.items.len != 0) return;
    if (rt.reserved_deferred_class_payload_finalizer_slots != 0) return;
    rt.deferred_class_payload_finalizers.clearAndFree(rt.nativeAllocator());
}

fn releaseEmptyClassPayloadRootBuffer(rt: *JSRuntime) void {
    if (rt.deferred_class_payload_roots.items.len != 0) return;
    if (rt.reserved_deferred_class_payload_finalizer_slots != 0) return;
    rt.deferred_class_payload_roots.clearAndFree(rt.nativeAllocator());
}
