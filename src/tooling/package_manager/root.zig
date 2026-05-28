//! Auto-generated minimal stub for layered build graph.
//! See docs/fun_zjs_subtree_architecture.md §3.
pub const root = @This();

pub const PackageManagerError = error{InstallNotImplemented};

pub fn install() PackageManagerError!void {
    return error.InstallNotImplemented;
}
