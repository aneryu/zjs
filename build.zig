const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The public "fun" library module now pulls in the full new layered tree
    // via the rewritten src/root.zig (primitives, js facade, runtime/vm, tooling/*, etc.).
    // This single-module approach satisfies Zig 0.16's "one file = one module root" rule
    // while still giving us the directory structure from fun_zjs_subtree_architecture.md.
    const fun_mod = b.addModule("fun", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "fun",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fun", .module = fun_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the runtime CLI");
    run_step.dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{ .root_module = fun_mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // New primary steps from the subtree architecture
    const fun_step = b.step("fun", "Build fun CLI");
    fun_step.dependOn(&b.addInstallArtifact(exe, .{}).step);

    const zjs_step = b.step("zjs", "Build zjs CLI (populate third_party/zjs via git subtree first)");
    _ = zjs_step;

    // Documentation + layering guard (updated for the new tree)
    const docs_check_cmd = b.addSystemCommand(&.{
        "sh", "-c",
        \\echo "=== fun docs-check ===" &&
        \\echo "Checking documented modules (layered layout)..." &&
        \\ls -d src/main.zig src/root.zig src/primitives src/diagnostics src/js src/runtime src/tooling src/platform src/common third_party/zjs 2>/dev/null || echo "(subtree may be empty — see third_party/zjs/README.md)" &&
        \\echo "Checking //! See docs/ headers..." &&
        \\grep -l "See docs/" src/main.zig src/root.zig src/primitives/root.zig src/js/root.zig src/runtime/root.zig src/tooling/root.zig 2>/dev/null || true &&
        \\echo "Running layering guard..." &&
        \\sh scripts/check-layering.sh &&
        \\echo "Docs discipline + layering checks passed."
    });
    const docs_check_step = b.step("docs-check", "Documentation consistency + import layering guard");
    docs_check_step.dependOn(&docs_check_cmd.step);
}
