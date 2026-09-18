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
    embedding_step: *std.Build.Step,
    /// Sema-only twin of `embedding_step` (public root assembles; comptime
    /// pins hold). checkpoint-gate's embedding dependency.
    check_embedding_step: *std.Build.Step,
};

fn forwardArgs(b: *std.Build, run: *std.Build.Step.Run) void {
    if (b.args) |args| run.addArgs(args);
}

fn addZjsTest(
    ctx: build_config.Ctx,
    name: []const u8,
    root_module: *std.Build.Module,
    filters: []const []const u8,
) *std.Build.Step.Compile {
    const t = ctx.b.addTest(.{
        .name = name,
        .root_module = root_module,
        .filters = filters,
    });
    build_config.forceLlvmBackendOnDebug(t);
    t.test_runner = .{
        .path = ctx.b.path("tools/timing_test_runner.zig"),
        .mode = .simple,
    };
    return t;
}

fn addShardedUnifiedRuns(
    ctx: build_config.Ctx,
    step: *std.Build.Step,
    exe: *std.Build.Step.Compile,
    test_shards: usize,
    shard_label: []const u8,
    gc_stress: bool,
) void {
    const b = ctx.b;
    for (0..test_shards) |shard| {
        const run = build_config.runArtifactOnCpus(b, ctx.gate_run_cpus, exe);
        run.addArgs(&.{ "--skip-prefix", "tests.stress." });
        if (gc_stress) {
            run.setEnvironmentVariable("ZJS_GC_STRESS", "1");
            run.setEnvironmentVariable("ZJS_GC_VERIFY_MINOR", "fatal");
            run.setEnvironmentVariable("ZJS_MINOR_AUDIT", "fatal");
        }
        if (test_shards != 1) {
            run.addArgs(&.{ "--shard", b.fmt("{d}/{d}", .{ shard, test_shards }) });
            run.setName(b.fmt("run test {s} shard {d}/{d}", .{ shard_label, shard, test_shards }));
            // Inherited stdio takes the build runner's global lock and
            // serialises the shards. Captured stderr is shown only when the
            // shard exits non-zero.
            _ = run.captureStdErr(.{});
        }
        forwardArgs(b, run);
        step.dependOn(&run.step);
    }
}

