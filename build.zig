const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zjs_enable_ic = b.option(bool, "zjs_enable_ic", "Enable shape-keyed inline caches") orelse true;
    const zjs_enable_opcode_profile = b.option(bool, "zjs_enable_opcode_profile", "Enable per-opcode profiling scopes") orelse false;
    // Default: the 16-byte (payload+tag) JSValue layout — the portable
    // reference representation that does not assume a 48-bit virtual address
    // space. The 8-byte NaN-boxed layout stays selectable (and guarded by the
    // test-altrepr step); it is lower-RSS / faster on this host but relies on
    // pointer-tagging assumptions, so it is no longer the default.
    const zjs_nan_boxing = b.option(bool, "zjs_nan_boxing", "Use the 8-byte NaN-boxed JSValue representation") orelse false;
    // OOM-injection coverage instrumentation (v1): records deduplicated
    // allocation call sites in core/memory.zig. Default off and comptime
    // gated, so the default build's allocation hot path is unchanged.
    // `zig build test-oom -Dzjs_oom_coverage=true` prints the count.
    const zjs_oom_coverage = b.option(bool, "zjs_oom_coverage", "Record distinct allocation call sites for the OOM corpus coverage report") orelse false;
    // Radical recursive rewrite (scratch/perf/ARCH-RECURSIVE-REWRITE.md): route
    // normal-func_kind JS->JS calls through the recursive register-resident
    // `callInternal` (pc/sp/var_buf as C-locals) instead of the flattened inline
    // Machine. Default OFF and comptime-gated while the rewrite is built up
    // incrementally — the default build keeps the proven flattened dispatchLoop.
    const zjs_recursive_dispatch = b.option(bool, "zjs_recursive_dispatch", "Use the recursive register-resident callInternal dispatcher (WIP)") orelse false;
    // Tail-call threaded dispatcher (scratch/perf/TAILCALL-REWRITE.md): each hot
    // opcode is its own small function; dispatch is `@call(.always_tail)` through
    // a 256-entry table = a real computed-goto `br`. Proven to match qjs per-opcode
    // (see the prototype). Default OFF + comptime-gated; when ON the engine module
    // is built with `-fomit-frame-pointer` (tail-call handlers never `ret`, so the
    // frame setup LLVM emits is pure overhead — removing it ~doubled the IPC).
    const zjs_tailcall_dispatch = b.option(bool, "zjs_tailcall_dispatch", "Use the tail-call threaded dispatcher (WIP)") orelse false;
    const engine_options = b.addOptions();
    engine_options.addOption(bool, "zjs_enable_ic", zjs_enable_ic);
    engine_options.addOption(bool, "zjs_enable_opcode_profile", zjs_enable_opcode_profile);
    engine_options.addOption(bool, "zjs_nan_boxing", zjs_nan_boxing);
    engine_options.addOption(bool, "zjs_oom_coverage", zjs_oom_coverage);
    engine_options.addOption(bool, "zjs_recursive_dispatch", zjs_recursive_dispatch);
    engine_options.addOption(bool, "zjs_tailcall_dispatch", zjs_tailcall_dispatch);
    // Omit the frame pointer ONLY when the tail-call dispatcher is on (the
    // default build keeps frame pointers + the user's gate baselines unchanged).
    const omit_fp: ?bool = if (zjs_tailcall_dispatch) true else null;

    const engine_mod = b.addModule("quickjs_zig_engine", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .omit_frame_pointer = omit_fp,
    });
    engine_mod.addOptions("build_options", engine_options);

    const plugin_fixture_options = b.addOptions();
    plugin_fixture_options.addOption(bool, "zjs_enable_ic", zjs_enable_ic);
    plugin_fixture_options.addOption(bool, "zjs_enable_opcode_profile", zjs_enable_opcode_profile);
    plugin_fixture_options.addOption(bool, "zjs_nan_boxing", zjs_nan_boxing);
    plugin_fixture_options.addOption(bool, "zjs_recursive_dispatch", zjs_recursive_dispatch);
    plugin_fixture_options.addOption(bool, "zjs_tailcall_dispatch", zjs_tailcall_dispatch);
    plugin_fixture_options.addOption(bool, "zjs_oom_coverage", zjs_oom_coverage);
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
        .omit_frame_pointer = omit_fp,
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

    // OOM no-panic rule: allocation failures must propagate as errors (the
    // catchable-OOM contract from eecf6c8); @panic / OutOfMemory-discard
    // forms in engine sources require an allowlist entry (<=10, currently 1:
    // the rope-flatten last resort).
    const run_architecture_oom_panics = b.addSystemCommand(&.{
        "node",
        "tools/architecture/check_oom_panics.js",
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
    architecture_check_step.dependOn(&run_architecture_oom_panics.step);
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
    test_options.addOption(bool, "zjs_enable_opcode_profile", zjs_enable_opcode_profile);
    test_options.addOption(bool, "zjs_nan_boxing", zjs_nan_boxing);
    test_options.addOption(bool, "zjs_oom_coverage", zjs_oom_coverage);
    test_options.addOption(bool, "zjs_recursive_dispatch", zjs_recursive_dispatch);
    test_options.addOption(bool, "zjs_tailcall_dispatch", zjs_tailcall_dispatch);
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

    // OOM injection suite (`zig build test-oom`): exhaustive allocation
    // failure injection (std.testing.checkAllAllocationFailures) over an
    // embedded JS corpus, plus single-shot fail-at-N recovery canaries.
    // Cost scales with allocation counts, so this is a phase-gate tier
    // command rather than part of the per-checkpoint `zig build test`.
    // The corpus binary compiles only the engine (internal_root), not the
    // unified test suite.
    const oom_engine_mod = b.createModule(.{
        .root_source_file = b.path("src/internal_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    oom_engine_mod.addOptions("build_options", engine_options);
    const oom_tests = b.addTest(.{
        .name = "oom-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/oom.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zjs", .module = oom_engine_mod },
            },
        }),
    });
    oom_tests.test_runner = .{
        .path = b.path("tools/timing_test_runner.zig"),
        .mode = .simple,
    };
    const run_oom_tests = b.addRunArtifact(oom_tests);
    if (b.args) |args| run_oom_tests.addArgs(args);
    const test_oom_step = b.step("test-oom", "Run allocation-failure injection over the embedded OOM corpus plus recovery canaries (phase-gate tier)");
    test_oom_step.dependOn(&run_oom_tests.step);

    // Focused 8MB-cap OOM behaviour fixture. The same tests run inside the
    // unified suite (all_tests.zig references src/tests/oom_cap.zig); this
    // binary makes the production gate's dependency on the cap behaviour
    // explicit.
    const oom_cap_tests = b.addTest(.{
        .name = "oom-cap-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/oom_cap.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zjs", .module = oom_engine_mod },
            },
        }),
    });
    oom_cap_tests.test_runner = .{
        .path = b.path("tools/timing_test_runner.zig"),
        .mode = .simple,
    };
    const run_oom_cap_tests = b.addRunArtifact(oom_cap_tests);

    // Alternate JSValue representation guard: runs the unified suite in a
    // nested build with the non-default representation (a full second build
    // graph, so the plugin fixtures recompile with a matching ABI
    // fingerprint). Required for any change touching core/value.zig or
    // value-representation semantics.
    const altrepr_tests = b.addSystemCommand(&.{
        b.graph.zig_exe, "build", "test", "-Dzjs_nan_boxing=true", "--summary", "all",
    });
    const altrepr_step = b.step("test-altrepr", "Run the unified tests with the non-default (8-byte NaN-boxed) JSValue representation");
    altrepr_step.dependOn(&altrepr_tests.step);

    // User-facing steps to expose
    const test_step = b.step("test", "Run all Zig tests (defaults to Debug optimization unless overridden)");

    test_step.dependOn(&run_unified_tests.step);

    const engine_production_gate_step = b.step("engine-production-gate", "Run the engine-only Production v1 release gate");
    engine_production_gate_step.dependOn(test_step);
    engine_production_gate_step.dependOn(smoke_step);
    engine_production_gate_step.dependOn(architecture_check_step);
    engine_production_gate_step.dependOn(test262_gate_step);
    engine_production_gate_step.dependOn(&run_oom_cap_tests.step);
}
