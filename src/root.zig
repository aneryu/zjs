//! Public runtime facade (equivalent of Bun's `src/bun.zig`).
//!
//! All reusable layers are re-exported here. `src/main.zig` and external
//! callers should import through this module only.
//!
//! Layout follows docs/fun_zjs_subtree_architecture.md. Legacy flat names are
//! still provided (with deprecation comments) for any code that imported the
//! M0/M1 scaffold directly.
//! See docs/architecture.md (historical), docs/roadmap.md (status matrix),
//! docs/fun_zjs_subtree_architecture.md (authoritative), and docs/runtime-mvp.md.

pub const version = "0.0.0";

// New canonical layered modules (preferred)
pub const primitives = @import("primitives/root.zig");
pub const diagnostics = @import("diagnostics/root.zig");
pub const js = @import("js/root.zig");
// Legacy runtime (with the explicit ExecutionNotImplemented placeholder) still lives
// in the old location until the vm wiring is implemented.
pub const runtime = @import("runtime/root.zig");
pub const tooling = @import("tooling/root.zig");
pub const platform = @import("platform/root.zig");
pub const common = @import("common/root.zig");

// Legacy flat aliases (preserve exact public API for existing tests + external code)
pub const core = primitives; // ModuleKind + detect now live in primitives
pub const cli = tooling.cli;
// Legacy adapters still live in their original files (real metadata preservation logic).
// They will be slimmed/merged into tooling/transpiler in a follow-up.
pub const js_parser = @import("js_parser/root.zig");
pub const transpiler = @import("transpiler/root.zig");
pub const resolver = tooling.resolver;
pub const loader = runtime.modules; // logical home for loader records
pub const bundler = tooling.bundler;
pub const package_manager = tooling.package_manager;
pub const test_runner = tooling.test_runner;
pub const repl = tooling; // placeholder surface

// Selected re-exports for the old "fun" usage in src/main.zig and tests
pub const Command = if (@hasDecl(tooling, "cli")) tooling.cli.Command else @import("tooling/cli/root.zig").Command;
pub const parseCommand = if (@hasDecl(tooling, "cli")) tooling.cli.parseCommand else @import("tooling/cli/root.zig").parseCommand;
pub const printHelp = if (@hasDecl(tooling, "cli")) tooling.cli.printHelp else @import("tooling/cli/root.zig").printHelp;

test "parse help commands" {
    const std = @import("std");
    try std.testing.expectEqual(Command.repl, parseCommand(&.{"fun"}));
    try std.testing.expectEqual(Command.help, parseCommand(&.{ "fun", "--help" }));
}

test "public runtime layers are reachable" {
    const std = @import("std");
    try std.testing.expectEqual(primitives.ModuleKind.javascript, primitives.detectModuleKind("index.js"));
    try std.testing.expectEqual(tooling.resolver.SpecifierKind.relative, tooling.resolver.classifySpecifier("./index.js"));
    try std.testing.expectEqualStrings("fun", primitives.project_name);
}

test "pipeline placeholders are explicit" {
    const std = @import("std");

    const record = loader.fromSource("entry.ts", "export const answer = 42;");
    const parsed = js_parser.parse(.{
        .source = record.source,
        .path = record.path,
        .kind = record.kind,
    });
    const passthrough = transpiler.passthrough(parsed);

    try std.testing.expectEqual(primitives.ModuleKind.typescript, passthrough.kind);
    try std.testing.expectError(error.TypeScriptTransformNotImplemented, transpiler.stripTypes(parsed));
    try std.testing.expectError(error.ExecutionNotImplemented, runtime.execute(.{ .source = passthrough.code }));
    try std.testing.expectError(error.BundlerNotImplemented, bundler.bundle(.{ .path = record.path }));
    try std.testing.expectError(error.InstallNotImplemented, package_manager.install());
    try std.testing.expectError(error.TestRunnerNotImplemented, test_runner.runAll());
    try std.testing.expectError(error.ReplNotImplemented, repl.start());
}
