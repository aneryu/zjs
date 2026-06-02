const std = @import("std");
const oom_helpers = @import("oom_helpers.zig");

test "optimized OOM sweeps stop once OOM and success coverage is observed" {
    if (oom_helpers.sweepMode() == .quick) {
        try std.testing.expect(oom_helpers.shouldStopAfterCoverage(true, true));
    }
}

test "full OOM sweeps keep scanning after OOM and success coverage is observed" {
    if (oom_helpers.fullSweep()) {
        try std.testing.expect(!oom_helpers.shouldStopAfterCoverage(true, true));
    }
}

test "optimized OOM sweeps can stop after OOM when success is checked separately" {
    if (oom_helpers.sweepMode() == .quick) {
        try std.testing.expect(oom_helpers.shouldStopAfterOom(true));
    }
}

test "full OOM sweeps do not stop after the first OOM" {
    if (oom_helpers.fullSweep()) {
        try std.testing.expect(!oom_helpers.shouldStopAfterOom(true));
    }
}

test "sampled OOM sweeps only run metadata offsets" {
    const samples = oom_helpers.SampleSet{
        .limit = 10,
        .offsets = &.{ 0, 3, 9 },
    };

    try std.testing.expect(oom_helpers.shouldRunOffsetForMode(.sampled, 0, samples));
    try std.testing.expect(!oom_helpers.shouldRunOffsetForMode(.sampled, 1, samples));
    try std.testing.expect(oom_helpers.shouldRunOffsetForMode(.sampled, 3, samples));
    try std.testing.expect(!oom_helpers.shouldRunOffsetForMode(.sampled, 8, samples));
    try std.testing.expect(oom_helpers.shouldRunOffsetForMode(.sampled, 9, samples));
    try std.testing.expect(!oom_helpers.shouldRunOffsetForMode(.sampled, 10, samples));
}

test "exhaustive OOM sweeps ignore metadata gaps but still respect limit" {
    const samples = oom_helpers.SampleSet{
        .limit = 4,
        .offsets = &.{1},
    };

    try std.testing.expect(oom_helpers.shouldRunOffsetForMode(.exhaustive, 0, samples));
    try std.testing.expect(oom_helpers.shouldRunOffsetForMode(.exhaustive, 2, samples));
    try std.testing.expect(!oom_helpers.shouldRunOffsetForMode(.exhaustive, 4, samples));
}

test "default OOM sample set includes early, boundary, and success offsets" {
    const samples = oom_helpers.defaultSampleSet(10);

    try std.testing.expect(oom_helpers.shouldRunOffsetForMode(.sampled, 0, samples));
    try std.testing.expect(oom_helpers.shouldRunOffsetForMode(.sampled, 1, samples));
    try std.testing.expect(oom_helpers.shouldRunOffsetForMode(.sampled, 2, samples));
    try std.testing.expect(oom_helpers.shouldRunOffsetForMode(.sampled, 4, samples));
    try std.testing.expect(oom_helpers.shouldRunOffsetForMode(.sampled, 8, samples));
    try std.testing.expect(oom_helpers.shouldRunOffsetForMode(.sampled, 9, samples));
    try std.testing.expect(!oom_helpers.shouldRunOffsetForMode(.sampled, 10, samples));
}
