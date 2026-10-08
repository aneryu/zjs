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
    _ = rt.collectForTest() catch |err| std.debug.panic("collectForTest: {s}", .{@errorName(err)});
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
    core.gc_weak.retain(rt, key_identity);
    errdefer core.gc_weak.release(rt, key_identity);
    const entries_slot = collection.weakCollectionEntriesSlot();
    const index = entries_slot.items.len;
    const inserted_holder = try core.property_state.registerHolder(rt, collection);
    errdefer if (inserted_holder) core.property_state.unregisterHolder(rt, collection);
    try collection.ensureWeakCollectionEntryCapacity(rt, index + 1);
    const refreshed_entries = collection.weakCollectionEntriesSlot();
    refreshed_entries.items = refreshed_entries.items.ptr[0 .. index + 1];
    errdefer refreshed_entries.items = refreshed_entries.items[0..index];
    refreshed_entries.items[index] = .{
        .key_identity = key_identity,
        .value = value,
    };
    _ = try core.property_state.registerHolder(rt, collection);
}
