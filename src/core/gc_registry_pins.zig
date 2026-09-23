//! The pin ledger: the authority on which headers a collection may not reclaim.
//!
//! Two populations share one array. Host pins are positive reference counts
//! taken by the C/native binding layer (`JS_DupValue`-shaped ownership that
//! lives outside the JS heap). Construction roots are the single reserved
//! count `construction_pin_count`: a fully initialized but deliberately
//! unpublished generator shell, which has no Shape installed and therefore
//! cannot be traced through, so nothing but this ledger can keep it alive.
//!
//! Pinning used to be spelled twice -- a ledger entry AND a header bit -- and
//! the bit existed only so the sweep's read points could ask "is this
//! pinned?" without the ledger's linear search. The ledger is the authority
//! (`verifyHeapAccounting` checks the bit against it, never the other way
//! round), so `set` is that same cache with the header left alone, which is
//! what freed `BlockFlags` bit 6 for `needs_finalizer`.
//!
//! The ledger does not own an allocator. Every fallible mutator takes the
//! runtime's `Runtime allocation helpers` as a parameter: a second copy of that pointer
//! inside every `JSRuntime` would buy nothing, and the Registry is the thing
//! that has one. One insertion-ordered hash map holds both the membership
//! index and the counts, so the sweep's "is this pinned?" is a single lookup
//! and teardown/audits iterate in a deterministic order.

const std = @import("std");
const gc = @import("gc.zig");
const object = @import("object.zig");

const Header = gc.Header;

pub const Ledger = struct {
    /// header -> pin count; `gc.construction_pin_count` marks a construction root.
    counts: std.AutoArrayHashMapUnmanaged(*Header, usize) = .empty,

    /// Idempotent: a Registry rolled back halfway through construction can
    /// reach this twice, and a second call has to be a no-op rather than a
    /// double free.
    pub fn deinit(self: *Ledger, account: *@import("../runtime.zig").JSRuntime) void {
        self.counts.deinit(account.nativeAllocator());
        self.counts = .empty;
    }

    /// Is `header` pinned? A single index lookup, not a header read.
    pub inline fn contains(self: *const Ledger, header: *const Header) bool {
        if (self.counts.count() == 0) return false;
        return self.counts.contains(@constCast(header));
    }

    pub fn count(self: *const Ledger) usize {
        return self.counts.count();
    }

    /// Pinned headers in insertion order; parallel to `pinCounts()`.
    pub fn headers(self: *const Ledger) []const *Header {
        return self.counts.keys();
    }

    pub fn pinCounts(self: *const Ledger) []const usize {
        return self.counts.values();
    }

    pub fn pin(self: *Ledger, account: *@import("../runtime.zig").JSRuntime, header: *Header) !void {
        if (self.counts.getPtr(header)) |existing| {
            std.debug.assert(existing.* != gc.construction_pin_count);
            existing.* +|= 1;
            return;
        }
        try self.counts.putNoClobber(account.nativeAllocator(), header, 1);
    }

    pub fn unpin(self: *Ledger, header: *Header) void {
        const existing = self.counts.getPtr(header) orelse return;
        std.debug.assert(existing.* != gc.construction_pin_count);
        if (existing.* > 1) {
            existing.* -= 1;
            return;
        }
        _ = self.counts.orderedRemove(header);
    }

    /// Reserve the existing pin ledger before taking a block cell, so adding
    /// the construction pin after initialization is a no-fail scalar publish.
    pub fn prepareConstructionRoot(self: *Ledger, account: *@import("../runtime.zig").JSRuntime) !void {
        try self.counts.ensureUnusedCapacity(account.nativeAllocator(), 1);
    }

    /// Protect a fully initialized Object whose shape is intentionally not
    /// installed yet. Only the detached generator constructor has this
    /// lifetime; all other block-cell objects publish immediately.
    pub fn addConstructionRoot(self: *Ledger, header: *Header) void {
        std.debug.assert(header.metaConst().flags.kind == .object);
        std.debug.assert(!header.metaConst().alloc_info.heap_accounted);
        self.counts.putAssumeCapacityNoClobber(header, gc.construction_pin_count);
    }

    pub fn removeConstructionRoot(self: *Ledger, header: *Header) void {
        const existing = self.counts.get(header).?;
        std.debug.assert(existing == gc.construction_pin_count);
        _ = self.counts.orderedRemove(header);
    }

    /// The first construction root still in the ledger, for teardown.
    pub fn firstConstructionRoot(self: *const Ledger) ?*Header {
        for (self.counts.keys(), self.counts.values()) |header, pin_count| {
            if (pin_count == gc.construction_pin_count) return header;
        }
        return null;
    }

    pub fn isConstructionRoot(self: *const Ledger, header: *const Header) bool {
        const pin_count = self.counts.get(@constCast(header)) orelse return false;
        if (pin_count != gc.construction_pin_count) return false;
        const meta = header.metaConst();
        // Byte 6 is SHARED: the low seven bits are Object's Shape projection
        // (which must still be pristine on a shell) and bit7 is the
        // remembered-set cache, which `gc_generation` owns and which a
        // construction shell legitimately acquires. A shell is a real store
        // target -- `runGeneratorParameterInit` writes its payload -- so the
        // barrier stamps bit7 on it like any other unyoung owner.
        //
        // Reading the whole byte here made that barrier write REVOKE the
        // construction-root verdict: `seedRoots` then fell through to
        // `shadeExact`, which correctly refuses an unpublished header, so the
        // shell went unmarked into the minor's bitmap sweep and
        // `destroyFromHeaderSlow` dereferenced the deliberately-absent
        // `shape_ref`. Deterministic under `ZJS_GC_STRESS=1` on test262
        // `language/statements/class/elements/
        // same-line-async-gen-rs-static-async-method-privatename-identifier-alt.js`,
        // and the 84%-progress SIGSEGV of the full stress suite.
        if (meta.alloc_info.heap_accounted or
            meta.alloc_info.standalone or
            !gc.Registry.isBlockCellHeader(header) or
            meta.flags.kind != .object or
            meta.flags.young or
            meta.flags.finalizing or
            meta.lifetime.mark_epoch != 0 or
            meta.lifetime.object_shape_summary & gc.trace_object_shape_summary_mask != 0 or
            meta.lifetime.flags.reserved != 0)
        {
            return false;
        }
        const shell = object.Object.fromHeaderConst(header);
        return shell.isDetachedGeneratorShellForGc();
    }
};
