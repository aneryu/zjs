const std = @import("std");
const config = @import("config.zig");

pub const Artifacts = struct {
    zjs_exe: *std.Build.Step.Compile,
    install_zjs: *std.Build.Step.InstallArtifact,
    zjs_profile_exe: *std.Build.Step.Compile,
    install_zjs_profile: *std.Build.Step.InstallArtifact,
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

fn addEngine(
    ctx: config.Ctx,
    options: *std.Build.Step.Options,
    omit_frame_pointer: bool,
) *std.Build.Module {
    const mod = ctx.b.createModule(.{
        .root_source_file = ctx.b.path("src/root.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
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
    hot_layout: bool,
) Cli {
    const b = ctx.b;
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_source),
            .target = ctx.target,
            .optimize = ctx.optimize,
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

fn omitFramePointer(optimize: std.builtin.OptimizeMode) bool {
    return switch (optimize) {
        .ReleaseFast, .ReleaseSmall => true,
        .Debug, .ReleaseSafe => false,
    };
}

pub fn addEngineArtifacts(ctx: config.Ctx) Artifacts {
    const b = ctx.b;
    const omit_frames = omitFramePointer(ctx.optimize);

    // Named public module for downstream `@import("zjs")`. Not returned:
    // embedding tests build their own root, and no other helper reads it.
    const engine_mod = b.addModule("zjs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = true,
    });
    engine_mod.addOptions("build_options", ctx.engine_options);

    const engine = addEngine(ctx, ctx.engine_options, omit_frames);
    const zjs = addCli(ctx, "zjs", "src/cli/zjs.zig", engine, true);
    addInstallStep(b, "zjs", "Build and install zjs (follows -Doptimize; default Debug)", zjs.install);
    b.getInstallStep().dependOn(&zjs.install.step);

    // Second install name so a later `-Doptimize=ReleaseSmall` (or similar)
    // does not overwrite an already-installed `zjs` from a previous invocation.
    const zjs_size = addCli(ctx, "zjs-size", "src/cli/zjs.zig", engine, true);
    addInstallStep(b, "zjs-size", "Build zjs-size: same engine as zjs under a second install name (follows -Doptimize)", zjs_size.install);

    // Same engine with per-opcode dispatch scopes compiled in.
    // A separate artifact so the default zjs binary never carries profiling code.
    var profile_engine_inputs = ctx.engine_inputs;
    profile_engine_inputs.enable_opcode_profile = true;
    const profile_engine_options = config.addEngineOptions(b, profile_engine_inputs);
    const profile_engine = addEngine(ctx, profile_engine_options, omit_frames);
    const zjs_profile = addCli(ctx, "zjs-profile", "src/cli/zjs.zig", profile_engine, true);
    addInstallStep(b, "zjs-profile", "Build and install zjs with per-opcode dispatch scopes (follows -Doptimize)", zjs_profile.install);

    const run_test262 = addCli(ctx, "run-test262", "src/cli/run_test262.zig", engine, false);
    addInstallStep(b, "run-test262", "Build and install run-test262 (follows -Doptimize)", run_test262.install);

    return .{
        .zjs_exe = zjs.exe,
        .install_zjs = zjs.install,
        .zjs_profile_exe = zjs_profile.exe,
        .install_zjs_profile = zjs_profile.install,
        .run_test262_exe = run_test262.exe,
        .install_run_test262 = run_test262.install,
    };
}
