const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const engine_mod = b.addModule("quickjs_zig_engine", .{
        .root_source_file = b.path("src/engine/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const quickjs_port_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/quickjs_port.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "quickjs_zig_engine", .module = engine_mod },
            },
        }),
    });

    const run_quickjs_port_tests = b.addRunArtifact(quickjs_port_tests);

    const test_quickjs_port_step = b.step("test-quickjs-port", "Run direct QuickJS port tests");
    test_quickjs_port_step.dependOn(&run_quickjs_port_tests.step);

    const test_step = b.step("test", "Run available Zig tests");
    test_step.dependOn(&run_quickjs_port_tests.step);
}