fn addSmokeStep(ctx: build_config.Ctx, artifacts: artifacts_mod.Artifacts) *std.Build.Step {
    const b = ctx.b;
    const options = b.addOptions();
    options.addOption([]const u8, "zjs_executable_path", b.getInstallPath(.bin, artifacts.zjs_exe.out_filename));
    options.addOption([]const u8, "zjs_profile_executable_path", b.getInstallPath(.bin, artifacts.zjs_profile_exe.out_filename));
    options.addOption(bool, "smoke_profile_checks", true);
    const tests = addZjsTest(ctx, "smoke-tests", b.createModule(.{
        .root_source_file = b.path("src/tests/smoke_test.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = true,
    }), &.{});
    tests.root_module.addOptions("build_options", options);
    const run = b.addRunArtifact(tests);
    run.step.dependOn(&artifacts.install_zjs.step);
    run.step.dependOn(&artifacts.install_zjs_profile.step);
    forwardArgs(b, run);
    const step = b.step("smoke", "Run JavaScript smoke fixtures against zjs");
    step.dependOn(&run.step);
    return step;
}

pub fn addTestGraph(ctx: build_config.Ctx, artifacts: artifacts_mod.Artifacts) TestGraph {
    const b = ctx.b;

    // Unified tests (one binary, `src/all_tests.zig`). `-Dtest-filter` builds
    // a separate, symbolised diagnostic selection. `test-fast -- <substring>`
    // reuses the full binary instead.
    //
    // The binary compiles once and runs as N parallel shard processes
    // (`--shard i/N`). A filtered run stays a single process so its output
    // reads as one list. Default 16 shards (2026-09-06: 8 shards, longest
    // 7.7 s of a ~8 s phase).
    const test_filter = b.option([]const u8, "test-filter", "Only run unified tests whose name contains this substring");
    const test_shards_option = b.option(usize, "test-shards", "Run the unified suite as this many parallel shard processes (default 16; 1 = unsharded)") orelse 16;
    const test_shards: usize = if (test_filter != null or test_shards_option == 0) 1 else test_shards_option;
    // Strip by default on the full run (owner ruling 2026-09-06). A
    // `-Dtest-filter` run is a diagnosis and keeps DWARF. `-Dtest-strip=false`
    // forces DWARF on the full run. Both variants sit in the cache.
    const test_strip = b.option(bool, "test-strip", "Build the unified test binary without debug info (default: true for the full run, false under -Dtest-filter)") orelse (test_filter == null);
    const unified_root = b.createModule(.{
        .root_source_file = b.path("src/all_tests.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = true,
    });
    const unified_tests = addZjsTest(
        ctx,
        "unified-tests",
        unified_root,
        if (test_filter) |f| &.{f} else &.{},
    );
    unified_tests.root_module.strip = test_strip;
    // Own options object so this compile root does not share a generated
    // options file with the public `zjs` module or the CLI.
    unified_tests.root_module.addImport("zjs", unified_tests.root_module);
    unified_tests.root_module.addOptions("build_options", build_config.addEngineOptions(b, ctx.engine_inputs));

    const test_step = b.step("test", "Run all Zig tests (defaults to Debug optimization unless overridden)");
    addShardedUnifiedRuns(ctx, test_step, unified_tests, test_shards, "unified-tests", false);

    // Runtime filtering leaves the compile root, optimization, DWARF, and
    // compile-time filters unchanged.
    const run_fast_tests = build_config.runArtifactOnCpus(b, ctx.gate_run_cpus, unified_tests);
    run_fast_tests.addArgs(&.{ "--require-tests", "--skip-prefix", "tests.stress.", "--filter" });
    forwardArgs(b, run_fast_tests);
    const fast_test_step = b.step("test-fast", "Run a required test-name substring from the unified binary without recompiling the selection: test-fast -- <substring>");
    fast_test_step.dependOn(&run_fast_tests.step);

    const gc_stress_step = b.step("test-gc-stress", "Run the unified suite under ZJS_GC_STRESS=1 ZJS_GC_VERIFY_MINOR=fatal ZJS_MINOR_AUDIT=fatal (~1 min; part of checkpoint-gate)");
    addShardedUnifiedRuns(ctx, gc_stress_step, unified_tests, test_shards, "unified-tests (gc-stress)", true);

    // Stress tier lives in the same binary (`--only-prefix tests.stress.`).
    // One process, not sharded: five tests, and `--require-tests` must see them.
    const run_stress_tests = build_config.runArtifactOnCpus(b, ctx.gate_run_cpus, unified_tests);
    run_stress_tests.addArgs(&.{ "--only-prefix", "tests.stress.", "--require-tests" });
    run_stress_tests.setName("run test unified-tests (stress tier)");
    _ = run_stress_tests.captureStdErr(.{});
    forwardArgs(b, run_stress_tests);
    const stress_step = b.step("test-stress", "Run the long-running stress tier (stack exhaustion, bigint kernel sweeps) from the unified binary");
    stress_step.dependOn(&run_stress_tests.step);

    const smoke_step = addSmokeStep(ctx, artifacts);

    // Nightly instrumentation, not a checkpoint dependency. Multiple
    // `--filter` arguments are OR-matched.
    const run_leak_census_tests = build_config.runArtifactOnCpus(b, ctx.gate_run_cpus, unified_tests);
    run_leak_census_tests.addArgs(&.{
        "--require-tests",
        "--repeat",
        "2",
        "--leak-census",
        "--skip-prefix",
        "tests.stress.",
        "--filter",
        "tests.exec.",
        "--filter",
        "tests.builtins.",
    });
    run_leak_census_tests.setName("run test unified-tests (leak census)");
    forwardArgs(b, run_leak_census_tests);
    const test_leak_census_step = b.step("test-leak-census", "Run the shared exec and builtins tiers twice and reject unaccounted retained growth (instrumentation tier; runs nightly)");
    test_leak_census_step.dependOn(&run_leak_census_tests.step);

    // Public-module assembly check. Independent `zjs` module rooted at
    // `src/root.zig` (not internal_root) and its own options object.
    // Hangs on engine-production-gate, not checkpoint.
    const embedding_engine_options = build_config.addEngineOptions(b, ctx.engine_inputs);
    const embedding_zjs_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = true,
    });
    // One options module shared by the engine and the test root: identical
    // contents generate one file, and one file may only be the root of one module.
    const embedding_options_mod = embedding_engine_options.createModule();
    embedding_zjs_mod.addImport("build_options", embedding_options_mod);
    const embedding_root = b.createModule(.{
        .root_source_file = b.path("src/tests/embedding_examples.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zjs", .module = embedding_zjs_mod },
        },
    });
    embedding_root.addImport("build_options", embedding_options_mod);
    const embedding_tests = addZjsTest(ctx, "test-embedding", embedding_root, &.{});
    const run_embedding_tests = b.addRunArtifact(embedding_tests);
    run_embedding_tests.addArg("--require-tests");
    forwardArgs(b, run_embedding_tests);
    const embedding_step = b.step("test-embedding", "Run focused public-module embedding tests");
    embedding_step.dependOn(&run_embedding_tests.step);
    // Sema-only twin: the same bodies already run inside the unified suite
    // through `internal_root`. checkpoint-gate takes this instead of a
    // second engine compile + link; the production gate keeps the full run.
    const check_embedding = addZjsTest(ctx, "check-embedding", embedding_tests.root_module, &.{});
    const check_embedding_step = b.step("check-embedding", "Semantic-analysis-only compile of the public-root embedding tests (no codegen, no run)");
    check_embedding_step.dependOn(&check_embedding.step);

    // OOM injection (`zig build test-oom`): `checkAllAllocationFailures` over
    // an embedded JS corpus, plus fail-at-N recovery canaries. Compiles the
    // engine (`internal_root`), not the unified suite.
    const oom_engine_mod = b.createModule(.{
        .root_source_file = b.path("src/internal_root.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = true,
    });
    // The one step that wants the injectable allocator topology. A build
    // option rather than `builtin.is_test` so `zig build test` does not
    // change the shipped heap.
    oom_engine_mod.addOptions("build_options", build_config.addEngineOptions(b, ctx.engine_inputs.withOomInjection(true)));
    const oom_tests = addZjsTest(ctx, "oom-tests", b.createModule(.{
        .root_source_file = b.path("src/tests/oom.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zjs", .module = oom_engine_mod },
        },
    }), &.{});
    const run_oom_tests = b.addRunArtifact(oom_tests);
    forwardArgs(b, run_oom_tests);
    const test_oom_step = b.step("test-oom", "Run allocation-failure injection over the embedded OOM corpus plus recovery canaries (instrumentation tier; runs nightly)");
    test_oom_step.dependOn(&run_oom_tests.step);

    // Sema-only compile of the unified root (`-fno-emit-bin`). Shares
    // `unified_tests.root_module` so this analyses exactly what `test`
    // compiles. Not a gate. See docs/testing-graph.md.
    const check_unified = addZjsTest(ctx, "check-unified-tests", unified_tests.root_module, &.{});
    const check_step = b.step("check", "Semantic-analysis-only compile of the unified test root: reject a non-compiling edit without codegen, link, or running any test");
    check_step.dependOn(&check_unified.step);

    return .{
        .test_step = test_step,
        .stress_step = stress_step,
        .gc_stress_step = gc_stress_step,
        .smoke_step = smoke_step,
        .embedding_step = embedding_step,
        .check_embedding_step = check_embedding_step,
    };
}
