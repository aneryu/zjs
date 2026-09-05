//! Two heap-side ledgers the Registry owns outright.
//!
//! `Tokens` is the off-account external-memory ledger: bytes the host holds
//! that the JS heap must nevertheless pace against. `NonBlockObjectAuthority`
//! is the membership authority for published Objects the block heap did not
//! serve.
//!
//! Both deliberately keep only mechanism. The pressure counters an external
//! allocation moves (`external_bytes`, `peak_external_bytes`,
//! `allocation_debt`) belong to the statistics block, so `Tokens` reports a
//! verdict and lets the Registry do the accounting; that is what keeps the
//! ledger's invariants ("an id appears once", "a release must match the
//! recorded byte count") readable in one place.
//!
//! Neither owns an allocator: the caller passes the account the Registry
//! already has.

const std = @import("std");
const gc = @import("gc.zig");
const memory = @import("memory.zig");

const GCObjectHeader = gc.GCObjectHeader;
const ExternalTokenEntry = gc.ExternalTokenEntry;

pub const Tokens = struct {
    entries: []ExternalTokenEntry = &.{},
    entries_capacity: usize = 0,
    /// Ids are never reused while an entry is live and never zero: zero is
    /// the "no token" spelling of `ExternalMemoryToken`.
    next_id: u64 = 1,

    /// Idempotent: a Registry rolled back halfway through construction can
    /// reach this twice.
    pub fn deinit(self: *Tokens, account: *memory.MemoryAccount) void {
        if (self.entries_capacity != 0) {
            account.free(ExternalTokenEntry, self.entries.ptr[0..self.entries_capacity]);
        } else if (self.entries.len != 0) {
            account.free(ExternalTokenEntry, self.entries);
        }
        self.entries = &.{};
        self.entries_capacity = 0;
    }

    pub fn count(self: Tokens) usize {
        return self.entries.len;
    }

    pub fn totalBytes(self: Tokens) usize {
        var total: usize = 0;
        for (self.entries) |entry| {
            total = std.math.add(usize, total, entry.bytes) catch std.math.maxInt(usize);
        }
        return total;
    }

    /// Record `bytes` and return the id that discharges them.
    pub fn add(self: *Tokens, account: *memory.MemoryAccount, bytes: usize) !u64 {
        try self.ensureCapacity(account, self.entries.len + 1);
        const id = self.takeId();
        self.entries.ptr[self.entries.len] = .{ .id = id, .bytes = bytes };
        self.entries = self.entries.ptr[0 .. self.entries.len + 1];
        return id;
    }

    /// Every way a release can be wrong, named. The Registry counts all three
    /// failures as one `external_invalid_release_count` tick, but the ledger
    /// does not need to know that.
    pub const Release = union(enum) {
        /// Discharged; these bytes leave the live ledger.
        released: usize,
        malformed,
        unknown_id,
        byte_mismatch,
    };

    pub fn release(self: *Tokens, id: u64, bytes: usize) Release {
        if (id == 0 or bytes == 0) {
            if (id != 0 or bytes != 0) return .malformed;
            // A zero token discharging zero bytes is the no-op token.
            return .{ .released = 0 };
        }
        const index = self.indexOf(id) orelse return .unknown_id;
        const entry = self.entries[index];
        if (entry.bytes != bytes) return .byte_mismatch;
        if (index + 1 < self.entries.len) {
            std.mem.copyForwards(
                ExternalTokenEntry,
                self.entries[index .. self.entries.len - 1],
                self.entries[index + 1 ..],
            );
        }
        self.entries = self.entries[0 .. self.entries.len - 1];
        return .{ .released = entry.bytes };
    }

    fn indexOf(self: Tokens, id: u64) ?usize {
        for (self.entries, 0..) |entry, index| {
            if (entry.id == id) return index;
        }
        return null;
    }

    fn takeId(self: *Tokens) u64 {
        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        return id;
    }

    fn ensureCapacity(self: *Tokens, account: *memory.MemoryAccount, required: usize) !void {
        if (required <= self.entries_capacity) return;
        var new_capacity = if (self.entries_capacity == 0) @as(usize, 8) else self.entries_capacity * 2;
        while (new_capacity < required) new_capacity *= 2;
        const next = try account.alloc(ExternalTokenEntry, new_capacity);
        errdefer account.free(ExternalTokenEntry, next);
        @memcpy(next[0..self.entries.len], self.entries);
        if (self.entries_capacity != 0) {
            account.free(ExternalTokenEntry, self.entries.ptr[0..self.entries_capacity]);
        } else if (self.entries.len != 0) {
            account.free(ExternalTokenEntry, self.entries);
        }
        self.entries = next[0..self.entries.len];
        self.entries_capacity = new_capacity;
    }
};

/// Header-external membership authority for published `.object` allocations
/// that are not served by the block heap. Block objects are enumerated by the
/// block allocation bitmap; every other traced kind remains on the intrusive
/// carrier list.
///
/// This intentionally stores only pointers. Object publication reserves one
/// slot before exposing a non-block allocation, so committing membership is a
/// no-fail append and no object/header byte is consumed. Removal is unordered:
/// collection is the only mutator, and none of the consumers assign semantic
/// meaning to allocation order.
pub const NonBlockObjectAuthority = struct {
    items: std.ArrayListUnmanaged(*GCObjectHeader) = .empty,
    /// Header-external condemnation lane. Object's body remains entirely
    /// semantic until its destructor strips resources, so neither live scalar
    /// nor Shape words may be borrowed by the morgue.
    doomed: std.ArrayListUnmanaged(*GCObjectHeader) = .empty,

    pub fn prepare(self: *NonBlockObjectAuthority, allocator: std.mem.Allocator) !void {
        try self.items.ensureUnusedCapacity(allocator, 1);
        const total_population = self.items.items.len + self.doomed.items.len + 1;
        try self.doomed.ensureTotalCapacity(allocator, total_population);
    }

    pub fn publish(self: *NonBlockObjectAuthority, header: *GCObjectHeader) void {
        std.debug.assert(header.metaConst().flags.kind == .object);
        std.debug.assert(!gc.Registry.isBlockCellHeader(header));
        self.items.appendAssumeCapacity(header);
    }

    fn indexOf(self: *const NonBlockObjectAuthority, header: *const GCObjectHeader) ?usize {
        for (self.items.items, 0..) |candidate, index| {
            if (candidate == header) return index;
        }
        return null;
    }

    pub fn remove(self: *NonBlockObjectAuthority, header: *const GCObjectHeader) bool {
        const index = self.indexOf(header) orelse return false;
        _ = self.items.swapRemove(index);
        return true;
    }

    pub fn condemn(self: *NonBlockObjectAuthority, header: *GCObjectHeader) void {
        const index = self.indexOf(header) orelse unreachable;
        _ = self.items.swapRemove(index);
        self.doomed.appendAssumeCapacity(header);
    }

    /// Idempotent: resets to the empty state so a partially constructed
    /// Registry can be torn down twice.
    pub fn deinit(self: *NonBlockObjectAuthority, allocator: std.mem.Allocator) void {
        std.debug.assert(self.doomed.items.len == 0);
        self.items.deinit(allocator);
        self.doomed.deinit(allocator);
        self.* = .{};
    }
};
