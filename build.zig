const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Zig defaults the build/test seed to a new random value for every
    // invocation. That changes test-runner arguments and destabilizes this
    // repository's large compile graph cache even when no source changed.
    // This stabilizes child compile/test steps; canonical commands also pass
    // CLI `--seed 0` so the build runner and dependency traversal are stable.
    // Randomized test runs remain available through the explicit project
    // option.
    const zjs_test_seed = b.option(u32, "zjs_test_seed", "Seed passed to Zig test runners (defaults to 0 for reproducible cached builds)") orelse 0;
    b.graph.random_seed = zjs_test_seed;
    const zjs_enable_opcode_profile = b.option(bool, "zjs_enable_opcode_profile", "Enable per-opcode profiling scopes") orelse false;
    // Match QuickJS's target policy: pointer-width >= 64 uses the canonical
    // 16-byte payload+tag JSValue; narrower targets use the 8-byte NaN-boxed
    // representation. The explicit option remains available for parity and
    // memory-footprint experiments, and `test-altrepr` guards the opposite of
    // the target default.
    const target_default_nan_boxing = target.result.ptrBitWidth() < 64;
    const zjs_nan_boxing = b.option(bool, "zjs_nan_boxing", "Use the 8-byte NaN-boxed JSValue representation") orelse target_default_nan_boxing;
    // QCP-1: compiler selection. v2 = the QuickJS-model compiler-v2 and the
    // production default since the switch ruling; legacy = the Phase 1/2/3
    // pipeline, kept as the explicit fallback; dual = compile with both,
    // compare, execute the v2 product, kept as the differential oracle.
    // See docs/qcp1_switch_decision.md for the gate the default rests on.
    const zjs_compiler = b.option([]const u8, "zjs_compiler", "Compiler selection: v2 (default), legacy, or dual") orelse "v2";
    if (!std.mem.eql(u8, zjs_compiler, "legacy") and
        !std.mem.eql(u8, zjs_compiler, "v2") and
        !std.mem.eql(u8, zjs_compiler, "dual"))
    {
        std.debug.print("error: invalid -Dzjs_compiler value '{s}': expected legacy, v2, or dual\n", .{zjs_compiler});
        std.process.exit(1);
    }
    // QCP-1: compiler-v2 final bytecode layout. `short` is part of the release
    // configuration, not an optimization knob: the switch measurements were
    // taken against it. `plain` stays reachable as the A/B diagnostic
    // instrument (it is how C2-B artifact residency was localised).
    const zjs_v2_layout = b.option([]const u8, "zjs_v2_layout", "compiler-v2 final layout: short (default) or plain (diagnostic)") orelse "short";
    if (!std.mem.eql(u8, zjs_v2_layout, "plain") and !std.mem.eql(u8, zjs_v2_layout, "short")) {
        std.debug.print("error: invalid -Dzjs_v2_layout value '{s}': expected plain or short\n", .{zjs_v2_layout});
        std.process.exit(1);
    }
    // OOM-injection coverage instrumentation (v1): records deduplicated
    // allocation call sites in core/memory.zig. Default off and comptime
    // gated, so the default build's allocation hot path is unchanged.
    // `zig build test-oom -Dzjs_oom_coverage=true` prints the count.
    const zjs_oom_coverage = b.option(bool, "zjs_oom_coverage", "Record distinct allocation call sites for the OOM corpus coverage report") orelse false;
    const zjs_force_gc = b.option(bool, "zjs_force_gc", "Force a full GC before each runtime heap allocation") orelse false;
    // Atom-ownership audit instrumentation: a one-slot quarantine on the
    // atom table's dead-slot free list (core/atom.zig) so a just-freed atom
    // id cannot be handed straight back by the very next intern. This turns
    // "borrow an atom out of a token, then use it after the owner released
    // it" from a silently masked hazard into a `dup` liveness assertion.
    // This is the ASAN / leak-checker tier: CI, fuzzing and regression runs
    // only. Default off, comptime erased when off (no field, no code, no
    // string in the default binary), and never part of the production path.
    // `zig build test -Dzjs_ownership_audit=true`; see
    // docs/borrowed_atom_audit.md §6.
    const zjs_ownership_audit = b.option(bool, "zjs_ownership_audit", "Quarantine one just-freed atom slot so borrowed-atom use-after-free trips an assertion instead of being masked by slot reuse (audit tier; never ReleaseFast)") orelse false;

    // ===== QCP-1 configuration signature =====
    // The defect class this closes is "a gate reports green about a
    // configuration it never ran". `zig build test-altrepr -Dzjs_compiler=v2`
    // spawned a child `zig build` that started from the defaults and ran the
    // *legacy* suite. Forwarding options fixes that one instance; the
    // signature makes the class unexpressible, because every gate can now
    // state which configuration its green belongs to.
    //
    // This is the build graph's BELIEF about the configuration. The compiled
    // code computes the same string independently, in src/config_signature.zig,
    // from the declarations it actually consumes (resolve_labels.default_layout,
    // Parser.single_backend_is_v2/dual_compare_enabled, core.value.nan_boxing,
    // core.memory.force_gc_on_allocation_enabled, core.atom.ownership_audit_enabled).
    // The two are compared by `zig build config-signature-check` against the
    // shipped binary and by the in-suite attestation test against the test
    // binary, so a drift between belief and behaviour fails instead of
    // reporting green.
    const config_signature = configSignature(b, .{
        .compiler = zjs_compiler,
        .layout = zjs_v2_layout,
        .nan_boxing = zjs_nan_boxing,
        .force_gc = zjs_force_gc,
        .ownership_audit = zjs_ownership_audit,
    });
    // Internal cross-build assertion. A parent build that spawns a child
    // `zig build` states the configuration it expects the child to resolve;
    // the child fails loudly here if it resolved anything else. This is what
    // turns a dropped/ignored option in a nested gate into a hard build
    // failure rather than a silent green.
    if (b.option([]const u8, "zjs_expect_config", "Internal: fail the build unless the resolved configuration signature matches exactly (used by nested gate builds)")) |expected| {
        if (!std.mem.eql(u8, expected, config_signature)) {
            std.debug.print(
                \\error: configuration signature mismatch
                \\  expected (requested by -Dzjs_expect_config): {s}
                \\  resolved (this build's own options):         {s}
                \\
            , .{ expected, config_signature });
            std.process.exit(1);
        }
    }

    const zjs_dossier_simple_ctor = b.option([]const u8, "zjs_dossier_simple_ctor", "Dossier-only simple-constructor variant: a, b, or c") orelse "a";
    if (!std.mem.eql(u8, zjs_dossier_simple_ctor, "a") and
        !std.mem.eql(u8, zjs_dossier_simple_ctor, "b") and
        !std.mem.eql(u8, zjs_dossier_simple_ctor, "c"))
    {
        std.debug.print(
            "error: invalid -Dzjs_dossier_simple_ctor value '{s}': expected a, b, or c\n",
            .{zjs_dossier_simple_ctor},
        );
        std.process.exit(1);
    }
    // Separate options object for the dossier harnesses. Reusing engine_options
    // here would register the same generated file under two module names
    // (the harnesses already receive it transitively via internal_fast_mod).
    const zjs_dossier_layout_pad = b.option(usize, "zjs_dossier_layout_pad", "Dossier-only layout-lineage pad slot count (0 = no effect)") orelse 0;
    const dossier_options = b.addOptions();
    dossier_options.addOption([]const u8, "zjs_dossier_simple_ctor", zjs_dossier_simple_ctor);
    dossier_options.addOption(usize, "zjs_dossier_layout_pad", zjs_dossier_layout_pad);
    const engine_options = b.addOptions();
    engine_options.addOption(bool, "zjs_enable_opcode_profile", zjs_enable_opcode_profile);
    engine_options.addOption(bool, "zjs_nan_boxing", zjs_nan_boxing);
    engine_options.addOption([]const u8, "zjs_compiler", zjs_compiler);
    engine_options.addOption([]const u8, "zjs_v2_layout", zjs_v2_layout);
    engine_options.addOption([]const u8, "zjs_expected_config_signature", config_signature);
    engine_options.addOption(bool, "zjs_oom_coverage", zjs_oom_coverage);
    engine_options.addOption(bool, "zjs_force_gc", zjs_force_gc);
    engine_options.addOption(bool, "zjs_ownership_audit", zjs_ownership_audit);
    engine_options.addOption([]const u8, "zjs_dossier_simple_ctor", zjs_dossier_simple_ctor);
    engine_options.addOption(usize, "zjs_dossier_layout_pad", zjs_dossier_layout_pad);

    const engine_mod = b.addModule("quickjs_zig_engine", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    engine_mod.addOptions("build_options", engine_options);

    const plugin_fixture_options = b.addOptions();
    plugin_fixture_options.addOption(bool, "zjs_enable_opcode_profile", zjs_enable_opcode_profile);
    plugin_fixture_options.addOption(bool, "zjs_nan_boxing", zjs_nan_boxing);
    plugin_fixture_options.addOption([]const u8, "zjs_compiler", zjs_compiler);
    plugin_fixture_options.addOption([]const u8, "zjs_v2_layout", zjs_v2_layout);
    plugin_fixture_options.addOption([]const u8, "zjs_expected_config_signature", config_signature);
    plugin_fixture_options.addOption(bool, "zjs_oom_coverage", zjs_oom_coverage);
    plugin_fixture_options.addOption(bool, "zjs_force_gc", zjs_force_gc);
    plugin_fixture_options.addOption(bool, "zjs_ownership_audit", zjs_ownership_audit);
    plugin_fixture_options.addOption([]const u8, "zjs_dossier_simple_ctor", zjs_dossier_simple_ctor);
    plugin_fixture_options.addOption(usize, "zjs_dossier_layout_pad", zjs_dossier_layout_pad);
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
    const install_runtime_plugin_fixture = b.addInstallArtifact(runtime_plugin_fixture, .{
        .dest_dir = .{ .override = .lib },
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
    const install_runtime_empty_plugin_fixture = b.addInstallArtifact(runtime_empty_plugin_fixture, .{
        .dest_dir = .{ .override = .lib },
    });

    const internal_fast_mod = b.createModule(.{
        .root_source_file = b.path("src/internal_root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .omit_frame_pointer = true, // EXPERIMENT: measure per-op prologue (stp/ldp) cost
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

    // Profiling CLI: the same ReleaseFast engine with per-opcode dispatch
    // scopes compiled in (the hot table is comptime-wrapped; see
    // exec/vm_profile.zig). A separate artifact so --profile-opcodes users
    // and the perf-runtime-profiles gate never depend on remembering -D
    // flags, and the default zjs binary never carries profiling code.
    const profile_engine_options = b.addOptions();
    profile_engine_options.addOption(bool, "zjs_enable_opcode_profile", true);
    profile_engine_options.addOption(bool, "zjs_nan_boxing", zjs_nan_boxing);
    profile_engine_options.addOption([]const u8, "zjs_compiler", zjs_compiler);
    profile_engine_options.addOption([]const u8, "zjs_v2_layout", zjs_v2_layout);
    profile_engine_options.addOption([]const u8, "zjs_expected_config_signature", config_signature);
    profile_engine_options.addOption(bool, "zjs_oom_coverage", zjs_oom_coverage);
    profile_engine_options.addOption(bool, "zjs_force_gc", zjs_force_gc);
    profile_engine_options.addOption(bool, "zjs_ownership_audit", zjs_ownership_audit);
    profile_engine_options.addOption([]const u8, "zjs_dossier_simple_ctor", zjs_dossier_simple_ctor);
    profile_engine_options.addOption(usize, "zjs_dossier_layout_pad", zjs_dossier_layout_pad);
    const internal_profile_mod = b.createModule(.{
        .root_source_file = b.path("src/internal_root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .omit_frame_pointer = true,
    });
    internal_profile_mod.addOptions("build_options", profile_engine_options);
    const zjs_profile_cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/zjs.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zjs", .module = internal_profile_mod },
        },
    });
    const zjs_profile_exe = b.addExecutable(.{
        .name = "zjs-profile",
        .root_module = zjs_profile_cli_mod,
    });
    const install_zjs_profile = b.addInstallArtifact(zjs_profile_exe, .{});
    const zjs_profile_step = b.step("zjs-profile", "Build and install the profiling zjs (per-opcode dispatch scopes)");
    zjs_profile_step.dependOn(&install_zjs_profile.step);

    // Debug-only CLI used by the inner-loop gate. Keep the production `zjs`
    // artifact ReleaseFast while avoiding optimized whole-engine compilation
    // on every focused edit.
    const internal_dev_mod = b.createModule(.{
        .root_source_file = b.path("src/internal_root.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    internal_dev_mod.addOptions("build_options", engine_options);
    const zjs_dev_cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/zjs.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zjs", .module = internal_dev_mod },
        },
    });
    const zjs_dev_exe = b.addExecutable(.{
        .name = "zjs-dev",
        .root_module = zjs_dev_cli_mod,
    });
    const install_zjs_dev = b.addInstallArtifact(zjs_dev_exe, .{});
    const zjs_dev_step = b.step("zjs-dev", "Build and install the Debug zjs used by inner-loop checks");
    zjs_dev_step.dependOn(&install_zjs_dev.step);

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

    const run_test262_dev_exe = b.addExecutable(.{
        .name = "run-test262-dev",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/run_test262.zig"),
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zjs", .module = internal_dev_mod },
            },
        }),
    });
    const install_run_test262_dev = b.addInstallArtifact(run_test262_dev_exe, .{});
    const run_test262_dev_step = b.step("run-test262-dev", "Build and install the Debug test262 runner used by checkpoint checks");
    run_test262_dev_step.dependOn(&install_run_test262_dev.step);

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

    const test262_smoke_files = [_][]const u8{
        "test262/test/language/types/null/S8.2_A1_T1.js",
        "test262/test/language/types/undefined/S8.1_A1_T1.js",
        "test262/test/language/expressions/assignment/S11.13.1_A3.2.js",
        "test262/test/language/statements/for/S12.6.3_A1.js",
        "test262/test/language/statements/try/S12.14_A1.js",
        "test262/test/language/expressions/arrow-function/empty-function-body-returns-undefined.js",
        "test262/test/built-ins/Array/prototype/push/S15.4.4.7_A1_T1.js",
        "test262/test/built-ins/Object/defineProperty/15.2.3.6-4-293.js",
        "test262/test/built-ins/String/prototype/slice/S15.5.4.13_A1_T1.js",
        "test262/test/built-ins/RegExp/prototype/test/S15.10.6.3_A1_T1.js",
        "test262/test/built-ins/Promise/prototype/then/S25.4.5.3_A1.1_T1.js",
        "test262/test/built-ins/JSON/stringify/value-primitive-top-level.js",
    };
    const run_test262_smoke = b.addRunArtifact(run_test262_dev_exe);
    run_test262_smoke.step.dependOn(&install_run_test262_dev.step);
    run_test262_smoke.addArg("-t");
    run_test262_smoke.addArg("8");
    run_test262_smoke.addArg("-T");
    run_test262_smoke.addArg("10000");
    run_test262_smoke.addArg("-c");
    run_test262_smoke.addArg("test262.conf");
    for (test262_smoke_files) |file| {
        run_test262_smoke.addArg("-f");
        run_test262_smoke.addArg(file);
    }
    run_test262_smoke.addArg("-R");
    run_test262_smoke.addArg(".zig-cache/test262-smoke");
    const test262_smoke_step = b.step("test262-smoke", "Run a small representative test262 file set with the Debug runner");
    test262_smoke_step.dependOn(&run_test262_smoke.step);

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
        // Minimum gates: an all-zero profile must never pass (the 2026-07-31
        // regression survived precisely because 0 <= max is vacuous).
        expect_opcode_mins: []const []const u8 = &.{},
    };

    const profiles = [_]ProfileConfig{
        .{
            .name = "perf-uri-profile",
            .desc = "Record a zjs runtime profile for the URI 4-byte decode benchmark script",
            .script = "uri_decode_4byte",
            .expect_stdout = "65536\n",
            // Exact dispatch-count pins recalibrated 2026-07-31 against the
            // restored total-dispatch counting (D0). A drop or rise must be
            // acknowledged by recalibrating, never by loosening to a vacuum.
            .expect_opcodes = &.{
                "get_var=988211",
                "get_var_ref0=0",
                "put_var=396322",
                "push_i16=396320",
                "goto16=66576",
                "add=527360",
                "if_false8=65536",
            },
            .expect_opcode_mins = &.{
                "get_var=988211",
                "put_var=396322",
                "push_i16=396320",
                "goto16=66576",
                "add=527360",
                "if_false8=65536",
            },
        },
        .{
            .name = "perf-uri-component-profile",
            .desc = "Record a zjs runtime profile for the URI component 4-byte decode benchmark script",
            .script = "uri_component_decode_4byte",
            .expect_stdout = "65536\n",
            // Exact dispatch-count pins recalibrated 2026-07-31 against the
            // restored total-dispatch counting (D0). A drop or rise must be
            // acknowledged by recalibrating, never by loosening to a vacuum.
            .expect_opcodes = &.{
                "get_var=988211",
                "get_var_ref0=0",
                "put_var=396322",
                "push_i16=396320",
                "goto16=66576",
                "add=527360",
                "if_false8=65536",
            },
            .expect_opcode_mins = &.{
                "get_var=988211",
                "put_var=396322",
                "push_i16=396320",
                "goto16=66576",
                "add=527360",
                "if_false8=65536",
            },
        },
        .{
            .name = "perf-prop-global-profile",
            .desc = "Record a zjs runtime profile for the global property read benchmark script",
            .script = "prop_read_global_mono",
            .expect_stdout = "1000000\n",
            // Exact dispatch-count pins recalibrated 2026-07-31 against the
            // restored total-dispatch counting (D0). A drop or rise must be
            // acknowledged by recalibrating, never by loosening to a vacuum.
            .expect_opcodes = &.{
                "get_field=1000000",
                "add=1000000",
                "goto8=1000000",
            },
            .expect_opcode_mins = &.{
                "get_field=1000000",
                "add=1000000",
                "goto8=1000000",
            },
        },
        .{
            .name = "perf-proto-global-profile",
            .desc = "Record a zjs runtime profile for the global prototype read benchmark script",
            .script = "proto_read_global",
            .expect_stdout = "1000000\n",
            // Exact dispatch-count pins recalibrated 2026-07-31 against the
            // restored total-dispatch counting (D0). A drop or rise must be
            // acknowledged by recalibrating, never by loosening to a vacuum.
            .expect_opcodes = &.{
                "get_field=1000000",
                "add=1000000",
                "goto8=1000000",
            },
            .expect_opcode_mins = &.{
                "get_field=1000000",
                "add=1000000",
                "goto8=1000000",
            },
        },
        .{
            .name = "perf-prop-poly3-profile",
            .desc = "Record a zjs runtime profile for the global polymorphic property read benchmark script",
            .script = "prop_read_poly3_global",
            .expect_stdout = "1000000\n",
            // Exact dispatch-count pins recalibrated 2026-07-31 against the
            // restored total-dispatch counting (D0). A drop or rise must be
            // acknowledged by recalibrating, never by loosening to a vacuum.
            .expect_opcodes = &.{
                "get_array_el=1000000",
                "get_field=1000000",
                "mod=1000000",
                "add=1000000",
                "goto8=1000000",
            },
            .expect_opcode_mins = &.{
                "get_array_el=1000000",
                "get_field=1000000",
                "mod=1000000",
                "add=1000000",
                "goto8=1000000",
            },
        },
        .{
            .name = "perf-call2-global-profile",
            .desc = "Record a zjs runtime profile for the global call2 loop benchmark script",
            .script = "call2_loop_global",
            .expect_stdout = "500000500000\n",
            // Exact dispatch-count pins recalibrated 2026-07-31 against the
            // restored total-dispatch counting (D0). A drop or rise must be
            // acknowledged by recalibrating, never by loosening to a vacuum.
            .expect_opcodes = &.{
                "call2=1000000",
                "add=2000000",
                "post_inc=1000000",
                "goto8=1000000",
            },
            .expect_opcode_mins = &.{
                "call2=1000000",
                "add=2000000",
                "post_inc=1000000",
                "goto8=1000000",
            },
        },
        .{
            .name = "perf-closure-call-global-profile",
            .desc = "Record a zjs runtime profile for the global closure call loop benchmark script",
            .script = "closure_call_loop_global",
            .expect_stdout = "500000500000\n",
            // Exact dispatch-count pins recalibrated 2026-07-31 against the
            // restored total-dispatch counting (D0). A drop or rise must be
            // acknowledged by recalibrating, never by loosening to a vacuum.
            .expect_opcodes = &.{
                "add=2000000",
                "post_inc=1000000",
                "goto8=1000000",
            },
            .expect_opcode_mins = &.{
                "add=2000000",
                "post_inc=1000000",
                "goto8=1000000",
            },
        },
        .{
            .name = "perf-string-loop-profile",
            .desc = "Record a zjs runtime profile for the string microbench loop script",
            .script = "string_loop",
            .expect_stdout = "261\n",
            // Exact dispatch-count pins recalibrated 2026-07-31 against the
            // restored total-dispatch counting (D0). A drop or rise must be
            // acknowledged by recalibrating, never by loosening to a vacuum.
            .expect_opcodes = &.{
                "get_var=5002",
                "get_length=5002",
                "push_i8=15309",
                "gt=5000",
                "get_field2=5311",
                "call_method=5311",
                "get_loc0=5313",
                "get_loc1=10001",
                "add=10002",
                "get_arg0=5001",
                "lt=5001",
                "if_false8=10001",
                "post_inc=0",
                "goto8=5000",
                "put_loc1=1",
                "drop=0",
            },
            .expect_opcode_mins = &.{
                "get_var=5002",
                "get_length=5002",
                "push_i8=15309",
                "gt=5000",
                "get_field2=5311",
                "call_method=5311",
                "get_loc0=5313",
                "get_loc1=10001",
                "add=10002",
                "get_arg0=5001",
                "lt=5001",
                "if_false8=10001",
                "goto8=5000",
                "put_loc1=1",
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
            b.getInstallPath(.bin, "zjs-profile"),
            "--expect-total-opcodes-min",
            "1",
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

    // Borrowed-atom escape rule: an atom id read out of a token (or out of a
    // helper that returns one) must not be returned, parked in a long-lived
    // parser State field, or read after advance()/freeToken() released the
    // token. This is the review-time half of the ada949be class-C fix; the
    // run-time half is -Dzjs_ownership_audit (docs/borrowed_atom_audit.md §8).
    const run_architecture_borrowed_atoms = b.addSystemCommand(&.{
        "node",
        "tools/architecture/check_borrowed_atoms.js",
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

    const architecture_check_step = b.step("architecture-check", "Check architecture dependency, OOM-panic, borrowed-atom, and public API rules");
    architecture_check_step.dependOn(&run_architecture_deps.step);
    architecture_check_step.dependOn(&run_architecture_oom_panics.step);
    architecture_check_step.dependOn(&run_architecture_borrowed_atoms.step);
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
    test_options.addOption(bool, "zjs_enable_opcode_profile", zjs_enable_opcode_profile);
    test_options.addOption(bool, "zjs_nan_boxing", zjs_nan_boxing);
    test_options.addOption([]const u8, "zjs_compiler", zjs_compiler);
    test_options.addOption([]const u8, "zjs_v2_layout", zjs_v2_layout);
    test_options.addOption([]const u8, "zjs_expected_config_signature", config_signature);
    test_options.addOption(bool, "zjs_oom_coverage", zjs_oom_coverage);
    test_options.addOption(bool, "zjs_force_gc", zjs_force_gc);
    test_options.addOption(bool, "zjs_ownership_audit", zjs_ownership_audit);
    test_options.addOption([]const u8, "zjs_dossier_simple_ctor", zjs_dossier_simple_ctor);
    test_options.addOption(usize, "zjs_dossier_layout_pad", zjs_dossier_layout_pad);
    test_options.addOption([]const u8, "runtime_plugin_fixture_path", b.getInstallPath(.lib, runtime_plugin_fixture.out_filename));
    test_options.addOption([]const u8, "runtime_empty_plugin_fixture_path", b.getInstallPath(.lib, runtime_empty_plugin_fixture.out_filename));
    unified_tests.root_module.addImport("quickjs_zig_engine", unified_tests.root_module);
    unified_tests.root_module.addImport("zjs", unified_tests.root_module);
    unified_tests.root_module.addOptions("build_options", test_options);
    const run_unified_tests = b.addRunArtifact(unified_tests);
    run_unified_tests.step.dependOn(&install_runtime_plugin_fixture.step);
    run_unified_tests.step.dependOn(&install_runtime_empty_plugin_fixture.step);
    if (b.args) |args| run_unified_tests.addArgs(args);

    // Production smoke tests retain the ReleaseFast CLI contract.
    const smoke_options = b.addOptions();
    smoke_options.addOption([]const u8, "zjs_executable_path", b.getInstallPath(.bin, "zjs"));
    smoke_options.addOption([]const u8, "zjs_profile_executable_path", b.getInstallPath(.bin, "zjs-profile"));
    smoke_options.addOption(bool, "smoke_profile_checks", true);
    const smoke_tests = b.addTest(.{
        .name = "smoke-tests-releasefast",
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
    smoke_tests.root_module.addOptions("build_options", smoke_options);
    const run_smoke_tests = b.addRunArtifact(smoke_tests);
    run_smoke_tests.step.dependOn(&install_zjs.step);
    run_smoke_tests.step.dependOn(&install_zjs_profile.step);
    if (b.args) |args| run_smoke_tests.addArgs(args);

    // Run the SHIPPED artifact and make it state its own configuration, then
    // compare that against what the build graph requested. The binary answers
    // from src/config_signature.zig, which reads the declarations the engine
    // consumes; this build states what it believes it configured. Any drift
    // between the two -- an option that never reached the code, a hardcoded
    // constant that outlived its option -- fails here.
    const run_config_signature = b.addRunArtifact(zjs_exe);
    run_config_signature.addArg("--print-config-signature");
    run_config_signature.expectStdOutEqual(b.fmt("{s}\n", .{config_signature}));
    const config_signature_step = b.step("config-signature-check", "Check the built zjs reports the configuration signature this build requested");
    config_signature_step.dependOn(&run_config_signature.step);

    const smoke_step = b.step("smoke", "Run JavaScript smoke fixtures against zjs");
    smoke_step.dependOn(&run_config_signature.step);
    smoke_step.dependOn(&run_smoke_tests.step);

    // Debug smoke tests are the single engine-bearing artifact in the inner
    // loop. They deliberately do not depend on unified-test modules or plugin
    // fixtures.
    // The dev inner loop deliberately carries no ReleaseFast engine build;
    // profile-contract smoke checks run in the release smoke tier only.
    const smoke_dev_options = b.addOptions();
    smoke_dev_options.addOption([]const u8, "zjs_executable_path", b.getInstallPath(.bin, "zjs-dev"));
    smoke_dev_options.addOption([]const u8, "zjs_profile_executable_path", "");
    smoke_dev_options.addOption(bool, "smoke_profile_checks", false);
    const smoke_dev_tests = b.addTest(.{
        .name = "smoke-tests-debug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/smoke_test.zig"),
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
        }),
    });
    smoke_dev_tests.test_runner = .{
        .path = b.path("tools/timing_test_runner.zig"),
        .mode = .simple,
    };
    smoke_dev_tests.root_module.addOptions("build_options", smoke_dev_options);
    const run_smoke_dev_tests = b.addRunArtifact(smoke_dev_tests);
    run_smoke_dev_tests.step.dependOn(&install_zjs_dev.step);
    if (b.args) |args| run_smoke_dev_tests.addArgs(args);

    const smoke_dev_step = b.step("smoke-dev", "Run JavaScript smoke fixtures against the Debug zjs");
    smoke_dev_step.dependOn(&run_smoke_dev_tests.step);

    // Explicit changed-area targets avoid compiling and running the entire
    // unified suite during focused work. Selection stays developer-driven;
    // checkpoint and production gates continue to use the unified root.
    const scoped_test_engine_mod = b.createModule(.{
        .root_source_file = b.path("src/internal_root.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    scoped_test_engine_mod.addOptions("build_options", test_options);
    const ScopedTestConfig = struct {
        name: []const u8,
        description: []const u8,
        root_source_file: []const u8,
        filter: []const u8,
        needs_plugin_fixtures: bool = false,
    };
    const scoped_test_configs = [_]ScopedTestConfig{
        .{ .name = "test-core", .description = "Run focused core value, object, GC, and ownership tests", .root_source_file = "src/tests/core.zig", .filter = "core.test" },
        .{ .name = "test-parser", .description = "Run focused lexer and parser tests", .root_source_file = "src/tests/parser.zig", .filter = "parser.test" },
        .{ .name = "test-bytecode", .description = "Run focused bytecode and pipeline tests", .root_source_file = "src/tests/bytecode.zig", .filter = "bytecode.test" },
        .{ .name = "test-exec", .description = "Run focused execution and VM tests", .root_source_file = "src/exec_tests.zig", .filter = "tests.exec" },
        .{ .name = "test-builtins", .description = "Run focused ECMAScript built-in tests", .root_source_file = "src/builtins_tests.zig", .filter = "tests.builtins" },
        .{ .name = "test-runtime", .description = "Run focused host runtime and plugin tests", .root_source_file = "src/runtime_tests.zig", .filter = "runtime.", .needs_plugin_fixtures = true },
        .{ .name = "test-runner", .description = "Run focused test262 runner tests", .root_source_file = "src/cli/run_test262.zig", .filter = "run_test262.test" },
        .{ .name = "test-compiler-v2", .description = "Run focused compiler-v2 (QCP) tests", .root_source_file = "src/compiler_v2_tests.zig", .filter = "compiler_v2." },
    };
    inline for (scoped_test_configs) |config| {
        const scoped_root = b.createModule(.{
            .root_source_file = b.path(config.root_source_file),
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zjs", .module = scoped_test_engine_mod },
            },
        });
        scoped_root.addOptions("build_options", test_options);
        const scoped_tests = b.addTest(.{
            .name = config.name,
            .root_module = scoped_root,
            .filters = &.{config.filter},
        });
        scoped_tests.test_runner = .{
            .path = b.path("tools/timing_test_runner.zig"),
            .mode = .simple,
        };
        const run_scoped_tests = b.addRunArtifact(scoped_tests);
        run_scoped_tests.addArg("--require-tests");
        if (config.needs_plugin_fixtures) {
            run_scoped_tests.step.dependOn(&install_runtime_plugin_fixture.step);
            run_scoped_tests.step.dependOn(&install_runtime_empty_plugin_fixture.step);
        }
        if (b.args) |args| run_scoped_tests.addArgs(args);
        const scoped_step = b.step(config.name, config.description);
        scoped_step.dependOn(&run_scoped_tests.step);
    }

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

    // Alternate JSValue representation guard: runs the unified suite with the
    // opposite of this target's default (a full second build graph, so the
    // plugin fixtures recompile with a matching ABI fingerprint). Required for
    // any change touching core/value.zig or value-representation semantics.
    const altrepr_option = if (target_default_nan_boxing)
        "-Dzjs_nan_boxing=false"
    else
        "-Dzjs_nan_boxing=true";
    const altrepr_seed = b.fmt("{d}", .{zjs_test_seed});
    const altrepr_project_seed = b.fmt("-Dzjs_test_seed={d}", .{zjs_test_seed});
    // The nested build is a separate `zig build` process, so it starts from
    // the *defaults* for every option the outer invocation was given unless
    // they are forwarded explicitly. Before this was forwarded,
    // `zig build test-altrepr -Dzjs_compiler=v2` silently ran the legacy
    // compiler: a gate reporting green about a configuration it never ran.
    // Forward the whole user option set rather than an enumerated list, so a
    // newly added -D option cannot silently reopen the same hole. Only the
    // three settings this step determines for itself are substituted:
    // the representation (inverted), the project seed, and the optimize mode
    // (resolved here so both `-Doptimize=` and `--release=` reach the child).
    const altrepr_forward_skip = [_][]const u8{
        "zjs_nan_boxing", // inverted below; forwarding it too would duplicate
        "zjs_test_seed", // passed explicitly as altrepr_project_seed
        "optimize", // passed explicitly as the resolved optimize mode
        "zjs_expect_config", // this build's expectation, not the child's
    };
    var altrepr_forwarded: std.ArrayList([]const u8) = .empty;
    var altrepr_user_options = b.user_input_options.iterator();
    while (altrepr_user_options.next()) |entry| {
        const name = entry.key_ptr.*;
        for (altrepr_forward_skip) |skip| {
            if (std.mem.eql(u8, name, skip)) break;
        } else switch (entry.value_ptr.value) {
            .flag => altrepr_forwarded.append(b.allocator, b.fmt("-D{s}", .{name})) catch @panic("OOM"),
            .scalar => |value| altrepr_forwarded.append(b.allocator, b.fmt("-D{s}={s}", .{ name, value })) catch @panic("OOM"),
            .list => |values| for (values.items) |value| {
                altrepr_forwarded.append(b.allocator, b.fmt("-D{s}={s}", .{ name, value })) catch @panic("OOM");
            },
            // Command-line -D options only ever produce the three forms
            // above. Fail loudly instead of dropping the option, because a
            // dropped option is exactly the defect this forwarding fixes.
            .map, .lazy_path, .lazy_path_list => {
                std.debug.print(
                    "error: cannot forward option '{s}' to the test-altrepr child build\n",
                    .{name},
                );
                std.process.exit(1);
            },
        }
    }
    // Hash-map iteration order is not part of the contract; sort so the child
    // command line (and therefore this step's cache key) is deterministic.
    std.mem.sort([]const u8, altrepr_forwarded.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    // Belt and braces over the forwarding above: state the exact configuration
    // this step intends the child to resolve (this build's settings with the
    // representation inverted). If any option is dropped, ignored, or defaulted
    // differently on the way down, the child's own signature differs and the
    // child build FAILS instead of running a different configuration and
    // reporting green -- which is precisely the defect this step once had.
    const altrepr_expect_config = b.fmt("-Dzjs_expect_config={s}", .{configSignature(b, .{
        .compiler = zjs_compiler,
        .layout = zjs_v2_layout,
        .nan_boxing = !zjs_nan_boxing,
        .force_gc = zjs_force_gc,
        .ownership_audit = zjs_ownership_audit,
    })});
    var altrepr_argv: std.ArrayList([]const u8) = .empty;
    altrepr_argv.appendSlice(b.allocator, &.{
        b.graph.zig_exe,
        "build",
        "test",
        altrepr_option,
        altrepr_project_seed,
        altrepr_expect_config,
        b.fmt("-Doptimize={s}", .{@tagName(optimize)}),
    }) catch @panic("OOM");
    altrepr_argv.appendSlice(b.allocator, altrepr_forwarded.items) catch @panic("OOM");
    altrepr_argv.appendSlice(b.allocator, &.{
        "--seed",
        altrepr_seed,
        "--summary",
        "all",
    }) catch @panic("OOM");
    const altrepr_tests = b.addSystemCommand(altrepr_argv.items);
    const altrepr_step = b.step("test-altrepr", "Run the unified tests with the representation opposite the target default");
    altrepr_step.dependOn(&altrepr_tests.step);

    // User-facing steps to expose
    const test_step = b.step("test", "Run all Zig tests (defaults to Debug optimization unless overridden)");

    test_step.dependOn(&run_unified_tests.step);

    const quick_check_step = b.step("quick-check", "Run the fast inner-loop validation gate");
    quick_check_step.dependOn(smoke_dev_step);

    const checkpoint_check_step = b.step("checkpoint-check", "Run checkpoint validation without the full test262, OOM-injection, or alternate-representation gates");
    checkpoint_check_step.dependOn(test_step);
    checkpoint_check_step.dependOn(smoke_dev_step);
    // Debug smoke covers the CLI contract at checkpoint tier. Keep the second
    // whole-engine ReleaseFast smoke compile exclusive to the production gate.
    checkpoint_check_step.dependOn(architecture_check_step);
    checkpoint_check_step.dependOn(test262_smoke_step);

    const engine_production_gate_step = b.step("engine-production-gate", "Run the engine-only Production v1 release gate");
    engine_production_gate_step.dependOn(test_step);
    engine_production_gate_step.dependOn(smoke_step);
    engine_production_gate_step.dependOn(architecture_check_step);
    engine_production_gate_step.dependOn(test262_gate_step);

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

/// QCP-1 configuration settings, in the canonical order the ruling names them.
/// Keep this list, `configSignature` below, and `src/config_signature.zig`
/// in lockstep: they are two independent computations of the same string and
/// their disagreement is exactly what the signature gate detects.
const ConfigSettings = struct {
    compiler: []const u8,
    layout: []const u8,
    nan_boxing: bool,
    force_gc: bool,
    ownership_audit: bool,
};

/// The build graph's belief about the configuration, in the same canonical,
/// deterministic encoding `src/config_signature.zig` produces from the
/// declarations the compiled code consumes.
fn configSignature(b: *std.Build, settings: ConfigSettings) []const u8 {
    return b.fmt(
        "zjs-config-v1:compiler={s},layout={s},repr={s},force_gc={s},ownership_audit={s}",
        .{
            settings.compiler,
            settings.layout,
            if (settings.nan_boxing) "nan_boxed" else "tagged",
            if (settings.force_gc) "on" else "off",
            if (settings.ownership_audit) "on" else "off",
        },
    );
}
