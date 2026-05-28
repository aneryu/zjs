const std = @import("std");
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

test "optimized OOM sweeps stop once OOM and success coverage is observed" {
    if (sweepMode() == .quick) {
        try std.testing.expect(shouldStopAfterCoverage(true, true));
    }
}

test "full OOM sweeps keep scanning after OOM and success coverage is observed" {
    if (fullSweep()) {
        try std.testing.expect(!shouldStopAfterCoverage(true, true));
    }
}

test "optimized OOM sweeps can stop after OOM when success is checked separately" {
    if (sweepMode() == .quick) {
        try std.testing.expect(shouldStopAfterOom(true));
    }
}

test "full OOM sweeps do not stop after the first OOM" {
    if (fullSweep()) {
        try std.testing.expect(!shouldStopAfterOom(true));
    }
}

test "sampled OOM sweeps only run metadata offsets" {
    const samples = SampleSet{
        .limit = 10,
        .offsets = &.{ 0, 3, 9 },
    };

    try std.testing.expect(shouldRunOffsetForMode(.sampled, 0, samples));
    try std.testing.expect(!shouldRunOffsetForMode(.sampled, 1, samples));
    try std.testing.expect(shouldRunOffsetForMode(.sampled, 3, samples));
    try std.testing.expect(!shouldRunOffsetForMode(.sampled, 8, samples));
    try std.testing.expect(shouldRunOffsetForMode(.sampled, 9, samples));
    try std.testing.expect(!shouldRunOffsetForMode(.sampled, 10, samples));
}

test "exhaustive OOM sweeps ignore metadata gaps but still respect limit" {
    const samples = SampleSet{
        .limit = 4,
        .offsets = &.{1},
    };

    try std.testing.expect(shouldRunOffsetForMode(.exhaustive, 0, samples));
    try std.testing.expect(shouldRunOffsetForMode(.exhaustive, 2, samples));
    try std.testing.expect(!shouldRunOffsetForMode(.exhaustive, 4, samples));
}

test "default OOM sample set includes early, boundary, and success offsets" {
    const samples = defaultSampleSet(10);

    try std.testing.expect(shouldRunOffsetForMode(.sampled, 0, samples));
    try std.testing.expect(shouldRunOffsetForMode(.sampled, 1, samples));
    try std.testing.expect(shouldRunOffsetForMode(.sampled, 2, samples));
    try std.testing.expect(shouldRunOffsetForMode(.sampled, 4, samples));
    try std.testing.expect(shouldRunOffsetForMode(.sampled, 8, samples));
    try std.testing.expect(shouldRunOffsetForMode(.sampled, 9, samples));
    try std.testing.expect(!shouldRunOffsetForMode(.sampled, 10, samples));
}
