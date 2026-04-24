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

    try printError(
        io,
        "run-test262: execution is not implemented yet; parsed {d} selected target(s)\n",
        .{config.selectedCount()},
    );
    std.process.exit(1);
}

fn argsToSlice(arena: std.mem.Allocator, args: std.process.Args) ![]const []const u8 {
    const raw_args = try args.toSlice(arena);
    const result = try arena.alloc([]const u8, raw_args.len);
    for (raw_args, 0..) |arg, i| result[i] = arg;
    return result;
}

fn printUsage(io: std.Io) !void {
    try printError(io, "usage: run-test262 -c <test262.conf> [options] <test-root>\n", .{});
}

fn printError(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    try stderr.print(fmt, args);
    try stderr.flush();
}
