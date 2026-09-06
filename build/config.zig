const std = @import("std");

/// Shared build-graph context passed to every add* helper. One bag so each
/// helper sees the same option objects, signature triple, and resolved
/// target/optimize without reconstructing them.
pub const Ctx = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    engine_inputs: EngineOptionInputs,
    settings: ConfigSettings,
    expect_config: []const u8,
    expect_config_debug: []const u8,
    expect_config_fast: []const u8,
    engine_options: *std.Build.Step.Options,
    engine_options_fast: *std.Build.Step.Options,
    engine_options_dev: *std.Build.Step.Options,
    /// taskset CPU list for the graph's Run steps (test shards, test262,
    /// the fixed-work smoke); "" leaves them on whatever `zig build` got.
    gate_run_cpus: []const u8,
};

/// The CPU list the graph's Run steps are pinned to. `zig build` itself is
/// launched on the compile pool (mise: `taskset -c ${ZJS_BUILD_CPUS:-5-8,15-18}`,
/// the eight X925 cores), which is the right place for the single-threaded
/// LLVM compiles and the wrong place for the test262 sweep, the shards and
/// the smoke: they scale with cores and had been sharing eight while ten
/// A725 cores idled. Resolution order:
///   -Dgate-run-cpus=<list>   explicit (empty string = no pinning)
///   ZJS_GATE_RUN_CPUS        environment
///   ZJS_BUILD_CPUS           an operator who narrowed the compile pool (to
///                            keep a measurement field quiet) narrowed the
///                            run pool with it
///   default                  every core but the measurement cores 9 and 19
/// Linux only (taskset); elsewhere the Run steps are unpinned.
pub fn gateRunCpus(b: *std.Build) []const u8 {
    const opt = b.option([]const u8, "gate-run-cpus", "taskset CPU list for the graph's Run steps: test shards, test262, fixed-work smoke (default: ZJS_GATE_RUN_CPUS, else ZJS_BUILD_CPUS, else 0-8,10-18; empty = unpinned)");
    if (opt) |v| return v;
    if (b.graph.environ_map.get("ZJS_GATE_RUN_CPUS")) |v| return v;
    if (b.graph.environ_map.get("ZJS_BUILD_CPUS")) |v| return v;
    return "0-8,10-18";
}

/// QCP-1 configuration settings, in the canonical order the ruling names them.
/// Keep this list, `configSignature` below, and `src/config_signature.zig`
/// in lockstep: they are two independent computations of the same string and
/// their disagreement is exactly what the signature gate detects.
pub const ConfigSettings = struct {
    compiler: []const u8,
    layout: []const u8,
    /// Not a performance setting in this context. The optimize mode decides
    /// whether the Debug/ReleaseSafe oracles exist at all -- whether
    /// `std.debug.assert` is live, whether safety checks trap, whether
    /// ReleaseFast genuinely strips the validation paths -- and therefore
    /// whether a release gate measured a production binary or a safety build.
    /// A parent asking for ReleaseSafe while the child builds Debug produced
    /// an identical compiler/layout/repr triple before this field existed, and
    /// read as green.
    optimize: std.builtin.OptimizeMode,
    force_gc: bool,
    ownership_audit: bool,
};

/// The build graph's belief about the configuration, in the same canonical,
/// deterministic encoding `src/config_signature.zig` produces from the
/// declarations the compiled code consumes.
///
/// `zjs-config-v3` adds the terminal GC/Object layout identity. It is not an
/// option: git is the rollback boundary, but old and new binaries must not
/// attest the same representation after Object's resident header disappears.
///
/// `repr` is fixed at `tagged`, the same way `compiler` is fixed at `v2`: the
/// 8-byte NaN-boxed alternative was deleted, so there is no longer a choice to
/// encode, but an artifact must still state the representation it was built
/// from. The component is kept rather than dropped so recorded v2 signatures
/// keep their meaning and the negative-drift check keeps a field to falsify --
/// the engine half of the comparison derives it from `@sizeOf(JSValue)`, not
/// from a literal.
pub fn configSignature(b: *std.Build, settings: ConfigSettings) []const u8 {
    return b.fmt(
        "zjs-config-v3:compiler={s},layout={s},repr=tagged,gc_layout=obj64_m,optimize={s},force_gc={s},ownership_audit={s}",
        .{
            settings.compiler,
            settings.layout,
            @tagName(settings.optimize),
            if (settings.force_gc) "on" else "off",
            if (settings.ownership_audit) "on" else "off",
        },
    );
}

