//! Weak object identities and the intrusive weak-holder chain
//! (`JSRuntime.weak`). This module owns register, unlink, and the paired map
//! update. Borrowed-holder tables and WeakRef [[KeptAlive]] live elsewhere.
//!
//! An object identity is `weak_id << 1`; a symbol identity is `atom << 1 | 1`
//! (`Identity`). Object ids are monotonic and are not reused.
//! Both maps are updated together: a failed second insert rolls the first
//! back, and death removes both entries in the same `take` before the object
//! storage is reused.

const std = @import("std");
const atom_mod = @import("atom.zig");
const object_mod = @import("object.zig");
const JSValue = @import("value.zig").JSValue;
const Object = object_mod.Object;
const JSRuntime = @import("../runtime.zig").JSRuntime;

/// The encoding stored in weak slots. Every encode/decode goes through here.
pub const Identity = struct {
    pub inline fn ofObjectId(weak_id: usize) usize {
        return weak_id << 1;
    }

    pub inline fn ofSymbol(atom_id: atom_mod.Atom) usize {
        return (@as(usize, atom_id.raw()) << 1) | 1;
    }

    pub inline fn isSymbol(identity: usize) bool {
        return (identity & 1) != 0;
    }

    /// The registry id of an object identity; null for a symbol identity.
    pub inline fn objectId(identity: usize) ?usize {
        if (isSymbol(identity)) return null;
        return identity >> 1;
    }

    /// The atom of a symbol identity; null for an object identity or an id
    /// outside the atom range.
    pub inline fn symbolAtom(identity: usize) ?atom_mod.Atom {
        if (!isSymbol(identity)) return null;
        const atom_id = identity >> 1;
        if (atom_id > std.math.maxInt(u32)) return null;
        return atom_mod.Atom.fromRaw(@intCast(atom_id));
    }
};

/// Weak slots (WeakRef/WeakMap/WeakSet/FinalizationRegistry/WeakRootSlot)
/// store `weak_id << 1` instead of the header address, so a recycled
/// allocation can never alias a stale identity and lookups are O(1).
pub const Registry = struct {
    /// Intrusive chain of live weak-capable payload objects.
    holder_head: ?*Object = null,
    holder_tail: ?*Object = null,
    /// Header address -> weak id.
    object_ids: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    /// Weak id -> object; a hit is the liveness test.
    id_objects: std.AutoHashMapUnmanaged(usize, *Object) = .empty,
    next_id: usize = 1,
    /// Removals since both maps were last rehashed. A std hash map removal
    /// leaves a tombstone and never regrows, and weak ids only increase, so
    /// without a rehash churn fills the tables with tombstones and every
    /// lookup of an absent key probes the whole table.
    removals_since_rehash: usize = 0,

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        std.debug.assert(self.holder_head == null and self.holder_tail == null);
        self.object_ids.deinit(allocator);
        self.id_objects.deinit(allocator);
    }

    /// Allocation-free; amortized O(1) per removal.
    fn noteRemoval(self: *Registry) void {
        self.removals_since_rehash += 1;
        const capacity = @max(self.object_ids.capacity(), self.id_objects.capacity());
        if (self.removals_since_rehash * 4 < capacity) return;
        self.removals_since_rehash = 0;
        if (self.object_ids.capacity() != 0) self.object_ids.rehash(std.hash_map.AutoContext(usize){});
        if (self.id_objects.capacity() != 0) self.id_objects.rehash(std.hash_map.AutoContext(usize){});
    }
};

/// Link a weak-capable payload for its lifetime. Allocation-free. The weak
/// pass walks the chain without splicing it.
pub fn registerHolder(rt: *JSRuntime, object: *Object) void {
    std.debug.assert(object.isWeakReferenceHolderClass());
    const link = object.weakReferenceHolderLink().?;
    std.debug.assert(!link.registered);
    std.debug.assert(link.previous == null);
    std.debug.assert(link.next == null);

    link.previous = rt.weak.holder_tail;
    if (rt.weak.holder_tail) |tail| {
        const tail_link = tail.weakReferenceHolderLink().?;
        std.debug.assert(tail_link.registered);
        tail_link.next = object;
    } else {
        rt.weak.holder_head = object;
    }
    rt.weak.holder_tail = object;
    link.registered = true;
    // The object unlinks itself at death (`unregisterHolder`).
    object.markNeedsFinalizer(rt);
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
        std.debug.assert(rt.weak.holder_head == object);
        rt.weak.holder_head = link.next;
    }
    if (link.next) |next| {
        const next_link = next.weakReferenceHolderLink().?;
        std.debug.assert(next_link.registered);
        next_link.previous = link.previous;
    } else {
        std.debug.assert(rt.weak.holder_tail == object);
        rt.weak.holder_tail = link.previous;
    }
    link.previous = null;
    link.next = null;
    link.registered = false;
}

/// Even identities only. Symbol identities (low bit set) are not in this table.
pub fn objectFromIdentity(rt: *const JSRuntime, identity: usize) ?*Object {
    return rt.weak.id_objects.get(Identity.objectId(identity) orelse return null);
}

