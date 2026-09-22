//! Optional process memory samples. Unavailable and unlimited readings are null.
const std = @import("std");
const builtin = @import("builtin");
const value_format = @import("core/value_format.zig");

pub var process_memory_reads_for_test: if (builtin.is_test) usize else void =
    if (builtin.is_test) 0 else {};

pub fn currentRssBytes() ?usize {
    if (builtin.os.tag != .linux) return null;
    var buf: [128]u8 = undefined;
    const contents = readLinuxFile("/proc/self/statm", &buf) orelse return null;
    var tokens = std.mem.tokenizeAny(u8, contents, " \t\r\n");
    _ = tokens.next() orelse return null;
    const resident_pages = parseUnsignedToken(tokens.next() orelse return null) orelse return null;
    return std.math.mul(usize, resident_pages, std.heap.pageSize()) catch std.math.maxInt(usize);
}

pub fn cgroupLimitBytes() ?usize {
    if (builtin.os.tag != .linux) return null;
    var buf: [128]u8 = undefined;
    if (readLinuxFile("/sys/fs/cgroup/memory.max", &buf)) |contents| {
        if (parseUnsignedToken(firstToken(contents))) |limit| return limit;
    }
    if (readLinuxFile("/sys/fs/cgroup/memory/memory.limit_in_bytes", &buf)) |contents| {
        if (parseUnsignedToken(firstToken(contents))) |limit| return limit;
    }
    return null;
}

fn readLinuxFile(path: []const u8, buf: []u8) ?[]const u8 {
    if (comptime builtin.os.tag == .linux) {
        if (comptime builtin.is_test) process_memory_reads_for_test += 1;
        const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
        defer _ = std.os.linux.close(fd);
        const len = std.posix.read(fd, buf) catch return null;
        return buf[0..len];
    }
    return null;
}

fn firstToken(contents: []const u8) []const u8 {
    var tokens = std.mem.tokenizeAny(u8, contents, " \t\r\n");
    return tokens.next() orelse "";
}

fn parseUnsignedToken(token: []const u8) ?usize {
    if (token.len == 0 or std.mem.eql(u8, token, "max")) return null;
    return value_format.parseAsciiInt(usize, token, 10) catch null;
}
