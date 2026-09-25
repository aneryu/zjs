//! AutoInit descriptor pool, iterator-next side table, and borrowed-holder
//! bookkeeping.
//!
//! The three stores stay on `JSRuntime` so auto-layout does not move
//! `vm_stack`. They are not one lifetime: AutoInit records live until
//! runtime teardown, an iterator-next edge is traced only from its owning
//! object, and borrowed holders are not the GC weak-holder chain.

const std = @import("std");
const Object = @import("object.zig").Object;
const property = @import("property.zig");
const JSRuntime = @import("../runtime.zig").JSRuntime;
const JSValue = @import("value.zig").JSValue;

pub const CachedIteratorNextEntry = struct {
    object: *Object,
    value: ?JSValue = null,
};

pub fn internAutoInit(rt: *JSRuntime, info: property.AutoInit) !*const property.AutoInit {
    for (rt.auto_init_descriptors.items) |stored| {
        if (stored.*.eql(info)) return stored;
    }
    const stored = try rt.createRuntime(property.AutoInit);
    errdefer rt.destroyRuntime(property.AutoInit, stored);
    stored.* = info;
    try rt.auto_init_descriptors.append(rt.nativeAllocator(), stored);
    return stored;
}

pub fn deinitAutoInit(rt: *JSRuntime) void {
    for (rt.auto_init_descriptors.items) |stored| rt.destroyRuntime(property.AutoInit, stored);
    rt.auto_init_descriptors.deinit(rt.nativeAllocator());
}

pub fn iteratorNextSlot(rt: *JSRuntime, object: *Object) !*?JSValue {
    if (iteratorNextSlotIfPresent(rt, object)) |slot| return slot;
    const entry = try rt.cached_iterator_next_entries.addOne(rt.nativeAllocator());
    entry.* = .{ .object = object };
    object.flags.has_iterator_next = true;
    object.markNeedsFinalizer(rt);
    return &entry.value;
}

/// Rebind the entry of an object the collector moved, or moved back during
/// evacuation rollback. `previous` may be a forwarding husk; only its address
/// is compared. Does not allocate.
pub fn relocateIteratorNext(rt: *JSRuntime, previous: *const Object, current: *Object) void {
    if (!current.flags.has_iterator_next) return;
    const index = iteratorNextIndex(rt, previous) orelse
        @panic("gc: relocating object missing iterator-next entry");
    rt.cached_iterator_next_entries.items[index].object = current;
}

pub fn iteratorNext(rt: *JSRuntime, object: *const Object) ?JSValue {
    const slot = iteratorNextSlotIfPresent(rt, object) orelse return null;
    return slot.*;
}

pub fn clearIteratorNext(rt: *JSRuntime, object: *Object) void {
    if (rt.cached_iterator_next_entries.items.len == 0) return;
    const index = iteratorNextIndex(rt, object) orelse return;
    rt.cached_iterator_next_entries.items[index].value = null;
    removeIteratorNextAt(rt, index);
    object.flags.has_iterator_next = false;
}

pub fn iteratorNextSlotIfPresent(rt: *JSRuntime, object: *const Object) ?*?JSValue {
    if (rt.cached_iterator_next_entries.items.len == 0) return null;
    const index = iteratorNextIndex(rt, object) orelse return null;
    return &rt.cached_iterator_next_entries.items[index].value;
}

pub fn deinitIteratorNext(rt: *JSRuntime) void {
    rt.cached_iterator_next_entries.deinit(rt.nativeAllocator());
}

fn iteratorNextIndex(rt: *const JSRuntime, object: *const Object) ?usize {
    if (rt.cached_iterator_next_entries.items.len == 0) return null;
    for (rt.cached_iterator_next_entries.items, 0..) |entry, index| {
        if (entry.object == object) return index;
    }
    return null;
}

fn removeIteratorNextAt(rt: *JSRuntime, index: usize) void {
    _ = rt.cached_iterator_next_entries.swapRemove(index);
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

pub fn deinitBorrowedHolders(rt: *JSRuntime) void {
    rt.borrowed_reference_holders.deinit(rt.nativeAllocator());
}

fn removeBorrowedHolderAt(rt: *JSRuntime, index: usize) void {
    const removed = rt.borrowed_reference_holders.swapRemove(index);
    if (index < rt.borrowed_reference_holders.items.len) {
        rt.borrowed_reference_holders.items[index].setBorrowedReferenceHolderIndex(index);
    }
    removed.setBorrowedReferenceHolderIndex(null);
    removed.flags.is_borrowed_reference_holder = false;
}

pub fn beginBorrowedCleanup(rt: *JSRuntime) void {
    std.debug.assert(!rt.borrowed_weak_cleanup_active);
    rt.borrowed_weak_cleanup_active = true;
    rt.borrowed_weak_cleanup_identity_set.clearRetainingCapacity();
    rt.borrowed_weak_cleanup_identities.clearRetainingCapacity();
}

pub fn endBorrowedCleanup(rt: *JSRuntime) void {
    rt.borrowed_weak_cleanup_active = false;
    rt.borrowed_weak_cleanup_identity_set.clearRetainingCapacity();
    rt.borrowed_weak_cleanup_identities.clearRetainingCapacity();
}

pub fn enqueueBorrowedCleanupIdentity(rt: *JSRuntime, identity: usize) !void {
    try rt.borrowed_weak_cleanup_identities.ensureUnusedCapacity(rt.nativeAllocator(), 1);
    if ((identity & 1) == 0) {
        try rt.borrowed_weak_cleanup_identity_set.put(rt.nativeAllocator(), identity, {});
    }
    rt.borrowed_weak_cleanup_identities.appendAssumeCapacity(identity);
}

pub fn borrowedCleanupIdentityMatches(rt: *const JSRuntime, identity: usize) bool {
    if (identity == 0) return false;
    if ((identity & 1) == 0) {
        return rt.borrowed_weak_cleanup_identity_set.contains(identity);
    }
    var index = rt.borrowed_weak_cleanup_identities.items.len;
    while (index != 0) {
        index -= 1;
        if (rt.borrowed_weak_cleanup_identities.items[index] == identity) return true;
    }
    return false;
}

pub inline fn borrowedCleanupIdentityMatchesSlice(rt: *const JSRuntime, start_index: usize, identity: usize) bool {
    if (identity == 0) return false;
    if ((identity & 1) == 0) {
        return rt.borrowed_weak_cleanup_identity_set.contains(identity);
    }
    var index = rt.borrowed_weak_cleanup_identities.items.len;
    while (index > start_index) {
        index -= 1;
        if (rt.borrowed_weak_cleanup_identities.items[index] == identity) return true;
    }
    return false;
}

pub fn clearBorrowedCleanup(rt: *JSRuntime) void {
    rt.borrowed_weak_cleanup_identity_set.clearRetainingCapacity();
    rt.borrowed_weak_cleanup_identities.clearAndFree(rt.nativeAllocator());
    rt.borrowed_weak_cleanup_active = false;
}

pub fn deinitBorrowedCleanup(rt: *JSRuntime) void {
    rt.borrowed_weak_cleanup_identity_set.deinit(rt.nativeAllocator());
    rt.borrowed_weak_cleanup_identities.deinit(rt.nativeAllocator());
}
