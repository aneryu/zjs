//! Leaf contract shared by module records and AUTOINIT property slots.
//!
//! This file deliberately has no Runtime dependency.  A MODULE_NS slot owns
//! its construction Realm separately; the opaque owner below is an immutable
//! Interface embedded in an address-stable module record.

const atom = @import("atom.zig");
const gc = @import("gc.zig");
const JSValue = @import("value.zig").JSValue;
const VarRef = @import("var_ref.zig").VarRef;

/// A MODULE_NS resolver returns either a newly-owned namespace value or the
/// existing export cell that the property must retain directly.  It never
/// snapshots a VarRef's current value.
pub const AutoInitMaterialization = union(enum) {
    value: JSValue,
    var_ref: *VarRef,
};

/// Stable module-owned Interface stored in the second AUTOINIT property word.
///
/// `atom_id` is the namespace export property being materialized.  Keeping it
/// in the callback contract lets one immutable owner serve every delayed
/// export of the same module, matching QuickJS's `(module, property atom)`
/// resolver input without allocating a per-property wrapper.
pub const AutoInitModuleOwner = struct {
    resolve: *const fn (
        owner: *const AutoInitModuleOwner,
        realm_header: *gc.Header,
        atom_id: atom.Atom,
    ) anyerror!AutoInitMaterialization,
};
