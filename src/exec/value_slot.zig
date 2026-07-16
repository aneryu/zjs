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
