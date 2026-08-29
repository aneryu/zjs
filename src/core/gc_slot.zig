//! Slot-under-RC (tracing-gc-design.md §5.2 / Stage 2).
//!
//! Heap reference mutation goes through these types so retain-new → publish →
//! release-old stays inside one Implementation. Stage 2 does not introduce
//! atomics; the concurrent layouts in §5.3–5.4 wait for Stage 6.
//!
//! Public `JSValue` / `property.Slot` layouts and the plugin ABI fingerprint
//! stay unchanged. A Slot here is the mutation protocol over existing fields,
//! not a new 16-byte representation.
//!
//! Default `rc` erases this module (`core/root.zig`) so production `.text`
//! carries no `gc_slot` symbols. Call sites that must stay identity-neutral
//! keep a comptime `stats_enabled` branch whose rc arm is the original helper.

const std = @import("std");
const builtin = @import("builtin");

const gc = @import("gc.zig");
const object_payloads = @import("object_payloads.zig");
const runtime_mod = @import("runtime.zig");
const JSRuntime = runtime_mod.JSRuntime;
const JSValue = @import("value.zig").JSValue;

pub const stats_enabled = builtin.is_test or gc.shadow_tracer_enabled;

pub const Stats = struct {
    set_calls: usize = 0,
    retains: usize = 0,
    publishes: usize = 0,
    releases: usize = 0,
    bulk_calls: usize = 0,

    pub fn reset(self: *Stats) void {
        self.* = .{};
    }
};

pub var stats: Stats = .{};

const write_audit = @import("gc_write_audit.zig");

inline fn noteSet(retained_new: bool, released_old: bool) void {
    if (comptime !stats_enabled) return;
    stats.set_calls += 1;
    stats.publishes += 1;
    if (retained_new) stats.retains += 1;
    if (released_old) stats.releases += 1;
    write_audit.noteSlot();
}

inline fn noteBulk() void {
    if (comptime !stats_enabled) return;
    stats.bulk_calls += 1;
    write_audit.noteSlot();
}

/// Heap JSValue field. Storage remains a plain `JSValue` / `?JSValue`.
pub const HeapValueSlot = struct {
    /// Caller has already retained `new_value` (ownership transfer), matching
    /// `Object.setOptionalValueSlot`. Retain-new is counted here because the
    /// caller dup is the Slot's retain step.
    ///
    /// Stage 6 barrier: after `slot.* = new_value` (the publish), call
    /// `postWriteBarrier(owner, decodeExactHeapRef(new_value))`. The
    /// retain-new happens before publish and needs no barrier.
    pub inline fn setOptionalOwned(rt: *JSRuntime, slot: *?JSValue, new_value: ?JSValue) void {
        const had_old = slot.* != null;
        noteSet(new_value != null, had_old);
        const old_value = slot.*;
        slot.* = new_value;
        if (old_value) |stored| stored.free(rt);
    }

    /// Borrowed `new_value`: Slot retains, publishes, then releases the old
    /// occupant. This is the §5.2 order spelled as one call.
    ///
    /// Stage 6 barrier: same as `setOptionalOwned` — after the publish store.
    pub inline fn set(rt: *JSRuntime, slot: *JSValue, new_value: JSValue) void {
        const retained = new_value.dup();
        noteSet(true, true);
        const old_value = slot.*;
        slot.* = retained;
        old_value.free(rt);
    }

    /// Owner-aware store. The generational barrier needs the *owner*, not the
    /// slot: a minor re-traces owners, so that is what has to be remembered
    /// (§8.3). Callers that have the owning header at hand should prefer this
    /// over `set`; the barrier is a no-op outside generational builds.
    pub inline fn setOwned(rt: *JSRuntime, owner: *gc.Header, slot: *JSValue, new_value: JSValue) void {
        set(rt, slot, new_value);
        rt.gc.generationalBarrier(owner, new_value.cycleMarkHeader());
    }

    /// Stage 6: no write barrier (no new exact target). Must not allocate.
    pub inline fn clearOptional(rt: *JSRuntime, slot: *?JSValue) void {
        noteSet(false, slot.* != null);
        const old_value = slot.*;
        slot.* = null;
        if (old_value) |stored| stored.free(rt);
    }

    pub inline fn loadForTrace(slot: *const JSValue) JSValue {
        return slot.*;
    }

    /// Bulk destroy of named optional fields (Iterator/Ordinary/Proxy).
    /// Stage 6: no write barrier; must not allocate after publication starts.
    pub fn destroyOptionalFields(rt: *JSRuntime, slots: []const *?JSValue) void {
        noteBulk();
        for (slots) |slot| clearOptional(rt, slot);
    }
};

