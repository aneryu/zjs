//! GC and heap-identity helpers for tests that build a runtime directly.
//!
//! `reclaimNow` is the precise-scan discipline: anything the test still
//! holds must be named in a `rootValues` / `rootObjects` frame.

const std = @import("std");
const zjs = @import("zjs");
const core = zjs.core;

/// Reclaim whatever the test has made unreachable.
///
/// The scan is `declared_only` (via `runObjectCycleRemoval`), so anything the
/// test still holds must be named in a `rootValues`/`rootObjects` frame. That
/// is deliberate: it is the precise-scan discipline that makes these tests
/// deterministic, and it is what turns a missing root into a test failure
/// rather than into a conservative-scan accident.
pub fn reclaimNow(rt: *core.JSRuntime) void {
    _ = rt.runObjectCycleRemoval();
}

pub fn objectFromValue(value: core.JSValue) *core.Object {
    return core.value_semantics.objectFromValue(value).?;
}

pub fn appendWeakCollectionEntry(rt: *core.JSRuntime, collection: *core.Object, key: *core.Object, value: core.JSValue) !void {
    return appendWeakCollectionEntryForValue(rt, collection, key.value(), value);
}

/// Same insertion, for weak keys that are not objects (symbols). The weak
/// collection stores an identity, not a pointer, so the object entry point is
/// just this one with `key.value()` already applied.
pub fn appendWeakCollectionEntryForValue(rt: *core.JSRuntime, collection: *core.Object, key: core.JSValue, value: core.JSValue) !void {
    const key_identity = (try core.Object.weakIdentityFromValue(rt, key)).?;
    rt.retainWeakIdentity(key_identity);
    errdefer rt.releaseWeakIdentity(key_identity);
    const entries_slot = collection.weakCollectionEntriesSlot();
    const index = entries_slot.items.len;
    const inserted_holder = !rt.borrowedReferenceHolderRegistered(collection);
    try rt.registerBorrowedReferenceHolder(collection);
    errdefer if (inserted_holder) rt.unregisterBorrowedReferenceHolder(collection);
    try collection.ensureWeakCollectionEntryCapacity(rt, index + 1);
    const refreshed_entries = collection.weakCollectionEntriesSlot();
    refreshed_entries.items = refreshed_entries.items.ptr[0 .. index + 1];
    errdefer refreshed_entries.items = refreshed_entries.items[0..index];
    refreshed_entries.items[index] = .{
        .key_identity = key_identity,
        .value = value,
    };
    try rt.registerBorrowedReferenceHolder(collection);
}

/// Drive an open incremental major cycle to completion. Threshold-triggered
/// collections under the tracer begin a cycle and finish it at a later poll;
/// tests that assert on freed counts after a crossing call this to reach the
/// poll where the result lands.
pub fn finishGcCycles(rt: anytype) void {
    var polls: usize = 0;
    while (rt.gc.incremental.markingActive() or rt.gc.morgue.pending) : (polls += 1) {
        std.debug.assert(polls < 100_000);
        _ = rt.pollGC(null, .safepoint) catch return;
    }
}
