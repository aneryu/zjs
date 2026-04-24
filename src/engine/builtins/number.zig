const dtoa = @import("../libs/dtoa.zig");

pub fn parseFloat(bytes: []const u8) !f64 {
    return dtoa.parseNumber(bytes);
}

pub fn toString(buf: []u8, value: f64) ![]const u8 {
    return dtoa.formatNumber(buf, value);
}
