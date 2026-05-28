//! Shared primitives: `ModuleKind` detection and future platform helpers.
//!
//! All layers depend on these enums. TypeScript kinds are recognized early
//! even though execution support is deferred.
//!
//! See docs/architecture.md and docs/runtime-mvp.md.

const std = @import("std");

pub const project_name = "fun";

pub const Layer = enum {
    cli,
    frontend,
    resolver,
    loader,
    runtime,
    tooling,
};

pub const ModuleKind = enum {
    javascript,
    typescript,
    jsx,
    tsx,
    json,
    unknown,
};

pub fn detectModuleKind(path: []const u8) ModuleKind {
    if (std.mem.endsWith(u8, path, ".js") or std.mem.endsWith(u8, path, ".mjs") or std.mem.endsWith(u8, path, ".cjs")) {
        return .javascript;
    }
    if (std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".mts") or std.mem.endsWith(u8, path, ".cts")) {
        return .typescript;
    }
    if (std.mem.endsWith(u8, path, ".jsx")) return .jsx;
    if (std.mem.endsWith(u8, path, ".tsx")) return .tsx;
    if (std.mem.endsWith(u8, path, ".json")) return .json;
    return .unknown;
}

test "detect module kind from runtime file extensions" {
    try std.testing.expectEqual(ModuleKind.javascript, detectModuleKind("index.js"));
    try std.testing.expectEqual(ModuleKind.javascript, detectModuleKind("index.mjs"));
    try std.testing.expectEqual(ModuleKind.typescript, detectModuleKind("index.ts"));
    try std.testing.expectEqual(ModuleKind.tsx, detectModuleKind("view.tsx"));
    try std.testing.expectEqual(ModuleKind.json, detectModuleKind("package.json"));
    try std.testing.expectEqual(ModuleKind.unknown, detectModuleKind("README.md"));
}
