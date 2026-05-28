//! Package manager (explicitly deferred placeholder).
//!
//! Deferred until after M4+ (basic execution + module loading).
//! See docs/roadmap.md (M7).

pub const PackageManagerError = error{
    InstallNotImplemented,
};

pub fn install() PackageManagerError!void {
    return error.InstallNotImplemented;
}

test "package manager is explicit placeholder" {
    const std = @import("std");
    try std.testing.expectError(error.InstallNotImplemented, install());
}
