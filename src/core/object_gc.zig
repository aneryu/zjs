//! FinalizationRegistry cleanup enqueueing.
//!
//! TGC S4-e spec 2.5 emptied this module of the death-side machinery it was
//! named for: the Pass-B parked-free drain, the Pass-A block-corpse
//! settlement, and the weak-husk keep/free decision are all gone. Edge
//! enumeration lives on `Object.traceChildEdgesFallible` and is driven by
//! `gc_trace_stw.traceHeaderEdges`.

const object_mod = @import("object.zig");
const runtime_mod = @import("runtime.zig");
const JSRuntime = runtime_mod.JSRuntime;
const FinalizationRegistryPayload = object_mod.FinalizationRegistryPayload;
const JSValue = @import("value.zig").JSValue;

pub fn enqueueFinalizationCleanup(
    rt: *JSRuntime,
    payload: *const FinalizationRegistryPayload,
    held_value: JSValue,
) void {
    // §9.3: the job slot was reserved when the cell was registered. Sweep
    // must not allocate.
    const callback = payload.cleanup_callback orelse {
        if (rt.job_queue.capacity != 0) rt.job_queue.releaseReservedEntries(1);
        return;
    };
    const realm = payload.realm.borrow() orelse unreachable;
    // Normal collections consume the slot reserved at register. Runtime
    // teardown deinits the queue first, then cycle-removes leftover
    // objects; fall back to an allocating enqueue so that path can
    // rehydrate the queue the way trial deletion always did.
    if (rt.job_queue.reserved_entries != 0) {
        rt.enqueueFinalizationJobReserved(realm, callback, held_value);
    } else {
        rt.enqueueFinalizationJobForRealm(realm, callback, held_value) catch {};
    }
}
