const config = @import("config.zig");
const artifacts_mod = @import("artifacts.zig");
const tests_mod = @import("tests.zig");

pub fn addGates(ctx: config.Ctx, artifacts: artifacts_mod.Artifacts, test_graph: tests_mod.TestGraph) void {
    const b = ctx.b;

    // Check mode, not inherited stdio: a Run step that inherits stdio holds
    // the build runner's stderr lock for its whole duration. The summary
    // line is asserted on stdout, so a red run shows the full log.
    const run_test262_exec = config.runArtifactOnCpus(b, ctx.gate_run_cpus, artifacts.run_test262_exe);
    run_test262_exec.step.dependOn(&artifacts.install_run_test262.step);
    run_test262_exec.addArg("-c");
    run_test262_exec.addArg("test262.conf");
    run_test262_exec.addArg("-d");
    run_test262_exec.addArg("test262/test");
    run_test262_exec.addArg("0");
    run_test262_exec.addArg("100000");
    run_test262_exec.addArg("-R");
    run_test262_exec.addArg("reports/test262-latest");
    // `-v`: failing cases print `FAIL <path>: <detail>` to stdout (passes stay
    // silent). At verbose 0 they only reach reports/test262-latest/, which
    // the next green run overwrites.
    run_test262_exec.addArg("-v");
    run_test262_exec.expectStdOutMatch("Result: 0/");
    const test262_check_step = b.step("test262-check", "Run the full test262 suite; any failed or newly-fixed case fails the step");
    test262_check_step.dependOn(&run_test262_exec.step);

    const quick_gate_step = b.step("quick-gate", "Run the fast inner-loop validation gate");
    quick_gate_step.dependOn(test_graph.smoke_step);

    const checkpoint_gate_step = b.step("checkpoint-gate", "Run checkpoint validation without the full test262, OOM-injection, or stress tiers");
    checkpoint_gate_step.dependOn(test_graph.test_step);
    checkpoint_gate_step.dependOn(test_graph.gc_stress_step);
    checkpoint_gate_step.dependOn(test_graph.smoke_step);
    // Public-API surface snapshot. A source-shape check; costs the
    // gate nothing it was not already paying.
    checkpoint_gate_step.dependOn(test_graph.check_embedding_step);

    const engine_production_gate_step = b.step("engine-production-gate", "Run the engine production gate (pass -Doptimize=ReleaseFast for the shipped configuration)");
    engine_production_gate_step.dependOn(test_graph.test_step);
    engine_production_gate_step.dependOn(test_graph.stress_step);
    engine_production_gate_step.dependOn(test_graph.smoke_step);
    engine_production_gate_step.dependOn(test_graph.embedding_step);
    engine_production_gate_step.dependOn(test262_check_step);
}