/// Heap pointer to a GC header. No atomics.
pub const GcPtrSlot = struct {
    /// Stage 6 barrier: after `slot.* = new_header`, `postWriteBarrier(owner, new_header)`.
    pub inline fn setOptionalHeader(rt: *JSRuntime, slot: *?*gc.Header, new_header: ?*gc.Header) void {
        if (new_header) |header| header.retain();
        noteSet(new_header != null, slot.* != null);
        const old_header = slot.*;
        slot.* = new_header;
        if (old_header) |header| JSValue.object(header).free(rt);
    }

    pub inline fn loadForTrace(slot: *const ?*gc.Header) ?*gc.Header {
        return slot.*;
    }
};

/// Owned `[]JSValue` buffer. `next_values` is already retained elementwise.
pub const GcBuffer = struct {
    /// Stage 6 barrier: after installing the slice pointer, shade every
    /// initial strong target (`postWriteBarrier` per element, or one shade of
    /// the unpublished backing then an atomic descriptor install — §5.5).
    pub inline fn setSlice(rt: *JSRuntime, slot: *[]JSValue, next_values: []JSValue) void {
        noteSet(next_values.len != 0, slot.len != 0);
        object_payloads.destroyValueSlice(rt, slot);
        slot.* = next_values;
    }

    pub inline fn loadForTrace(slot: *const []JSValue) []JSValue {
        return slot.*;
    }

    /// Copy `src` into unpublished `dst`. Each element is retained.
    ///
    /// Stage 6 barrier: this loop publishes per-Slot. Either wrap each store
    /// in `enterBarrierCriticalScope` + `postWriteBarrier(owner, dst[i])`, or
    /// fill `dst` unpublished, shade every exact target, then atomically
    /// install the backing descriptor (§5.5).
    pub fn copyOwned(dst: []JSValue, src: []const JSValue) void {
        std.debug.assert(dst.len == src.len);
        noteBulk();
        for (dst, src) |*to, from| to.* = from.dup();
    }

    /// Move ownership of `src` into `dst` and zero `src`. No extra retain.
    ///
    /// Stage 6 barrier: after each publish (or after the unpublished backing
    /// is initialized), `postWriteBarrier` for every new exact target. No
    /// retain of already-owned values.
    pub fn moveOwned(dst: []JSValue, src: []JSValue) void {
        std.debug.assert(dst.len == src.len);
        noteBulk();
        for (dst, src) |*to, *from| {
            to.* = from.*;
            from.* = JSValue.undefinedValue();
        }
    }

    /// Grow or shrink a capacity-tracked buffer. Live prefix is copyOwned
    /// onto a new allocation, then the old backing is destroyed.
    ///
    /// Stage 6: build an unpublished backing, publish its initialized Slots,
    /// shade every initial strong target, then atomically install the backing
    /// descriptor. Must not allocate after publication begins (§5.5).
    pub fn resize(
        rt: *JSRuntime,
        slot: *[]JSValue,
        capacity: *usize,
        new_len: usize,
    ) !void {
        noteBulk();
        if (new_len == slot.len) return;
        if (new_len == 0) {
            object_payloads.destroyValueSliceWithCapacity(rt, slot, capacity);
            return;
        }
        const next = try rt.memory.alloc(JSValue, new_len);
        const copy_len = @min(slot.len, new_len);
        copyOwned(next[0..copy_len], slot.*[0..copy_len]);
        if (new_len > copy_len) @memset(next[copy_len..], JSValue.undefinedValue());
        object_payloads.destroyValueSliceWithCapacity(rt, slot, capacity);
        slot.* = next[0..new_len];
        capacity.* = new_len;
    }

    /// Stage 6: no write barrier (no new exact targets). Must not allocate.
    pub fn destroy(rt: *JSRuntime, slot: *[]JSValue) void {
        noteBulk();
        object_payloads.destroyValueSlice(rt, slot);
    }
};

/// One data-property install. Not wired to `Object.property_storage` or dense
/// elements this stage (design §6.4 snapshot domain, Stage 6).
///
/// Stage 6 barrier: after the Entry.data store, `postWriteBarrier(owner,
/// decodeExactHeapRef(value))`. Shape-flag publication of the arm is part of
/// the same layout transaction as today.
pub const PropertyInstall = struct {
    pub fn installOwnedData(rt: *JSRuntime, slot: *JSValue, next_value: JSValue) void {
        _ = rt;
        noteBulk();
        slot.* = next_value;
    }
};

/// Weak identity (ephemeron / WeakRef). Not a strong retain.
/// Stage 6: no strong write barrier; identity table update is mutator-only.
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
