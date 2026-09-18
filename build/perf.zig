const config = @import("config.zig");
const artifacts_mod = @import("artifacts.zig");

pub fn addPerfSteps(ctx: config.Ctx, artifacts: artifacts_mod.Artifacts) void {
    const b = ctx.b;
    const zjs_exe = artifacts.zjs_exe;

    const run_perf_benchmark = b.addRunArtifact(zjs_exe);
    run_perf_benchmark.addArg("--perf-json");
    run_perf_benchmark.addArg("tests/perf/microbench.js");
    const perf_benchmark_step = b.step("perf-benchmark", "Run a repeatable diagnostic JS performance benchmark");
    perf_benchmark_step.dependOn(&run_perf_benchmark.step);
}
