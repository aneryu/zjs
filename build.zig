const std = @import("std");

fn execShardUsesOomOptions(path: []const u8) bool {
    return std.mem.eql(u8, path, "src/tests/exec/core_native.zig") or
        std.mem.eql(u8, path, "src/tests/exec/builtins_async.zig") or
        std.mem.eql(u8, path, "src/tests/exec/engine_smoke.zig") or
        std.mem.eql(u8, path, "src/tests/exec/collection_typedarray.zig") or
        std.mem.eql(u8, path, "src/tests/exec/module_regexp.zig") or
        std.mem.eql(u8, path, "src/tests/exec/iter_generator.zig") or
        std.mem.eql(u8, path, "src/tests/exec/vm_control.zig") or
        std.mem.eql(u8, path, "src/tests/exec/vm_classes.zig");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zjs_enable_ic = b.option(bool, "zjs_enable_ic", "Enable shape-keyed inline caches") orelse true;
    const shard_filter = b.option([]const u8, "shard", "Only run the specified zjs test shard");
    const engine_options = b.addOptions();
    engine_options.addOption(bool, "zjs_enable_ic", zjs_enable_ic);
    const quick_oom_options = b.addOptions();
    quick_oom_options.addOption(bool, "full_oom_sweep", false);
    quick_oom_options.addOption(bool, "sampled_oom_sweep", false);
    const sampled_oom_options = b.addOptions();
    sampled_oom_options.addOption(bool, "full_oom_sweep", false);
    sampled_oom_options.addOption(bool, "sampled_oom_sweep", true);
    const exhaustive_oom_options = b.addOptions();
    exhaustive_oom_options.addOption(bool, "full_oom_sweep", true);
    exhaustive_oom_options.addOption(bool, "sampled_oom_sweep", false);

    const test262_protocol_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/test262_protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test262_protocol_fast_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/test262_protocol.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const engine_mod = b.addModule("quickjs_zig_engine", .{
        .root_source_file = b.path("src/engine/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    engine_mod.addOptions("build_options", engine_options);
    const qjs_cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/qjs.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "quickjs_zig_engine", .module = engine_mod },
            .{ .name = "test262_protocol", .module = test262_protocol_mod },
        },
    });
    const test262_runner_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/test262_runner.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "quickjs_zig_engine", .module = engine_mod },
            .{ .name = "test262_protocol", .module = test262_protocol_mod },
        },
    });
    const test262_engine_fast_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    test262_engine_fast_mod.addOptions("build_options", engine_options);
    const test262_runner_fast_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/test262_runner.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .imports = &.{
            .{ .name = "quickjs_zig_engine", .module = test262_engine_fast_mod },
            .{ .name = "test262_protocol", .module = test262_protocol_fast_mod },
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
    b.installArtifact(qjs_exe);
    const qjs_test262_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/qjs.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .imports = &.{
            .{ .name = "quickjs_zig_engine", .module = test262_engine_fast_mod },
            .{ .name = "test262_protocol", .module = test262_protocol_fast_mod },
        },
    });
    const qjs_test262_exe = b.addExecutable(.{
        .name = "zjs-test262",
        .root_module = qjs_test262_mod,
    });
    const install_qjs_test262 = b.addInstallArtifact(qjs_test262_exe, .{});

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
    run_test262_step.dependOn(&install_qjs_test262.step);

    // Add actual test262 execution step.
    const run_test262_exec = b.addRunArtifact(run_test262_exe);
    run_test262_exec.step.dependOn(&install_run_test262.step);
    run_test262_exec.step.dependOn(&install_qjs_test262.step);
    run_test262_exec.addArg("-c");
    run_test262_exec.addArg("test262.conf");
    run_test262_exec.addArg("-d");
    run_test262_exec.addArg("test262/test");
    run_test262_exec.addArg("0");
    run_test262_exec.addArg("100000");
    run_test262_exec.addArg("-R");
    run_test262_exec.addArg("reports/test262-latest");
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

    const run_perf_benchmark = b.addRunArtifact(qjs_test262_exe);
    run_perf_benchmark.addArg("--perf-json");
    run_perf_benchmark.addArg("tests/perf/microbench.js");
    const perf_benchmark_step = b.step("perf-benchmark", "Run a repeatable diagnostic JS performance benchmark");
    perf_benchmark_step.dependOn(&run_perf_benchmark.step);

    const engine_root_test_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    engine_root_test_mod.addOptions("build_options", engine_options);
    const engine_root_tests = b.addTest(.{
        .root_module = engine_root_test_mod,
    });
    const run_engine_root_tests = b.addRunArtifact(engine_root_tests);

    const engine_production_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/engine_production.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "quickjs_zig_engine", .module = engine_mod },
            },
        }),
    });
    const run_engine_production_tests = b.addRunArtifact(engine_production_tests);

    const leak_check_engine_step = b.step("leak-check-engine", "Run embedding lifecycle and leak-focused engine tests");
    leak_check_engine_step.dependOn(&run_engine_production_tests.step);

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

    // Each exec test source compiles into its own binary so the binaries can
    // be compiled and run in parallel during `zig build test`. Each binary
    // also re-uses the same `engine_mod` so the engine compile is cached
    // across the shards. Sharding shapes were introduced in commit 14e37b2
    // and extended later when individual shards grew too slow.
    const ExecShard = struct { name: []const u8, path: []const u8 };
    const exec_shards = [_]ExecShard{
        .{ .name = "exec-core-native", .path = "src/tests/exec/core_native.zig" },
        .{ .name = "exec-builtins-async", .path = "src/tests/exec/builtins_async.zig" },
        .{ .name = "exec-engine-smoke", .path = "src/tests/exec/engine_smoke.zig" },
        .{ .name = "exec-eval-errors", .path = "src/tests/exec/eval_errors.zig" },
        .{ .name = "exec-class-object", .path = "src/tests/exec/class_object.zig" },
        .{ .name = "exec-primitive-string", .path = "src/tests/exec/primitive_string.zig" },
        .{ .name = "exec-collection-typedarray", .path = "src/tests/exec/collection_typedarray.zig" },
        .{ .name = "exec-module-regexp", .path = "src/tests/exec/module_regexp.zig" },
        .{ .name = "exec-iter-generator", .path = "src/tests/exec/iter_generator.zig" },
        .{ .name = "exec-async-perf", .path = "src/tests/exec/async_perf.zig" },
        .{ .name = "exec-vm-literals", .path = "src/tests/exec/vm_literals.zig" },
        .{ .name = "exec-vm-functions", .path = "src/tests/exec/vm_functions.zig" },
        .{ .name = "exec-vm-control", .path = "src/tests/exec/vm_control.zig" },
        .{ .name = "exec-vm-objects", .path = "src/tests/exec/vm_objects.zig" },
        .{ .name = "exec-vm-classes", .path = "src/tests/exec/vm_classes.zig" },
        .{ .name = "exec-vm-assignments", .path = "src/tests/exec/vm_assignments.zig" },
        .{ .name = "exec-vm-prototypes", .path = "src/tests/exec/vm_prototypes.zig" },
        .{ .name = "exec-vm-iter-async", .path = "src/tests/exec/vm_iter_async.zig" },
        .{ .name = "exec-vm-shared-internal", .path = "src/engine/internal_tests.zig" },
    };

    const test_exec_step = b.step("test-exec", "Run bytecode execution tests");
    var exec_run_steps: [exec_shards.len]*std.Build.Step = undefined;
    inline for (exec_shards, 0..) |shard, i| {
        const matches_filter = if (shard_filter) |filter| std.mem.eql(u8, shard.name, filter) else true;
        const test_mod = b.createModule(.{
            .root_source_file = b.path(shard.path),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "quickjs_zig_engine", .module = engine_mod },
            },
        });
        test_mod.addOptions("build_options", engine_options);
        if (execShardUsesOomOptions(shard.path)) {
            test_mod.addOptions("oom_options", quick_oom_options);
        }
        const tests = b.addTest(.{
            .name = shard.name,
            .root_module = test_mod,
        });
        const run_tests = b.addRunArtifact(tests);
        exec_run_steps[i] = &run_tests.step;
        if (matches_filter) {
            test_exec_step.dependOn(&run_tests.step);
        }
    }

    // `test`: separate ReleaseSafe exec test artifacts that share the
    // engine compile via `engine_release_safe_mod`. ReleaseSafe keeps
    // every safety check the Debug tests carry (overflow / undefined-
    // behavior / index-out-of-bounds / leak detection), but trades the
    // Debug allocator's heavy tracking and the per-call safety
    // instrumentation for an LLVM-optimized binary. Empirically
    // `eval(';')` drops from ~195 us/call to ~50 us/call, so the warm
    // test wall time drops to roughly a third of `zig build test`
    // (~10s -> ~5s on the 20-core ref machine).
    //
    // Cost: every test binary recompiles from scratch under
    // ReleaseSafe (~3 min cold for the full set), and the cache lives
    // in a separate per-optimize hash so flipping between
    // `test` and `test-debug` does not steal each other's cached
    // binaries.
    const engine_release_safe_mod = b.addModule("quickjs_zig_engine_release_safe", .{
        .root_source_file = b.path("src/engine/root.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    engine_release_safe_mod.addOptions("build_options", engine_options);
    const test_step = b.step("test", "Run all Zig tests (ReleaseSafe exec shards, fast warm runs, slow first cold compile)");
    inline for (exec_shards) |shard| {
        const matches_filter = if (shard_filter) |filter| std.mem.eql(u8, shard.name, filter) or std.mem.eql(u8, shard.name ++ "-fast", filter) else true;
        const fast_test_mod = b.createModule(.{
            .root_source_file = b.path(shard.path),
            .target = target,
            .optimize = .ReleaseSafe,
            .link_libc = true,
            .imports = &.{
                .{ .name = "quickjs_zig_engine", .module = engine_release_safe_mod },
            },
        });
        fast_test_mod.addOptions("build_options", engine_options);
        if (execShardUsesOomOptions(shard.path)) {
            fast_test_mod.addOptions("oom_options", quick_oom_options);
        }
        const fast_tests = b.addTest(.{
            .name = shard.name ++ "-fast",
            .root_module = fast_test_mod,
        });
        const run_fast_tests = b.addRunArtifact(fast_tests);
        if (matches_filter) {
            test_step.dependOn(&run_fast_tests.step);
        }
    }

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

    const test_debug_step = b.step("test-debug", "Run available Zig tests with exec shards in Debug mode (slower run, fast cold compile)");
    test_debug_step.dependOn(&run_engine_root_tests.step);
    test_debug_step.dependOn(&run_engine_production_tests.step);
    test_debug_step.dependOn(&run_core_tests.step);
    test_debug_step.dependOn(&run_bytecode_tests.step);
    test_debug_step.dependOn(&run_frontend_tests.step);
    inline for (exec_shards, 0..) |shard, i| {
        const matches_filter = if (shard_filter) |filter| std.mem.eql(u8, shard.name, filter) else true;
        if (matches_filter) {
            test_debug_step.dependOn(exec_run_steps[i]);
        }
    }
    test_debug_step.dependOn(&run_builtins_tests.step);
    test_debug_step.dependOn(&run_tools_tests.step);
    test_debug_step.dependOn(&run_test262_runner_tests.step);

    const engine_oom_mod = b.addModule("quickjs_zig_engine_oom", .{
        .root_source_file = b.path("src/engine/root.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    engine_oom_mod.addOptions("build_options", engine_options);
    const test_oom_step = b.step("test-oom", "Run sampled exec OOM fail-index sweeps in Debug mode");
    const test_oom_exhaustive_step = b.step("test-oom-exhaustive", "Run exhaustive exec OOM fail-index sweeps in Debug mode (very slow)");
    inline for (exec_shards) |shard| {
        const oom_test_mod = b.createModule(.{
            .root_source_file = b.path(shard.path),
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
            .imports = &.{
                .{ .name = "quickjs_zig_engine", .module = engine_oom_mod },
            },
        });
        oom_test_mod.addOptions("build_options", engine_options);
        if (execShardUsesOomOptions(shard.path)) {
            oom_test_mod.addOptions("oom_options", sampled_oom_options);
        }
        const oom_tests = b.addTest(.{
            .name = shard.name ++ "-oom",
            .root_module = oom_test_mod,
            .filters = &.{"OOM"},
        });
        const run_oom_tests = b.addRunArtifact(oom_tests);
        test_oom_step.dependOn(&run_oom_tests.step);

        const exhaustive_oom_test_mod = b.createModule(.{
            .root_source_file = b.path(shard.path),
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
            .imports = &.{
                .{ .name = "quickjs_zig_engine", .module = engine_oom_mod },
            },
        });
        exhaustive_oom_test_mod.addOptions("build_options", engine_options);
        if (execShardUsesOomOptions(shard.path)) {
            exhaustive_oom_test_mod.addOptions("oom_options", exhaustive_oom_options);
        }
        const exhaustive_oom_tests = b.addTest(.{
            .name = shard.name ++ "-oom-exhaustive",
            .root_module = exhaustive_oom_test_mod,
            .filters = &.{"OOM"},
        });
        const run_exhaustive_oom_tests = b.addRunArtifact(exhaustive_oom_tests);
        test_oom_exhaustive_step.dependOn(&run_exhaustive_oom_tests.step);
    }

    // `test-fast` remains as an alias for `test` (ReleaseSafe exec shards) for compatibility
    const test_fast_step = b.step("test-fast", "Run all Zig tests (ReleaseSafe exec shards, fast warm runs, slow first cold compile) [Alias for test]");
    test_fast_step.dependOn(test_step);

    // `test` also picks up the (cheap) non-exec test binaries
    // from the Debug build so it remains a full drop-in replacement
    // for `zig build test-debug`. Those non-exec binaries finish in <1s
    // each even in Debug, so re-compiling them under ReleaseSafe just
    // to save tens of milliseconds is not worth the extra cache
    // entries.
    test_step.dependOn(&run_engine_root_tests.step);
    test_step.dependOn(&run_engine_production_tests.step);
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_bytecode_tests.step);
    test_step.dependOn(&run_frontend_tests.step);
    test_step.dependOn(&run_builtins_tests.step);
    test_step.dependOn(&run_tools_tests.step);
    test_step.dependOn(&run_test262_runner_tests.step);

    const engine_production_gate_step = b.step("engine-production-gate", "Run the engine-only Production v1 release gate");
    engine_production_gate_step.dependOn(test_step);
    engine_production_gate_step.dependOn(test_fast_step);
    engine_production_gate_step.dependOn(smoke_step);
    engine_production_gate_step.dependOn(test262_gate_step);
}
