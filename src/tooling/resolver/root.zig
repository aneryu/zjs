//! Import specifier classification (relative / absolute / builtin / package).
//!
//! MVP only supports local ESM + `node:` builtins. Bare packages rejected.
//! See docs/runtime-mvp.md and docs/architecture.md.

const std = @import("std");

pub const SpecifierKind = enum {
    relative,
    absolute,
    package,
    builtin,
};

pub const Request = struct {
    specifier: []const u8,
    importer: ?[]const u8 = null,
};

pub const ResolvedPath = struct {
    path: []const u8,
    kind: SpecifierKind,
};

pub fn classifySpecifier(specifier: []const u8) SpecifierKind {
    if (std.mem.startsWith(u8, specifier, "node:")) return .builtin;
    if (std.mem.startsWith(u8, specifier, "./") or
        std.mem.startsWith(u8, specifier, "../") or
        std.mem.eql(u8, specifier, ".") or
        std.mem.eql(u8, specifier, ".."))
    {
        return .relative;
    }
    if (std.fs.path.isAbsolute(specifier)) return .absolute;
    return .package;
}

test "classify import specifiers" {
    try std.testing.expectEqual(SpecifierKind.relative, classifySpecifier("./app"));
    try std.testing.expectEqual(SpecifierKind.relative, classifySpecifier("../lib"));
    try std.testing.expectEqual(SpecifierKind.absolute, classifySpecifier("/tmp/app.js"));
    try std.testing.expectEqual(SpecifierKind.builtin, classifySpecifier("node:fs"));
    try std.testing.expectEqual(SpecifierKind.package, classifySpecifier("react"));
}
