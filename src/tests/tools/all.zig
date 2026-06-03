const test262_runner = @import("../../cli/run_test262.zig");
const std = @import("std");

// ---- CC-1: regression-baseline gate ---------------------------------

test "test262 args parse --regression-baseline" {
    const config = try test262_runner.parseArgs(&.{
        "-c",                    "test262.conf",
        "--regression-baseline", "reports/test262-baseline/test262-by-dir.json",
        "test262/test",
    });
    try std.testing.expectEqualStrings(
        "reports/test262-baseline/test262-by-dir.json",
        config.regression_baseline.?,
    );
}

test "test262 baseline parser reads dir + passed pairs from by-dir.json" {
    const sample =
        \\[
        \\  { "dir": "annexB/built-ins", "passed": 2, "failed": 212, "known_failed": 0 },
        \\  { "dir": "built-ins/Array", "passed": 233, "failed": 2848, "known_failed": 0 },
        \\  { "dir": "language/expressions", "passed": 100, "failed": 50, "known_failed": 5 }
        \\]
    ;
    const entries = try test262_runner.parseBaseline(std.testing.allocator, sample);
    defer test262_runner.freeBaseline(std.testing.allocator, entries);

    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("annexB/built-ins", entries[0].dir);
    try std.testing.expectEqual(@as(usize, 2), entries[0].passed);
    try std.testing.expectEqualStrings("built-ins/Array", entries[1].dir);
    try std.testing.expectEqual(@as(usize, 233), entries[1].passed);
    try std.testing.expectEqualStrings("language/expressions", entries[2].dir);
    try std.testing.expectEqual(@as(usize, 100), entries[2].passed);
}

test "test262 checkRegressions detects passed-count drops" {
    var reporter = test262_runner.Reporter.initQuiet(std.testing.allocator, null);
    defer reporter.deinit();

    // Synthesise a current-run snapshot: dir A regressed (2 -> 1),
    // dir B held steady (5 -> 5), dir C improved (3 -> 7).
    try reporter.recordResult(std.testing.io, "test/A/x1.js", .passed, "", false);
    try reporter.recordResult(std.testing.io, "test/B/x1.js", .passed, "", false);
    try reporter.recordResult(std.testing.io, "test/B/x2.js", .passed, "", false);
    try reporter.recordResult(std.testing.io, "test/B/x3.js", .passed, "", false);
    try reporter.recordResult(std.testing.io, "test/B/x4.js", .passed, "", false);
    try reporter.recordResult(std.testing.io, "test/B/x5.js", .passed, "", false);
    try reporter.recordResult(std.testing.io, "test/C/x1.js", .passed, "", false);
    try reporter.recordResult(std.testing.io, "test/C/x2.js", .passed, "", false);
    try reporter.recordResult(std.testing.io, "test/C/x3.js", .passed, "", false);
    try reporter.recordResult(std.testing.io, "test/C/x4.js", .passed, "", false);
    try reporter.recordResult(std.testing.io, "test/C/x5.js", .passed, "", false);
    try reporter.recordResult(std.testing.io, "test/C/x6.js", .passed, "", false);
    try reporter.recordResult(std.testing.io, "test/C/x7.js", .passed, "", false);
    // recordResult uses deriveDirSegment which produces the first two
    // path components ("test/A" / "test/B" / "test/C") when the
    // `/test/` marker is absent.

    const baseline = [_]test262_runner.BaselineEntry{
        .{ .dir = "test/A", .passed = 2 },
        .{ .dir = "test/B", .passed = 5 },
        .{ .dir = "test/C", .passed = 3 },
        .{ .dir = "test/D", .passed = 9 }, // not present in current; ignored
    };
    const result = try test262_runner.checkRegressions(std.testing.io, &reporter, &baseline);
    try std.testing.expectEqual(@as(usize, 1), result.count); // test/A regressed
    try std.testing.expectEqual(@as(usize, 3), result.matched); // test/A,B,C matched; test/D not present
}

test "test262 checkRegressions returns zero when all dirs hold or improve" {
    var reporter = test262_runner.Reporter.init(std.testing.allocator, null);
    defer reporter.deinit();
    try reporter.recordResult(std.testing.io, "test/A/x1.js", .passed, "", false);
    try reporter.recordResult(std.testing.io, "test/A/x2.js", .passed, "", false);
    const baseline = [_]test262_runner.BaselineEntry{
        .{ .dir = "test/A", .passed = 2 },
    };
    const result = try test262_runner.checkRegressions(std.testing.io, &reporter, &baseline);
    try std.testing.expectEqual(@as(usize, 0), result.count);
    try std.testing.expectEqual(@as(usize, 1), result.matched);
}
