//! Temporary adapter for transforms (real work belongs in `zjs`).
//!
//! `passthrough` and `stripTypes` are explicit placeholders.
//! See docs/architecture.md and docs/roadmap.md.

const primitives = @import("../primitives/root.zig");
const core = primitives; // legacy during migration
const js_parser = @import("../js_parser/root.zig");

pub const TranspileError = error{
    TypeScriptTransformNotImplemented,
};

pub const Output = struct {
    code: []const u8,
    kind: core.ModuleKind,
};

pub fn passthrough(parsed: js_parser.ParsedModule) Output {
    return .{
        .code = parsed.source,
        .kind = parsed.kind,
    };
}

pub fn stripTypes(_: js_parser.ParsedModule) TranspileError!Output {
    return error.TypeScriptTransformNotImplemented;
}

test "transpiler placeholder keeps parser output intact" {
    const std = @import("std");
    const parsed = js_parser.parse(.{ .source = "let value: number = 1;", .kind = .typescript });
    const output = passthrough(parsed);

    try std.testing.expectEqual(core.ModuleKind.typescript, output.kind);
    try std.testing.expectEqualStrings("let value: number = 1;", output.code);
}
