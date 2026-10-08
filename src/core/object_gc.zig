//! FinalizationRegistry cleanup enqueueing.
//!
//! TGC S4-e spec 2.5 emptied this module of the death-side machinery it was
//! named for: the Pass-B parked-free drain, the Pass-A block-corpse
//! settlement, and the weak-husk keep/free decision are all gone. Edge
//! enumeration lives on `Object.traceChildEdgesFallible` and is driven by
//! `gc_trace_stw.traceHeaderEdges`.

const std = @import("std");
const jobs = @import("jobs.zig");
const object_mod = @import("object.zig");
const runtime_mod = @import("../runtime.zig");
const JSRuntime = runtime_mod.JSRuntime;
const FinalizationRegistryPayload = object_mod.FinalizationRegistryPayload;
const FinalizationRegistryCell = object_mod.FinalizationRegistryCell;
const JSValue = @import("value.zig").JSValue;

/// Enqueue the cleanup job of `cell` (whose target just died) and mark it
/// queued: it stays in the registry's cells, target identity released, until
/// the job takes it. Returns false when no job was enqueued (no callback);
/// the caller then drops the cell.
pub fn enqueueFinalizationCleanup(
    rt: *JSRuntime,
    registry: JSValue,
    payload: *const FinalizationRegistryPayload,
    cell: *FinalizationRegistryCell,
) bool {
    // §9.3: the job slot was reserved when the cell was registered. Sweep
    // must not allocate.
    const callback = payload.cleanup_callback orelse {
        if (rt.job_queue.capacity != 0) rt.job_queue.releaseReservedEntries(1);
        cell.state = .queued;
        return false;
    };
    const realm = payload.realm.borrow().?;
    std.debug.assert(realm.runtime == rt);
    const job = jobs.Job.initFinalization(realm, callback, cell.held_value, registry, cell.id);
    // Normal collections consume the slot reserved at register. Runtime
    // teardown deinits the queue first, then cycle-removes leftover
    // objects; fall back to an allocating enqueue so that path can
    // rehydrate the queue the way trial deletion always did.
    if (rt.job_queue.reserved_entries != 0) {
        rt.job_queue.enqueueReserved(job);
    } else {
        rt.job_queue.enqueueFinalization(job) catch {};
    }
    cell.state = .queued;
    if (cell.target_identity) |identity| rt.releaseWeakIdentity(identity);
    cell.target_identity = null;
    return true;
}
