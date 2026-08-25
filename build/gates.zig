const config = @import("config.zig");
const artifacts_mod = @import("artifacts.zig");
const tests_mod = @import("tests.zig");

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

    // Add actual test262 execution step.
    const run_test262_exec = b.addRunArtifact(run_test262_exe);
    run_test262_exec.step.dependOn(&install_run_test262.step);
    run_test262_exec.addArg("-c");
    run_test262_exec.addArg("test262.conf");
    run_test262_exec.addArg("-d");
    run_test262_exec.addArg("test262/test");
    run_test262_exec.addArg("0");
    run_test262_exec.addArg("100000");
    run_test262_exec.addArg("-R");
    run_test262_exec.addArg("reports/test262-latest");
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
    checkpoint_gate_step.dependOn(embedding_step);

    const engine_production_gate_step = b.step("engine-production-gate", "Run the engine-only Production v1 release gate");
    engine_production_gate_step.dependOn(test_step);
    engine_production_gate_step.dependOn(smoke_step);
    engine_production_gate_step.dependOn(embedding_step);
    engine_production_gate_step.dependOn(&run_architecture_deps.step);
    engine_production_gate_step.dependOn(&run_architecture_oom_panics.step);
    engine_production_gate_step.dependOn(&run_architecture_borrowed_atoms.step);
    engine_production_gate_step.dependOn(&run_architecture_gc_slots.step);
    engine_production_gate_step.dependOn(&run_architecture_stage_boundaries.step);
    engine_production_gate_step.dependOn(test262_check_step);
}
