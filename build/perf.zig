const config = @import("config.zig");
const artifacts_mod = @import("artifacts.zig");
const profiles = @import("profiles.zig");

pub fn addPerfSteps(ctx: config.Ctx, artifacts: artifacts_mod.Artifacts) void {
    const b = ctx.b;
    const target = ctx.target;
    const forceLlvmBackendOnDebug = config.forceLlvmBackendOnDebug;
    const zjs_exe = artifacts.zjs_exe;
    const install_zjs = artifacts.install_zjs;
    const install_zjs_profile = artifacts.install_zjs_profile;
    const internal_fast_mod = artifacts.internal_fast_mod;
    const dossier_options = ctx.dossier_options;

    const run_perf_benchmark = b.addRunArtifact(zjs_exe);
    run_perf_benchmark.addArg("--perf-json");
    run_perf_benchmark.addArg("tests/perf/microbench.js");
    const perf_benchmark_step = b.step("perf-benchmark", "Run a repeatable diagnostic JS performance benchmark");
    perf_benchmark_step.dependOn(&run_perf_benchmark.step);

    const perf_runtime_profiles_step = b.step("perf-runtime-profiles", "Record zjs runtime profiles for focused benchmark scripts");

    inline for (profiles.runtime_profiles) |profile| {
        const base_args = [_][]const u8{
            "node",
            "tools/perf/run_runtime_profile.js",
            "--zjs",
            b.getInstallPath(.bin, "zjs-profile"),
            "--expect-total-opcodes-min",
            "1",
            "--output",
            ".zig-cache/perf/current/runtime/" ++ profile.script ++ ".json",
            "--stdout",
            ".zig-cache/perf/current/runtime/" ++ profile.script ++ ".stdout",
            "--expect-stdout",
            profile.expect_stdout,
        };

        const opcode_args = comptime blk: {
            var arr: [profile.expect_opcodes.len * 2][]const u8 = undefined;
            for (profile.expect_opcodes, 0..) |opcode, idx| {
                arr[idx * 2] = "--expect-opcode-max";
                arr[idx * 2 + 1] = opcode;
            }
            break :blk arr;
        };

        const opcode_min_args = comptime blk: {
            var arr: [profile.expect_opcode_mins.len * 2][]const u8 = undefined;
            for (profile.expect_opcode_mins, 0..) |opcode, idx| {
                arr[idx * 2] = "--expect-opcode-min";
                arr[idx * 2 + 1] = opcode;
            }
            break :blk arr;
        };

        const script_args = [_][]const u8{
            "reports/perf/current/scripts/" ++ profile.script ++ ".js",
        };

        const full_args = base_args ++ opcode_args ++ opcode_min_args ++ script_args;

        const run_profile = b.addSystemCommand(&full_args);
        run_profile.step.dependOn(&install_zjs.step);
        run_profile.step.dependOn(&install_zjs_profile.step);

        const profile_step = b.step(profile.name, profile.desc);
        profile_step.dependOn(&run_profile.step);
        perf_runtime_profiles_step.dependOn(profile_step);
    }

    const run_perf_self_current = b.addSystemCommand(&.{
        "bun",
        "tools/compare/run_microbench.js",
        "--zjs-only",
        "--iters",
        "30",
        "--warmup",
        "5",
        "--zjs",
        b.getInstallPath(.bin, "zjs"),
        "--output",
        ".zig-cache/perf/current/microbench-zjs-releasefast.json",
        "--emit-scripts",
        ".zig-cache/perf/current/scripts",
    });
    run_perf_self_current.step.dependOn(&install_zjs.step);

    const run_perf_self_diff = b.addSystemCommand(&.{
        "node",
        "tools/perf/diff_report.js",
        "--warn-case-regressions",
        "--output",
        ".zig-cache/perf/current/diff-zjs-self.md",
        "reports/perf/baseline/microbench-zjs-releasefast.json",
        ".zig-cache/perf/current/microbench-zjs-releasefast.json",
    });
    run_perf_self_diff.step.dependOn(&run_perf_self_current.step);
    const perf_self_check_step = b.step("perf-self-check", "Compare current zjs microbench timings against the checked-in zjs self baseline");
    perf_self_check_step.dependOn(&run_perf_self_diff.step);

    const run_perf_self_update = b.addSystemCommand(&.{
        "bun",
        "tools/compare/run_microbench.js",
        "--zjs-only",
        "--iters",
        "30",
        "--warmup",
        "5",
        "--zjs",
        b.getInstallPath(.bin, "zjs"),
        "--output",
        "reports/perf/baseline/microbench-zjs-releasefast.json",
        "--emit-scripts",
        ".zig-cache/perf/baseline/scripts",
    });
    run_perf_self_update.step.dependOn(&install_zjs.step);
    const run_perf_self_env_update = b.addSystemCommand(&.{
        "node",
        "tools/perf/write_env.js",
        "--iters",
        "30",
        "--warmup",
        "5",
        "--output",
        "reports/perf/baseline/env-zjs-self.md",
        "--zjs",
        b.getInstallPath(.bin, "zjs"),
        "--notes",
        "ZJS self-baseline report; qjs is intentionally not configured for this gate. This 64-bit build uses the default 16-byte JSValue representation.",
    });
    run_perf_self_env_update.step.dependOn(&run_perf_self_update.step);
    const perf_self_update_step = b.step("perf-self-update-baseline", "Refresh the checked-in zjs self performance baseline");
    perf_self_update_step.dependOn(&run_perf_self_env_update.step);

    const run_perf_hotpath = b.addSystemCommand(&.{
        "bun",
        "tools/compare/run_microbench.js",
        "--suite",
        "hotpath",
        "--zjs-only",
        "--iters",
        "30",
        "--warmup",
        "5",
        "--zjs",
        b.getInstallPath(.bin, "zjs"),
        "--output",
        ".zig-cache/perf/current/hotpath-zjs-releasefast.json",
        "--emit-scripts",
        ".zig-cache/perf/current/hotpath-scripts",
    });
    run_perf_hotpath.step.dependOn(&install_zjs.step);
    const perf_hotpath_step = b.step("perf-hotpath", "Record independent hotpath calibration benchmark report");
    perf_hotpath_step.dependOn(&run_perf_hotpath.step);

    const run_measurement_contract_tests = b.addSystemCommand(&.{
        "bun",
        "tools/compare/test_measurement_contract.js",
        "--output",
        ".zig-cache/perf/measurement-contract-tests.json",
    });
    const measurement_contract_test_step = b.step(
        "perf-measurement-contract",
        "Run the whole-process measurement contract tests (no binaries, no measurement lock)",
    );
    measurement_contract_test_step.dependOn(&run_measurement_contract_tests.step);

    const run_perf_native_callback = b.addSystemCommand(&.{
        "bun",
        "tools/compare/run_microbench.js",
        "--suite",
        "native-callback",
        "--zjs-only",
        "--interleaved",
        "--sessions",
        "3",
        "--iters",
        "30",
        "--warmup",
        "5",
        "--zjs",
        b.getInstallPath(.bin, "zjs"),
        "--output",
        ".zig-cache/perf/current/native-callback-zjs-releasefast.json",
        "--emit-scripts",
        ".zig-cache/perf/current/native-callback-scripts",
    });
    run_perf_native_callback.step.dependOn(&install_zjs.step);
    const perf_native_callback_step = b.step("perf-native-callback", "Record the native callback and execution-root benchmark suite");
    perf_native_callback_step.dependOn(&run_perf_native_callback.step);

    // Same-runtime benchmark harness: reuse the production engine module so
    // compile-once/execute-many measurements use the exact ReleaseFast engine
    // configuration and build options as the zjs CLI.
    const same_runtime_mod = b.createModule(.{
        .root_source_file = b.path("tools/perf/same_runtime/zjs_same_runtime.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .omit_frame_pointer = true,
        .imports = &.{
            .{ .name = "zjs", .module = internal_fast_mod },
        },
    });
    same_runtime_mod.addOptions("dossier_options", dossier_options);
    const same_runtime_exe = b.addExecutable(.{
        .name = "zjs-same-runtime",
        .root_module = same_runtime_mod,
    });
    forceLlvmBackendOnDebug(same_runtime_exe);
    const install_same_runtime = b.addInstallArtifact(same_runtime_exe, .{});
    const same_runtime_step = b.step("perf-same-runtime", "Build and install the ReleaseFast same-runtime benchmark harness");
    same_runtime_step.dependOn(&install_same_runtime.step);
    const build_qjs_same_runtime = b.addSystemCommand(&.{
        "bash",
        "tools/perf/same_runtime/build_qjs_harness.sh",
    });
    const same_runtime_all_step = b.step(
        "perf-same-runtime-all",
        "Build and install both zjs and QuickJS same-runtime benchmark harnesses",
    );
    same_runtime_all_step.dependOn(&install_same_runtime.step);
    same_runtime_all_step.dependOn(&build_qjs_same_runtime.step);

    // Direct/core performance scaffold. This is intentionally isolated from
    // every validation gate: the build-only step installs the Zig harness,
    // while perf-direct lets the driver compile the pinned QuickJS C harness
    // and run ABBA-interleaved paired samples.
    const perf_direct_zjs_mod = b.createModule(.{
        .root_source_file = b.path("tools/perf/direct/zjs_direct_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zjs", .module = internal_fast_mod },
        },
    });
    perf_direct_zjs_mod.addOptions("dossier_options", dossier_options);
    const perf_direct_zjs_exe = b.addExecutable(.{
        .name = "zjs-direct-bench",
        .root_module = perf_direct_zjs_mod,
    });
    forceLlvmBackendOnDebug(perf_direct_zjs_exe);
    const install_perf_direct_zjs = b.addInstallArtifact(perf_direct_zjs_exe, .{});
    const perf_direct_build_step = b.step("perf-direct-build", "Build and install the zjs direct/core benchmark harness");
    perf_direct_build_step.dependOn(&install_perf_direct_zjs.step);

    const run_perf_direct = b.addSystemCommand(&.{
        "bash",
        "tools/perf/direct/run_direct.sh",
        "--zig",
        b.graph.zig_exe,
        "--zjs",
        b.getInstallPath(.bin, "zjs-direct-bench"),
    });
    run_perf_direct.step.dependOn(&install_perf_direct_zjs.step);
    if (b.args) |args| run_perf_direct.addArgs(args);
    const perf_direct_step = b.step("perf-direct", "Run zjs versus pinned QuickJS direct/core benchmarks");
    perf_direct_step.dependOn(&run_perf_direct.step);

}
