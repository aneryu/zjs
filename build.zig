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
    const engine_options = b.addOptions();
    engine_options.addOption(bool, "zjs_enable_ic", zjs_enable_ic);

    const engine_mod = b.addModule("quickjs_zig_engine", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    engine_mod.addOptions("build_options", engine_options);

    const plugin_fixture_options = b.addOptions();
    plugin_fixture_options.addOption(bool, "zjs_enable_ic", zjs_enable_ic);
    const plugin_fixture_zjs_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    plugin_fixture_zjs_mod.addOptions("build_options", plugin_fixture_options);
    const runtime_plugin_fixture_mod = b.createModule(.{
        .root_source_file = b.path("tests/fixtures/runtime_plugin_fixture.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zjs", .module = plugin_fixture_zjs_mod },
        },
    });
    const runtime_plugin_fixture = b.addLibrary(.{
        .name = "zjs-runtime-plugin-fixture",
        .linkage = .dynamic,
        .root_module = runtime_plugin_fixture_mod,
    });
    const runtime_empty_plugin_fixture_mod = b.createModule(.{
        .root_source_file = b.path("tests/fixtures/runtime_empty_plugin_fixture.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zjs", .module = plugin_fixture_zjs_mod },
        },
    });
    const runtime_empty_plugin_fixture = b.addLibrary(.{
        .name = "zjs-runtime-empty-plugin-fixture",
        .linkage = .dynamic,
        .root_module = runtime_empty_plugin_fixture_mod,
    });

    const internal_fast_mod = b.createModule(.{
        .root_source_file = b.path("src/internal_root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    internal_fast_mod.addOptions("build_options", engine_options);
    const zjs_cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/zjs.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zjs", .module = internal_fast_mod },
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
                .{ .name = "zjs", .module = internal_fast_mod },
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
        "ZJS self-baseline report; qjs is intentionally not configured for this gate.",
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

    const run_architecture_deps = b.addSystemCommand(&.{
        "node",
        "tools/architecture/check_deps.js",
    });

    const architecture_public_api_mod = b.createModule(.{
        .root_source_file = b.path("tools/architecture/check_public_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zjs", .module = engine_mod },
        },
    });
    const architecture_public_api = b.addExecutable(.{
        .name = "check-public-api",
        .root_module = architecture_public_api_mod,
    });
    const run_architecture_public_api = b.addRunArtifact(architecture_public_api);
    run_architecture_public_api.addArg("reports/api/public-symbols.txt");

    const update_architecture_public_api = b.addRunArtifact(architecture_public_api);
    update_architecture_public_api.addArg("--write");
    update_architecture_public_api.addArg("reports/api/public-symbols.txt");

    const architecture_check_step = b.step("architecture-check", "Check architecture dependency rules and public API snapshot");
    architecture_check_step.dependOn(&run_architecture_deps.step);
    architecture_check_step.dependOn(&run_architecture_public_api.step);

    const architecture_snapshot_step = b.step("architecture-update-api-snapshot", "Refresh the public API snapshot");
    architecture_snapshot_step.dependOn(&update_architecture_public_api.step);

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
    const test_options = b.addOptions();
    test_options.addOption(bool, "zjs_enable_ic", zjs_enable_ic);
    test_options.addOptionPath("runtime_plugin_fixture_path", runtime_plugin_fixture.getEmittedBin());
    test_options.addOptionPath("runtime_empty_plugin_fixture_path", runtime_empty_plugin_fixture.getEmittedBin());
    test_options.addOption([]const u8, "zjs_executable_path", b.getInstallPath(.bin, "zjs"));
    unified_tests.root_module.addImport("quickjs_zig_engine", unified_tests.root_module);
    unified_tests.root_module.addImport("zjs", unified_tests.root_module);
    unified_tests.root_module.addOptions("build_options", test_options);
    const run_unified_tests = b.addRunArtifact(unified_tests);
    run_unified_tests.step.dependOn(&install_zjs.step);
    if (b.args) |args| run_unified_tests.addArgs(args);

    // Smoke tests (runs only the CLI integration tests in src/tests/smoke_test.zig)
    const smoke_tests = b.addTest(.{
        .name = "smoke-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/smoke_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    smoke_tests.test_runner = .{
        .path = b.path("tools/timing_test_runner.zig"),
        .mode = .simple,
    };
    smoke_tests.root_module.addImport("quickjs_zig_engine", unified_tests.root_module);
    smoke_tests.root_module.addImport("zjs", unified_tests.root_module);
    smoke_tests.root_module.addOptions("build_options", test_options);
    const run_smoke_tests = b.addRunArtifact(smoke_tests);
    run_smoke_tests.step.dependOn(&install_zjs.step);
    if (b.args) |args| run_smoke_tests.addArgs(args);

    const smoke_step = b.step("smoke", "Run JavaScript smoke fixtures against zjs");
    smoke_step.dependOn(&run_smoke_tests.step);

    // User-facing steps to expose
    const test_step = b.step("test", "Run all Zig tests (defaults to Debug optimization unless overridden)");

    test_step.dependOn(&run_unified_tests.step);

    const engine_production_gate_step = b.step("engine-production-gate", "Run the engine-only Production v1 release gate");
    engine_production_gate_step.dependOn(test_step);
    engine_production_gate_step.dependOn(smoke_step);
    engine_production_gate_step.dependOn(architecture_check_step);
    engine_production_gate_step.dependOn(test262_gate_step);
}
