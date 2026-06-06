const std = @import("std");
const zjs = @import("zjs");

const SnapshotPath = "reports/api/public-symbols.txt";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    defer args.deinit();
    _ = args.next();

    var write_snapshot = false;
    var snapshot_path: []const u8 = SnapshotPath;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--write")) {
            write_snapshot = true;
        } else {
            snapshot_path = arg;
        }
    }

    var actual = std.ArrayList([]const u8).empty;
    defer {
        for (actual.items) |item| allocator.free(item);
        actual.deinit(allocator);
    }

    try appendNamespaceDecls(allocator, &actual, zjs, "zjs.");
    try appendNamespaceDecls(allocator, &actual, zjs.kernel, "zjs.kernel.");
    try appendNamespaceDecls(allocator, &actual, zjs.runtime, "zjs.runtime.");
    try appendSelectedJSValueDecls(allocator, &actual);
    sortUnique(actual.items);

    if (write_snapshot) {
        try writeSnapshot(init.io, snapshot_path, actual.items);
        return;
    }

    const expected = try readSnapshot(init.io, allocator, snapshot_path);
    defer {
        for (expected) |item| allocator.free(item);
        allocator.free(expected);
    }

    if (equalStringSlices(expected, actual.items)) {
        var stdout_buffer: [256]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
        const stdout = &stdout_writer.interface;
        try stdout.print("public API snapshot ok ({d} symbols)\n", .{actual.items.len});
        try stdout.flush();
        return;
    }

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    try stderr.print("public API snapshot mismatch: {s}\n", .{snapshot_path});
    try printDiff(stderr, expected, actual.items);
    try stderr.flush();
    std.process.exit(1);
}

fn appendNamespaceDecls(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    comptime Namespace: type,
    comptime prefix: []const u8,
) !void {
    inline for (@typeInfo(Namespace).@"struct".decls) |decl| {
        try out.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, decl.name }));
    }
}

fn appendSelectedJSValueDecls(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    const names = [_][]const u8{ "Scope", "Local", "Persistent", "Weak" };
    inline for (names) |name| {
        if (@hasDecl(zjs.JSValue, name)) {
            try out.append(allocator, try std.fmt.allocPrint(allocator, "zjs.JSValue.{s}", .{name}));
        }
    }
}

fn readSnapshot(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(raw);

    var lines = std.ArrayList([]const u8).empty;
    errdefer {
        for (lines.items) |item| allocator.free(item);
        lines.deinit(allocator);
    }

    var iter = std.mem.splitScalar(u8, raw, '\n');
    while (iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        try lines.append(allocator, try allocator.dupe(u8, line));
    }

    sortUnique(lines.items);
    return try lines.toOwnedSlice(allocator);
}

fn writeSnapshot(io: std.Io, path: []const u8, symbols: []const []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const out = &writer.interface;
    try out.writeAll(
        \\# zjs public API symbol snapshot
        \\#
        \\# This file is checked by `zig build architecture-check`.
        \\# It freezes the public declaration surface exposed through src/root.zig,
        \\# zjs.kernel, zjs.runtime, and the selected JSValue lifetime aliases.
        \\
    );
    for (symbols) |symbol| {
        try out.print("{s}\n", .{symbol});
    }
    try out.flush();
}

fn sortUnique(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, lessThanString);
    var write_index: usize = 0;
    var read_index: usize = 0;
    while (read_index < items.len) : (read_index += 1) {
        if (write_index != 0 and std.mem.eql(u8, items[write_index - 1], items[read_index])) continue;
        items[write_index] = items[read_index];
        write_index += 1;
    }
    if (write_index != items.len) {
        @panic("duplicate public API symbol generated; update checker to avoid duplicate aliases");
    }
}

fn lessThanString(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn equalStringSlices(lhs: []const []const u8, rhs: []const []const u8) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

fn printDiff(stderr: *std.Io.Writer, expected: []const []const u8, actual: []const []const u8) !void {
    var expected_index: usize = 0;
    var actual_index: usize = 0;
    while (expected_index < expected.len or actual_index < actual.len) {
        if (expected_index >= expected.len) {
            try stderr.print("  + {s}\n", .{actual[actual_index]});
            actual_index += 1;
            continue;
        }
        if (actual_index >= actual.len) {
            try stderr.print("  - {s}\n", .{expected[expected_index]});
            expected_index += 1;
            continue;
        }
        const left = expected[expected_index];
        const right = actual[actual_index];
        if (std.mem.eql(u8, left, right)) {
            expected_index += 1;
            actual_index += 1;
        } else if (std.mem.lessThan(u8, left, right)) {
            try stderr.print("  - {s}\n", .{left});
            expected_index += 1;
        } else {
            try stderr.print("  + {s}\n", .{right});
            actual_index += 1;
        }
    }
}
