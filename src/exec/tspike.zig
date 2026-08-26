//! PERF-T-SPIKE (branch-quarantined): the hand-prebuilt registry behind the
//! guarded direct-slot opcodes (`tspike_get_slot` / `tspike_put_slot`).
//!
//! Policy: policies/spikes/perf-t-spike-v1.json. The thesis under test: a
//! typed site that KNOWS its receiver layout can replace the per-access
//! probe chain (shape -> mask -> prop_size -> bucket -> Property -> compare)
//! with guard + direct slot load. Sites are rewritten from get_field /
//! put_field by resolve_labels.zig when ZJS_TSPIKE=1; each site owns one
//! registry entry, captured on FIRST execution (the static prototype of a
//! compile-time-prebuilt shape: after iteration one, the hot loop pays
//! exactly guard + load — no side-table, no feedback machinery).
//!
//! Guard arms (baked per build via -Dzjs_tspike_guard, no runtime branch):
//!   u64  — compares Shape.tspike_identity (fresh at creation and before
//!          every in-place mutation, preserved across grow-relocation):
//!          sound everywhere, the production-shaped mechanism.
//!   ptr  — compares the Shape pointer itself: sound ONLY while guarded
//!          shapes never mutate in place (rc==1 in-place mutation keeps the
//!          address). Run it on the typed benches only; this unsound domain
//!          is exactly why the real design restricts pinned-pointer guards
//!          to immutable typed shapes.
//!
//! Spike simplifications (documented, acceptable for pricing): the registry
//! is process-global (single-Runtime benches; production is per-Runtime);
//! misses and polymorphic sites fall back to the generic cold path with no
//! invalidation machinery; proto support is one level deep.

const std = @import("std");
const build_options = @import("build_options");
const core = @import("../core/root.zig");

pub const guard_setting: []const u8 = build_options.zjs_tspike_guard;
pub const enabled = !std.mem.eql(u8, guard_setting, "off");
pub const Arm = enum { u64_identity, pinned_ptr };
pub const arm: Arm = if (std.mem.eql(u8, guard_setting, "ptr")) .pinned_ptr else .u64_identity;

pub const State = enum(u8) { empty, own, proto, poisoned };

/// Identities start at 1 and shape pointers are non-null, so a zeroed entry
/// can never guard-match: the empty state needs no extra check on the hit
/// path.
pub const Entry = struct {
    own_identity: u64 = 0,
    recv_identity: u64 = 0,
    proto_identity: u64 = 0,
    own_shape: ?*const core.Shape = null,
    recv_shape: ?*const core.Shape = null,
    proto_shape: ?*const core.Shape = null,
    slot_index: u32 = 0,
    state: State = .empty,
};

pub const site_capacity = 256;
pub var registry: [site_capacity]Entry = @splat(.{});

pub inline fn guardOwn(shape_ptr: *const core.Shape, e: *const Entry) bool {
    return switch (comptime arm) {
        .u64_identity => shape_ptr.tspike_identity == e.own_identity,
        .pinned_ptr => shape_ptr == e.own_shape,
    };
}

pub inline fn guardProtoRecv(shape_ptr: *const core.Shape, e: *const Entry) bool {
    return switch (comptime arm) {
        .u64_identity => shape_ptr.tspike_identity == e.recv_identity,
        .pinned_ptr => shape_ptr == e.recv_shape,
    };
}

pub inline fn guardProtoHolder(proto_shape: *const core.Shape, e: *const Entry) bool {
    return switch (comptime arm) {
        .u64_identity => proto_shape.tspike_identity == e.proto_identity,
        .pinned_ptr => proto_shape == e.proto_shape,
    };
}

fn slotIndexOf(obj: *const core.Object, slot: *const core.JSValue) u32 {
    const base = @intFromPtr(obj.prop_values);
    const addr = @intFromPtr(slot);
    return @intCast((addr - base) / @sizeOf(core.property.Entry));
}

/// First-execution capture: resolve the site once through the ordinary probe
/// and pin the expectation. Returns true when the entry now guards the given
/// object (caller re-runs the hit path); on false the entry is poisoned and
/// the site stays generic forever.
pub fn capture(obj: *core.Object, atom_id: core.Atom, e: *Entry, comptime want_write: bool) bool {
    var slow = false;
    if (want_write) {
        if (obj.findWritableOwnDataSlotFast(atom_id, &slow)) |slot| {
            e.slot_index = slotIndexOf(obj, slot);
            e.own_identity = obj.shape_ref.tspike_identity;
            e.own_shape = obj.shape_ref;
            e.state = .own;
            return true;
        }
        e.state = .poisoned;
        return false;
    }
    if (obj.findOwnDataSlotFast(atom_id, &slow)) |slot| {
        e.slot_index = slotIndexOf(obj, slot);
        e.own_identity = obj.shape_ref.tspike_identity;
        e.own_shape = obj.shape_ref;
        e.state = .own;
        return true;
    }
    if (slow) {
        e.state = .poisoned;
        return false;
    }
    // One-level prototype capture (method reads): guard = receiver shape
    // (which also pins WHICH object is the proto — proto lives in the shape)
    // + the proto object's own shape (its layout may change independently).
    if (obj.getPrototype()) |proto_obj| {
        var proto_slow = false;
        if (proto_obj.findOwnDataSlotFast(atom_id, &proto_slow)) |slot| {
            e.slot_index = slotIndexOf(proto_obj, slot);
            e.recv_identity = obj.shape_ref.tspike_identity;
            e.recv_shape = obj.shape_ref;
            e.proto_identity = proto_obj.shape_ref.tspike_identity;
            e.proto_shape = proto_obj.shape_ref;
            e.state = .proto;
            return true;
        }
    }
    e.state = .poisoned;
    return false;
}
