//! Module loading primitives (records + source classification).
//!
//! Currently in-memory only. Real FS loading and graph belong in later milestones.
//! See docs/runtime-mvp.md and docs/architecture.md.

const primitives = @import("../../primitives/root.zig");
const core = primitives; // legacy alias inside this file

pub const ModuleRecord = struct {
    path: []const u8,
    source: []const u8,
    kind: core.ModuleKind,
};

pub fn classifyPath(path: []const u8) core.ModuleKind {
    return core.detectModuleKind(path);
}

pub fn fromSource(path: []const u8, source: []const u8) ModuleRecord {
    return .{
        .path = path,
        .source = source,
        .kind = classifyPath(path),
    };
}

test "loader records source and detected kind" {
    const std = @import("std");
    const record = fromSource("entry.ts", "console.log(1)");

    try std.testing.expectEqual(core.ModuleKind.typescript, record.kind);
    try std.testing.expectEqualStrings("entry.ts", record.path);
    try std.testing.expectEqualStrings("console.log(1)", record.source);
}
