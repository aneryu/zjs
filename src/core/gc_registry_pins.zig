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
//! runtime's `MemoryAccount` as a parameter: a second copy of that pointer
//! inside every `JSRuntime` would buy nothing, and the Registry is the thing
//! that has one.

const std = @import("std");
const gc = @import("gc.zig");
const memory = @import("memory.zig");
const object = @import("object.zig");

const GCObjectHeader = gc.GCObjectHeader;
const PinEntry = gc.PinEntry;

pub const Ledger = struct {
    entries: []PinEntry = &.{},
    entries_capacity: usize = 0,
    /// TGC S4-e spec 2.5: membership index for `entries`.
    ///
    /// Kept exactly in step with `entries` by the four mutators below, so
    /// `count()` is `entries.len` and the empty-heap case -- the normal one --
    /// costs a single load and branch, like the header bit did.
    set: std.AutoHashMapUnmanaged(usize, void) = .empty,

    /// Idempotent: a Registry rolled back halfway through construction can
    /// reach this twice, and a second call has to be a no-op rather than a
    /// double free.
    pub fn deinit(self: *Ledger, account: *memory.MemoryAccount) void {
        if (self.entries_capacity != 0) {
            account.free(PinEntry, self.entries.ptr[0..self.entries_capacity]);
        } else if (self.entries.len != 0) {
            account.free(PinEntry, self.entries);
        }
        self.entries = &.{};
        self.entries_capacity = 0;
        self.set.deinit(account.persistent_allocator);
        self.set = .empty;
    }

    /// Is `header` pinned? The ledger's membership index, not a header read.
    pub inline fn contains(self: *const Ledger, header: *const GCObjectHeader) bool {
        if (self.set.count() == 0) return false;
        return self.set.contains(@intFromPtr(header));
    }

    pub fn pin(self: *Ledger, account: *memory.MemoryAccount, header: *GCObjectHeader) !void {
        if (self.indexOf(header)) |index| {
            std.debug.assert(self.entries[index].count != gc.construction_pin_count);
            self.entries[index].count +|= 1;
            return;
        }
        try self.ensureCapacity(account, self.entries.len + 1);
        // Fallible step first: the array commit below must not be able to
        // leave the ledger and its index disagreeing.
        try self.set.put(account.persistent_allocator, @intFromPtr(header), {});
        self.entries.ptr[self.entries.len] = .{
            .header = header,
            .count = 1,
        };
        self.entries = self.entries.ptr[0 .. self.entries.len + 1];
    }

    pub fn unpin(self: *Ledger, header: *GCObjectHeader) void {
        const index = self.indexOf(header) orelse return;
        std.debug.assert(self.entries[index].count != gc.construction_pin_count);
        if (self.entries[index].count > 1) {
            self.entries[index].count -= 1;
            return;
        }
        self.removeAt(index);
        _ = self.set.remove(@intFromPtr(header));
    }

    pub fn indexOf(self: *const Ledger, header: *const GCObjectHeader) ?usize {
        for (self.entries, 0..) |entry, index| {
            if (entry.header == header) return index;
        }
        return null;
    }

    fn removeAt(self: *Ledger, index: usize) void {
        if (index + 1 < self.entries.len) {
            std.mem.copyForwards(
                PinEntry,
                self.entries[index .. self.entries.len - 1],
                self.entries[index + 1 ..],
            );
        }
        self.entries = self.entries[0 .. self.entries.len - 1];
    }

    fn ensureCapacity(self: *Ledger, account: *memory.MemoryAccount, required: usize) !void {
        if (required <= self.entries_capacity) return;
        var new_capacity = if (self.entries_capacity == 0) @as(usize, 8) else self.entries_capacity * 2;
        while (new_capacity < required) new_capacity *= 2;
        const next = try account.alloc(PinEntry, new_capacity);
        errdefer account.free(PinEntry, next);
        @memcpy(next[0..self.entries.len], self.entries);
        if (self.entries_capacity != 0) {
            account.free(PinEntry, self.entries.ptr[0..self.entries_capacity]);
        } else if (self.entries.len != 0) {
            account.free(PinEntry, self.entries);
        }
        self.entries = next[0..self.entries.len];
        self.entries_capacity = new_capacity;
    }

    /// Reserve the existing pin ledger before taking a block cell, so adding
    /// the construction pin after initialization is a no-fail scalar publish.
    pub fn prepareConstructionRoot(self: *Ledger, account: *memory.MemoryAccount) !void {
        try self.ensureCapacity(account, self.entries.len + 1);
        try self.set.ensureUnusedCapacity(account.persistent_allocator, 1);
    }

    /// Protect a fully initialized Object whose shape is intentionally not
    /// installed yet. Only the detached generator constructor has this
    /// lifetime; all other block-cell objects publish immediately.
    pub fn addConstructionRoot(self: *Ledger, header: *GCObjectHeader) void {
        std.debug.assert(header.metaConst().flags.kind == .object);
        std.debug.assert(!header.metaConst().alloc_info.heap_accounted);
        std.debug.assert(self.indexOf(header) == null);
        std.debug.assert(self.entries.len < self.entries_capacity);
        self.entries.ptr[self.entries.len] = .{
            .header = header,
            .count = gc.construction_pin_count,
        };
        self.entries = self.entries.ptr[0 .. self.entries.len + 1];
        self.set.putAssumeCapacity(@intFromPtr(header), {});
    }

    pub fn removeConstructionRoot(self: *Ledger, header: *GCObjectHeader) void {
        const index = self.indexOf(header) orelse unreachable;
        std.debug.assert(self.entries[index].count == gc.construction_pin_count);
        self.removeAt(index);
        _ = self.set.remove(@intFromPtr(header));
    }

    /// The first construction root still in the ledger, for teardown.
    pub fn firstConstructionRoot(self: *const Ledger) ?*GCObjectHeader {
        for (self.entries) |entry| {
            if (entry.count == gc.construction_pin_count) return entry.header;
        }
        return null;
    }

    pub fn isConstructionRoot(self: *const Ledger, header: *const GCObjectHeader) bool {
        const index = self.indexOf(header) orelse return false;
        if (self.entries[index].count != gc.construction_pin_count) return false;
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

    pub fn entryIsConstructionRoot(self: *const Ledger, entry: PinEntry) bool {
        return entry.count == gc.construction_pin_count and self.isConstructionRoot(entry.header);
    }
};
