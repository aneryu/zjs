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
    // Final bytecode layout. `short` is the release configuration; `plain`
    // stays reachable as an A/B diagnostic.
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
    const zjs_ownership_audit = b.option(bool, "zjs_ownership_audit", "Quarantine the atom slots retired by the last sweep so borrowed-atom use-after-free trips an assertion instead of being masked by slot reuse (audit tier; never ReleaseFast)") orelse false;
    const engine_option_inputs: config.EngineOptionInputs = .{
        .enable_opcode_profile = zjs_enable_opcode_profile,
        .compiler_layout = zjs_compiler_layout,
        .oom_coverage = zjs_oom_coverage,
        .force_gc = zjs_force_gc,
        .ownership_audit = zjs_ownership_audit,
    };
    const engine_options = config.addEngineOptions(b, engine_option_inputs);

    const ctx = config.Ctx{
        .b = b,
        .target = target,
        .optimize = optimize,
        .engine_inputs = engine_option_inputs,
        .engine_options = engine_options,
        .gate_run_cpus = config.gateRunCpus(b),
    };
    const engine_artifacts = artifacts.addEngineArtifacts(ctx);
    const test_graph = tests_graph.addTestGraph(ctx, engine_artifacts);
    perf.addPerfSteps(ctx, engine_artifacts);
    gates.addGates(ctx, engine_artifacts, test_graph);
}
