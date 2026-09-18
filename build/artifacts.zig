const std = @import("std");
const config = @import("config.zig");

pub const Artifacts = struct {
    zjs_exe: *std.Build.Step.Compile,
    install_zjs: *std.Build.Step.InstallArtifact,
    zjs_profile_exe: *std.Build.Step.Compile,
    install_zjs_profile: *std.Build.Step.InstallArtifact,
    zjs_dev_exe: *std.Build.Step.Compile,
    install_zjs_dev: *std.Build.Step.InstallArtifact,
    run_test262_exe: *std.Build.Step.Compile,
    install_run_test262: *std.Build.Step.InstallArtifact,
};

const Cli = struct {
    exe: *std.Build.Step.Compile,
    install: *std.Build.Step.InstallArtifact,
};

fn applyHotLayout(b: *std.Build, target: std.Build.ResolvedTarget, exe: *std.Build.Step.Compile) void {
    // L-1: gather every dispatch Handler into `.text.zjs.op_handlers`
    // (source order). Other targets keep the default layout.
    if (target.result.cpu.arch == .aarch64 and target.result.ofmt == .elf) {
        exe.setLinkerScript(b.path("src/exec/tail_hot_layout_aarch64.ld"));
    }
}

fn addInternalEngine(
    ctx: config.Ctx,
    optimize: std.builtin.OptimizeMode,
    options: *std.Build.Step.Options,
    omit_frame_pointer: bool,
) *std.Build.Module {
    const mod = ctx.b.createModule(.{
        .root_source_file = ctx.b.path("src/internal_root.zig"),
        .target = ctx.target,
        .optimize = optimize,
        .link_libc = true,
        .omit_frame_pointer = omit_frame_pointer,
    });
    mod.addOptions("build_options", options);
    return mod;
}

fn addCli(
    ctx: config.Ctx,
    name: []const u8,
    root_source: []const u8,
    engine: *std.Build.Module,
    optimize: std.builtin.OptimizeMode,
    hot_layout: bool,
) Cli {
    const b = ctx.b;
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_source),
            .target = ctx.target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "zjs", .module = engine }},
        }),
    });
    config.forceLlvmBackendOnDebug(exe);
    if (hot_layout) applyHotLayout(b, ctx.target, exe);
    return .{ .exe = exe, .install = b.addInstallArtifact(exe, .{}) };
}

fn addInstallStep(b: *std.Build, name: []const u8, desc: []const u8, install: *std.Build.Step.InstallArtifact) void {
    const step = b.step(name, desc);
    step.dependOn(&install.step);
}

pub fn addEngineArtifacts(ctx: config.Ctx) Artifacts {
    const b = ctx.b;
    const keep_frame_pointer = ctx.engine_inputs.gc_roots_diag;

    // Named public module for downstream `@import("zjs")`. Not returned:
    // embedding tests build their own Debug root, and no other helper reads it.
    const engine_mod = b.addModule("zjs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = true,
    });
    engine_mod.addOptions("build_options", ctx.engine_options);

    const internal_fast_mod = addInternalEngine(ctx, .ReleaseFast, ctx.engine_options_fast, !keep_frame_pointer);
    const zjs = addCli(ctx, "zjs", "src/cli/zjs.zig", internal_fast_mod, .ReleaseFast, true);
    // Publish the build graph's expectation for post-strip release checks.
    // The executable independently attests this value during compilation.
    const signature_files = b.addWriteFiles();
    const signature_file = signature_files.add("zjs.config-signature", b.fmt("{s}\n", .{ctx.expect_config_fast}));
    const install_signature = b.addInstallFileWithDir(signature_file, .bin, "zjs.config-signature");
    zjs.install.step.dependOn(&install_signature.step);
    addInstallStep(b, "zjs", "Build and install production zjs (always ReleaseFast; use zjs-size for -Doptimize experiments)", zjs.install);
    b.getInstallStep().dependOn(&zjs.install.step);

    // Size/codegen experiments follow -Doptimize in BOTH modules and retain
    // the caller's expected signature verbatim. Keep the production artifact
    // and its cache identity independent of the experimental mode.
    const internal_size_mod = addInternalEngine(ctx, ctx.optimize, ctx.engine_options, !keep_frame_pointer);
    const zjs_size = addCli(ctx, "zjs-size", "src/cli/zjs.zig", internal_size_mod, ctx.optimize, true);
    addInstallStep(b, "zjs-size", "Build experimental zjs-size following -Doptimize (e.g. -Doptimize=ReleaseSmall; default Debug)", zjs_size.install);

    // Same ReleaseFast engine with per-opcode dispatch scopes compiled in.
    // A separate artifact so the default zjs binary never carries profiling code.
    var profile_engine_inputs = ctx.engine_inputs.withExpect(ctx.expect_config_fast);
    profile_engine_inputs.enable_opcode_profile = true;
    const profile_engine_options = config.addEngineOptions(b, profile_engine_inputs);
    const internal_profile_mod = addInternalEngine(ctx, .ReleaseFast, profile_engine_options, true);
    const zjs_profile = addCli(ctx, "zjs-profile", "src/cli/zjs.zig", internal_profile_mod, .ReleaseFast, true);
    addInstallStep(b, "zjs-profile", "Build and install the profiling zjs (per-opcode dispatch scopes)", zjs_profile.install);

    // Debug CLI for the inner-loop gate. Production `zjs` stays ReleaseFast.
    const internal_dev_mod = addInternalEngine(ctx, .Debug, ctx.engine_options_dev, false);
    const zjs_dev = addCli(ctx, "zjs-dev", "src/cli/zjs.zig", internal_dev_mod, .Debug, false);
    addInstallStep(b, "zjs-dev", "Build and install the Debug zjs used by inner-loop checks", zjs_dev.install);

    const run_test262 = addCli(ctx, "run-test262", "src/cli/run_test262.zig", internal_fast_mod, .ReleaseFast, false);
    addInstallStep(b, "run-test262", "Build and install run-test262", run_test262.install);

    const run_test262_dev = addCli(ctx, "run-test262-dev", "src/cli/run_test262.zig", internal_dev_mod, .Debug, false);
    addInstallStep(b, "run-test262-dev", "Build and install the Debug test262 runner", run_test262_dev.install);

    return .{
        .zjs_exe = zjs.exe,
        .install_zjs = zjs.install,
        .zjs_profile_exe = zjs_profile.exe,
        .install_zjs_profile = zjs_profile.install,
        .zjs_dev_exe = zjs_dev.exe,
        .install_zjs_dev = zjs_dev.install,
        .run_test262_exe = run_test262.exe,
        .install_run_test262 = run_test262.install,
    };
}
