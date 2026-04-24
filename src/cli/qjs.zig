const std = @import("std");
const engine = @import("quickjs_zig_engine");

const max_source_size = 64 * 1024 * 1024;

pub const CliError = error{
    Usage,
};

pub const Command = union(enum) {
    eval: []const u8,
    file: []const u8,
};

pub fn parseArgs(args: []const []const u8) CliError!Command {
    if (args.len == 0) return error.Usage;
    if (std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help")) return error.Usage;
    if (std.mem.eql(u8, args[0], "-e")) {
        if (args.len != 2) return error.Usage;
        return .{ .eval = args[1] };
    }
    if (args.len == 1 and args[0].len != 0 and args[0][0] != '-') return .{ .file = args[0] };
    return error.Usage;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try argsToSlice(arena, init.minimal.args);

    const command = parseArgs(args[1..]) catch {
        try printUsage(io);
        std.process.exit(2);
    };

    const source_text = switch (command) {
        .eval => |source| source,
        .file => |path| std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_source_size)) catch |err| {
            try printError(io, "zjs: unable to read {s}: {s}\n", .{ path, @errorName(err) });
            std.process.exit(1);
        },
    };
    defer if (command == .file) allocator.free(source_text);

    var runtime = engine.Engine.init(allocator) catch |err| {
        try printError(io, "zjs: engine init failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer runtime.deinit();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const value = runtime.evalWithOutput(source_text, &stdout_writer.interface) catch |err| {
        try printError(io, "zjs: evaluation failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    try stdout_writer.interface.flush();
    defer value.free(runtime.runtime);

    if (value.isException()) {
        try printError(io, "zjs: uncaught exception\n", .{});
        std.process.exit(1);
    }

    runtime.runJobs();
}

fn argsToSlice(arena: std.mem.Allocator, args: std.process.Args) ![]const []const u8 {
    const raw_args = try args.toSlice(arena);
    const result = try arena.alloc([]const u8, raw_args.len);
    for (raw_args, 0..) |arg, i| result[i] = arg;
    return result;
}

fn printUsage(io: std.Io) !void {
    try printError(io, "usage: zjs -e <script>\n       zjs <file.js>\n", .{});
}

fn printError(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    try stderr.print(fmt, args);
    try stderr.flush();
}

test "qjs args accept eval source" {
    const command = try parseArgs(&.{ "-e", "1" });
    try std.testing.expectEqualStrings("1", command.eval);
}

test "qjs args accept one file" {
    const command = try parseArgs(&.{"input.js"});
    try std.testing.expectEqualStrings("input.js", command.file);
}

test "qjs args reject missing source" {
    try std.testing.expectError(error.Usage, parseArgs(&.{"-e"}));
    try std.testing.expectError(error.Usage, parseArgs(&.{}));
}
