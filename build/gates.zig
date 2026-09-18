const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const artifacts_mod = @import("artifacts.zig");
const tests_mod = @import("tests.zig");

/// Run `exe` under `taskset -c cpus` when a pin list is set. `cpus` empty
/// (or a non-Linux host) is a plain `addRunArtifact`.
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
    const run_test262_exe = artifacts.run_test262_exe;
    const install_run_test262 = artifacts.install_run_test262;
    const test_step = test_graph.test_step;
    const smoke_step = test_graph.smoke_step;
    const smoke_dev_step = test_graph.smoke_dev_step;
    const embedding_step = test_graph.embedding_step;

    // Add actual test262 execution step. Optional pin via `-Dgate-run-cpus`.
    // Check mode, not inherited stdio: a Run step that inherits stdio holds
    // the build runner's stderr lock for its whole duration. The summary
    // line is asserted on stdout, so a red run shows the full log.
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
    // The public-API surface snapshot. It used to fire only on the production
    // gate, which is why four commits on 2026-08-20 grew `JSValue`'s public
    // decl count past its pin and none of them noticed: `checkpoint-gate` is
    // what a code-bearing change is actually handed off behind. The test is a
    // Debug source-shape check, so it costs the gate nothing it was not
    // already paying.
    checkpoint_gate_step.dependOn(test_graph.check_embedding_step);

    const engine_production_gate_step = b.step("engine-production-gate", "Run the engine-only Production v1 release gate");
    engine_production_gate_step.dependOn(test_step);
    // The stress tier is excluded from test_step so per-change close-out
    // stays fast; the production gate pays for it here.
    engine_production_gate_step.dependOn(test_graph.stress_step);
    engine_production_gate_step.dependOn(smoke_step);
    engine_production_gate_step.dependOn(embedding_step);
    engine_production_gate_step.dependOn(test262_check_step);
}
