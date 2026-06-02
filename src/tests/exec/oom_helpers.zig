const oom_options = @import("oom_options");

pub const SweepMode = enum {
    quick,
    sampled,
    exhaustive,
};

pub const SampleSet = struct {
    limit: usize,
    offsets: []const usize,

    pub fn contains(self: SampleSet, fail_offset: usize) bool {
        for (self.offsets) |offset| {
            if (offset == fail_offset) return true;
        }
        return false;
    }
};

pub fn defaultSampleSet(comptime limit: usize) SampleSet {
    if (limit == 0) @compileError("OOM sample set limit must be non-zero");
    return .{
        .limit = limit,
        .offsets = &.{ 0, 1, 2, 4, 8, 16, 32, 64, 128, 256, limit - 1 },
    };
}

pub fn sweepMode() SweepMode {
    if (oom_options.full_oom_sweep) return .exhaustive;
    if (oom_options.sampled_oom_sweep) return .sampled;
    return .quick;
}

pub fn fullSweep() bool {
    return sweepMode() == .exhaustive;
}

pub fn sampledSweep() bool {
    return sweepMode() == .sampled;
}

pub fn shouldRunOffset(samples: SampleSet, fail_offset: usize) bool {
    return shouldRunOffsetForMode(sweepMode(), fail_offset, samples);
}

pub fn shouldRunOffsetForMode(mode: SweepMode, fail_offset: usize, samples: SampleSet) bool {
    if (fail_offset >= samples.limit) return false;
    return switch (mode) {
        .quick => true,
        .sampled => samples.contains(fail_offset),
        .exhaustive => true,
    };
}

pub fn shouldStopAfterCoverage(saw_oom: bool, saw_success: bool) bool {
    return sweepMode() == .quick and saw_oom and saw_success;
}

pub fn shouldStopAfterOom(saw_oom: bool) bool {
    return sweepMode() == .quick and saw_oom;
}
