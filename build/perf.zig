const config = @import("config.zig");
const artifacts_mod = @import("artifacts.zig");

pub fn addPerfSteps(ctx: config.Ctx, artifacts: artifacts_mod.Artifacts) void {
    const run_perf_benchmark = ctx.b.addRunArtifact(artifacts.zjs_exe);
    run_perf_benchmark.addArg("--perf-json");
    run_perf_benchmark.addArg("tests/perf/microbench.js");
    const perf_benchmark_step = ctx.b.step("perf-benchmark", "Run a repeatable diagnostic JS performance benchmark");
    perf_benchmark_step.dependOn(&run_perf_benchmark.step);
}
