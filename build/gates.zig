const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const artifacts_mod = @import("artifacts.zig");
const tests_mod = @import("tests.zig");

/// Run `exe` under `taskset -c cpus` (Linux) so a gate's Run steps can use
/// more cores than the compile pool the whole `zig build` was launched on.
/// `cpus` empty (or a non-Linux host) is a plain `addRunArtifact`.
pub fn runArtifactOnCpus(b: *std.Build, cpus: []const u8, exe: *std.Build.Step.Compile) *std.Build.Step.Run {
    if (cpus.len == 0 or builtin.os.tag != .linux) return b.addRunArtifact(exe);
    const run = b.addSystemCommand(&.{ "taskset", "-c", cpus });
    run.addArtifactArg(exe);
    run.setName(b.fmt("run {s} (cpus {s})", .{ exe.name, cpus }));
    return run;
}

pub fn addGates(ctx: config.Ctx, artifacts: artifacts_mod.Artifacts, test_graph: tests_mod.TestGraph) void {
    const b = ctx.b;
    const expect_config_fast = ctx.expect_config_fast;
    const zjs_exe = artifacts.zjs_exe;
    const install_zjs = artifacts.install_zjs;
    const run_test262_exe = artifacts.run_test262_exe;
    const install_run_test262 = artifacts.install_run_test262;
    const test_step = test_graph.test_step;
    const smoke_step = test_graph.smoke_step;
    const smoke_dev_step = test_graph.smoke_dev_step;
    const embedding_step = test_graph.embedding_step;

    // Add actual test262 execution step. Pinned to the gate's run pool
    // (`-Dgate-run-cpus`; every core but the two measurement cores 9/19 by
    // default) rather than the compile pool `zig build` was started on: the
    // runner takes one worker thread per core it can see, and the compiles
    // are what the big cores are for. Check mode, not inherited stdio: a Run
    // step that inherits stdio holds the build runner's stderr lock for its
    // whole duration, which serialised this 28 s run behind (or ahead of)
    // the 53 s fixed-work smoke on every merge gate until 2026-09-06. The
    // summary line is asserted on stdout, so a red run shows the full log.
    const run_test262_exec = runArtifactOnCpus(b, ctx.gate_run_cpus, run_test262_exe);
    run_test262_exec.step.dependOn(&install_run_test262.step);
    run_test262_exec.addArg("-c");
    run_test262_exec.addArg("test262.conf");
    run_test262_exec.addArg("-d");
    run_test262_exec.addArg("test262/test");
    run_test262_exec.addArg("0");
    run_test262_exec.addArg("100000");
    run_test262_exec.addArg("-R");
    run_test262_exec.addArg("reports/test262-latest");
    // `-v`: failing cases print `FAIL <path>: <detail>` to stdout (passes stay
    // silent), so the stdout the check prints on a red run names them; at
    // verbose 0 they only reach reports/test262-latest/test262-failures.log,
    // which the next green run overwrites (2026-09-06: one red test262 under
    // full gate load lost its failure text exactly that way).
    run_test262_exec.addArg("-v");
    run_test262_exec.expectStdOutMatch("Result: 0/");
    const test262_check_step = b.step("test262-check", "Run the full test262 suite; any failed or newly-fixed case fails the step");
    test262_check_step.dependOn(&run_test262_exec.step);

    // Macro-workload completion gate. test262 cases are small and short-lived,
    // so almost none of them survive long enough to be promoted out of the
    // young generation, which leaves the generational write barrier largely
    // unexercised. A macro benchmark builds a large long-lived object graph and
    // then keeps mutating it, which is exactly that shape. The gap this closes
    // is not hypothetical: with the tracing collector at test262 0/49778 and
    // both unit suites green, six of the nine vendored bench-v8 runs still
    // failed outright -- five with `InvalidBuiltinRegistry`, one with a
    // segfault -- every one of them a live object reclaimed by a minor.
    //
    // It asserts completion, not a score, so it is a correctness gate and
    // belongs here rather than under `perf-*`.
    const run_macro_check = b.addSystemCommand(&.{ "python3", "tools/perf/bench_v8/check_completes.py" });
    // The macro workloads are where the arena invariant broke, and where a
    // deleted block stamp is still caught today; unit tests never recycle an
    // arena with dirty content. A no-op in the refcounting build, which never
    // reads the variable.
    run_macro_check.setEnvironmentVariable("ZJS_GC_ARENA_AUDIT", "1");
    run_macro_check.addArtifactArg(zjs_exe);
    const macro_check_step = b.step("macro-check", "Assert every vendored bench-v8 benchmark still completes on the built zjs");
    macro_check_step.dependOn(&run_macro_check.step);

    const run_architecture_deps = b.addSystemCommand(&.{
        "node",
        "tools/architecture/check_deps.js",
    });

    // OOM no-panic rule: allocation failures must propagate as errors (the
    // catchable-OOM contract from eecf6c8). OutOfMemory-discard and
    // catch-unreachable-on-alloc forms require an allowlist entry (currently
    // the rope-flatten last resort).
    const run_architecture_oom_panics = b.addSystemCommand(&.{
        "node",
        "tools/architecture/check_oom_panics.js",
    });

    // Borrowed-atom escape rule: an atom id read out of a token (or out of a
    // helper that returns one) must not be returned, parked in a long-lived
    // parser State field, or read after advance()/freeToken() released the
    // token. This is the review-time half of the ada949be class-C fix; the
    // run-time half is -Dzjs_ownership_audit (docs/borrowed_atom_audit.md §8).
    const run_architecture_borrowed_atoms = b.addSystemCommand(&.{
        "node",
        "tools/architecture/check_borrowed_atoms.js",
    });

    const run_architecture_gc_slots = b.addSystemCommand(&.{
        "node",
        "tools/architecture/check_gc_slots.js",
    });

    // Compiler-stage boundaries: the two explicit `noinline` stages that
    // made legacy deletion performance-stable. Checkpoint checks the
    // declarations. The production gate already compiles ReleaseFast `zjs`
    // for smoke and then `nm`s the independent symbols.
    const run_architecture_stage_source = b.addSystemCommand(&.{
        "node",
        "tools/architecture/check_compiler_stage_boundaries.js",
        "--source-only",
    });

    const run_architecture_stage_boundaries = b.addSystemCommand(&.{
        "node",
        "tools/architecture/check_compiler_stage_boundaries.js",
    });
    run_architecture_stage_boundaries.addArg(b.getInstallPath(.bin, zjs_exe.out_filename));
    run_architecture_stage_boundaries.step.dependOn(&install_zjs.step);

    // Run the SHIPPED artifact and make it state its own configuration, then
    // compare that against what the build graph requested. The binary answers
    // from src/config_signature.zig, which reads the declarations the engine
    // consumes; this build states what it believes it configured. Any drift
    // between the two -- an option that never reached the code, a hardcoded
    // constant that outlived its option -- fails here.
    // `zjs` pins ReleaseFast regardless of -Doptimize, so the string it must
    // print is the ReleaseFast expectation, not the top-level one. Getting
    // this wrong in either direction is the very confusion the `optimize`
    // component exists to make visible.
    const run_config_signature = b.addRunArtifact(zjs_exe);
    run_config_signature.addArg("--print-config-signature");
    run_config_signature.expectStdOutEqual(b.fmt("{s}\n", .{expect_config_fast}));
    const config_signature_step = b.step("config-signature-check", "Check the built zjs reports the configuration signature this build requested");
    config_signature_step.dependOn(&run_config_signature.step);

    smoke_step.dependOn(&run_config_signature.step);

    const quick_gate_step = b.step("quick-gate", "Run the fast inner-loop validation gate");
    quick_gate_step.dependOn(smoke_dev_step);

    const checkpoint_gate_step = b.step("checkpoint-gate", "Run checkpoint validation without the full test262, OOM-injection, or ReleaseFast binary gates");
    checkpoint_gate_step.dependOn(test_step);
    checkpoint_gate_step.dependOn(test_graph.gc_stress_step);
    checkpoint_gate_step.dependOn(smoke_dev_step);
    // Source-side architecture only. The ReleaseFast compiler-stage `nm`
    // half stays on the production gate, which already compiles zjs for smoke.
    checkpoint_gate_step.dependOn(&run_architecture_deps.step);
    checkpoint_gate_step.dependOn(&run_architecture_oom_panics.step);
    checkpoint_gate_step.dependOn(&run_architecture_borrowed_atoms.step);
    checkpoint_gate_step.dependOn(&run_architecture_gc_slots.step);
    checkpoint_gate_step.dependOn(&run_architecture_stage_source.step);
    // The public-API surface snapshot. It used to fire only on the production
    // gate, which is why four commits on 2026-08-20 grew `JSValue`'s public
    // decl count past its pin and none of them noticed: `checkpoint-gate` is
    // what a code-bearing change is actually handed off behind. The test is a
    // Debug source-shape check, so it costs the gate nothing it was not
    // already paying.
    checkpoint_gate_step.dependOn(test_graph.check_embedding_step);

    // Fixed-work smoke (tools/perf/gate_smoke.sh) as a build step, so the
    // merge gate runs it inside the graph -- concurrently with test262 and
    // the suites -- instead of after the whole graph as a second command
    // (the 2026-08-30 batch-gate accounting had the serial sweep at ~8 of
    // ~12 minutes; parallel mode brought it down, the serial position stayed).
    // It is a crash/invariant smoke, not a measurement; the runs share the
    // gate's run pool (`-Dgate-run-cpus`) and `-Dgate-smoke-cpus` overrides.
    const gate_smoke_cpus = b.option([]const u8, "gate-smoke-cpus", "taskset CPU list for the parallel fixed-work smoke (default: the gate run pool)") orelse ctx.gate_run_cpus;
    // One ordinary run per workload, not the script's default three: the
    // arena-audit/stats run is the stronger half, and on the merge gate the
    // smoke is the critical path (earley-boyer alone: 3 x 22 s + 30 s audit
    // on one X925 core). Every batch re-runs it, so a scheduling-dependent
    // crash still gets its repeats across batches. `-Dgate-smoke-runs=3`
    // restores the old shape.
    const gate_smoke_runs = b.option([]const u8, "gate-smoke-runs", "Ordinary runs per workload before the arena-audit run (default 1)") orelse "1";
    const gate_smoke_corpus = b.option([]const u8, "gate-smoke-corpus", "Fixed-work corpus directory (default /tmp/gcgap-fixed)") orelse "/tmp/gcgap-fixed";
    const run_gate_smoke = b.addSystemCommand(&.{"tools/perf/gate_smoke.sh"});
    run_gate_smoke.addArtifactArg(zjs_exe);
    // Positional: corpus, then a CPU the script validates but does not use
    // in parallel mode, then the ordinary-run count.
    run_gate_smoke.addArgs(&.{ gate_smoke_corpus, "5", gate_smoke_runs });
    if (gate_smoke_cpus.len != 0) run_gate_smoke.setEnvironmentVariable("ZJS_GATE_PARALLEL_CPUS", gate_smoke_cpus);
    run_gate_smoke.step.dependOn(&install_zjs.step);
    // Check mode (the script's closing line is asserted on stdout; a red
    // run prints the whole log) instead of inherited stdio, which would hold
    // the runner's stderr lock and serialise the smoke against test262. The
    // step keys on the zjs artifact's content hash, so it re-runs for every
    // engine change and is a cache hit when the binary is byte-identical --
    // the script's own stale-binary guard covers the out-of-graph callers.
    run_gate_smoke.expectStdOutMatch("fixed-work smoke: all clean");
    const gate_smoke_step = b.step("gate-smoke", "Run the fixed-work corpus smoke (ordinary runs + arena-audit stats run per workload) against the built zjs");
    gate_smoke_step.dependOn(&run_gate_smoke.step);

    // Per-merge-batch gate (docs/verification-policy.md): everything the
    // production gate proves about the ENGINE, minus the release-artifact
    // duplicates. Compared with engine-production-gate it drops the
    // ReleaseFast `zjs-profile` compile (smoke's profile-contract checks are
    // release-tier), the second Debug engine compile behind `test-embedding`
    // (sema-only `check-embedding` instead; the runtime pins run in the
    // unified suite), and takes the fixed-work smoke in-graph. Engine
    // compiles: 2 ReleaseFast (zjs, run-test262) + 2 Debug (unified,
    // zjs-dev), down from 3 + 3.
    const merge_gate_step = b.step("merge-gate", "Per-merge-batch gate: suites + stress + gc-stress + smoke-dev + architecture + test262 + fixed-work smoke (2 ReleaseFast + 2 Debug engine compiles)");
    merge_gate_step.dependOn(test_step);
    merge_gate_step.dependOn(test_graph.gc_stress_step);
    merge_gate_step.dependOn(test_graph.stress_step);
    merge_gate_step.dependOn(smoke_dev_step);
    merge_gate_step.dependOn(test_graph.check_embedding_step);
    merge_gate_step.dependOn(&run_architecture_deps.step);
    merge_gate_step.dependOn(&run_architecture_oom_panics.step);
    merge_gate_step.dependOn(&run_architecture_borrowed_atoms.step);
    merge_gate_step.dependOn(&run_architecture_gc_slots.step);
    merge_gate_step.dependOn(&run_architecture_stage_boundaries.step);
    merge_gate_step.dependOn(&run_config_signature.step);
    merge_gate_step.dependOn(test262_check_step);
    merge_gate_step.dependOn(gate_smoke_step);

    const engine_production_gate_step = b.step("engine-production-gate", "Run the engine-only Production v1 release gate");
    engine_production_gate_step.dependOn(test_step);
    // The stress tier is excluded from test_step so per-change close-out
    // stays fast; the production gate pays for it here.
    engine_production_gate_step.dependOn(test_graph.stress_step);
    engine_production_gate_step.dependOn(smoke_step);
    engine_production_gate_step.dependOn(embedding_step);
    engine_production_gate_step.dependOn(&run_architecture_deps.step);
    engine_production_gate_step.dependOn(&run_architecture_oom_panics.step);
    engine_production_gate_step.dependOn(&run_architecture_borrowed_atoms.step);
    engine_production_gate_step.dependOn(&run_architecture_gc_slots.step);
    engine_production_gate_step.dependOn(&run_architecture_stage_boundaries.step);
    engine_production_gate_step.dependOn(test262_check_step);
}
