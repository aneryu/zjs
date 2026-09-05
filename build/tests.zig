const std = @import("std");
const build_config = @import("config.zig");
const artifacts_mod = @import("artifacts.zig");

pub const TestGraph = struct {
    test_step: *std.Build.Step,
    // The long-running stress tier. Not part of test_step: per-change
    // close-out (docs/verification-policy.md) runs `zig build test`, and the
    // stress tier's cost belongs to the production/CI/merge-batch gates.
    stress_step: *std.Build.Step,
    /// The unified suite again under every GC diagnostic switch
    /// (`test-gc-stress`). ~1 minute, so it rides checkpoint-gate.
    gc_stress_step: *std.Build.Step,
    smoke_step: *std.Build.Step,
    smoke_dev_step: *std.Build.Step,
    embedding_step: *std.Build.Step,
    /// Sema-only twin of `embedding_step` (public root assembles; comptime
    /// pins hold). checkpoint-gate's embedding dependency.
    check_embedding_step: *std.Build.Step,
};

pub fn addTestGraph(ctx: build_config.Ctx, artifacts: artifacts_mod.Artifacts) TestGraph {
    const b = ctx.b;
    const target = ctx.target;
    const optimize = ctx.optimize;
    const engine_option_inputs = ctx.engine_inputs;
    const expect_config_debug = ctx.expect_config_debug;
    const addEngineOptions = build_config.addEngineOptions;
    const forceLlvmBackendOnDebug = build_config.forceLlvmBackendOnDebug;
    const install_zjs = artifacts.install_zjs;
    const install_zjs_profile = artifacts.install_zjs_profile;
    const install_zjs_dev = artifacts.install_zjs_dev;
    const runtime_plugin_fixture = artifacts.runtime_plugin_fixture;
    const install_runtime_plugin_fixture = artifacts.install_runtime_plugin_fixture;
    const runtime_empty_plugin_fixture = artifacts.runtime_empty_plugin_fixture;
    const install_runtime_empty_plugin_fixture = artifacts.install_runtime_empty_plugin_fixture;

    // Unified tests (runs all tests in one single binary, using src/all_tests.zig as compile root)
    // `-Dtest-filter=<substring>` narrows the unified run to matching test
    // names (iteration aid: compile once, run the handful under repair).
    const test_filter = b.option([]const u8, "test-filter", "Only run unified tests whose name contains this substring");
    // The unified binary compiles once and runs as N parallel shard processes
    // (`--shard i/N`, round-robin over the test index): the run is the
    // larger half of `zig build test` and it parallelises where the
    // single-module compile cannot. A filtered run stays a single process so
    // its output reads as one list.
    const test_shards_option = b.option(usize, "test-shards", "Run the unified suite as this many parallel shard processes (default 8; 1 = unsharded)") orelse 8;
    const test_shards: usize = if (test_filter != null or test_shards_option == 0) 1 else test_shards_option;
    // Debug info is half of the unified compile (measured 2026-09-05: ~60 s
    // with DWARF, ~30 s without). A stripped binary still names the failing
    // test and the error, but its error-return traces are bare addresses, so
    // the default follows the two ways the suite is run: the full run (the
    // per-change close-out, checkpoint-gate) is the green path and strips;
    // a `-Dtest-filter` run is somebody diagnosing a red and keeps DWARF.
    // Both variants sit in the build cache, so alternating between them on
    // unchanged sources costs no recompile. `-Dtest-strip=false` forces DWARF
    // on the full run (owner ruling 2026-09-06: strip by default).
    const test_strip = b.option(bool, "test-strip", "Build the unified test binary without debug info (default: true for the full run, false under -Dtest-filter)") orelse (test_filter == null);
    const unified_tests = b.addTest(.{
        .name = "unified-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/all_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .filters = if (test_filter) |f| &.{f} else &.{},
    });
    forceLlvmBackendOnDebug(unified_tests);
    unified_tests.root_module.strip = test_strip;
    unified_tests.test_runner = .{
        .path = b.path("tools/timing_test_runner.zig"),
        .mode = .simple,
    };
    // The unified suite follows -Doptimize; the scoped targets below pin
    // Debug. They therefore cannot share one expectation, and did not have to
    // share one options object either -- that reuse is exactly how a Debug
    // artifact would have ended up attesting a ReleaseSafe configuration.
    const test_options = addEngineOptions(b, engine_option_inputs);
    test_options.addOption([]const u8, "runtime_plugin_fixture_path", b.getInstallPath(.lib, runtime_plugin_fixture.out_filename));
    test_options.addOption([]const u8, "runtime_empty_plugin_fixture_path", b.getInstallPath(.lib, runtime_empty_plugin_fixture.out_filename));
    const scoped_test_options = addEngineOptions(b, engine_option_inputs.withExpect(expect_config_debug));
    scoped_test_options.addOption([]const u8, "runtime_plugin_fixture_path", b.getInstallPath(.lib, runtime_plugin_fixture.out_filename));
    scoped_test_options.addOption([]const u8, "runtime_empty_plugin_fixture_path", b.getInstallPath(.lib, runtime_empty_plugin_fixture.out_filename));
    unified_tests.root_module.addImport("zjs", unified_tests.root_module);
    unified_tests.root_module.addOptions("build_options", test_options);
    // FNABI C/Zig round-trip (src/tests/abi_layout.zig) @cImports the
    // generated src/abi/fun_native_abi.h.
    unified_tests.root_module.addIncludePath(b.path("src"));
    const test_step = b.step("test", "Run all Zig tests (defaults to Debug optimization unless overridden)");
    for (0..test_shards) |shard| {
        const run_unified_tests = b.addRunArtifact(unified_tests);
        run_unified_tests.step.dependOn(&install_runtime_plugin_fixture.step);
        run_unified_tests.step.dependOn(&install_runtime_empty_plugin_fixture.step);
        run_unified_tests.addArgs(&.{ "--skip-prefix", "tests.stress." });
        if (test_shards != 1) {
            run_unified_tests.addArgs(&.{ "--shard", b.fmt("{d}/{d}", .{ shard, test_shards }) });
            run_unified_tests.setName(b.fmt("run test unified-tests shard {d}/{d}", .{ shard, test_shards }));
            // A Run step that inherits stdio takes the build runner's global
            // lock and the shards would queue up one after another. Capturing
            // stderr makes the step an output-producing one instead: no lock,
            // so the shards run concurrently; the captured output is shown
            // only when the shard exits non-zero (`.check` mode would print
            // every shard's stderr as a warning even on success). The
            // unsharded run keeps inherited stdio so a filtered run streams.
            _ = run_unified_tests.captureStdErr(.{});
        }
        if (b.args) |args| run_unified_tests.addArgs(args);
        test_step.dependOn(&run_unified_tests.step);
    }

    // TGC S0 safety net (docs/tracing-gc-s0-spec.md §L2): the same suite with
    // the collector at every safepoint (`ZJS_GC_STRESS=1`, cadence 64), every
    // minor's condemned set re-derived by a fresh full trace
    // (`ZJS_GC_VERIFY_MINOR=fatal`: a precisely reachable corpse panics), and
    // the old-owner edge audit (`ZJS_MINOR_AUDIT=fatal`: an unremembered
    // old-to-condemned edge panics). The `fatal` spellings are what make this
    // a gate rather than a log. Measured 55 s on 2026-09-03.
    const gc_stress_step = b.step("test-gc-stress", "Run the unified suite under ZJS_GC_STRESS=1 ZJS_GC_VERIFY_MINOR=fatal ZJS_MINOR_AUDIT=fatal (~1 min; part of checkpoint-gate)");
    for (0..test_shards) |shard| {
        const run_gc_stress_tests = b.addRunArtifact(unified_tests);
        run_gc_stress_tests.step.dependOn(&install_runtime_plugin_fixture.step);
        run_gc_stress_tests.step.dependOn(&install_runtime_empty_plugin_fixture.step);
        run_gc_stress_tests.setEnvironmentVariable("ZJS_GC_STRESS", "1");
        run_gc_stress_tests.setEnvironmentVariable("ZJS_GC_VERIFY_MINOR", "fatal");
        run_gc_stress_tests.setEnvironmentVariable("ZJS_MINOR_AUDIT", "fatal");
        run_gc_stress_tests.addArgs(&.{ "--skip-prefix", "tests.stress." });
        if (test_shards != 1) {
            run_gc_stress_tests.addArgs(&.{ "--shard", b.fmt("{d}/{d}", .{ shard, test_shards }) });
            run_gc_stress_tests.setName(b.fmt("run test unified-tests (gc-stress) shard {d}/{d}", .{ shard, test_shards }));
            _ = run_gc_stress_tests.captureStdErr(.{});
        }
        if (b.args) |args| run_gc_stress_tests.addArgs(args);
        gc_stress_step.dependOn(&run_gc_stress_tests.step);
    }

    // Stress tier: the long-running tests (stack exhaustion, bigint kernel
    // sweeps; src/tests/stress.zig) stay out of the per-change `zig build
    // test` close-out and checkpoint-gate so those keep fast feedback, and
    // ride the merge/production gates. They compile into the SAME unified
    // binary (selected by `--only-prefix tests.stress.`; the per-change shards
    // pass `--skip-prefix`), which retired the second Debug engine compile
    // the old `src/stress_tests.zig` root cost every gate (~37 s CPU,
    // 2026-09-06). One process, not sharded: five tests, and
    // `--require-tests` must be able to see them.
    const run_stress_tests = b.addRunArtifact(unified_tests);
    run_stress_tests.step.dependOn(&install_runtime_plugin_fixture.step);
    run_stress_tests.step.dependOn(&install_runtime_empty_plugin_fixture.step);
    run_stress_tests.addArgs(&.{ "--only-prefix", "tests.stress.", "--require-tests" });
    run_stress_tests.setName("run test unified-tests (stress tier)");
    _ = run_stress_tests.captureStdErr(.{});
    if (b.args) |args| run_stress_tests.addArgs(args);
    const stress_step = b.step("test-stress", "Run the long-running stress tier (stack exhaustion, bigint kernel sweeps) from the unified binary");
    stress_step.dependOn(&run_stress_tests.step);

    // Production smoke tests retain the ReleaseFast CLI contract.
    const smoke_options = b.addOptions();
    smoke_options.addOption([]const u8, "zjs_executable_path", b.getInstallPath(.bin, artifacts.zjs_exe.out_filename));
    smoke_options.addOption([]const u8, "zjs_profile_executable_path", b.getInstallPath(.bin, artifacts.zjs_profile_exe.out_filename));
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
    forceLlvmBackendOnDebug(smoke_tests);
    smoke_tests.test_runner = .{
        .path = b.path("tools/timing_test_runner.zig"),
        .mode = .simple,
    };
    smoke_tests.root_module.addOptions("build_options", smoke_options);
    const run_smoke_tests = b.addRunArtifact(smoke_tests);
    run_smoke_tests.step.dependOn(&install_zjs.step);
    run_smoke_tests.step.dependOn(&install_zjs_profile.step);
    if (b.args) |args| run_smoke_tests.addArgs(args);

    const smoke_step = b.step("smoke", "Run JavaScript smoke fixtures against zjs");
    smoke_step.dependOn(&run_smoke_tests.step);
    // Debug smoke tests are the single engine-bearing artifact in the inner
    // loop. They deliberately do not depend on unified-test modules or plugin
    // fixtures.
    // The dev inner loop deliberately carries no ReleaseFast engine build;
    // profile-contract smoke checks run in the release smoke tier only.
    const smoke_dev_options = b.addOptions();
    smoke_dev_options.addOption([]const u8, "zjs_executable_path", b.getInstallPath(.bin, artifacts.zjs_dev_exe.out_filename));
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
    forceLlvmBackendOnDebug(smoke_dev_tests);
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
    scoped_test_engine_mod.addOptions("build_options", scoped_test_options);

    // Deterministic representation dump for driver review.  It is a tooling
    // artifact over the same Debug engine module used by focused core tests;
    // the shipped CLI does not import it or embed the committed baseline.
    const gc_representation_mod = b.createModule(.{
        .root_source_file = b.path("src/gc_representation.zig"),
        .target = target,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "zjs", .module = scoped_test_engine_mod },
        },
    });
    const gc_representation_exe = b.addExecutable(.{
        .name = "gc-representation-snapshot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gc/representation_snapshot.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "gc_representation", .module = gc_representation_mod },
            },
        }),
    });
    forceLlvmBackendOnDebug(gc_representation_exe);
    const run_gc_representation = b.addRunArtifact(gc_representation_exe);
    const gc_representation_step = b.step(
        "gc-representation-snapshot",
        "Print the deterministic GC representation snapshot",
    );
    gc_representation_step.dependOn(&run_gc_representation.step);

    const ScopedTestConfig = struct {
        name: []const u8,
        description: []const u8,
        root_source_file: []const u8,
        filter: []const u8,
        needs_plugin_fixtures: bool = false,
    };
    const scoped_test_configs = [_]ScopedTestConfig{
        .{ .name = "test-core", .description = "Run focused core value, object, GC, and ownership tests", .root_source_file = "src/core_tests.zig", .filter = "tests.core." },
        .{ .name = "test-parser", .description = "Run focused lexer and parser tests", .root_source_file = "src/parser_tests.zig", .filter = "tests.parser." },
        .{ .name = "test-bytecode", .description = "Run focused bytecode and pipeline tests", .root_source_file = "src/bytecode_tests.zig", .filter = "tests.bytecode." },
        .{ .name = "test-exec", .description = "Run focused execution and VM tests", .root_source_file = "src/exec_tests.zig", .filter = "tests.exec." },
        .{ .name = "test-builtins", .description = "Run focused ECMAScript built-in tests", .root_source_file = "src/builtins_tests.zig", .filter = "tests.builtins." },
        .{ .name = "test-runtime", .description = "Run focused host runtime and plugin tests", .root_source_file = "src/runtime_tests.zig", .filter = "runtime.", .needs_plugin_fixtures = true },
        .{ .name = "test-runner", .description = "Run focused test262 runner tests", .root_source_file = "src/runner_tests.zig", .filter = "cli.run_test262" },
        .{ .name = "test-compiler", .description = "Run focused compiler (QCP) tests", .root_source_file = "src/compiler_tests.zig", .filter = "compiler." },
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
        scoped_root.addOptions("build_options", scoped_test_options);
        const scoped_tests = b.addTest(.{
            .name = config.name,
            .root_module = scoped_root,
            .filters = &.{config.filter},
        });
        forceLlvmBackendOnDebug(scoped_tests);
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

    // Shared-engine convergence census (`zig build test-leak-census`): run
    // both shared tiers twice in one process. Pass 0 warms legitimate lazy
    // state; pass 1 enforces the module-accounted allocation high-water gate.
    // This is an instrumentation/nightly tier, not a checkpoint dependency.
    const leak_census_root = b.createModule(.{
        .root_source_file = b.path("src/leak_census_tests.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zjs", .module = scoped_test_engine_mod },
        },
    });
    leak_census_root.addOptions("build_options", scoped_test_options);
    const leak_census_tests = b.addTest(.{
        .name = "leak-census-tests",
        .root_module = leak_census_root,
    });
    forceLlvmBackendOnDebug(leak_census_tests);
    leak_census_tests.test_runner = .{
        .path = b.path("tools/timing_test_runner.zig"),
        .mode = .simple,
    };
    const run_leak_census_tests = b.addRunArtifact(leak_census_tests);
    run_leak_census_tests.addArgs(&.{ "--require-tests", "--repeat", "2", "--leak-census" });
    const test_leak_census_step = b.step("test-leak-census", "Run the shared exec and builtins tiers twice and reject unaccounted retained growth (instrumentation tier; runs nightly)");
    test_leak_census_step.dependOn(&run_leak_census_tests.step);

    // Public-module assembly check. Independent Debug `zjs` module rooted at
    // `src/root.zig` (not internal_root) and its own options object (rule 丙).
    // The shell does not attest: the public surface does not export
    // config_signature. Hangs on engine-production-gate, not checkpoint.
    const embedding_engine_options = addEngineOptions(b, engine_option_inputs.withExpect(expect_config_debug));
    const embedding_zjs_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    embedding_zjs_mod.addOptions("build_options", embedding_engine_options);
    const embedding_test_options = addEngineOptions(b, engine_option_inputs.withExpect(expect_config_debug));
    embedding_test_options.addOption([]const u8, "runtime_plugin_fixture_path", b.getInstallPath(.lib, runtime_plugin_fixture.out_filename));
    embedding_test_options.addOption([]const u8, "runtime_empty_plugin_fixture_path", b.getInstallPath(.lib, runtime_empty_plugin_fixture.out_filename));
    const embedding_root = b.createModule(.{
        .root_source_file = b.path("src/embedding_tests.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zjs", .module = embedding_zjs_mod },
        },
    });
    embedding_root.addOptions("build_options", embedding_test_options);
    const embedding_tests = b.addTest(.{
        .name = "test-embedding",
        .root_module = embedding_root,
        .filters = &.{"tests.embedding_examples."},
    });
    forceLlvmBackendOnDebug(embedding_tests);
    embedding_tests.test_runner = .{
        .path = b.path("tools/timing_test_runner.zig"),
        .mode = .simple,
    };
    const run_embedding_tests = b.addRunArtifact(embedding_tests);
    run_embedding_tests.addArg("--require-tests");
    run_embedding_tests.step.dependOn(&install_runtime_plugin_fixture.step);
    run_embedding_tests.step.dependOn(&install_runtime_empty_plugin_fixture.step);
    if (b.args) |args| run_embedding_tests.addArgs(args);
    const embedding_step = b.step("test-embedding", "Run focused public-module embedding tests");
    embedding_step.dependOn(&run_embedding_tests.step);
    // The public-root assembly check without codegen: what `test-embedding`
    // uniquely proves is that `src/root.zig` assembles and its comptime pins
    // hold; the same test bodies (and their runtime pins, e.g. the public
    // decl counts) already run inside the unified suite through
    // `internal_root`. checkpoint-gate takes this ~6 s sema pass instead of
    // the ~40 s Debug engine compile + link; the production gate keeps the
    // full run.
    const check_embedding = b.addTest(.{
        .name = "check-embedding",
        .root_module = embedding_tests.root_module,
    });
    forceLlvmBackendOnDebug(check_embedding);
    check_embedding.test_runner = .{
        .path = b.path("tools/timing_test_runner.zig"),
        .mode = .simple,
    };
    const check_embedding_step = b.step("check-embedding", "Semantic-analysis-only compile of the public-root embedding test shell (no codegen, no run)");
    check_embedding_step.dependOn(&check_embedding.step);

    // OOM injection suite (`zig build test-oom`): exhaustive allocation
    // failure injection (std.testing.checkAllAllocationFailures) over an
    // embedded JS corpus, plus single-shot fail-at-N recovery canaries.
    // Cost scales with allocation counts, so this is an instrumentation tier
    // command rather than part of the per-checkpoint `zig build test`.
    // The corpus binary compiles only the engine (internal_root), not the
    // unified test suite.
    const oom_engine_mod = b.createModule(.{
        .root_source_file = b.path("src/internal_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // The one step that wants the injectable allocator topology, and the
    // reason `oom_injection` is a build option instead of `builtin.is_test`:
    // this module needs the block heap and the slab arenas on the account's
    // backing allocator, and `zig build test` must not.
    const oom_engine_options = addEngineOptions(b, engine_option_inputs.withOomInjection(true));
    oom_engine_mod.addOptions("build_options", oom_engine_options);
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
    forceLlvmBackendOnDebug(oom_tests);
    oom_tests.test_runner = .{
        .path = b.path("tools/timing_test_runner.zig"),
        .mode = .simple,
    };
    const run_oom_tests = b.addRunArtifact(oom_tests);
    if (b.args) |args| run_oom_tests.addArgs(args);
    const test_oom_step = b.step("test-oom", "Run allocation-failure injection over the embedded OOM corpus plus recovery canaries (instrumentation tier; runs nightly)");
    test_oom_step.dependOn(&run_oom_tests.step);

    // ===== `zig build check`: semantic analysis, no codegen, no link =====
    // A `Compile` step whose emitted binary nobody consumes is invoked with
    // `-fno-emit-bin` (`std.Build.Step.Compile`: `if (compile.generated_bin ==
    // null) try zig_args.append("-fno-emit-bin")`), which stops the pipeline
    // after semantic analysis. Measured on this tree at d0159646 (aarch64,
    // Zig 0.16.0), serially, interleaved A/B/A/B, pinned to one exclusive
    // 3.9 GHz core -- this machine is big.LITTLE and a compile pinned across
    // both core types reads ~2x slower and ~10x noisier:
    //
    //   emitting        wall 112.6 / 113.0 s   peak rss 8.25 GB
    //   -fno-emit-bin   wall  54.7 /  55.0 s   peak rss 1.40 GB
    //
    // So a little over half of a Debug test compile is LLVM codegen plus the
    // link of a 245 MB object file, and that half buys 5.9x the peak memory.
    // An edit that does not compile is rejected in ~55 s instead of ~176 s
    // (113 s compile + the 63 s test run it never reaches).
    //
    // What this DOES check: every comptime assertion the tree owns still runs.
    // `config_signature.attest`, the opcode declaration ledger's comptime
    // asserts and the FNABI `@cImport` round-trip are semantic analysis, not
    // codegen, so they all fire here.
    //
    // What it does NOT check: anything a machine-code backend decides, and any
    // behaviour at all. `@call(.always_tail)` lowering and the `.space`
    // tombstones are codegen; no test is executed. `check` is therefore a
    // convenience and never a gate -- no `*-gate` step depends on it, and
    // `zig build test` remains the checkpoint dependency.
    //
    // It shares `unified_tests.root_module` deliberately. A second module
    // "configured the same way" would be a second thing to keep in sync, and
    // the entire value of the step is that it analyses exactly what
    // `zig build test` compiles.
    const check_unified = b.addTest(.{
        .name = "check-unified-tests",
        .root_module = unified_tests.root_module,
    });
    forceLlvmBackendOnDebug(check_unified);
    check_unified.test_runner = .{
        .path = b.path("tools/timing_test_runner.zig"),
        .mode = .simple,
    };
    const check_step = b.step("check", "Semantic-analysis-only compile of the unified test root: reject a non-compiling edit without codegen, link, or running any test");
    check_step.dependOn(&check_unified.step);

    return .{
        .test_step = test_step,
        .stress_step = stress_step,
        .gc_stress_step = gc_stress_step,
        .smoke_step = smoke_step,
        .smoke_dev_step = smoke_dev_step,
        .embedding_step = embedding_step,
        .check_embedding_step = check_embedding_step,
    };
}
