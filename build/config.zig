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
    dossier_options: *std.Build.Step.Options,
    engine_options: *std.Build.Step.Options,
    engine_options_fast: *std.Build.Step.Options,
    engine_options_dev: *std.Build.Step.Options,
};

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
/// `zjs-config-v2` (was v1, which had no `optimize`): the prefix is versioned
/// so a historical v1 string cannot be read as complete proof now that the
/// field set has grown, and cannot match a v2 build on its first five fields.
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
        "zjs-config-v2:compiler={s},layout={s},repr=tagged,optimize={s},force_gc={s},ownership_audit={s}",
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
    force_gc: bool,
    ownership_audit: bool,
    dossier_layout_pad: usize,

    pub fn withExpect(self: EngineOptionInputs, expect_config: []const u8) EngineOptionInputs {
        var out = self;
        out.expect_config = expect_config;
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
    options.addOption(bool, "zjs_force_gc", in.force_gc);
    options.addOption(bool, "zjs_ownership_audit", in.ownership_audit);
    options.addOption(usize, "zjs_dossier_layout_pad", in.dossier_layout_pad);
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
