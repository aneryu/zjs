//! AutoInit descriptor pool and borrowed-holder bookkeeping.
//!
//! `JSRuntime` embeds one `State`; this module owns its operations and
//! teardown. The stores are not one lifetime: AutoInit records live until
//! runtime teardown, borrowed holders are not the GC weak-holder chain, and
//! the weak-cleanup batch exists only while holders are being cleared.

const std = @import("std");
const gc_weak = @import("gc_weak.zig");
const Object = @import("object.zig").Object;
const property = @import("property.zig");
const JSRuntime = @import("../runtime.zig").JSRuntime;

/// Property side tables embedded in `JSRuntime.property_tables`.
pub const State = struct {
    /// Objects that may hold borrowed references; each caches its index.
    borrowed_holders: std.ArrayListUnmanaged(*Object) = .empty,
    weak_cleanup: BorrowedWeakCleanup = .{},
    auto_init: std.ArrayListUnmanaged(*property.AutoInit) = .empty,
};

/// The runtime-lifetime AutoInit record equal to `info`, created on first use.
pub fn internAutoInit(rt: *JSRuntime, info: property.AutoInit) !*const property.AutoInit {
    for (rt.property_tables.auto_init.items) |stored| {
        if (stored.*.eql(info)) return stored;
    }
    const stored = try rt.createNative(property.AutoInit);
    errdefer rt.destroyNative(property.AutoInit, stored);
    stored.* = info;
    try rt.property_tables.auto_init.append(rt.nativeAllocator(), stored);
    return stored;
}

/// Free the runtime-lifetime stores at teardown.
pub fn deinit(rt: *JSRuntime) void {
    const state = &rt.property_tables;
    for (state.auto_init.items) |stored| rt.destroyNative(property.AutoInit, stored);
    state.auto_init.deinit(rt.nativeAllocator());
    state.borrowed_holders.deinit(rt.nativeAllocator());
    state.weak_cleanup.deinit(rt.nativeAllocator());
}

/// Enter `object` on the holder list. Returns whether this call inserted it,
/// so an errdefer can undo exactly its own registration.
pub fn registerHolder(rt: *JSRuntime, object: *Object) error{OutOfMemory}!bool {
    if (object.flags.is_borrowed_reference_holder) return false;
    const holders = &rt.property_tables.borrowed_holders;
    const index = holders.items.len;
    try holders.append(rt.nativeAllocator(), object);
    object.setBorrowedReferenceHolderIndex(index);
    object.flags.is_borrowed_reference_holder = true;
    object.markNeedsFinalizer(rt);
    return true;
}

pub fn unregisterHolder(rt: *JSRuntime, object: *Object) void {
    if (!object.flags.is_borrowed_reference_holder) return;
    const state = &rt.property_tables;
    const index = holderIndex(state, object) orelse return;
    const removed = state.borrowed_holders.swapRemove(index);
    if (index < state.borrowed_holders.items.len) {
        state.borrowed_holders.items[index].setBorrowedReferenceHolderIndex(index);
    }
    removed.setBorrowedReferenceHolderIndex(null);
    removed.flags.is_borrowed_reference_holder = false;
}

/// `object`'s position on the holder list: its cached index when that still
/// names it, else a scan (a callback may have reshuffled the list).
fn holderIndex(state: *State, object: *Object) ?usize {
    if (!object.flags.is_borrowed_reference_holder) return null;
    const holders = state.borrowed_holders.items;
    if (object.borrowedReferenceHolderIndex()) |cached| {
        if (cached < holders.len and holders[cached] == object) return cached;
    }
    for (holders, 0..) |candidate, index| {
        if (candidate == object) {
            object.setBorrowedReferenceHolderIndex(index);
            return index;
        }
    }
    return null;
}

/// Which destroyed identities a holder must drop: one identity, or every
/// identity queued in the current cleanup batch from `start_index` on.
pub const IdentityMatcher = union(enum) {
    single: usize,
    runtime_batch: usize,

    pub inline fn matches(self: IdentityMatcher, rt: *JSRuntime, identity: usize) bool {
        return switch (self) {
            .single => |stored| stored == identity,
            .runtime_batch => |start_index| rt.property_tables.weak_cleanup.matchesFrom(start_index, identity),
        };
    }
};