/// Object identities are not counted: a token stays valid until its object
/// dies, and death hands it back (`takeObject`). Only symbol identities,
/// whose atom entry is kept indexed by this count, are counted.
pub fn retain(rt: *JSRuntime, identity: usize) void {
    rt.atoms.retainSymbolWeakRef(Identity.symbolAtom(identity) orelse return);
}

/// Mirror of `retain`: releasing an object identity is a no-op because
/// nothing was retained.
pub fn release(rt: *JSRuntime, identity: usize) void {
    rt.atoms.releaseSymbolWeakRef(rt, Identity.symbolAtom(identity) orelse return);
}

/// Empty a weak slot and release what it held.
pub fn clearSlot(rt: *JSRuntime, slot: *?usize) void {
    const identity = slot.* orelse return;
    slot.* = null;
    release(rt, identity);
}

pub fn isLive(rt: *const JSRuntime, identity: usize) bool {
    if (Identity.isSymbol(identity)) {
        const symbol_atom = Identity.symbolAtom(identity) orelse return false;
        return rt.atoms.kind(symbol_atom) == .symbol;
    }
    return objectFromIdentity(rt, identity) != null;
}

/// The value a live identity names, or undefined once it is gone.
pub fn toValue(rt: *JSRuntime, identity: usize) JSValue {
    if (Identity.isSymbol(identity)) {
        const symbol_atom = Identity.symbolAtom(identity) orelse return JSValue.undefinedValue();
        if (rt.atoms.kind(symbol_atom) != .symbol) return JSValue.undefinedValue();
        return rt.atoms.symbolValueIfLive(rt, symbol_atom);
    }
    const object = objectFromIdentity(rt, identity) orelse return JSValue.undefinedValue();
    return object.value();
}

/// Encoded weak identity (`weak_id << 1`). First registration allocates a
/// fresh id. The second map insert rolls back the first on failure, and
/// `next_id` advances only after both inserts succeed.
pub fn registerObject(rt: *JSRuntime, object: *Object) !usize {
    const address = @intFromPtr(object.gcHeaderConst()) & ~@as(usize, 1);
    if (object.flags.has_weak_id) {
        const weak_id = rt.weak.object_ids.get(address).?;
        return Identity.ofObjectId(weak_id);
    }
    const weak_id = rt.weak.next_id;
    try rt.weak.object_ids.put(rt.nativeAllocator(), address, weak_id);
    rt.weak.id_objects.put(rt.nativeAllocator(), weak_id, object) catch |err| {
        _ = rt.weak.object_ids.remove(address);
        return err;
    };
    rt.weak.next_id += 1;
    object.flags.has_weak_id = true;
    // The finalizer bit stays. Death returns the id from the destructor
    // (`takeObject`), which only runs for the finalizer set. Clearing the bit
    // here would leave this pair pointing at freed memory, and a hit in
    // `id_objects` is the liveness test.
    object.markNeedsFinalizer(rt);
    return Identity.ofObjectId(weak_id);
}

pub fn peekObject(rt: *const JSRuntime, object: *const Object) ?usize {
    if (!object.flags.has_weak_id) return null;
    const address = @intFromPtr(object.gcHeaderConst()) & ~@as(usize, 1);
    const weak_id = rt.weak.object_ids.get(address) orelse return null;
    return Identity.ofObjectId(weak_id);
}

/// Rebind the address half of an existing identity for an object the
/// collector moved, or moved back during evacuation rollback; promotion and
/// rollback both come through here so no table is left naming the husk.
/// The id is unchanged and nothing is allocated. Removing the old key supplies capacity for its replacement.
/// `previous` may already be a forwarding husk; only its address is read.
/// The evacuation journal calls this in reverse when restoring the source.
pub fn relocateObject(rt: *JSRuntime, previous: *const Object, current: *Object) void {
    if (!current.flags.has_weak_id) return;
    const old_address = @intFromPtr(previous.gcHeaderConst());
    const new_address = @intFromPtr(current.gcHeader());
    std.debug.assert(old_address != new_address);
    const entry = rt.weak.object_ids.fetchRemove(old_address) orelse
        @panic("gc: relocating object missing weak identity");
    const registered = rt.weak.id_objects.getPtr(entry.value) orelse
        @panic("gc: relocating weak identity missing reverse entry");
    std.debug.assert(registered.* == previous);
    rt.weak.object_ids.putAssumeCapacityNoClobber(new_address, entry.value);
    registered.* = current;
    rt.weak.noteRemoval();
}

/// Removes `object` from both maps and returns its encoded identity.
/// Does not clear weak slots, run callbacks, or reuse `next_id`.
pub fn takeObject(rt: *JSRuntime, object: *Object) ?usize {
    if (!object.flags.has_weak_id) return null;
    object.flags.has_weak_id = false;
    const address = @intFromPtr(object.gcHeader()) & ~@as(usize, 1);
    const weak_id = rt.weak.object_ids.get(address) orelse return null;
    _ = rt.weak.object_ids.remove(address);
    _ = rt.weak.id_objects.remove(weak_id);
    rt.weak.noteRemoval();
    return Identity.ofObjectId(weak_id);
}
