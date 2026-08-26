const std = @import("std");
const config = @import("build/config.zig");
const artifacts = @import("build/artifacts.zig");
const tests_graph = @import("build/tests.zig");
const perf = @import("build/perf.zig");
const gates = @import("build/gates.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Zig's CLI injects a random `--seed` into the build runner. That would
    // change test-runner arguments and duplicate cache artifacts even when no
    // source changed. Pin the graph seed here so child compile/test steps stay
    // stable without requiring CLI `--seed`. Randomized runs remain available
    // through `-Dzjs_test_seed`.
    const zjs_test_seed = b.option(u32, "zjs_test_seed", "Seed passed to Zig test runners (defaults to 0 for reproducible cached builds)") orelse 0;
    b.graph.random_seed = zjs_test_seed;
    const zjs_enable_opcode_profile = b.option(bool, "zjs_enable_opcode_profile", "Enable per-opcode profiling scopes") orelse false;
    // PERF-T-SPIKE (branch-quarantined): off | u64 | ptr. Non-off compiles the
    // guarded direct-slot opcodes and the shape-identity field; the guard arm
    // is baked per build so neither arm pays a runtime branch. Default off:
    // zero trace in production builds.
    const zjs_tspike_guard = b.option([]const u8, "zjs_tspike_guard", "T-spike guard arm: off (default) | u64 | ptr") orelse "off";
    if (!std.mem.eql(u8, zjs_tspike_guard, "off") and !std.mem.eql(u8, zjs_tspike_guard, "u64") and !std.mem.eql(u8, zjs_tspike_guard, "ptr")) {
        std.debug.print("error: invalid -Dzjs_tspike_guard value '{s}': expected off, u64, or ptr\n", .{zjs_tspike_guard});
        std.process.exit(1);
    }
    // QCP-1: the engine has exactly one compiler. `-Dzjs_compiler` retired with
    // the legacy production path; the component stays in the configuration
    // signature so an artifact still NAMES the compiler it was built from and
    // the negative drift gate still has a component to falsify.
    const compiler_name = "v2";
    // QCP-1: compiler final bytecode layout. `short` is part of the release
    // configuration, not an optimization knob: the switch measurements were
    // taken against it. `plain` stays reachable as the A/B diagnostic
    // instrument (it is how C2-B artifact residency was localised).
    const zjs_compiler_layout = b.option([]const u8, "zjs_compiler_layout", "compiler final layout: short (default) or plain (diagnostic)") orelse "short";
    if (!std.mem.eql(u8, zjs_compiler_layout, "plain") and !std.mem.eql(u8, zjs_compiler_layout, "short")) {
        std.debug.print("error: invalid -Dzjs_compiler_layout value '{s}': expected plain or short\n", .{zjs_compiler_layout});
        std.process.exit(1);
    }
    // OOM-injection coverage instrumentation (v1): records deduplicated
    // allocation call sites in core/memory.zig. Default off and comptime
    // gated, so the default build's allocation hot path is unchanged.
    // `zig build test-oom -Dzjs_oom_coverage=true` prints the count.
    const zjs_oom_coverage = b.option(bool, "zjs_oom_coverage", "Record distinct allocation call sites for the OOM corpus coverage report") orelse false;
    const zjs_force_gc = b.option(bool, "zjs_force_gc", "Force a full GC before each runtime heap allocation") orelse false;
    // Atom-ownership audit instrumentation: a one-slot quarantine on the
    // atom table's dead-slot free list (core/atom.zig) so a just-freed atom
    // id cannot be handed straight back by the very next intern. This turns
    // "borrow an atom out of a token, then use it after the owner released
    // it" from a silently masked hazard into a `dup` liveness assertion.
    // This is the ASAN / leak-checker tier: CI, fuzzing and regression runs
    // only. Default off, comptime erased when off (no field, no code, no
    // string in the default binary), and never part of the production path.
    // `zig build test -Dzjs_ownership_audit=true`; see
    // docs/borrowed_atom_audit.md §6.
    const zjs_ownership_audit = b.option(bool, "zjs_ownership_audit", "Quarantine one just-freed atom slot so borrowed-atom use-after-free trips an assertion instead of being masked by slot reuse (audit tier; never ReleaseFast)") orelse false;

    // ===== QCP-1 configuration signature =====
    // The defect class this closes is "a gate reports green about a
    // configuration it never ran". A nested `zig build` used to start from the
    // defaults and run a different configuration than the parent asked for.
    // Forwarding options fixes one instance; the signature makes the class
    // unexpressible, because every gate can now state which configuration its
    // green belongs to.
    //
    // This is the build graph's BELIEF about the configuration. The compiled
    // code computes the same string independently, in src/config_signature.zig,
    // from the declarations it actually consumes (resolve_labels.default_layout,
    // @sizeOf(core.value.JSValue), builtin.mode,
    // core.memory.force_gc_on_allocation_enabled,
    // core.atom.ownership_audit_enabled) and fails its own COMPILATION when the
    // two disagree (`config_signature.attest`). `zig build
    // config-signature-check` repeats the comparison at runtime against the
    // shipped binary.
    const config_settings: config.ConfigSettings = .{
        .compiler = compiler_name,
        .layout = zjs_compiler_layout,
        .optimize = optimize,
        .force_gc = zjs_force_gc,
        .ownership_audit = zjs_ownership_audit,
    };
    // Cross-build assertion. A parent build that spawns a child `zig build`
    // states the configuration it expects the child to resolve.
    //
    // It is deliberately NOT compared against build.zig's own belief here.
    // That comparison would only prove build.zig agrees with itself, and it
    // would short-circuit the check that matters: the expectation is handed
    // down to the artifacts, where `config_signature.attest` compares it
    // against the declarations the compiled code consumes. A wrong expectation
    // therefore fails the COMPILATION of every engine-bearing artifact.
    const config_expect_override = b.option([]const u8, "zjs_expect_config", "Fail every engine-bearing artifact unless its effective configuration signature matches exactly (for a parent build asserting what a child `zig build` must resolve)");
    if (config_expect_override) |override| {
        // Shape check only: a value check here would preempt the artifacts.
        if (!std.mem.startsWith(u8, override, "zjs-config-") or
            std.mem.indexOfScalar(u8, override, ':') == null)
        {
            std.debug.print(
                "error: -Dzjs_expect_config value '{s}' is not a configuration signature (expected a 'zjs-config-<n>:<field>=<value>,...' string)\n",
                .{override},
            );
            std.process.exit(1);
        }
    }
    // Each artifact reports its OWN optimize mode, so each artifact needs its
    // own expectation: `zjs`, `zjs-profile` and `run-test262` PIN ReleaseFast,
    // `zjs-dev` and the scoped test artifacts PIN Debug, and the unified suite
    // and public engine module FOLLOW -Doptimize. One build-wide string cannot
    // describe all three.
    //
    // The split matters, and getting it wrong would hollow out the whole point
    // of having an `optimize` component:
    //
    //   * artifacts that FOLLOW -Doptimize get the caller's string VERBATIM.
    //     That is what makes "the parent asked for ReleaseSafe, the child
    //     actually built Debug" a hard failure instead of a green -- exactly
    //     the case the component exists for. Substituting here would rewrite
    //     the assertion into whatever the child did and always agree.
    //   * artifacts that PIN their mode get the `optimize` field substituted,
    //     because a Debug test binary is not evidence of drift for having been
    //     built Debug. Every other field is carried through untouched: those
    //     are the fields the caller is asserting about.
    const expect_config = config_expect_override orelse config.configSignature(b, config_settings);
    const expect_config_debug = config.pinnedExpectedConfig(b, config_expect_override, config_settings, .Debug);
    const expect_config_fast = config.pinnedExpectedConfig(b, config_expect_override, config_settings, .ReleaseFast);

    // Separate options object for the dossier harnesses. Reusing engine_options
    // here would register the same generated file under two module names
    // (the harnesses already receive it transitively via internal_fast_mod).
    const zjs_dossier_layout_pad = b.option(usize, "zjs_dossier_layout_pad", "Dossier-only layout-lineage pad slot count (0 = no effect)") orelse 0;
    const dossier_options = b.addOptions();
    dossier_options.addOption(usize, "zjs_dossier_layout_pad", zjs_dossier_layout_pad);
    // One options shape for every engine-bearing module; the only field that
    // varies between them is `zjs_expect_config`, because that is the one
    // field whose correct value depends on the artifact's own optimize mode.
    const engine_option_inputs: config.EngineOptionInputs = .{
        .enable_opcode_profile = zjs_enable_opcode_profile,
        .tspike_guard = zjs_tspike_guard,
        .compiler_layout = zjs_compiler_layout,
        .expect_config = expect_config,
        .oom_coverage = zjs_oom_coverage,
        .force_gc = zjs_force_gc,
        .ownership_audit = zjs_ownership_audit,
        .dossier_layout_pad = zjs_dossier_layout_pad,
    };
    // Follows -Doptimize: the public engine module and the OOM corpus engine.
    const engine_options = config.addEngineOptions(b, engine_option_inputs);
    // Pinned ReleaseFast: internal_fast_mod (zjs, run-test262, perf harnesses).
    const engine_options_fast = config.addEngineOptions(b, engine_option_inputs.withExpect(expect_config_fast));
    // Pinned Debug: internal_dev_mod (zjs-dev, run-test262-dev).
    const engine_options_dev = config.addEngineOptions(b, engine_option_inputs.withExpect(expect_config_debug));

    const ctx = config.Ctx{
        .b = b,
        .target = target,
        .optimize = optimize,
        .engine_inputs = engine_option_inputs,
        .settings = config_settings,
        .expect_config = expect_config,
        .expect_config_debug = expect_config_debug,
        .expect_config_fast = expect_config_fast,
        .dossier_options = dossier_options,
        .engine_options = engine_options,
        .engine_options_fast = engine_options_fast,
        .engine_options_dev = engine_options_dev,
    };
    const engine_artifacts = artifacts.addEngineArtifacts(ctx);
    const test_graph = tests_graph.addTestGraph(ctx, engine_artifacts);
    perf.addPerfSteps(ctx, engine_artifacts);
    gates.addGates(ctx, engine_artifacts, test_graph);
}
