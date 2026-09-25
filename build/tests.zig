const std = @import("std");
const build_config = @import("config.zig");
const artifacts_mod = @import("artifacts.zig");

pub const TestGraph = struct {
    test_step: *std.Build.Step,
    /// The engine suite again under every GC diagnostic switch
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

fn addEngineModule(ctx: build_config.Ctx, unified: bool) *std.Build.Module {
    // The unified suite is rooted at the repository so `src/` unit tests
    // and `tests/` integration tests stay one module. Host compiles keep
    // `src/root.zig` and never see `tests/`.
    const mod = ctx.b.createModule(.{
        .root_source_file = ctx.b.path(if (unified) "test_root.zig" else "src/root.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = true,
    });
    const inputs = if (unified)
        ctx.engine_inputs.withUnifiedTestSuite(true)
    else
        ctx.engine_inputs;
    mod.addOptions("build_options", build_config.addEngineOptions(ctx.b, inputs));
    return mod;
}

fn runEngineTests(
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

    // Engine suite (`test_root.zig` is the test root; `@import("zjs")` is itself).
    // `-Dtest-filter` builds a separate, symbolised diagnostic selection.
    // `test-fast -- <substring>` is the same kind of compile-time filter, as
    // its own step. CLI tests are a separate compile so engine files never
    // path-import `src/cli/`. `$262` is the `test262_host` module.
    const test_filter = b.option([]const u8, "test-filter", "Only run engine tests whose name contains this substring");
    // Strip by default on the full run (owner ruling 2026-09-06). A
    // `-Dtest-filter` run is a diagnosis and keeps DWARF. `-Dtest-strip=false`
    // forces DWARF on the full run. Both variants sit in the cache.
    const test_strip = b.option(bool, "test-strip", "Build the engine test binary without debug info (default: true for the full run, false under -Dtest-filter)") orelse (test_filter == null);

    const unified_root = addEngineModule(ctx, true);
    unified_root.addImport("zjs", unified_root);
    const unified_host = build_config.addHost(ctx, unified_root);
    unified_root.addImport("zjs_host", unified_host);
    unified_root.addImport("test262_host", build_config.addTest262Host(ctx, unified_root, unified_host));
    const unified_tests = addZjsTest(
        ctx,
        "unified-tests",
        unified_root,
        if (test_filter) |f| &.{ f, "zjs.pull_test_modules" } else &.{},
    );
    unified_tests.root_module.strip = test_strip;

    const host_engine = addEngineModule(ctx, false);
    const cli_root = b.createModule(.{
        .root_source_file = b.path("src/cli/tests.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zjs", .module = host_engine },
            .{ .name = "zjs_host", .module = build_config.addHost(ctx, host_engine) },
        },
    });
    const cli_tests = addZjsTest(ctx, "cli-tests", cli_root, &.{});
    cli_tests.root_module.strip = test_strip;

    const test_step = b.step("test", "Run engine and CLI Zig tests (defaults to Debug optimization unless overridden)");
    const string_boundaries = b.addSystemCommand(&.{"python3"});
    string_boundaries.addFileArg(b.path("tools/check_string_boundaries.py"));
    b.step("check-string-boundaries", "Reject implicit string materialization outside compatibility owners").dependOn(&string_boundaries.step);
    test_step.dependOn(&string_boundaries.step);
    const run_unified = runEngineTests(ctx, unified_tests, false);
    if (test_filter) |f| run_unified.setEnvironmentVariable("ZJS_TEST_FILTER", f);
    test_step.dependOn(&run_unified.step);
    if (test_filter == null) {
        test_step.dependOn(&b.addRunArtifact(cli_tests).step);
    }

    // `zig test` cannot exercise builtin.is_test == false. This executable
    // guards the always-registered exact-root contract in production builds.
    const exact_root_exe = b.addExecutable(.{
        .name = "exact-roots-contract",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/exact_roots_executable.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "zjs", .module = host_engine }},
        }),
    });
    build_config.forceLlvmBackendOnDebug(exact_root_exe);
    const run_exact_roots = b.addRunArtifact(exact_root_exe);
    b.step("test-exact-roots", "Verify exact roots in a non-test executable").dependOn(&run_exact_roots.step);
    if (test_filter == null) test_step.dependOn(&run_exact_roots.step);

    const incomplete_visitor = addZjsTest(ctx, "gc-visitor-negative", b.createModule(.{
        .root_source_file = b.path("tests/gc_visitor_incomplete.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zjs", .module = host_engine }},
    }), &.{});
    incomplete_visitor.expect_errors = .{ .contains = "incomplete GC visitor gc_visitor_incomplete.Incomplete: missing visitAtom" };
    b.step("test-gc-visitor-contract", "Verify incomplete GC visitors fail compilation").dependOn(&incomplete_visitor.step);
    if (test_filter == null) test_step.dependOn(&incomplete_visitor.step);

    const fast_test_step = b.step("test-fast", "Run engine tests whose names contain a required substring: test-fast -- <substring>");
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
            const run_fast = runEngineTests(ctx, fast_tests, false);
            run_fast.setEnvironmentVariable("ZJS_TEST_FILTER", args[0]);
            fast_test_step.dependOn(&run_fast.step);
        }
    } else {
        fast_test_step.dependOn(&b.addFail(missing_fast_filter).step);
    }

    const gc_stress_step = b.step("test-gc-stress", "Run the engine suite under ZJS_GC_STRESS=1 ZJS_GC_VERIFY=fatal ZJS_GC_AUDIT=fatal (~1 min; part of checkpoint-gate)");
    gc_stress_step.dependOn(&runEngineTests(ctx, unified_tests, true).step);

    const smoke_step = addSmokeStep(ctx, artifacts);

    // Nightly instrumentation, not a checkpoint dependency. Compile-time
    // filter selects the VM/eval integration suite; the dedicated runner
    // runs that selection twice so pass 0 warms lazy Realm state.
    const leak_census_tests = addZjsTest(ctx, "leak-census-tests", unified_root, &.{
        "tests.exec.",
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

    // Embedder cookbook check. Independent `zjs` module rooted at
    // `src/root.zig` and its own options object. Hangs on
    // engine-production-gate, not checkpoint.
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
    // engine (`src/root.zig`), not the unified suite.
    const oom_engine_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
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

    // Sema-only compile of the engine and CLI roots (`-fno-emit-bin`).
    // Not a gate. See docs/testing-graph.md.
    const check_unified = addZjsTest(ctx, "check-unified-tests", unified_tests.root_module, &.{});
    const check_cli = addZjsTest(ctx, "check-cli-tests", cli_tests.root_module, &.{});
    const check_step = b.step("check", "Semantic-analysis-only compile of the engine and CLI test roots: reject a non-compiling edit without codegen, link, or running any test");
    check_step.dependOn(&check_unified.step);
    check_step.dependOn(&check_cli.step);

    return .{
        .test_step = test_step,
        .gc_stress_step = gc_stress_step,
        .smoke_step = smoke_step,
        .embedding_step = embedding_step,
        .check_embedding_step = check_embedding_step,
    };
}
