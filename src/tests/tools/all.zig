const qjs_cli = @import("qjs_cli");
const smoke_runner = @import("smoke_runner");
const test262_runner = @import("test262_runner");
const std = @import("std");

test "qjs args accept eval source and one file" {
    const eval_command = try qjs_cli.parseArgs(&.{ "-e", "1" });
    try std.testing.expectEqualStrings("1", eval_command.eval.source);

    const file_command = try qjs_cli.parseArgs(&.{"input.js"});
    try std.testing.expectEqualStrings("input.js", file_command.file.path);
    try std.testing.expectEqual(@as(usize, 1), file_command.file.script_args.len);
}

test "qjs args reject invalid forms" {
    try std.testing.expectError(error.Usage, qjs_cli.parseArgs(&.{"-e"}));
    try std.testing.expectError(error.Usage, qjs_cli.parseArgs(&.{"--unknown"}));
}

test "smoke manifest helpers count entries and build expected paths" {
    try std.testing.expectEqual(@as(usize, 2), smoke_runner.countManifestEntries("# comment\narith.js\n\nvars.js\n"));
    var buffer: [128]u8 = undefined;
    const path = try smoke_runner.expectedPath(&buffer, "arith.js", ".out");
    try std.testing.expectEqualStrings("tests/zig-smoke/expected/arith.js.out", path);
}

test "test262 args parse QuickJS-shaped config and selectors" {
    const config = try test262_runner.parseArgs(&.{ "-c", "test262.conf", "-m", "-t", "1", "test262/test" });
    try std.testing.expectEqualStrings("test262.conf", config.config_path.?);
    try std.testing.expect(config.module);
    try std.testing.expectEqual(@as(u32, 1), config.threads);
    try std.testing.expectEqualStrings("test262/test", config.test_root.?);

    const selected = try test262_runner.parseArgs(&.{ "-d", "built-ins/Object", "-f", "language/types/null.js", "-e", "known.txt" });
    try std.testing.expectEqualStrings("built-ins/Object", selected.dirs.get(0));
    try std.testing.expectEqualStrings("language/types/null.js", selected.files.get(0));
    try std.testing.expectEqualStrings("known.txt", selected.known_error_file.?);
}

test "test262 args parse QuickJS index span" {
    const config = try test262_runner.parseArgs(&.{ "-c", "test262.conf", "0", "20" });
    try std.testing.expectEqual(@as(?usize, 0), config.start_index);
    try std.testing.expectEqual(@as(?usize, 20), config.stop_index);
}

test "test262 config text parses paths features and excludes" {
    var loaded = try test262_runner.loadConfigText(std.testing.allocator, "",
        \\[config]
        \\testdir=test262/test
        \\harnessdir=test262/harness
        \\errorfile=test262_errors.txt
        \\[features]
        \\Intl.Locale=skip
        \\Map
        \\[exclude]
        \\test262/test/intl402/
    );
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("test262/test", loaded.testdir.?);
    try std.testing.expectEqualStrings("test262/harness", loaded.harnessdir.?);
    try std.testing.expectEqualStrings("test262_errors.txt", loaded.errorfile.?);
    try std.testing.expect(loaded.excludes.contains("test262/test/intl402/foo.js"));
    try std.testing.expectEqual(@as(usize, 1), loaded.enabled_features.items.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.skipped_features.items.len);
}

test "test262 metadata helper parses runner-critical fields" {
    var metadata = try test262_runner.parseMetadataText(std.testing.allocator,
        \\/*---
        \\includes: [propertyHelper.js, compareArray.js]
        \\features: [BigInt]
        \\flags: [module]
        \\negative:
        \\  phase: parse
        \\  type: SyntaxError
        \\---*/
    );
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("propertyHelper.js", metadata.includes.items[0]);
    try std.testing.expectEqualStrings("compareArray.js", metadata.includes.items[1]);
    try std.testing.expect(metadata.features.contains("BigInt"));
    try std.testing.expect(metadata.flags.contains("module"));
    try std.testing.expectEqualStrings("parse", metadata.negative.?.phase.?);
    try std.testing.expectEqualStrings("SyntaxError", metadata.negative.?.type_name.?);
}

test "test262 metadata helper parses block lists" {
    var metadata = try test262_runner.parseMetadataText(std.testing.allocator,
        \\/*---
        \\includes:
        \\  - propertyHelper.js
        \\  - compareArray.js
        \\features:
        \\  - BigInt
        \\flags:
        \\  - onlyStrict
        \\---*/
    );
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("propertyHelper.js", metadata.includes.items[0]);
    try std.testing.expectEqualStrings("compareArray.js", metadata.includes.items[1]);
    try std.testing.expect(metadata.features.contains("BigInt"));
    try std.testing.expect(metadata.flags.contains("onlyStrict"));
}

test "test262 negative helper does not accept wrong failure type" {
    const negative = test262_runner.NegativeMetadata{
        .phase = "runtime",
        .type_name = "TypeError",
    };
    try std.testing.expect(test262_runner.negativeResultMatches(negative, false, "TypeError: invalid"));
    try std.testing.expect(!test262_runner.negativeResultMatches(negative, false, "SyntaxError: invalid"));
}

test "test262 temp source helper avoids shared worker path" {
    var first_buf: [128]u8 = undefined;
    var second_buf: [128]u8 = undefined;
    const first = try test262_runner.tempTestPath(&first_buf, "test/a.js", 0);
    const second = try test262_runner.tempTestPath(&second_buf, "test/b.js", 0);

    try std.testing.expect(!std.mem.eql(u8, first, second));
}

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
    var reporter = test262_runner.Reporter.init(std.testing.allocator, null);
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
