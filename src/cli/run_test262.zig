const std = @import("std");
const runner = @import("test262_runner");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try argsToSlice(arena, init.minimal.args);

    var config = runner.parseArgs(args[1..]) catch |err| {
        try printError(io, "run-test262: {s}\n", .{@errorName(err)});
        try printUsage(io);
        std.process.exit(2);
    };

    // Auto-enable external-engine mode when the user did not pass --engine.
    // Prefer the ReleaseFast test262 engine installed by `zig build
    // run-test262`; fall back to the developer `zjs` binary if it exists.
    // Running each test as a fresh subprocess prevents a single crashing or
    // infinite-looping test from hanging or killing the entire run.
    if (config.engine_path == null) {
        if (std.Io.Dir.cwd().access(io, "zig-out/bin/zjs-test262", .{})) |_| {
            config.engine_path = "zig-out/bin/zjs-test262";
        } else |_| if (std.Io.Dir.cwd().access(io, "zig-out/bin/zjs", .{})) |_| {
            config.engine_path = "zig-out/bin/zjs";
        } else |_| {}
    }
    if (config.timeout_ms == null) {
        // 20 seconds per test caps wall-time impact of stuck tests while
        // leaving room for exhaustive URI UTF-8 and legacy regexp literal
        // sweeps. Override with `-T <ms>`.
        config.timeout_ms = 20_000;
    }

    var summary = runner.runSelectedTests(init.gpa, io, config, "zig-out/bin/zjs-test262") catch |err| {
        try printError(io, "run-test262: unable to run tests: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer summary.deinit(init.gpa);

    try printSummary(io, summary);
    const baseline_gate = config.regression_baseline != null;
    const has_unexpected = !baseline_gate and (summary.failed != 0 or summary.fixed != 0);
    const has_regression = summary.regressions != 0;
    std.process.exit(if (has_unexpected or has_regression) 1 else 0);
}

fn argsToSlice(arena: std.mem.Allocator, args: std.process.Args) ![]const []const u8 {
    const raw_args = try args.toSlice(arena);
    const result = try arena.alloc([]const u8, raw_args.len);
    for (raw_args, 0..) |arg, i| result[i] = arg;
    return result;
}

fn printUsage(io: std.Io) !void {
    try printError(
        io,
        "usage: run-test262 -c <test262.conf> [options] [test-root] [start [stop]]\n" ++
            "  -d <dir>                 add a test directory selector\n" ++
            "  -f <file>                add a single test file selector\n" ++
            "  -e <file>                use a known-errors file\n" ++
            "  -u                       update the known-errors file from failures\n" ++
            "  -m                       run selected tests as modules\n" ++
            "  -t <n>                   run up to <n> tests in parallel\n" ++
            "  -T <ms>                  per-test timeout in milliseconds\n" ++
            "  -R <dir>                 emit test262-failures.log, test262-buckets.json,\n" ++
            "                           test262-by-dir.json, and\n" ++
            "                           test262-skipped-features.json under <dir>\n" ++
            "  --engine <path>          run prepared tests with an external qjs-compatible\n" ++
            "                           binary instead of the embedded zjs engine\n" ++
            "  --no-batch              disable zjs-test262 batch worker reuse\n" ++
            "  --regression-baseline F  exit non-zero if any directory's `passed`\n" ++
            "                           count is lower than F (a previous by-dir.json)\n" ++
            "  --enable-feature <name> temporarily enable a config-skipped feature\n" ++
            "  --skip-feature <name>   temporarily skip a config-enabled feature\n",
        .{},
    );
}

fn printError(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    try stderr.print(fmt, args);
    try stderr.flush();
}

fn printSummary(io: std.Io, summary: runner.ExecutionSummary) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "run-test262: prepared {d}/{d} tests",
        .{ summary.selection.selected_tests, summary.selection.total_tests },
    );
    if (summary.selection.excluded_tests != 0) try stdout.print(", {d} excluded", .{summary.selection.excluded_tests});
    if (summary.selection.skipped_by_feature != 0) try stdout.print(", {d} skipped by feature", .{summary.selection.skipped_by_feature});
    if (summary.selection.skipped_by_index != 0) try stdout.print(", {d} skipped by index", .{summary.selection.skipped_by_index});
    try stdout.print("\n", .{});
    if (summary.selection.harnessdir) |harnessdir| try stdout.print("harness: {s}\n", .{harnessdir});
    if (summary.selection.errorfile) |errorfile| try stdout.print("known errors: {s}\n", .{errorfile});
    try stdout.print("Result: {d}/{d} errors, passed {d}", .{ summary.failed, summary.selection.selected_tests, summary.passed });
    if (summary.known_failures != 0) try stdout.print(", known {d}", .{summary.known_failures});
    if (summary.fixed != 0) try stdout.print(", fixed {d}", .{summary.fixed});
    if (summary.regressions != 0) try stdout.print(", regressed {d}", .{summary.regressions});
    try stdout.print("\n", .{});
    try stdout.flush();
}
