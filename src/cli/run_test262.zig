const std = @import("std");
const runner = @import("test262_runner");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try argsToSlice(arena, init.minimal.args);

    const config = runner.parseArgs(args[1..]) catch |err| {
        try printError(io, "run-test262: {s}\n", .{@errorName(err)});
        try printUsage(io);
        std.process.exit(2);
    };

    var summary = runner.runSelectedTests(init.gpa, io, config, "zig-out/bin/zjs") catch |err| {
        try printError(io, "run-test262: unable to run tests: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer summary.deinit(init.gpa);

    try printSummary(io, summary);
    const has_unexpected = summary.failed != 0 or summary.fixed != 0;
    std.process.exit(if (has_unexpected) 1 else 0);
}

fn argsToSlice(arena: std.mem.Allocator, args: std.process.Args) ![]const []const u8 {
    const raw_args = try args.toSlice(arena);
    const result = try arena.alloc([]const u8, raw_args.len);
    for (raw_args, 0..) |arg, i| result[i] = arg;
    return result;
}

fn printUsage(io: std.Io) !void {
    try printError(io,
        "usage: run-test262 -c <test262.conf> [options] <test-root>\n" ++
        "  -R <dir>  emit test262-failures.log, test262-buckets.json,\n" ++
        "            and test262-by-dir.json under <dir>\n",
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
    try stdout.print("\n", .{});
    try stdout.flush();
}
