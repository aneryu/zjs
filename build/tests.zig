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
    const zjs_test_seed = ctx.zjs_test_seed;
    const target_default_nan_boxing = ctx.target_default_nan_boxing;
    const zjs_nan_boxing = ctx.settings.nan_boxing;
    const config_settings = ctx.settings;
    const addEngineOptions = build_config.addEngineOptions;
    const forceLlvmBackendOnDebug = build_config.forceLlvmBackendOnDebug;
    const configSignature = build_config.configSignature;
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
        .{ .name = "test-runner", .description = "Run focused test262 runner tests", .root_source_file = "src/runner_tests.zig", .filter = "cli.run_test262." },
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
    forceLlvmBackendOnDebug(oom_tests);
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
    const altrepr_project_seed = b.fmt("-Dzjs_test_seed={d}", .{zjs_test_seed});
    // The nested build is a separate `zig build` process, so it starts from
    // the *defaults* for every option the outer invocation was given unless
    // they are forwarded explicitly. Before this was forwarded, a nested gate
    // silently resolved the defaults and reported green about a configuration
    // it never ran.
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
    var altrepr_settings = config_settings;
    altrepr_settings.nan_boxing = !zjs_nan_boxing;
    const altrepr_expect_config = b.fmt("-Dzjs_expect_config={s}", .{configSignature(b, altrepr_settings)});
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
        "--summary",
        "all",
    }) catch @panic("OOM");
    const altrepr_tests = b.addSystemCommand(altrepr_argv.items);
    const altrepr_step = b.step("test-altrepr", "Run the unified tests with the representation opposite the target default");
    altrepr_step.dependOn(&altrepr_tests.step);

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
