const qjs_cli = @import("qjs_cli");
const smoke_runner = @import("smoke_runner");
const test262_runner = @import("test262_runner");
const std = @import("std");

test "qjs args accept eval source and one file" {
    const eval_command = try qjs_cli.parseArgs(&.{ "-e", "1" });
    try std.testing.expectEqualStrings("1", eval_command.eval);

    const file_command = try qjs_cli.parseArgs(&.{"input.js"});
    try std.testing.expectEqualStrings("input.js", file_command.file.path);
    try std.testing.expectEqual(@as(usize, 1), file_command.file.script_args.len);
}

test "qjs args reject invalid forms" {
    try std.testing.expectError(error.Usage, qjs_cli.parseArgs(&.{"-e"}));
    try std.testing.expectError(error.Usage, qjs_cli.parseArgs(&.{}));
}

test "smoke manifest helpers count entries and build expected paths" {
    try std.testing.expectEqual(@as(usize, 2), smoke_runner.countManifestEntries("# comment\narith.js\n\nvars.js\n"));
    var buffer: [128]u8 = undefined;
    const path = try smoke_runner.expectedPath(&buffer, "arith.js", ".out");
    try std.testing.expectEqualStrings("tests/zig-smoke/expected/arith.js.out", path);
}

test "test262 args parse QuickJS-shaped config and selectors" {
    const config = try test262_runner.parseArgs(&.{ "-c", "quickjs/test262.conf", "-m", "-t", "1", "quickjs/test262/test" });
    try std.testing.expectEqualStrings("quickjs/test262.conf", config.config_path.?);
    try std.testing.expect(config.module);
    try std.testing.expectEqual(@as(u32, 1), config.threads);
    try std.testing.expectEqualStrings("quickjs/test262/test", config.test_root.?);

    const selected = try test262_runner.parseArgs(&.{ "-d", "built-ins/Object", "-f", "language/types/null.js", "-e", "known.txt" });
    try std.testing.expectEqualStrings("built-ins/Object", selected.dirs.get(0));
    try std.testing.expectEqualStrings("language/types/null.js", selected.files.get(0));
    try std.testing.expectEqualStrings("known.txt", selected.known_error_file.?);
}

test "test262 args parse QuickJS index span" {
    const config = try test262_runner.parseArgs(&.{ "-c", "quickjs/test262.conf", "0", "20" });
    try std.testing.expectEqual(@as(?usize, 0), config.start_index);
    try std.testing.expectEqual(@as(?usize, 20), config.stop_index);
}

test "test262 config text parses paths features and excludes" {
    var loaded = try test262_runner.loadConfigText(std.testing.allocator, "quickjs",
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

    try std.testing.expectEqualStrings("quickjs/test262/test", loaded.testdir.?);
    try std.testing.expectEqualStrings("quickjs/test262/harness", loaded.harnessdir.?);
    try std.testing.expectEqualStrings("quickjs/test262_errors.txt", loaded.errorfile.?);
    try std.testing.expect(loaded.excludes.contains("quickjs/test262/test/intl402/foo.js"));
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
