//! Known-error file loading, path resolution, and serialization for run-test262.
const std = @import("std");
const runner_config = @import("run_test262_config.zig");
const NameList = @import("run_test262_names.zig").NameList;
pub fn load(allocator: std.mem.Allocator, io: std.Io, errorfile: ?[]const u8) !NameList {
    const path = errorfile orelse return NameList.init(allocator);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return NameList.init(allocator),
        else => return err,
    };
    defer allocator.free(bytes);
    return parseText(allocator, dirname(path), bytes);
}

pub fn parseText(allocator: std.mem.Allocator, base_dir: []const u8, text: []const u8) !NameList {
    var known = NameList.init(allocator);
    errdefer known.deinit();

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const entry = runner_config.stripComment(std.mem.trim(u8, line, " \t\r"));
        if (entry.len == 0) continue;
        try known.appendOwned(try normalizePath(allocator, base_dir, entryPath(entry)));
    }
    known.sortAndDedupe();
    return known;
}

pub fn write(allocator: std.mem.Allocator, io: std.Io, errorfile: []const u8, failures: NameList) !void {
    const rendered = try renderText(allocator, failures, dirname(errorfile));
    defer allocator.free(rendered);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = errorfile, .data = rendered });
}

pub fn mergeForUpdate(allocator: std.mem.Allocator, known_failures: NameList, selected_tests: NameList, current_failures: NameList) !NameList {
    var merged = NameList.init(allocator);
    errdefer merged.deinit();

    for (current_failures.items) |test_path| try merged.append(test_path);
    for (known_failures.items) |test_path| {
        if (!selected_tests.contains(test_path)) try merged.append(test_path);
    }
    merged.sortAndDedupe();
    return merged;
}

pub fn renderText(allocator: std.mem.Allocator, failures: NameList, base_dir: []const u8) ![]u8 {
    var stable = NameList.init(allocator);
    defer stable.deinit();
    for (failures.items) |test_path| try stable.append(test_path);
    stable.sortAndDedupe();

    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    for (stable.items) |test_path| {
        try buffer.appendSlice(allocator, pathRelativeToBase(base_dir, test_path));
        try buffer.append(allocator, '\n');
    }
    return buffer.toOwnedSlice(allocator);
}

fn dirname(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse "";
}

fn entryPath(line: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, line, ':')) |colon| return std.mem.trim(u8, line[0..colon], " \t");
    return line;
}

fn normalizePath(allocator: std.mem.Allocator, base_dir: []const u8, path: []const u8) ![]const u8 {
    if (base_dir.len == 0 or std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    if (std.mem.eql(u8, path, base_dir)) return allocator.dupe(u8, path);
    if (std.mem.startsWith(u8, path, base_dir) and path.len > base_dir.len and path[base_dir.len] == '/') {
        return allocator.dupe(u8, path);
    }
    return std.fs.path.join(allocator, &.{ base_dir, path });
}

fn pathRelativeToBase(base_dir: []const u8, path: []const u8) []const u8 {
    if (base_dir.len == 0) return path;
    if (std.mem.startsWith(u8, path, base_dir) and path.len > base_dir.len and path[base_dir.len] == '/') {
        return path[base_dir.len + 1 ..];
    }
    return path;
}
