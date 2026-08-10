//! Representation-independent operations for frame value slots.
//!
//! A value slot always owns one plain JSValue. Binding identity is handled by
//! `open_bindings.zig`; this Module deliberately knows nothing about VarRef
//! handles or the active JSValue bit layout.

const core = @import("../core/root.zig");

/// Return an additional owned reference to the value in `slot`.
pub inline fn loadOwned(slot: *const core.JSValue) core.JSValue {
    return slot.*.dup();
}

/// Replace a slot with an already-owned value.
///
/// Publishing the new value before releasing the old one is required for
/// self-assignment and for finalizers that re-enter the engine.
pub inline fn replaceOwned(rt: anytype, slot: *core.JSValue, owned_next: core.JSValue) void {
    const old = slot.*;
    slot.* = owned_next;
    old.free(rt);
}

/// Replace a slot with a borrowed value, retaining it for the slot first.
pub inline fn replaceBorrowed(rt: anytype, slot: *core.JSValue, borrowed_next: core.JSValue) void {
    replaceOwned(rt, slot, borrowed_next.dup());
}

/// `replaceOwned` twin for tail-call dispatch handlers: the old value's
/// release reads the Vm-resident deinit mirror byte (see
/// JSValue.freeWithDeinitMirror) instead of `rt.gc.phase`.
pub inline fn replaceOwnedWithDeinitMirror(rt: anytype, gc_deinit: bool, slot: *core.JSValue, owned_next: core.JSValue) void {
    const old = slot.*;
    slot.* = owned_next;
    old.freeWithDeinitMirror(rt, gc_deinit);
}

/// `replaceBorrowed` twin; see `replaceOwnedWithDeinitMirror`.
pub inline fn replaceBorrowedWithDeinitMirror(rt: anytype, gc_deinit: bool, slot: *core.JSValue, borrowed_next: core.JSValue) void {
    replaceOwnedWithDeinitMirror(rt, gc_deinit, slot, borrowed_next.dup());
}