/// The expectation to compile an artifact against WHEN THAT ARTIFACT PINS ITS
/// OPTIMIZE MODE (`zjs` and `run-test262` at ReleaseFast, `zjs-dev` and the
/// scoped test artifacts at Debug).
///
/// Without `-Dzjs_expect_config` this is simply build.zig's own belief for that
/// artifact's mode. With one, the caller's string is carried through field for
/// field -- those are the fields it is asserting about -- except `optimize`,
/// which is substituted, because a pinned Debug test binary reporting
/// `optimize=Debug` is not drift.
///
/// Artifacts that FOLLOW `-Doptimize` do NOT go through here: they get the
/// caller's string verbatim, so a child that resolved a different optimize mode
/// than the parent asked for fails. See the call sites.
///
/// A malformed or stale-version override is deliberately passed through
/// unchanged rather than rejected here: it then fails at the artifact, with a
/// message naming the version and the fields, instead of failing in this file
/// with build.zig's own opinion of itself.
pub fn pinnedExpectedConfig(
    b: *std.Build,
    override: ?[]const u8,
    settings: ConfigSettings,
    mode: std.builtin.OptimizeMode,
) []const u8 {
    var per_artifact = settings;
    per_artifact.optimize = mode;
    const text = override orelse return configSignature(b, per_artifact);
    const needle = ",optimize=";
    const start = std.mem.indexOf(u8, text, needle) orelse return text;
    const value_start = start + needle.len;
    const value_end = std.mem.indexOfScalarPos(u8, text, value_start, ',') orelse text.len;
    return b.fmt("{s}{s}{s}", .{ text[0..value_start], @tagName(mode), text[value_end..] });
}

/// The build options every engine-bearing module receives. One shape, so a
/// module cannot silently be given a subset; `expect_config` is the only field
/// that legitimately differs between them.
pub const EngineOptionInputs = struct {
    enable_opcode_profile: bool,
    tspike_guard: []const u8,
    compiler_layout: []const u8,
    expect_config: []const u8,
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
    force_gc: bool,
    ownership_audit: bool,
    dossier_layout_pad: usize,
    /// R3 roots diagnosis build. Default false; diag artifacts only.
    gc_roots_diag: bool,

    pub fn withExpect(self: EngineOptionInputs, expect_config: []const u8) EngineOptionInputs {
        var out = self;
        out.expect_config = expect_config;
        return out;
    }

    pub fn withOomInjection(self: EngineOptionInputs, oom_injection: bool) EngineOptionInputs {
        var out = self;
        out.oom_injection = oom_injection;
        return out;
    }
};

pub fn addEngineOptions(b: *std.Build, in: EngineOptionInputs) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption(bool, "zjs_enable_opcode_profile", in.enable_opcode_profile);
    options.addOption([]const u8, "zjs_tspike_guard", in.tspike_guard);
    options.addOption([]const u8, "zjs_compiler_layout", in.compiler_layout);
    options.addOption([]const u8, "zjs_expect_config", in.expect_config);
    options.addOption(bool, "zjs_oom_coverage", in.oom_coverage);
    options.addOption(bool, "zjs_oom_injection", in.oom_injection);
    options.addOption(bool, "zjs_force_gc", in.force_gc);
    options.addOption(bool, "zjs_ownership_audit", in.ownership_audit);
    options.addOption(usize, "zjs_dossier_layout_pad", in.dossier_layout_pad);
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
