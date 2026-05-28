//! Auto-generated minimal stub for layered build graph.
//! See docs/fun_zjs_subtree_architecture.md §3.
pub const root = @This();

pub const BundleError = error{BundlerNotImplemented};
pub const EntryPoint = struct { path: []const u8 };

pub fn bundle(_: EntryPoint) BundleError!void {
    return error.BundlerNotImplemented;
}
