//! The tracer's intrusive header lists, and the Registry's cursors into them.
//!
//! One list holds every published non-Object carrier in allocation order
//! (qjs `rt->gc_obj_list`). Published Objects are deliberately absent: block
//! cells are enumerated by allocation bitmaps and the rare non-block
//! population uses a side authority.
//!
//! Each list is a cyclic sentinel with a per-list tail word (list.h). The
//! extra word is paid once per list, never once per object; the QuickJS
//! doubly-linked node it replaced went with the rc collector, so removal
//! normally rides a traversal that already carries the predecessor. The two
//! kinds a mutator can unlink at an arbitrary position -- Shape and Realm --
//! keep a backlink in body space instead.

const std = @import("std");
const gc = @import("gc.zig");
const shape = @import("shape.zig");
const context_mod = @import("context.zig");

const Header = gc.GCObjectHeader;
const GCObjectHeader = gc.GCObjectHeader;
const GcKind = gc.GcKind;
const InvariantError = gc.InvariantError;

/// Shape and Realm may be relocated or rolled back at an arbitrary list
/// position. They store the backlink removed from the compact Header in body
/// space; other kinds are detached by collector cursor walks.
inline fn storedListPrevious(h: *const Header) ?*Header {
    return switch (h.metaConst().flags.kind) {
        .shape => blk: {
            const owner: *const shape.Shape = @alignCast(@fieldParentPtr("header", h));
            break :blk owner.trace_list_previous.previous();
        },
        .realm_context => blk: {
            const owner: *const context_mod.JSContext = @alignCast(@fieldParentPtr("header", h));
            break :blk owner.traceListPreviousPtrConst().*;
        },
        else => null,
    };
}

inline fn setStoredListPrevious(h: *Header, previous: ?*Header) void {
    switch (h.metaConst().flags.kind) {
        .shape => {
            const owner: *shape.Shape = @alignCast(@fieldParentPtr("header", h));
            owner.trace_list_previous.setPrevious(previous);
        },
        .realm_context => {
            const owner: *context_mod.JSContext = @alignCast(@fieldParentPtr("header", h));
            owner.traceListPreviousPtr().* = previous;
        },
        else => {},
    }
}

/// Intrusive-list authority: the compact non-Object successor plus this per-list
/// tail. The extra word is paid once per list, never once per object. (The
/// QuickJS doubly-linked node it replaced went with the rc collector.)
pub const IntrusiveHeaderList = struct {
    sentinel: Header = .{},
    /// Empty lists point at their own sentinel. This keeps append/delete in
    /// the same branch-free shape as the old intrusive sentinel: the tail link
    /// is always writable, including for the first element.
    tail: ?*Header = null,
};

pub inline fn listInit(head: *IntrusiveHeaderList) void {
    head.sentinel.next_non_object = &head.sentinel;
    head.tail = &head.sentinel;
}

pub inline fn listEmpty(head: *const IntrusiveHeaderList) bool {
    return head.sentinel.next_non_object == @constCast(&head.sentinel);
}

pub inline fn listAddTail(head: *IntrusiveHeaderList, el: *Header) void {
    std.debug.assert(el.metaConst().flags.kind != .object);
    std.debug.assert(el.next_non_object == null);
    const previous = head.tail.?;
    el.next_non_object = &head.sentinel;
    previous.next_non_object = el;
    head.tail = el;
    setStoredListPrevious(el, previous);
}

/// Append to a collector-private list whose every removal is performed by a
/// forward traversal already carrying the predecessor. Such lists never need
/// Shape/Realm's arbitrary-unlink backlink, so do not pay the kind dispatch
/// that maintains it on the allocation-ordered `gc_obj_list`.
pub inline fn listAddTailTraversalOwned(head: *IntrusiveHeaderList, el: *Header) void {
    std.debug.assert(el.metaConst().flags.kind != .object);
    std.debug.assert(el.next_non_object == null);
    const previous = head.tail.?;
    el.next_non_object = &head.sentinel;
    previous.next_non_object = el;
    head.tail = el;
}

/// Return the predecessor of `el` in `head`. Callers that do not already hold
/// a traversal cursor pay one cold forward scan, except for the two kinds that
/// keep an accelerator backlink in their body.
pub inline fn listPrevious(head: *IntrusiveHeaderList, el: *Header) *Header {
    switch (el.metaConst().flags.kind) {
        .shape, .realm_context => {
            const previous = storedListPrevious(el) orelse unreachable;
            std.debug.assert(previous.next_non_object == el);
            return previous;
        },
        else => {},
    }
    var previous: *Header = &head.sentinel;
    while (previous.next_non_object != el) {
        previous = previous.next_non_object.?;
        std.debug.assert(previous != &head.sentinel);
    }
    return previous;
}

/// Delete `el` when its predecessor is already known by the caller's forward
/// traversal. This is the normal compact-trace sweep primitive: one pointer
/// splice, never a search per corpse.
pub inline fn listDelAfter(head: *IntrusiveHeaderList, previous: *Header, el: *Header) void {
    std.debug.assert(el.metaConst().flags.kind != .object);
    std.debug.assert(previous.next_non_object == el);
    const next = el.next_non_object.?;
    previous.next_non_object = next;
    if (next != &head.sentinel) setStoredListPrevious(next, previous);
    head.tail = if (head.tail == el) previous else head.tail;
    // Linkage is already authoritatively cleared by `next = null` below.
    // ReleaseFast does not pay a second kind dispatch merely to scrub the
    // Shape/Realm acceleration slot of an object that is either destroyed
    // or immediately re-linked (which overwrites it). Keep the scrub in
    // safety builds so stale-backlink misuse still fails close to origin.
    if (std.debug.runtime_safety) setStoredListPrevious(el, null);
    el.next_non_object = null;
}

