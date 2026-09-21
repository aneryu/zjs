const std = @import("std");
const builtin = @import("builtin");

/// Shared build-graph context passed to every add* helper. One bag so each
/// helper sees the same option objects and resolved target/optimize without
/// reconstructing them. One `zig build` is one optimize mode.
pub const Ctx = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    engine_inputs: EngineOptionInputs,
    engine_options: *std.Build.Step.Options,
    /// Optional taskset CPU list for the graph's Run steps (unit tests,
    /// test262); "" leaves them unpinned.
    gate_run_cpus: []const u8,
};

/// Optional CPU list for the graph's Run steps. Default is unpinned.
/// Resolution: `-Dgate-run-cpus` → `ZJS_GATE_RUN_CPUS` → `ZJS_BUILD_CPUS`.
/// An empty string disables pinning. Linux only (`taskset`); elsewhere the
/// Run steps are always unpinned.
pub fn gateRunCpus(b: *std.Build) []const u8 {
    const opt = b.option([]const u8, "gate-run-cpus", "optional taskset CPU list for the graph's Run steps: unit tests, test262 (default: ZJS_GATE_RUN_CPUS, else ZJS_BUILD_CPUS, else unpinned)");
    if (opt) |v| return v;
    if (b.graph.environ_map.get("ZJS_GATE_RUN_CPUS")) |v| return v;
    if (b.graph.environ_map.get("ZJS_BUILD_CPUS")) |v| return v;
    return "";
}

/// Run `exe` under `taskset -c cpus` when a pin list is set. `cpus` empty
/// (or a non-Linux host) is a plain `addRunArtifact`.
pub fn runArtifactOnCpus(b: *std.Build, cpus: []const u8, exe: *std.Build.Step.Compile) *std.Build.Step.Run {
    if (cpus.len == 0 or builtin.os.tag != .linux) return b.addRunArtifact(exe);
    const run = b.addSystemCommand(&.{ "taskset", "-c", cpus });
    run.addArtifactArg(exe);
    run.setName(b.fmt("run {s} (cpus {s})", .{ exe.name, cpus }));
    return run;
}

/// The build options every engine-bearing module receives. One shape, so a
/// module cannot silently be given a subset.
pub const EngineOptionInputs = struct {
    enable_opcode_profile: bool,
    compiler_layout: []const u8,
    oom_coverage: bool,
    /// Route the block heap's superblock/extent backing and the small-object
    /// slab arena refills through `MemoryAccount.backing_allocator`, so the
    /// allocations the tracing collector moved into those pools are visible to
    /// `std.testing.checkAllAllocationFailures` and to the fail-at-N
    /// allocators. This is the OOM tier's injection surface, not a semantic
    /// switch: the byte accounting and the memory-limit behaviour are the same
    /// either way.
    ///
    /// Default false, including under `zig build test`: keyed off
    /// `builtin.is_test` it changed the allocator topology of the ENTIRE unit
    /// suite, so every test measured a heap the shipped build never has. Only
    /// the `test-oom` step turns it on.
    oom_injection: bool = false,
    /// Package unit-test files and `tests/engine.zig` import themselves
    /// only when this is true. Default false so `test-embedding` /
    /// `test-oom` do not analyze those families. The unified `test`
    /// module turns it on.
    unified_test_suite: bool = false,
    force_gc: bool,
    ownership_audit: bool,
    /// R3 roots diagnosis build. Default false; diag artifacts only.
    gc_roots_diag: bool,

    pub fn withOomInjection(self: EngineOptionInputs, oom_injection: bool) EngineOptionInputs {
        var out = self;
        out.oom_injection = oom_injection;
        return out;
    }

    pub fn withUnifiedTestSuite(self: EngineOptionInputs, unified_test_suite: bool) EngineOptionInputs {
        var out = self;
        out.unified_test_suite = unified_test_suite;
        return out;
    }
};

pub fn addEngineOptions(b: *std.Build, in: EngineOptionInputs) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption(bool, "zjs_enable_opcode_profile", in.enable_opcode_profile);
    options.addOption([]const u8, "zjs_compiler_layout", in.compiler_layout);
    options.addOption(bool, "zjs_oom_coverage", in.oom_coverage);
    options.addOption(bool, "zjs_oom_injection", in.oom_injection);
    options.addOption(bool, "zjs_unified_test_suite", in.unified_test_suite);
    options.addOption(bool, "zjs_force_gc", in.force_gc);
    options.addOption(bool, "zjs_ownership_audit", in.ownership_audit);
    options.addOption(bool, "zjs_gc_roots_diag", in.gc_roots_diag);
    return options;
}

/// stage2 backends cannot lower `@call(.always_tail)` or the NMFD `.space`
/// tombstone. Force LLVM on every Debug artifact. Leave Release* unset
/// (those already default to LLVM). This also defends aarch64: if Zig later
/// defaults aarch64 Debug to a self-hosted backend, local always_tail would
/// break silently.
pub fn forceLlvmBackendOnDebug(compile: *std.Build.Step.Compile) void {
    if (compile.root_module.optimize == .Debug) compile.use_llvm = true;
}

/// `$262` host for `run-test262` and test compiles that need TestEngine
/// harness globals. Depends on `engine`; the engine never imports this
/// file. Each engine instance needs its own host module so types match.
pub fn addTest262Host(ctx: Ctx, engine: *std.Build.Module) *std.Build.Module {
    return ctx.b.createModule(.{
        .root_source_file = ctx.b.path("src/cli/run_test262_host.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zjs", .module = engine }},
    });
}
