//! PERF-T-SPIKE (branch-quarantined): the site registry behind the guarded
//! direct-slot opcodes (`tspike_get_slot` / `tspike_put_slot`).
//!
//! Policy: policies/spikes/perf-t-spike-v1.json. The thesis under test: a
//! site that KNOWS its receiver layout can replace the per-access probe
//! chain (shape -> mask -> prop_size -> bucket -> Property -> compare) with
//! guard + direct slot load. Sites are rewritten from get_field / put_field
//! by resolve_labels.zig when ZJS_TSPIKE=1; each site owns one registry
//! entry, captured on FIRST execution — the stand-in for a compile-time
//! prebuilt typed shape, so after iteration one the hot loop pays exactly
//! guard + load, with no side table and no feedback machinery.
//!
//! TWO PROTOTYPE-FAIRNESS RULES, learned from the first draft's disassembly
//! (which would have UNDER-priced the mechanism and risked a false kill):
//!   1. `capture()` must NEVER be inlined into a resident handler. Inlining
//!      it forced callee-saved spills and gave the handler a 3-instruction
//!      prologue + epilogue that the baseline `op_get_field` (a leaf, no
//!      prologue) does not pay. Capture lives behind a cold tail handler.
//!   2. `Entry` is a power-of-two size, so site addressing is
//!      `base + (idx << 5)` instead of a multiply by a 56-byte stride.
//!
//! Guard arms (baked per build via -Dzjs_tspike_guard, no runtime branch):
//!   u64  — key = Shape.tspike_identity (fresh at creation and before every
//!          in-place mutation, preserved across grow-relocation): sound
//!          everywhere; costs one extra load per guard.
//!   ptr  — key = the Shape address itself: zero loads (the pointer is
//!          already in hand), but sound ONLY while guarded shapes never
//!          mutate in place. That load is the entire measurable difference
//!          between the arms, which is what this spike prices.
//!
//! Spike simplifications (documented, acceptable for pricing): the registry
//! is process-global (single-Runtime benches; production is per-Runtime);
//! a missed guard falls back to the generic path with no invalidation
//! machinery; prototype support is one level deep.

const std = @import("std");
const build_options = @import("build_options");
const core = @import("../core/root.zig");

pub const guard_setting: []const u8 = build_options.zjs_tspike_guard;
pub const enabled = !std.mem.eql(u8, guard_setting, "off");
pub const Arm = enum { u64_identity, pinned_ptr };
pub const arm: Arm = if (std.mem.eql(u8, guard_setting, "ptr")) .pinned_ptr else .u64_identity;

pub const state_empty: u32 = 0;
pub const state_own: u32 = 1;
pub const state_proto: u32 = 2;
pub const state_poisoned: u32 = 3;

/// 32 bytes: power-of-two stride keeps site addressing a shift.
/// Keys are 0 in the empty state; shape identities start at 1 and shape
/// addresses are never 0, so an empty entry can never guard-match and the
/// hot path needs no separate emptiness test.
pub const Entry = extern struct {
    guard_key: u64 = 0,
    /// Nonzero only for prototype sites: the holder's own shape key. Doubles
    /// as the own/proto discriminator on the hot path.
    proto_key: u64 = 0,
    slot_index: u32 = 0,
    state: u32 = state_empty,
    reserved0: u32 = 0,
    reserved1: u32 = 0,

    comptime {
        std.debug.assert(@sizeOf(Entry) == 32);
    }
};

pub const site_capacity = 256;
pub var registry: [site_capacity]Entry = @splat(.{});

/// The guard key for a shape. The u64 arm loads a field; the pinned-pointer
/// arm uses the pointer already in hand.
pub inline fn shapeKey(s: *const core.Shape) u64 {
    return switch (comptime arm) {
        .u64_identity => s.tspike_identity,
        .pinned_ptr => @intFromPtr(s),
    };
}

fn slotIndexOf(obj: *const core.Object, slot: *const core.JSValue) u32 {
    const base = @intFromPtr(obj.prop_values);
    const addr = @intFromPtr(slot);
    return @intCast((addr - base) / @sizeOf(core.property.Entry));
}

/// First-execution capture. `noinline` is load-bearing: see fairness rule 1.
/// Returns true when the entry now guards this object, so the caller can
/// re-dispatch into the resident handler and take the ordinary hit path.
pub noinline fn capture(obj: *core.Object, atom_id: core.Atom, e: *Entry, comptime want_write: bool) bool {
    var slow = false;
    if (want_write) {
        if (obj.findWritableOwnDataSlotFast(atom_id, &slow)) |slot| {
            e.slot_index = slotIndexOf(obj, slot);
            e.guard_key = shapeKey(obj.shape_ref);
            e.proto_key = 0;
            e.state = state_own;
            return true;
        }
        e.state = state_poisoned;
        return false;
    }
    if (obj.findOwnDataSlotFast(atom_id, &slow)) |slot| {
        e.slot_index = slotIndexOf(obj, slot);
        e.guard_key = shapeKey(obj.shape_ref);
        e.proto_key = 0;
        e.state = state_own;
        return true;
    }
    if (slow) {
        e.state = state_poisoned;
        return false;
    }
    // One-level prototype capture (method reads). Double guard: the receiver
    // shape pins WHICH object is the prototype (proto lives in the shape),
    // and the prototype's own shape key pins its layout.
    if (obj.getPrototype()) |proto_obj| {
        var proto_slow = false;
        if (proto_obj.findOwnDataSlotFast(atom_id, &proto_slow)) |slot| {
            e.slot_index = slotIndexOf(proto_obj, slot);
            e.guard_key = shapeKey(obj.shape_ref);
            e.proto_key = shapeKey(proto_obj.shape_ref);
            e.state = state_proto;
            return true;
        }
    }
    e.state = state_poisoned;
    return false;
}