/// Traversal-owned counterpart to `listDelAfter`. The caller promises this is
/// not `gc_obj_list`: no mutator can arbitrarily unlink Shape/Realm nodes from
/// it, so successor backlinks are deliberately absent and need no repair.
pub inline fn listDelAfterTraversalOwned(head: *IntrusiveHeaderList, previous: *Header, el: *Header) void {
    std.debug.assert(el.metaConst().flags.kind != .object);
    std.debug.assert(previous.next_non_object == el);
    previous.next_non_object = el.next_non_object.?;
    head.tail = if (head.tail == el) previous else head.tail;
    el.next_non_object = null;
}

pub inline fn listFirst(head: *const IntrusiveHeaderList) ?*Header {
    const next = head.sentinel.next_non_object.?;
    if (next == @constCast(&head.sentinel)) return null;
    return next;
}

pub inline fn headerLinked(header: *const Header) bool {
    return header.nextNonObject() != null;
}

pub fn verifyCircularHeaderList(
    head: *IntrusiveHeaderList,
    expected_kind: ?GcKind,
    comptime verify_stored_previous: bool,
) InvariantError!usize {
    const sentinel = &head.sentinel;
    if (sentinel.next_non_object == null) return error.CorruptGcList;
    if (listEmpty(head)) {
        if (head.tail != sentinel) return error.CorruptGcList;
        return 0;
    }

    var tortoise = sentinel.next_non_object.?;
    var hare = sentinel.next_non_object.?;
    while (hare != sentinel) {
        hare = hare.nextNonObject() orelse return error.CorruptGcList;
        if (hare == sentinel) break;
        hare = hare.nextNonObject() orelse return error.CorruptGcList;
        tortoise = tortoise.nextNonObject() orelse return error.CorruptGcList;
        if (hare != sentinel and tortoise == hare) return error.CorruptGcList;
    }

    var count: usize = 0;
    var previous: *GCObjectHeader = sentinel;
    var current = sentinel.next_non_object;
    while (current) |node| {
        if (node == sentinel) break;
        if (expected_kind) |kind| {
            if (node.metaConst().flags.kind != kind) return error.DoomedBucketKindMismatch;
        }
        if (comptime verify_stored_previous) {
            switch (node.metaConst().flags.kind) {
                .shape, .realm_context => if (storedListPrevious(node) != previous)
                    return error.CorruptGcList,
                else => {},
            }
        }
        const next = node.nextNonObject() orelse return error.CorruptGcList;
        previous = node;
        current = next;
        count += 1;
    }
    if (previous.next_non_object != sentinel or head.tail != previous) return error.CorruptGcList;
    return count;
}


/// The Registry's list cursors.
pub const Lists = struct {
    // qjs `rt->gc_obj_list`. Call `init` after the Registry reaches its
    // stable address -- the sentinel is self-referential.
    objects: IntrusiveHeaderList = .{},

    /// First young object in `objects`, or null when nothing is young.
    /// See `Registry.objectIterator(.young)` for why the young set is a suffix.
    young_head: ?*Header = null,
    /// Predecessor of `young_head`. Compact trace nodes have no backlink, so
    /// retaining this one per-runtime cursor lets a minor detach a young list
    /// suffix in O(young) rather than searching from the list head per corpse.
    young_predecessor: ?*Header = null,

    // No live-object counter: qjs add_gc_object/remove_gc_object
    // (quickjs.c:6540/6548) are pure list splices with no count scalar.
    // Diagnostics (`Registry.liveCount`) derive the count by walking, like
    // `liveCountKind` always has.

    /// The header the tracing sweep has unlinked and is destroying right now.
    ///
    /// `Registry.containsHeader` reads it so a synchronous class payload
    /// finalizer asking `JSRuntime.ownsObject` about its own object gets
    /// `true` while its callback runs.
    sweep_current: ?*GCObjectHeader = null,

    /// Bind the cyclic sentinel (qjs `init_list_head`). Must run before any
    /// header is published, and is idempotent: rebinding an empty list to
    /// itself is the same state.
    pub fn init(self: *Lists) void {
        listInit(&self.objects);
    }

    /// Publication marks a freshly appended carrier young immediately after
    /// linkage. Capture the old tail before that append while it is still
    /// O(1).
    pub inline fn stageYoungTailPredecessor(self: *Lists) void {
        if (self.young_head == null) {
            self.young_predecessor = self.objects.tail.?;
        }
    }

    pub inline fn resetYoungSuffix(self: *Lists) void {
        self.young_head = null;
        self.young_predecessor = null;
    }

    /// qjs `list_add_tail` (quickjs.c:6545).
    pub inline fn linkTail(self: *Lists, header: *GCObjectHeader) void {
        std.debug.assert(header.metaConst().flags.kind != .object);
        self.stageYoungTailPredecessor();
        listAddTail(&self.objects, header);
    }
};
