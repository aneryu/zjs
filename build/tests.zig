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
    return t;
}

fn runUnifiedTests(
    ctx: build_config.Ctx,
    exe: *std.Build.Step.Compile,
    gc_stress: bool,
) *std.Build.Step.Run {
    const run = build_config.runArtifactOnCpus(ctx.b, ctx.gate_run_cpus, exe);
    if (gc_stress) {
        run.setEnvironmentVariable("ZJS_GC_STRESS", "1");
        run.setEnvironmentVariable("ZJS_GC_VERIFY", "fatal");
        run.setEnvironmentVariable("ZJS_GC_AUDIT", "fatal");
    }
    return run;
}

fn addSmokeStep(ctx: build_config.Ctx, artifacts: artifacts_mod.Artifacts) *std.Build.Step {
    const b = ctx.b;
    const options = b.addOptions();
    options.addOption([]const u8, "zjs_executable_path", b.getInstallPath(.bin, artifacts.zjs_exe.out_filename));
    options.addOption([]const u8, "zjs_profile_executable_path", b.getInstallPath(.bin, artifacts.zjs_profile_exe.out_filename));
    options.addOption(bool, "smoke_profile_checks", true);
    const tests = addZjsTest(ctx, "smoke-tests", b.createModule(.{
        .root_source_file = b.path("tests/smoke_test.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = true,
    }), &.{});
    tests.root_module.addOptions("build_options", options);
    const run = b.addRunArtifact(tests);
    run.step.dependOn(&artifacts.install_zjs.step);
    run.step.dependOn(&artifacts.install_zjs_profile.step);
    const step = b.step("smoke", "Run JavaScript smoke fixtures against zjs");
    step.dependOn(&run.step);
    return step;
}

pub fn addTestGraph(ctx: build_config.Ctx, artifacts: artifacts_mod.Artifacts) TestGraph {
    const b = ctx.b;

    // Unified tests (one binary, `src/internal_root.zig`). `-Dtest-filter` builds
    // a separate, symbolised diagnostic selection. `test-fast -- <substring>`
    // is the same kind of compile-time filter, as its own step.
    const test_filter = b.option([]const u8, "test-filter", "Only run unified tests whose name contains this substring");
    // Strip by default on the full run (owner ruling 2026-09-06). A
    // `-Dtest-filter` run is a diagnosis and keeps DWARF. `-Dtest-strip=false`
    // forces DWARF on the full run. Both variants sit in the cache.
    const test_strip = b.option(bool, "test-strip", "Build the unified test binary without debug info (default: true for the full run, false under -Dtest-filter)") orelse (test_filter == null);
    // One module: Zig collects tests from the root module only, so the test
    // root `src/unified_tests.zig` imports the engine by path and mirrors
    // `internal_root.zig` (the module imports itself as `zjs`). Keeping the
    // stress and CLI families out of `internal_root.zig` is what lets the
    // CLI executable, whose root is `src/cli/zjs.zig`, link the same engine
    // sources without a module clash.
    const unified_root = b.createModule(.{
        .root_source_file = b.path("src/unified_tests.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = true,
    });
    const unified_tests = addZjsTest(
        ctx,
        "unified-tests",
        unified_root,
        if (test_filter) |f| &.{ f, "zjs.pull_test_modules" } else &.{},
    );
    unified_tests.root_module.strip = test_strip;
    // Own options object so this compile root does not share a generated
    // options file with the public `zjs` module or the CLI.
    unified_tests.root_module.addImport("zjs", unified_tests.root_module);
    unified_tests.root_module.addOptions("build_options", build_config.addEngineOptions(b, ctx.engine_inputs.withUnifiedTestSuite(true)));

    const test_step = b.step("test", "Run all Zig tests (defaults to Debug optimization unless overridden)");
    const run_unified = runUnifiedTests(ctx, unified_tests, false);
    if (test_filter) |f| run_unified.setEnvironmentVariable("ZJS_TEST_FILTER", f);
    test_step.dependOn(&run_unified.step);

    const fast_test_step = b.step("test-fast", "Run tests whose names contain a required substring: test-fast -- <substring>");
    const missing_fast_filter = "test-fast requires a nonempty substring: zig build test-fast -- '<name>'";
    if (b.args) |args| {
        var nonempty = false;
        for (args) |arg| {
            if (arg.len != 0) nonempty = true;
        }
        if (!nonempty) {
            fast_test_step.dependOn(&b.addFail(missing_fast_filter).step);
        } else {
            const filters = b.allocator.alloc([]const u8, args.len + 1) catch @panic("OOM");
            @memcpy(filters[0..args.len], args);
            // Keep the module-pull test in the binary so `--test-filter`
            // still discovers the suite, and so a typo fails instead of
            // a green 0-test run.
            filters[args.len] = "zjs.pull_test_modules";
            const fast_tests = addZjsTest(ctx, "fast-tests", unified_root, filters);
            fast_tests.root_module.strip = false;
            const run_fast = runUnifiedTests(ctx, fast_tests, false);
            run_fast.setEnvironmentVariable("ZJS_TEST_FILTER", args[0]);
            fast_test_step.dependOn(&run_fast.step);
        }
    } else {
        fast_test_step.dependOn(&b.addFail(missing_fast_filter).step);
    }

    const gc_stress_step = b.step("test-gc-stress", "Run the unified suite under ZJS_GC_STRESS=1 ZJS_GC_VERIFY=fatal ZJS_GC_AUDIT=fatal (~1 min; part of checkpoint-gate)");
    gc_stress_step.dependOn(&runUnifiedTests(ctx, unified_tests, true).step);

    // Stress tier is compiled into the unified binary but SkipZigTest unless
    // ZJS_RUN_STRESS=1. This step is a compile-time filtered binary so it
    // does not re-run the rest of the suite.
    const stress_tests = addZjsTest(ctx, "stress-tests", unified_root, &.{
        "stress.",
        "zjs.pull_test_modules",
    });
    const run_stress_tests = build_config.runArtifactOnCpus(b, ctx.gate_run_cpus, stress_tests);
    run_stress_tests.setEnvironmentVariable("ZJS_RUN_STRESS", "1");
    run_stress_tests.setName("run test unified-tests (stress tier)");
    const stress_step = b.step("test-stress", "Run the long-running stress tier (stack exhaustion, bigint kernel sweeps)");
    stress_step.dependOn(&run_stress_tests.step);

    const smoke_step = addSmokeStep(ctx, artifacts);

    // Nightly instrumentation, not a checkpoint dependency. Compile-time
    // filter selects the shared exec/builtin tiers; the dedicated runner
    // runs that selection twice so pass 0 warms lazy Realm state.
    const leak_census_tests = addZjsTest(ctx, "leak-census-tests", unified_root, &.{
        "exec.tests.",
        "zjs.pull_test_modules",
    });
    leak_census_tests.test_runner = .{
        .path = b.path("tools/leak_census_runner.zig"),
        .mode = .simple,
    };
    const run_leak_census_tests = build_config.runArtifactOnCpus(b, ctx.gate_run_cpus, leak_census_tests);
    run_leak_census_tests.setEnvironmentVariable("ZJS_LEAK_CENSUS", "1");
    run_leak_census_tests.setName("run test unified-tests (leak census)");
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
        .root_source_file = b.path("tests/embedding_examples.zig"),
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
    const embedding_step = b.step("test-embedding", "Run focused public-module embedding tests");
    embedding_step.dependOn(&run_embedding_tests.step);
    // Sema-only twin of the public-root embedding tests. checkpoint-gate
    // takes this instead of a second engine compile + link; the production
    // gate keeps the full run.
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
        .root_source_file = b.path("tests/oom.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zjs", .module = oom_engine_mod },
        },
    }), &.{});
    const run_oom_tests = b.addRunArtifact(oom_tests);
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
