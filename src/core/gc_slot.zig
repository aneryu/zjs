//! Slot-under-RC (tracing-gc-design.md §5.2 / Stage 2).
//!
//! Heap reference mutation goes through these types so retain-new → publish →
//! release-old stays inside one Implementation. Stage 2 does not introduce
//! atomics; the concurrent layouts in §5.3–5.4 wait for Stage 6.
//!
//! Public `JSValue` / `property.Slot` layouts and the plugin ABI fingerprint
//! stay unchanged. A Slot here is the mutation protocol over existing fields,
//! not a new 16-byte representation.

const std = @import("std");
const builtin = @import("builtin");

const gc = @import("gc.zig");
const object_mod = @import("object.zig");
const object_payloads = @import("object_payloads.zig");
const runtime_mod = @import("runtime.zig");
const JSRuntime = runtime_mod.JSRuntime;
const JSValue = @import("value.zig").JSValue;
const Object = object_mod.Object;

pub const stats_enabled = builtin.is_test or gc.shadow_tracer_enabled;

pub const Stats = struct {
    set_calls: usize = 0,
    retains: usize = 0,
    publishes: usize = 0,
    releases: usize = 0,

    pub fn reset(self: *Stats) void {
        self.* = .{};
    }
};

pub var stats: Stats = .{};

inline fn noteSet(retained_new: bool, released_old: bool) void {
    if (comptime !stats_enabled) return;
    stats.set_calls += 1;
    stats.publishes += 1;
    if (retained_new) stats.retains += 1;
    if (released_old) stats.releases += 1;
}

/// Heap JSValue field. Storage remains a plain `JSValue` / `?JSValue`.
pub const HeapValueSlot = struct {
    /// Caller has already retained `new_value` (ownership transfer), matching
    /// `Object.setOptionalValueSlot`. Retain-new is counted here because the
    /// caller dup is the Slot's retain step.
    pub inline fn setOptionalOwned(rt: *JSRuntime, slot: *?JSValue, new_value: ?JSValue) void {
        const had_old = slot.* != null;
        noteSet(new_value != null, had_old);
        const old_value = slot.*;
        slot.* = new_value;
        if (old_value) |stored| stored.free(rt);
    }

    /// Borrowed `new_value`: Slot retains, publishes, then releases the old
    /// occupant. This is the §5.2 order spelled as one call.
    pub inline fn set(rt: *JSRuntime, slot: *JSValue, new_value: JSValue) void {
        const retained = new_value.dup();
        noteSet(true, true);
        const old_value = slot.*;
        slot.* = retained;
        old_value.free(rt);
    }

    pub inline fn clearOptional(rt: *JSRuntime, slot: *?JSValue) void {
        noteSet(false, slot.* != null);
        const old_value = slot.*;
        slot.* = null;
        if (old_value) |stored| stored.free(rt);
    }

    pub inline fn loadForTrace(slot: *const JSValue) JSValue {
        return slot.*;
    }
};

/// Heap pointer to a GC header (`*Object`, `*Shape`, …). No atomics.
pub const GcPtrSlot = struct {
    pub inline fn setObject(rt: *JSRuntime, slot: *?*Object, new_object: ?*Object) void {
        if (new_object) |obj| obj.header.retain();
        noteSet(new_object != null, slot.* != null);
        const old_object = slot.*;
        slot.* = new_object;
        if (old_object) |obj| obj.value().free(rt);
    }

    pub inline fn loadForTrace(slot: *const ?*Object) ?*Object {
        return slot.*;
    }
};

/// Owned `[]JSValue` buffer. `next_values` is already retained elementwise.
pub const GcBuffer = struct {
    pub inline fn setSlice(rt: *JSRuntime, slot: *[]JSValue, next_values: []JSValue) void {
        noteSet(next_values.len != 0, slot.len != 0);
        object_payloads.destroyValueSlice(rt, slot);
        slot.* = next_values;
    }

    pub inline fn loadForTrace(slot: *const []JSValue) []JSValue {
        return slot.*;
    }
};

/// Weak identity (ephemeron / WeakRef). Not a strong retain.
pub const WeakIdentitySlot = struct {
    pub inline fn set(rt: *JSRuntime, slot: *?usize, new_identity: ?usize) void {
        if (slot.*) |old_identity| rt.releaseWeakIdentity(old_identity);
        slot.* = new_identity;
    }

    pub inline fn clear(rt: *JSRuntime, slot: *?usize) void {
        if (slot.*) |old_identity| rt.releaseWeakIdentity(old_identity);
        slot.* = null;
    }
};

test "HeapValueSlot setOptionalOwned retains new then releases old" {
    if (comptime !stats_enabled) return;
    const rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const first = try Object.create(rt, @import("class.zig").ids.object, null);
    const second = try Object.create(rt, @import("class.zig").ids.object, null);
    const first_header = &first.header;
    var slot: ?JSValue = first.value();
    stats.reset();
    HeapValueSlot.setOptionalOwned(rt, &slot, second.value());
    try std.testing.expectEqual(@as(usize, 1), stats.set_calls);
    try std.testing.expectEqual(@as(usize, 1), stats.retains);
    try std.testing.expectEqual(@as(usize, 1), stats.publishes);
    try std.testing.expectEqual(@as(usize, 1), stats.releases);
    try std.testing.expect(slot != null);
    try std.testing.expect(!rt.gc.containsHeader(first_header));
    if (slot) |stored| stored.free(rt);
}
