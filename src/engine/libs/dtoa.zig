pub fn parseNumber(bytes: []const u8) !f64 {
    if (std.mem.eql(u8, bytes, "Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, bytes, "+Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, bytes, "-Infinity")) return -std.math.inf(f64);
    if (std.mem.eql(u8, bytes, "NaN")) return std.math.nan(f64);
    return std.fmt.parseFloat(f64, bytes);
}

pub fn formatNumber(buf: []u8, value: f64) ![]const u8 {
    if (std.math.isNan(value)) return "NaN";
    if (std.math.isPositiveInf(value)) return "Infinity";
    if (std.math.isNegativeInf(value)) return "-Infinity";
    return std.fmt.bufPrint(buf, "{d}", .{value});
}

const std = @import("std");
