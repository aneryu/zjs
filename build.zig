const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zjs_enable_ic = b.option(bool, "zjs_enable_ic", "Enable shape-keyed inline caches") orelse true;
    const shard_filter = b.option([]const u8, "shard", "Only run the specified zjs test shard");
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
    const test262_runner_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/run_test262.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "quickjs_zig_engine", .module = engine_mod },
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

    // 1. Engine tests
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

    // 2. Core runtime tests
    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/core/all.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "quickjs_zig_engine", .module = engine_mod },
                .{ .name = "zjs_cli", .module = zjs_cli_mod },
                .{ .name = "test262_runner", .module = test262_runner_mod },
            },
        }),
    });
    const run_core_tests = b.addRunArtifact(core_tests);

    // 3. GC stress tests
    const gc_stress_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/gc_stress.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "quickjs_zig_engine", .module = engine_mod },
            },
        }),
    });
    const run_gc_stress_tests = b.addRunArtifact(gc_stress_tests);

    // 4. Bytecode tests
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

    // 5. Frontend tests
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

    // 6. Builtins tests
    const builtins_test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests/builtins/all.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "quickjs_zig_engine", .module = engine_mod },
        },
    });
    const builtins_tests = b.addTest(.{
        .root_module = builtins_test_mod,
    });
    const run_builtins_tests = b.addRunArtifact(builtins_tests);

    // 7. Tools and CLI tests
    const tools_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/tools/all.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "test262_runner", .module = test262_runner_mod },
            },
        }),
    });
    const run_tools_tests = b.addRunArtifact(tools_tests);

    const zjs_cli_tests = b.addTest(.{
        .name = "zjs-cli",
        .root_module = zjs_cli_mod,
    });
    const run_zjs_cli_tests = b.addRunArtifact(zjs_cli_tests);

    const test262_runner_tests = b.addTest(.{
        .root_module = test262_runner_mod,
    });
    const run_test262_runner_tests = b.addRunArtifact(test262_runner_tests);


    // User-facing steps to expose
    const test_step = b.step("test", "Run all Zig tests (defaults to Debug optimization unless overridden)");

    // Expose fine-grained steps as requested (only those selected to be kept)
    const test_core_step = b.step("test-core", "Run core runtime foundation tests");
    test_core_step.dependOn(&run_core_tests.step);

    const test_frontend_step = b.step("test-frontend", "Run frontend parser and emitter tests");
    test_frontend_step.dependOn(&run_frontend_tests.step);

    const gc_stress_step = b.step("gc-stress", "Run deterministic GC stress tests");
    gc_stress_step.dependOn(&run_gc_stress_tests.step);


    // Attach common non-exec tests to main test step
    test_step.dependOn(&run_engine_root_tests.step);
    test_step.dependOn(&run_engine_production_tests.step);
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_gc_stress_tests.step);
    test_step.dependOn(&run_bytecode_tests.step);
    test_step.dependOn(&run_frontend_tests.step);
    test_step.dependOn(&run_builtins_tests.step);
    test_step.dependOn(&run_tools_tests.step);
    test_step.dependOn(&run_zjs_cli_tests.step);
    test_step.dependOn(&run_test262_runner_tests.step);


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
        .{ .name = "exec-collection-typedarray", .path = "src/tests/exec/collection_typedarray.zig" },
    };

    // Exec shards compilation and mapping to test steps
    inline for (exec_shards) |shard| {
        const matches_filter = if (shard_filter) |filter| std.mem.eql(u8, shard.name, filter) or std.mem.eql(u8, shard.name ++ "-fast", filter) else true;
        if (matches_filter) {
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
            const tests = b.addTest(.{
                .name = shard.name,
                .root_module = test_mod,
            });
            const run_tests = b.addRunArtifact(tests);
            test_step.dependOn(&run_tests.step);
        }
    }

    const engine_production_gate_step = b.step("engine-production-gate", "Run the engine-only Production v1 release gate");
    engine_production_gate_step.dependOn(test_step);
    engine_production_gate_step.dependOn(gc_stress_step);
    engine_production_gate_step.dependOn(test262_gate_step);
}
