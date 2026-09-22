//! Weak object identities and the intrusive weak-holder chain.
//!
//! The fields stay on `JSRuntime` (`weak_reference_holder_head` / `_tail`,
//! `weak_object_ids`, `weak_id_objects`, `next_weak_id`). The runtime struct
//! is auto-layout and `vm_stack` is `align(64)`, so grouping those fields
//! would repack the cold tail. This module owns register, unlink, and the
//! paired map update. Borrowed-holder tables and WeakRef [[KeptAlive]] stay
//! where they are.
//!
//! An object identity is `weak_id << 1`. Ids are monotonic and are not reused.
//! Both maps are updated together: a failed second insert rolls the first
//! back, and death removes both entries in the same `take` before the object
//! storage is reused.

const std = @import("std");
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const JSRuntime = @import("runtime.zig").JSRuntime;

/// Link a weak-capable payload for its lifetime. Allocation-free. The weak
/// pass walks the chain without splicing it.
pub fn registerHolder(rt: *JSRuntime, object: *Object) void {
    std.debug.assert(object.isWeakReferenceHolderClass());
    const link = object.weakReferenceHolderLink().?;
    std.debug.assert(!link.registered);
    std.debug.assert(link.previous == null);
    std.debug.assert(link.next == null);

    link.previous = rt.weak_reference_holder_tail;
    if (rt.weak_reference_holder_tail) |tail| {
        const tail_link = tail.weakReferenceHolderLink().?;
        std.debug.assert(tail_link.registered);
        tail_link.next = object;
    } else {
        rt.weak_reference_holder_head = object;
    }
    rt.weak_reference_holder_tail = object;
    link.registered = true;
    // The object unlinks itself at death (`unregisterHolder`).
    object.markNeedsFinalizer(rt);
}

pub fn holderHead(rt: *const JSRuntime) ?*Object {
    return rt.weak_reference_holder_head;
}

pub fn unregisterHolder(rt: *JSRuntime, object: *Object) void {
    if (!object.isWeakReferenceHolderClass()) return;
    const link = object.weakReferenceHolderLink() orelse return;
    if (!link.registered) return;

    if (link.previous) |previous| {
        const previous_link = previous.weakReferenceHolderLink().?;
        std.debug.assert(previous_link.registered);
        previous_link.next = link.next;
    } else {
        std.debug.assert(rt.weak_reference_holder_head == object);
        rt.weak_reference_holder_head = link.next;
    }
    if (link.next) |next| {
        const next_link = next.weakReferenceHolderLink().?;
        std.debug.assert(next_link.registered);
        next_link.previous = link.previous;
    } else {
        std.debug.assert(rt.weak_reference_holder_tail == object);
        rt.weak_reference_holder_tail = link.previous;
    }
    link.previous = null;
    link.next = null;
    link.registered = false;
}

pub fn deinitIds(rt: *JSRuntime, allocator: std.mem.Allocator) void {
    rt.weak_object_ids.deinit(allocator);
    rt.weak_id_objects.deinit(allocator);
}

/// Even identities only. Symbol identities (low bit set) are not in this table.
pub fn objectFromIdentity(rt: *const JSRuntime, identity: usize) ?*Object {
    if ((identity & 1) != 0) return null;
    return rt.weak_id_objects.get(identity >> 1);
}

/// Encoded weak identity (`weak_id << 1`). First registration allocates a
/// fresh id. The second map insert rolls back the first on failure, and
/// `next_weak_id` advances only after both inserts succeed.
pub fn registerObject(rt: *JSRuntime, object: *Object) !usize {
    const address = @intFromPtr(object.gcHeaderConst()) & ~@as(usize, 1);
    if (object.flags.has_weak_id) {
        const weak_id = rt.weak_object_ids.get(address).?;
        return weak_id << 1;
    }
    const weak_id = rt.next_weak_id;
    try rt.weak_object_ids.put(rt.nativeAllocator(), address, weak_id);
    rt.weak_id_objects.put(rt.nativeAllocator(), weak_id, object) catch |err| {
        _ = rt.weak_object_ids.remove(address);
        return err;
    };
    rt.next_weak_id += 1;
    object.flags.has_weak_id = true;
    // The finalizer bit stays. Death returns the id from the destructor
    // (`takeObject`), which only runs for the finalizer set. Clearing the bit
    // here would leave this pair pointing at freed memory, and a hit in
    // `weak_id_objects` is the liveness test.
    object.markNeedsFinalizer(rt);
    return weak_id << 1;
}

pub fn peekObject(rt: *const JSRuntime, object: *const Object) ?usize {
    if (!object.flags.has_weak_id) return null;
    const address = @intFromPtr(object.gcHeaderConst()) & ~@as(usize, 1);
    const weak_id = rt.weak_object_ids.get(address) orelse return null;
    return weak_id << 1;
}

/// Removes `object` from both maps and returns its encoded identity.
/// Does not clear weak slots, run callbacks, or reuse `next_weak_id`.
pub fn takeObject(rt: *JSRuntime, object: *Object) ?usize {
    if (!object.flags.has_weak_id) return null;
    object.flags.has_weak_id = false;
    const address = @intFromPtr(object.gcHeader()) & ~@as(usize, 1);
    const weak_id = rt.weak_object_ids.get(address) orelse return null;
    _ = rt.weak_object_ids.remove(address);
    _ = rt.weak_id_objects.remove(weak_id);
    return weak_id << 1;
}
