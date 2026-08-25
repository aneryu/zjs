const std = @import("std");
const build_config = @import("config.zig");
const artifacts_mod = @import("artifacts.zig");

pub const TestGraph = struct {
    test_step: *std.Build.Step,
    smoke_step: *std.Build.Step,
    smoke_dev_step: *std.Build.Step,
    embedding_step: *std.Build.Step,
};

pub fn addTestGraph(ctx: build_config.Ctx, artifacts: artifacts_mod.Artifacts) TestGraph {
    const b = ctx.b;
    const target = ctx.target;
    const optimize = ctx.optimize;
    const engine_option_inputs = ctx.engine_inputs;
    const engine_options = ctx.engine_options;
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
    const unified_tests = b.addTest(.{
        .name = "unified-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/all_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    forceLlvmBackendOnDebug(unified_tests);
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
    const run_unified_tests = b.addRunArtifact(unified_tests);
    run_unified_tests.step.dependOn(&install_runtime_plugin_fixture.step);
    run_unified_tests.step.dependOn(&install_runtime_empty_plugin_fixture.step);
    if (b.args) |args| run_unified_tests.addArgs(args);

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
    forceLlvmBackendOnDebug(oom_tests);
    oom_tests.test_runner = .{
        .path = b.path("tools/timing_test_runner.zig"),
        .mode = .simple,
    };
    const run_oom_tests = b.addRunArtifact(oom_tests);
    if (b.args) |args| run_oom_tests.addArgs(args);
    const test_oom_step = b.step("test-oom", "Run allocation-failure injection over the embedded OOM corpus plus recovery canaries (instrumentation tier; runs nightly)");
    test_oom_step.dependOn(&run_oom_tests.step);

    // User-facing steps to expose
    const test_step = b.step("test", "Run all Zig tests (defaults to Debug optimization unless overridden)");

    test_step.dependOn(&run_unified_tests.step);

    return .{
        .test_step = test_step,
        .smoke_step = smoke_step,
        .smoke_dev_step = smoke_dev_step,
        .embedding_step = embedding_step,
    };
}
