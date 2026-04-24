const unicode = @import("../libs/unicode.zig");

pub fn charAt(bytes: []const u8, index: usize) []const u8 {
    if (index >= bytes.len) return "";
    return bytes[index .. index + 1];
}

pub fn toUpperAscii(buf: []u8, bytes: []const u8) []u8 {
    const n = @min(buf.len, bytes.len);
    for (bytes[0..n], 0..) |byte, i| buf[i] = unicode.toUpperAscii(byte);
    return buf[0..n];
}
