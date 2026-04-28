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
    const qjs_cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/qjs.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "quickjs_zig_engine", .module = engine_mod },
        },
    });
    const test262_runner_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/test262_runner.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "quickjs_zig_engine", .module = engine_mod },
        },
    });
    const test262_engine_fast_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    const qjs_cli_fast_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/qjs.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .imports = &.{
            .{ .name = "quickjs_zig_engine", .module = test262_engine_fast_mod },
        },
    });
    const test262_runner_fast_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/test262_runner.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .imports = &.{
            .{ .name = "quickjs_zig_engine", .module = test262_engine_fast_mod },
        },
    });
    const smoke_runner_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/smoke_runner.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const qjs_exe = b.addExecutable(.{
        .name = "zjs",
        .root_module = qjs_cli_mod,
    });
    const install_qjs = b.addInstallArtifact(qjs_exe, .{});
    const qjs_step = b.step("qjs", "Build and install zjs");
    qjs_step.dependOn(&install_qjs.step);

    const qjs_fast_exe = b.addExecutable(.{
        .name = "zjs",
        .root_module = qjs_cli_fast_mod,
    });
    const install_qjs_fast = b.addInstallArtifact(qjs_fast_exe, .{});

    const run_test262_exe = b.addExecutable(.{
        .name = "run-test262",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/run_test262.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
            .imports = &.{
                .{ .name = "test262_runner", .module = test262_runner_fast_mod },
            },
        }),
    });
    const install_run_test262 = b.addInstallArtifact(run_test262_exe, .{});
    const run_test262_step = b.step("run-test262", "Build and install run-test262");
    run_test262_step.dependOn(&install_run_test262.step);

    // Add actual test262 execution step with regression baseline
    const run_test262_exec = b.addRunArtifact(run_test262_exe);
    run_test262_exec.step.dependOn(&install_run_test262.step);
    run_test262_exec.addArg("-c");
    run_test262_exec.addArg("quickjs/test262.conf");
    run_test262_exec.addArg("-d");
    run_test262_exec.addArg("quickjs/test262/test");
    run_test262_exec.addArg("0");
    run_test262_exec.addArg("100000");
    run_test262_exec.addArg("-R");
    run_test262_exec.addArg("reports/test262-latest");
    // Enable regression gate by default (M0.3)
    run_test262_exec.addArg("--regression-baseline");
    run_test262_exec.addArg("docs/quickjs-redesign/baseline/2026-04-29/test262-by-dir.json");
    const test262_gate_step = b.step("test262-gate", "Run test262 with regression gate");
    test262_gate_step.dependOn(&run_test262_exec.step);

    const smoke_runner_exe = b.addExecutable(.{
        .name = "smoke-runner",
        .root_module = smoke_runner_mod,
    });
    const run_smoke = b.addRunArtifact(smoke_runner_exe);
    run_smoke.step.dependOn(&install_qjs.step);
    run_smoke.addArg("zig-out/bin/zjs");
    run_smoke.addArg("tests/zig-smoke/manifest.txt");
    const smoke_step = b.step("smoke", "Run JS smoke scripts against zjs");
    smoke_step.dependOn(&run_smoke.step);

    const run_microbench = b.addSystemCommand(&.{ "bun", "tools/compare/run_microbench.js" });
    run_microbench.step.dependOn(&install_qjs_fast.step);
    const microbench_step = b.step("microbench", "Run QuickJS microbench comparison against zjs");
    microbench_step.dependOn(&run_microbench.step);

    // Bytecode disassembler (M1.4 comparison toolchain)
    const dump_zjs_mod = b.createModule(.{
        .root_source_file = b.path("tools/compare/dump-zjs-bytecode.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "quickjs_zig_engine", .module = engine_mod },
        },
    });
    const dump_zjs_exe = b.addExecutable(.{
        .name = "dump-zjs-bytecode",
        .root_module = dump_zjs_mod,
    });
    const install_dump_zjs = b.addInstallArtifact(dump_zjs_exe, .{});
    const dump_zjs_step = b.step("dump-zjs-bytecode", "Build the ZJS bytecode disassembler");
    dump_zjs_step.dependOn(&install_dump_zjs.step);

    const diff_bc_mod = b.createModule(.{
        .root_source_file = b.path("tools/compare/diff-bc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const diff_bc_exe = b.addExecutable(.{
        .name = "diff-bc",
        .root_module = diff_bc_mod,
    });
    const install_diff_bc = b.addInstallArtifact(diff_bc_exe, .{});

    const run_f10_parity = b.addSystemCommand(&.{
        "bash",
        "tools/compare/run-f10-parity.sh",
        "tests/test262-anchors/F10/sample.list",
        "zig-out/bin/dump-zjs-bytecode",
        "tools/compare/dump-quickjs-bytecode.sh",
        "zig-out/bin/diff-bc",
    });
    run_f10_parity.step.dependOn(&install_dump_zjs.step);
    run_f10_parity.step.dependOn(&install_diff_bc.step);
    const f10_parity_step = b.step("f10-parity", "Compare ZJS and QuickJS opcode sequences for F10 anchors");
    f10_parity_step.dependOn(&run_f10_parity.step);

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
                .{ .name = "qjs_cli", .module = qjs_cli_mod },
                .{ .name = "smoke_runner", .module = smoke_runner_mod },
                .{ .name = "test262_runner", .module = test262_runner_mod },
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

    const builtins_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/builtins/all.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "quickjs_zig_engine", .module = engine_mod },
            },
        }),
    });

    const run_builtins_tests = b.addRunArtifact(builtins_tests);
    const test_builtins_step = b.step("test-builtins", "Run builtins and support library tests");
    test_builtins_step.dependOn(&run_builtins_tests.step);

    const tools_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/tools/all.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "quickjs_zig_engine", .module = engine_mod },
                .{ .name = "qjs_cli", .module = qjs_cli_mod },
                .{ .name = "smoke_runner", .module = smoke_runner_mod },
                .{ .name = "test262_runner", .module = test262_runner_mod },
            },
        }),
    });

    const run_tools_tests = b.addRunArtifact(tools_tests);
    const test262_runner_tests = b.addTest(.{
        .root_module = test262_runner_mod,
    });
    const run_test262_runner_tests = b.addRunArtifact(test262_runner_tests);

    const test_tools_step = b.step("test-tools", "Run CLI and validation tooling tests");
    test_tools_step.dependOn(&run_tools_tests.step);
    test_tools_step.dependOn(&run_test262_runner_tests.step);

    const test_step = b.step("test", "Run available Zig tests");
    test_step.dependOn(&run_quickjs_port_tests.step);
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_bytecode_tests.step);
    test_step.dependOn(&run_frontend_tests.step);
    test_step.dependOn(&run_exec_tests.step);
    test_step.dependOn(&run_builtins_tests.step);
    test_step.dependOn(&run_tools_tests.step);
    test_step.dependOn(&run_test262_runner_tests.step);
}
