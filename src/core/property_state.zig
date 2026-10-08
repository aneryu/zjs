//! AutoInit descriptor pool and borrowed-holder bookkeeping.
//!
//! The stores live on `JSRuntime` but are not one lifetime: AutoInit records
//! live until runtime teardown, and borrowed holders are not the GC
//! weak-holder chain.

const std = @import("std");
const Object = @import("object.zig").Object;
const property = @import("property.zig");
const JSRuntime = @import("../runtime.zig").JSRuntime;

pub fn internAutoInit(rt: *JSRuntime, info: property.AutoInit) !*const property.AutoInit {
    for (rt.auto_init_descriptors.items) |stored| {
        if (stored.*.eql(info)) return stored;
    }
    const stored = try rt.createNative(property.AutoInit);
    errdefer rt.destroyNative(property.AutoInit, stored);
    stored.* = info;
    try rt.auto_init_descriptors.append(rt.nativeAllocator(), stored);
    return stored;
}

/// Free the runtime-lifetime stores at teardown.
pub fn deinit(rt: *JSRuntime) void {
    for (rt.auto_init_descriptors.items) |stored| rt.destroyNative(property.AutoInit, stored);
    rt.auto_init_descriptors.deinit(rt.nativeAllocator());
    rt.borrowed_reference_holders.deinit(rt.nativeAllocator());
}

pub fn registerBorrowedHolder(rt: *JSRuntime, object: *Object) !void {
    if (object.flags.is_borrowed_reference_holder) return;
    const index = rt.borrowed_reference_holders.items.len;
    try rt.borrowed_reference_holders.append(rt.nativeAllocator(), object);
    object.setBorrowedReferenceHolderIndex(index);
    object.flags.is_borrowed_reference_holder = true;
    object.markNeedsFinalizer(rt);
}

pub fn unregisterBorrowedHolder(rt: *JSRuntime, object: *Object) void {
    if (!object.flags.is_borrowed_reference_holder) return;
    if (object.borrowedReferenceHolderIndex()) |cached_index| {
        if (cached_index < rt.borrowed_reference_holders.items.len and rt.borrowed_reference_holders.items[cached_index] == object) {
            removeBorrowedHolderAt(rt, cached_index);
            return;
        }
    }
    var found: ?usize = null;
    for (rt.borrowed_reference_holders.items, 0..) |candidate, index| {
        if (candidate == object) {
            found = index;
            break;
        }
    }
    const index = found orelse return;
    removeBorrowedHolderAt(rt, index);
}

fn removeBorrowedHolderAt(rt: *JSRuntime, index: usize) void {
    const removed = rt.borrowed_reference_holders.swapRemove(index);
    if (index < rt.borrowed_reference_holders.items.len) {
        rt.borrowed_reference_holders.items[index].setBorrowedReferenceHolderIndex(index);
    }
    removed.setBorrowedReferenceHolderIndex(null);
    removed.flags.is_borrowed_reference_holder = false;
}

/// Identities of objects destroyed while borrowed holders are being cleared
/// (`JSRuntime.borrowed_weak_cleanup`). A cleanup pass may destroy further
/// globals; their identities queue here instead of recursing.
pub const BorrowedWeakCleanup = struct {
    identities: std.ArrayListUnmanaged(usize) = .empty,
    /// O(1) membership companion for `identities`. Only even (object)
    /// identities are inserted; symbol identities keep the slice scan.
    identity_set: std.AutoHashMapUnmanaged(usize, void) = .empty,
    active: bool = false,

    pub fn begin(self: *BorrowedWeakCleanup) void {
        std.debug.assert(!self.active);
        self.active = true;
        self.identity_set.clearRetainingCapacity();
        self.identities.clearRetainingCapacity();
    }

    pub fn end(self: *BorrowedWeakCleanup) void {
        self.active = false;
        self.identity_set.clearRetainingCapacity();
        self.identities.clearRetainingCapacity();
    }

    pub fn enqueue(self: *BorrowedWeakCleanup, allocator: std.mem.Allocator, identity: usize) !void {
        try self.identities.ensureUnusedCapacity(allocator, 1);
        if ((identity & 1) == 0) try self.identity_set.put(allocator, identity, {});
        self.identities.appendAssumeCapacity(identity);
    }

    /// Whether `identity` was queued at or after `start_index`. Object
    /// identities use the set, which covers the whole batch.
    pub inline fn matchesFrom(self: *const BorrowedWeakCleanup, start_index: usize, identity: usize) bool {
        if (identity == 0) return false;
        if ((identity & 1) == 0) return self.identity_set.contains(identity);
        var index = self.identities.items.len;
        while (index > start_index) {
            index -= 1;
            if (self.identities.items[index] == identity) return true;
        }
        return false;
    }

    pub fn deinit(self: *BorrowedWeakCleanup, allocator: std.mem.Allocator) void {
        self.identity_set.deinit(allocator);
        self.identities.deinit(allocator);
        self.* = .{};
    }
};
