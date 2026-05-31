const std = @import("std");

const max_file_size = 1024 * 1024;
const smoke_root = "tests/zig-smoke";
const expected_root = "tests/zig-smoke/expected";

pub const ManifestEntry = struct {
    script: []const u8,
};

pub fn countManifestEntries(manifest: []const u8) usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, manifest, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        count += 1;
    }
    return count;
}

pub fn expectedPath(buffer: []u8, script: []const u8, suffix: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}/{s}{s}", .{ expected_root, script, suffix });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try argsToSlice(arena, init.minimal.args);

    if (args.len != 3) {
        try printError(io, "usage: smoke-runner <zjs-path> <manifest>\n", .{});
        std.process.exit(2);
    }

    const zjs_path = args[1];
    const manifest_path = args[2];
    const manifest = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(max_file_size)) catch |err| {
        try printError(io, "smoke: unable to read {s}: {s}\n", .{ manifest_path, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(manifest);

    var failures: usize = 0;
    var total: usize = 0;
    var it = std.mem.splitScalar(u8, manifest, '\n');
    while (it.next()) |line| {
        const script = std.mem.trim(u8, line, " \t\r");
        if (script.len == 0 or script[0] == '#') continue;
        total += 1;
        if (!try runOne(io, allocator, zjs_path, script)) failures += 1;
    }

    if (failures != 0) {
        try printError(io, "smoke: {d}/{d} scripts failed\n", .{ failures, total });
        std.process.exit(1);
    }
    try printOut(io, "smoke: {d}/{d} scripts passed\n", .{ total, total });
}

fn runOne(io: std.Io, allocator: std.mem.Allocator, zjs_path: []const u8, script: []const u8) !bool {
    var script_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const script_path = try std.fmt.bufPrint(&script_path_buf, "{s}/{s}", .{ smoke_root, script });
    const argv = [_][]const u8{ zjs_path, script_path };
    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(max_file_size),
        .stderr_limit = .limited(max_file_size),
    }) catch |err| {
        try printError(io, "smoke: {s}: spawn failed: {s}\n", .{ script, @errorName(err) });
        return false;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const actual_status: u8 = switch (result.term) {
        .exited => |code| code,
        else => 255,
    };
    const expected_status = try readExpectedStatus(io, allocator, script);
    const expected_stdout = try readExpectedOptional(io, allocator, script, ".out");
    defer if (expected_stdout) |bytes| allocator.free(bytes);
    const expected_stderr = try readExpectedOptional(io, allocator, script, ".err");
    defer if (expected_stderr) |bytes| allocator.free(bytes);

    var ok = actual_status == expected_status;
    if (expected_stdout) |bytes| {
        var normalized_stdout = result.stdout;
        var allocated_stdout: ?[]u8 = null;
        defer if (allocated_stdout) |b| allocator.free(b);
        if (std.mem.eql(u8, script, "script_args.js")) {
            const count = std.mem.count(u8, result.stdout, zjs_path);
            if (count > 0) {
                const new_len = result.stdout.len - count * zjs_path.len + count * 15;
                allocated_stdout = try allocator.alloc(u8, new_len);
                _ = std.mem.replace(u8, result.stdout, zjs_path, "zig-out/bin/zjs", allocated_stdout.?);
                normalized_stdout = allocated_stdout.?;
            }
        }
        ok = ok and std.mem.eql(u8, bytes, normalized_stdout);
    } else {
        ok = ok and result.stdout.len == 0;
    }
    if (expected_stderr) |bytes| ok = ok and std.mem.eql(u8, bytes, result.stderr) else ok = ok and result.stderr.len == 0;
    if (!ok) {
        try printError(io, "smoke: {s}: expected status {d}, got {d}; stdout {d} bytes, stderr {d} bytes\n", .{
            script,
            expected_status,
            actual_status,
            result.stdout.len,
            result.stderr.len,
        });
    }
    return ok;
}

fn readExpectedStatus(io: std.Io, allocator: std.mem.Allocator, script: []const u8) !u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try expectedPath(&path_buf, script, ".status");
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64)) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer allocator.free(bytes);
    return std.fmt.parseInt(u8, std.mem.trim(u8, bytes, " \t\r\n"), 10) catch 1;
}

fn readExpectedOptional(io: std.Io, allocator: std.mem.Allocator, script: []const u8, suffix: []const u8) !?[]u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try expectedPath(&path_buf, script, suffix);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_size)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
}

fn argsToSlice(arena: std.mem.Allocator, args: std.process.Args) ![]const []const u8 {
    const raw_args = try args.toSlice(arena);
    const result = try arena.alloc([]const u8, raw_args.len);
    for (raw_args, 0..) |arg, i| result[i] = arg;
    return result;
}

fn printOut(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    try stdout.print(fmt, args);
    try stdout.flush();
}

fn printError(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    try stderr.print(fmt, args);
    try stderr.flush();
}

test "manifest entries ignore comments and blanks" {
    try std.testing.expectEqual(@as(usize, 2), countManifestEntries("# comment\narith.js\n\nvars.js\n"));
}

test "expected path uses smoke expected directory" {
    var buffer: [128]u8 = undefined;
    const path = try expectedPath(&buffer, "arith.js", ".out");
    try std.testing.expectEqualStrings("tests/zig-smoke/expected/arith.js.out", path);
}