/// A destroyed realm global may still be named by raw borrowed pointers in
/// holders (realm-global identities). Clear them now; a cleanup pass that
/// destroys further globals queues their identities into the same batch.
pub fn onGlobalDestroyed(rt: *JSRuntime, destroyed: *Object) void {
    if (rt.gc.isTearingDown()) return;
    // The raw address identity only drives borrowed raw-pointer cleanup
    // such as realm-global pointers. Registered weak identities are kept
    // until the qjs-style weak sweep releases them.
    const destroyed_identity = @intFromPtr(destroyed.gcHeader()) & ~@as(usize, 1);
    if (rt.property_tables.borrowed_holders.items.len == 0) return;
    if (!destroyed.isGlobal()) return;
    const cleanup = &rt.property_tables.weak_cleanup;
    if (cleanup.active) {
        cleanup.enqueue(rt.nativeAllocator(), destroyed_identity) catch {
            clearBorrowedReferencesForDestroyedIdentity(rt, destroyed_identity);
        };
        return;
    }

    cleanup.begin();
    defer cleanup.end();
    cleanup.enqueue(rt.nativeAllocator(), destroyed_identity) catch {
        clearBorrowedReferencesForDestroyedIdentity(rt, destroyed_identity);
    };

    drainBorrowedWeakCleanup(rt);
}

fn drainBorrowedWeakCleanup(rt: *JSRuntime) void {
    var scanned_identity_count: usize = 0;
    while (scanned_identity_count < rt.property_tables.weak_cleanup.identities.items.len) {
        clearBorrowedReferencesForMatcher(rt, .{ .runtime_batch = scanned_identity_count });
        scanned_identity_count = rt.property_tables.weak_cleanup.identities.items.len;
    }
}

fn clearBorrowedReferencesForDestroyedIdentity(rt: *JSRuntime, destroyed_identity: usize) void {
    clearBorrowedReferencesForMatcher(rt, .{ .single = destroyed_identity });
}

fn clearBorrowedReferencesForMatcher(rt: *JSRuntime, matcher: IdentityMatcher) void {
    refreshBorrowedReferenceHolderIndexes(rt);
    var finalization_enqueue_blocked = false;
    var index: usize = 0;
    while (index < rt.property_tables.borrowed_holders.items.len) {
        const current = rt.property_tables.borrowed_holders.items[index];
        if (!current.mayContainBorrowedReferences()) {
            index += 1;
            continue;
        }
        current.clearBorrowedReferencesToDestroyedIdentities(rt, matcher, &finalization_enqueue_blocked);
        if (index < rt.property_tables.borrowed_holders.items.len and rt.property_tables.borrowed_holders.items[index] == current) {
            index += 1;
            continue;
        }
        const current_index = holderIndex(&rt.property_tables, current) orelse {
            continue;
        };
        if (current_index < rt.property_tables.borrowed_holders.items.len and rt.property_tables.borrowed_holders.items[current_index] == current) {
            index = current_index + 1;
        } else {
            index = current_index;
        }
    }
}

/// Re-stamp every holder's cached position so the matcher loop below can
/// trust `borrowedReferenceHolderIndex()` after a callback reshuffles the
/// list. TGC S4-e: this pass used to COMPACT the list as well, because a
/// weak husk could sit in it as an already-destroyed entry. Husks are gone
/// -- an entry leaves this list in `unregisterHolder`,
/// inside the holder's own destructor -- so only the index repair is left,
/// which is what the name now says.
fn refreshBorrowedReferenceHolderIndexes(rt: *JSRuntime) void {
    for (rt.property_tables.borrowed_holders.items, 0..) |current, index| {
        current.setBorrowedReferenceHolderIndex(index);
    }
}

/// Identities of objects destroyed while borrowed holders are being cleared
/// (`State.weak_cleanup`). A cleanup pass may destroy further
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
        if (!gc_weak.Identity.isSymbol(identity)) try self.identity_set.put(allocator, identity, {});
        self.identities.appendAssumeCapacity(identity);
    }

    /// Whether `identity` was queued at or after `start_index`. Object
    /// identities use the set, which covers the whole batch.
    pub inline fn matchesFrom(self: *const BorrowedWeakCleanup, start_index: usize, identity: usize) bool {
        if (identity == 0) return false;
        if (!gc_weak.Identity.isSymbol(identity)) return self.identity_set.contains(identity);
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
