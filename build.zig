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

    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/core/all.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "quickjs_zig_engine", .module = engine_mod },
            },
        }),
    });

    const run_core_tests = b.addRunArtifact(core_tests);
    const test_core_step = b.step("test-core", "Run core runtime foundation tests");
    test_core_step.dependOn(&run_core_tests.step);

    const bytecode_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/bytecode/all.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "quickjs_zig_engine", .module = engine_mod },
            },
        }),
    });

    const run_bytecode_tests = b.addRunArtifact(bytecode_tests);
    const test_bytecode_step = b.step("test-bytecode", "Run opcode and bytecode metadata tests");
    test_bytecode_step.dependOn(&run_bytecode_tests.step);

    const frontend_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/frontend/all.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "quickjs_zig_engine", .module = engine_mod },
            },
        }),
    });

    const run_frontend_tests = b.addRunArtifact(frontend_tests);
    const test_frontend_step = b.step("test-frontend", "Run frontend parser and emitter tests");
    test_frontend_step.dependOn(&run_frontend_tests.step);

    const exec_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/exec/all.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "quickjs_zig_engine", .module = engine_mod },
            },
        }),
    });

    const run_exec_tests = b.addRunArtifact(exec_tests);
    const test_exec_step = b.step("test-exec", "Run bytecode execution tests");
    test_exec_step.dependOn(&run_exec_tests.step);

    const test_step = b.step("test", "Run available Zig tests");
    test_step.dependOn(&run_quickjs_port_tests.step);
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_bytecode_tests.step);
    test_step.dependOn(&run_frontend_tests.step);
    test_step.dependOn(&run_exec_tests.step);
}
