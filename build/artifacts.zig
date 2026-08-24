const std = @import("std");
const config = @import("config.zig");
const irregexp = @import("irregexp.zig");

pub const Artifacts = struct {
    engine_mod: *std.Build.Module,
    runtime_plugin_fixture: *std.Build.Step.Compile,
    install_runtime_plugin_fixture: *std.Build.Step.InstallArtifact,
    runtime_empty_plugin_fixture: *std.Build.Step.Compile,
    install_runtime_empty_plugin_fixture: *std.Build.Step.InstallArtifact,
    internal_fast_mod: *std.Build.Module,
    zjs_exe: *std.Build.Step.Compile,
    install_zjs: *std.Build.Step.InstallArtifact,
    zjs_profile_exe: *std.Build.Step.Compile,
    install_zjs_profile: *std.Build.Step.InstallArtifact,
    zjs_dev_exe: *std.Build.Step.Compile,
    install_zjs_dev: *std.Build.Step.InstallArtifact,
    run_test262_exe: *std.Build.Step.Compile,
    install_run_test262: *std.Build.Step.InstallArtifact,
    run_test262_dev_exe: *std.Build.Step.Compile,
    install_run_test262_dev: *std.Build.Step.InstallArtifact,
    irregexp: irregexp.Libs,
};

pub fn addEngineArtifacts(ctx: config.Ctx) Artifacts {
    const b = ctx.b;
    const target = ctx.target;
    const optimize = ctx.optimize;
    const engine_option_inputs = ctx.engine_inputs;
    const engine_options = ctx.engine_options;
    const engine_options_fast = ctx.engine_options_fast;
    const engine_options_dev = ctx.engine_options_dev;
    const expect_config_fast = ctx.expect_config_fast;
    const addEngineOptions = config.addEngineOptions;
    const forceLlvmBackendOnDebug = config.forceLlvmBackendOnDebug;

    const irregexp_libs = irregexp.addLibraries(b, target, optimize);

    const engine_mod = b.addModule("zjs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    engine_mod.addOptions("build_options", engine_options);
    irregexp.link(engine_mod, irregexp_libs.follow);

    // Separate options object (not a reuse of engine_options) so the same
    // generated file is not registered under two module names; follows
    // -Doptimize like the fixture modules themselves.
    const plugin_fixture_options = addEngineOptions(b, engine_option_inputs);
    const plugin_fixture_zjs_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    plugin_fixture_zjs_mod.addOptions("build_options", plugin_fixture_options);
    irregexp.link(plugin_fixture_zjs_mod, irregexp_libs.follow);
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
    forceLlvmBackendOnDebug(runtime_plugin_fixture);
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
    forceLlvmBackendOnDebug(runtime_empty_plugin_fixture);
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
    internal_fast_mod.addOptions("build_options", engine_options_fast);
    irregexp.link(internal_fast_mod, irregexp_libs.fast);
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
    forceLlvmBackendOnDebug(zjs_exe);
    // L-1: gather every dispatch Handler into `.text.zjs.op_handlers`
    // (source order). The retired get_arg0..3 pin lived in this same
    // script and sat a megabyte from the loc/arith bodies. Other
    // targets keep the default layout — no ELF script, no AArch64
    // size asserts.
    if (target.result.cpu.arch == .aarch64 and target.result.ofmt == .elf) {
        zjs_exe.setLinkerScript(b.path("src/exec/tail_hot_layout_aarch64.ld"));
    }
    const install_zjs = b.addInstallArtifact(zjs_exe, .{});
    const zjs_step = b.step("zjs", "Build and install zjs");
    zjs_step.dependOn(&install_zjs.step);
    b.installArtifact(zjs_exe);

    // Profiling CLI: the same ReleaseFast engine with per-opcode dispatch
    // scopes compiled in (the hot table is comptime-wrapped; see
    // exec/vm_profile.zig). A separate artifact so --profile-opcodes users
    // and the perf-runtime-profiles gate never depend on remembering -D
    // flags, and the default zjs binary never carries profiling code.
    var profile_engine_inputs = engine_option_inputs.withExpect(expect_config_fast);
    profile_engine_inputs.enable_opcode_profile = true;
    const profile_engine_options = addEngineOptions(b, profile_engine_inputs);
    const internal_profile_mod = b.createModule(.{
        .root_source_file = b.path("src/internal_root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .omit_frame_pointer = true,
    });
    internal_profile_mod.addOptions("build_options", profile_engine_options);
    irregexp.link(internal_profile_mod, irregexp_libs.fast);
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
    forceLlvmBackendOnDebug(zjs_profile_exe);
    // Same L-1 island as production zjs. The retired table-wrapper lived
    // in `.op_handlers` and slid every handler; keep the profile artifact
    // on the same script so leftover-ladder disassembly matches prod.
    if (target.result.cpu.arch == .aarch64 and target.result.ofmt == .elf) {
        zjs_profile_exe.setLinkerScript(b.path("src/exec/tail_hot_layout_aarch64.ld"));
    }
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
    internal_dev_mod.addOptions("build_options", engine_options_dev);
    irregexp.link(internal_dev_mod, irregexp_libs.debug);
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
    forceLlvmBackendOnDebug(zjs_dev_exe);
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
    forceLlvmBackendOnDebug(run_test262_exe);
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
    forceLlvmBackendOnDebug(run_test262_dev_exe);
    const install_run_test262_dev = b.addInstallArtifact(run_test262_dev_exe, .{});
    const run_test262_dev_step = b.step("run-test262-dev", "Build and install the Debug test262 runner");
    run_test262_dev_step.dependOn(&install_run_test262_dev.step);

    return .{
        .engine_mod = engine_mod,
        .runtime_plugin_fixture = runtime_plugin_fixture,
        .install_runtime_plugin_fixture = install_runtime_plugin_fixture,
        .runtime_empty_plugin_fixture = runtime_empty_plugin_fixture,
        .install_runtime_empty_plugin_fixture = install_runtime_empty_plugin_fixture,
        .internal_fast_mod = internal_fast_mod,
        .zjs_exe = zjs_exe,
        .install_zjs = install_zjs,
        .zjs_profile_exe = zjs_profile_exe,
        .install_zjs_profile = install_zjs_profile,
        .zjs_dev_exe = zjs_dev_exe,
        .install_zjs_dev = install_zjs_dev,
        .run_test262_exe = run_test262_exe,
        .install_run_test262 = install_run_test262,
        .run_test262_dev_exe = run_test262_dev_exe,
        .install_run_test262_dev = install_run_test262_dev,
        .irregexp = irregexp_libs,
    };
}
