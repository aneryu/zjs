pub fn stringifyInt(buf: []u8, value: i32) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{value});
}

pub fn parseInt(bytes: []const u8) !i32 {
    return std.fmt.parseInt(i32, bytes, 10);
}

const std = @import("std");
