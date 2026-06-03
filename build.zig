const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zjs_enable_ic = b.option(bool, "zjs_enable_ic", "Enable shape-keyed inline caches") orelse true;
    const engine_options = b.addOptions();
    engine_options.addOption(bool, "zjs_enable_ic", zjs_enable_ic);

    const engine_mod = b.addModule("quickjs_zig_engine", .{
        .root_source_file = b.path("src/engine/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    engine_mod.addOptions("build_options", engine_options);
    const test262_engine_fast_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    test262_engine_fast_mod.addOptions("build_options", engine_options);
    const zjs_cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/zjs.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zjs", .module = test262_engine_fast_mod },
        },
    });
    const zjs_exe = b.addExecutable(.{
        .name = "zjs",
        .root_module = zjs_cli_mod,
    });
    const install_zjs = b.addInstallArtifact(zjs_exe, .{});
    const zjs_step = b.step("zjs", "Build and install zjs");
    zjs_step.dependOn(&install_zjs.step);
    b.installArtifact(zjs_exe);

    const run_test262_exe = b.addExecutable(.{
        .name = "run-test262",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/run_test262.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
            .imports = &.{
                .{ .name = "quickjs_zig_engine", .module = test262_engine_fast_mod },
            },
        }),
    });
    const install_run_test262 = b.addInstallArtifact(run_test262_exe, .{});
    const run_test262_step = b.step("run-test262", "Build and install run-test262");
    run_test262_step.dependOn(&install_run_test262.step);

    // Add actual test262 execution step.
    const run_test262_exec = b.addRunArtifact(run_test262_exe);
    run_test262_exec.step.dependOn(&install_run_test262.step);
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

    const run_perf_benchmark = b.addRunArtifact(zjs_exe);
    run_perf_benchmark.addArg("--perf-json");
    run_perf_benchmark.addArg("tests/perf/microbench.js");
    const perf_benchmark_step = b.step("perf-benchmark", "Run a repeatable diagnostic JS performance benchmark");
    perf_benchmark_step.dependOn(&run_perf_benchmark.step);

    const ProfileConfig = struct {
        name: []const u8,
        desc: []const u8,
        script: []const u8,
        expect_stdout: []const u8,
        expect_opcodes: []const []const u8,
    };

    const profiles = [_]ProfileConfig{
        .{
            .name = "perf-uri-profile",
            .desc = "Record a zjs runtime profile for the URI 4-byte decode benchmark script",
            .script = "uri_decode_4byte",
            .expect_stdout = "65536\n",
            .expect_opcodes = &.{
                "get_var=67626",
                "get_var_ref0=0",
                "put_var=1042",
                "push_i16=1040",
                "goto16=0",
                "add=0",
                "if_false8=1",
            },
        },
        .{
            .name = "perf-uri-component-profile",
            .desc = "Record a zjs runtime profile for the URI component 4-byte decode benchmark script",
            .script = "uri_component_decode_4byte",
            .expect_stdout = "65536\n",
            .expect_opcodes = &.{
                "get_var=67626",
                "get_var_ref0=0",
                "put_var=1042",
                "push_i16=1040",
                "goto16=0",
                "add=0",
                "if_false8=1",
            },
        },
        .{
            .name = "perf-prop-global-profile",
            .desc = "Record a zjs runtime profile for the global property read benchmark script",
            .script = "prop_read_global_mono",
            .expect_stdout = "1000000\n",
            .expect_opcodes = &.{
                "get_field=0",
                "add=0",
                "goto8=0",
            },
        },
        .{
            .name = "perf-proto-global-profile",
            .desc = "Record a zjs runtime profile for the global prototype read benchmark script",
            .script = "proto_read_global",
            .expect_stdout = "1000000\n",
            .expect_opcodes = &.{
                "get_field=0",
                "add=0",
                "goto8=0",
            },
        },
        .{
            .name = "perf-prop-poly3-profile",
            .desc = "Record a zjs runtime profile for the global polymorphic property read benchmark script",
            .script = "prop_read_poly3_global",
            .expect_stdout = "1000000\n",
            .expect_opcodes = &.{
                "get_array_el=0",
                "get_field=0",
                "mod=0",
                "add=0",
                "goto8=0",
            },
        },
        .{
            .name = "perf-call2-global-profile",
            .desc = "Record a zjs runtime profile for the global call2 loop benchmark script",
            .script = "call2_loop_global",
            .expect_stdout = "500000500000\n",
            .expect_opcodes = &.{
                "call2=0",
                "add=0",
                "post_inc=0",
                "goto8=0",
            },
        },
        .{
            .name = "perf-closure-call-global-profile",
            .desc = "Record a zjs runtime profile for the global closure call loop benchmark script",
            .script = "closure_call_loop_global",
            .expect_stdout = "500000500000\n",
            .expect_opcodes = &.{
                "add=0",
                "post_inc=0",
                "goto8=0",
            },
        },
        .{
            .name = "perf-string-loop-profile",
            .desc = "Record a zjs runtime profile for the string microbench loop script",
            .script = "string_loop",
            .expect_stdout = "261\n",
            .expect_opcodes = &.{
                "get_var=1",
                "get_length=2",
                "push_i8=0",
                "gt=0",
                "get_field2=2",
                "call_method=2",
                "get_loc0=6000",
                "get_loc1=100",
                "add=2",
                "get_arg0=0",
                "lt=0",
                "if_false8=0",
                "post_inc=0",
                "goto8=0",
                "put_loc1=1",
                "drop=1",
            },
        },
        .{
            .name = "perf-empty-loop-profile",
            .desc = "Record a zjs runtime profile for the empty int32 for-loop benchmark script",
            .script = "empty_loop",
            .expect_stdout = "0\n",
            .expect_opcodes = &.{},
        },
    };

    const perf_runtime_profiles_step = b.step("perf-runtime-profiles", "Record checked zjs runtime profiles for focused benchmark scripts");

    inline for (profiles) |profile| {
        const base_args = [_][]const u8{
            "node",
            "tools/perf/run_runtime_profile.js",
            "--zjs",
            b.getInstallPath(.bin, "zjs"),
            "--output",
            "reports/perf/current/runtime/" ++ profile.script ++ ".json",
            "--stdout",
            "reports/perf/current/runtime/" ++ profile.script ++ ".stdout",
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

        const script_args = [_][]const u8{
            "reports/perf/current/scripts/" ++ profile.script ++ ".js",
        };

        const full_args = base_args ++ opcode_args ++ script_args;

        const run_profile = b.addSystemCommand(&full_args);
        run_profile.step.dependOn(&install_zjs.step);

        const profile_step = b.step(profile.name, profile.desc);
        profile_step.dependOn(&run_profile.step);
        perf_runtime_profiles_step.dependOn(profile_step);
    }

    const run_perf_env = b.addSystemCommand(&.{
        "node",
        "tools/perf/write_env.js",
        "--iters",
        "120",
        "--warmup",
        "15",
        "--output",
        "reports/perf/current/env.md",
        "--notes",
        "top10/diff are generated from checked-in zjs-microbench JSON reports; perf-benchmark is a separate runtime smoke and does not refresh reports/perf/current/microbench.json.",
    });

    const run_perf_top10 = b.addSystemCommand(&.{
        "node",
        "tools/perf/top10_report.js",
        "--output",
        "reports/perf/current/top10.md",
        "reports/perf/current/microbench.json",
    });
    run_perf_top10.step.dependOn(&run_perf_env.step);

    const run_perf_diff = b.addSystemCommand(&.{
        "node",
        "tools/perf/diff_report.js",
        "--allow-sample-config-drift",
        "--warn-case-regressions",
        "--output",
        "reports/perf/current/diff.md",
        "reports/perf/baseline/microbench-releasefast.json",
        "reports/perf/current/microbench.json",
    });
    run_perf_diff.step.dependOn(&run_perf_top10.step);

    const perf_compare_step = b.step("perf-compare", "Refresh checked-in performance report environment, top-10, and diff summaries");
    perf_compare_step.dependOn(&run_perf_diff.step);

    // Unified tests (runs all tests in one single binary, using src/all_tests.zig as compile root)
    const unified_tests = b.addTest(.{
        .name = "unified-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/all_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    unified_tests.test_runner = .{
        .path = b.path("tools/timing_test_runner.zig"),
        .mode = .simple,
    };
    unified_tests.root_module.addImport("quickjs_zig_engine", unified_tests.root_module);
    unified_tests.root_module.addImport("zjs", unified_tests.root_module);
    unified_tests.root_module.addOptions("build_options", engine_options);
    const run_unified_tests = b.addRunArtifact(unified_tests);

    // User-facing steps to expose
    const test_step = b.step("test", "Run all Zig tests (defaults to Debug optimization unless overridden)");

    test_step.dependOn(&run_unified_tests.step);

    const engine_production_gate_step = b.step("engine-production-gate", "Run the engine-only Production v1 release gate");
    engine_production_gate_step.dependOn(test_step);
    engine_production_gate_step.dependOn(test262_gate_step);
}
