//! Temporary adapter / metadata boundary for parsing.
//!
//! Real JS/TS work lives in `zjs`. Only preserves source kind/goal here.
//! See docs/architecture.md and docs/zjs-integration.md.

const primitives = @import("../primitives/root.zig");
const core = primitives; // legacy during migration

pub const ParseGoal = enum {
    script,
    module,
};

pub const ParseInput = struct {
    source: []const u8,
    path: ?[]const u8 = null,
    kind: core.ModuleKind = .javascript,
    goal: ParseGoal = .module,
};

pub const ParsedModule = struct {
    source: []const u8,
    path: ?[]const u8,
    kind: core.ModuleKind,
    goal: ParseGoal,
};

pub fn parse(input: ParseInput) ParsedModule {
    return .{
        .source = input.source,
        .path = input.path,
        .kind = input.kind,
        .goal = input.goal,
    };
}

test "parser placeholder preserves source metadata" {
    const std = @import("std");
    const parsed = parse(.{
        .source = "export const answer = 42;",
        .path = "answer.ts",
        .kind = .typescript,
    });

    try std.testing.expectEqual(core.ModuleKind.typescript, parsed.kind);
    try std.testing.expectEqual(ParseGoal.module, parsed.goal);
    try std.testing.expectEqualStrings("answer.ts", parsed.path.?);
}
