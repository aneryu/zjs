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

const ExternalTokenEntry = gc.ExternalTokenEntry;
const Header = gc.Header;

pub const Tokens = struct {
    entries: std.ArrayListUnmanaged(ExternalTokenEntry) = .empty,
    /// Ids are never reused while an entry is live and never zero: zero is
    /// the "no token" spelling of `ExternalMemoryToken`.
    next_id: u64 = 1,

    /// Idempotent: a Registry rolled back halfway through construction can
    /// reach this twice.
    pub fn deinit(self: *Tokens, account: *@import("runtime.zig").JSRuntime) void {
        self.entries.deinit(account.nativeAllocator());
        self.entries = .empty;
    }

    pub fn count(self: Tokens) usize {
        return self.entries.items.len;
    }

    pub fn totalBytes(self: Tokens) usize {
        var total: usize = 0;
        for (self.entries.items) |entry| {
            total = std.math.add(usize, total, entry.bytes) catch std.math.maxInt(usize);
        }
        return total;
    }

    /// Record `bytes` and return the id that discharges them.
    pub fn add(self: *Tokens, account: *@import("runtime.zig").JSRuntime, bytes: usize) !u64 {
        try self.entries.ensureUnusedCapacity(account.nativeAllocator(), 1);
        const id = self.takeId();
        self.entries.appendAssumeCapacity(.{ .id = id, .bytes = bytes });
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
        const entry = self.entries.items[index];
        if (entry.bytes != bytes) return .byte_mismatch;
        _ = self.entries.orderedRemove(index);
        return .{ .released = entry.bytes };
    }

    fn indexOf(self: Tokens, id: u64) ?usize {
        for (self.entries.items, 0..) |entry, index| {
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
    items: std.ArrayListUnmanaged(*Header) = .empty,
    /// Header-external condemnation lane. Object's body remains entirely
    /// semantic until its destructor strips resources, so neither live scalar
    /// nor Shape words may be borrowed by the morgue.
    doomed: std.ArrayListUnmanaged(*Header) = .empty,

    pub fn prepare(self: *NonBlockObjectAuthority, allocator: std.mem.Allocator) !void {
        try self.items.ensureUnusedCapacity(allocator, 1);
        const total_population = self.items.items.len + self.doomed.items.len + 1;
        try self.doomed.ensureTotalCapacity(allocator, total_population);
    }

    pub fn publish(self: *NonBlockObjectAuthority, header: *Header) void {
        std.debug.assert(header.metaConst().flags.kind == .object);
        std.debug.assert(!gc.Registry.isBlockCellHeader(header));
        self.items.appendAssumeCapacity(header);
    }

    fn indexOf(self: *const NonBlockObjectAuthority, header: *const Header) ?usize {
        for (self.items.items, 0..) |candidate, index| {
            if (candidate == header) return index;
        }
        return null;
    }

    pub fn remove(self: *NonBlockObjectAuthority, header: *const Header) bool {
        const index = self.indexOf(header) orelse return false;
        _ = self.items.swapRemove(index);
        return true;
    }

    pub fn condemn(self: *NonBlockObjectAuthority, header: *Header) void {
        const index = self.indexOf(header).?;
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
