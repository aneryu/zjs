//! Shared GC VERIFY/AUDIT stderr writer.
//!
//! Leftover `std.debug.print` instantiations for arena / doomed-reclaim /
//! block-heap audit lines share one label + unsigned-number walk. Call sites
//! keep the field mapping; this is not a format language. Not on `core/root`
//! or the public embedder API. CLI `writeCounterLine` stays CLI-only.

const std = @import("std");

pub const Part = union(enum) {
    text: []const u8,
    dec: u64,
    hex: u64,
};

/// Zig `{}` / `{any}` for `bool`.
pub inline fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

/// Same stderr lock and ignore-errors contract as `std.debug.print`.
pub fn print(parts: []const Part) void {
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    const writer = &stderr.file_writer.interface;
    write(writer, parts) catch return;
    writer.flush() catch return;
}

/// Writes leftover audit labels and unsigned numbers. `{d}` / `{x}` digits
/// match `std.fmt` (no prefix, no padding, no leading zeros except zero).
pub noinline fn write(writer: *std.Io.Writer, parts: []const Part) std.Io.Writer.Error!void {
    var dec_buf: [20]u8 = undefined;
    var hex_buf: [16]u8 = undefined;
    for (parts) |part| {
        switch (part) {
            .text => |text| try writer.writeAll(text),
            .dec => |value| try writer.writeAll(formatDec(value, &dec_buf)),
            .hex => |value| try writer.writeAll(formatHex(value, &hex_buf)),
        }
    }
}

fn formatDec(value: u64, buf: *[20]u8) []const u8 {
    var rest = value;
    var i: usize = buf.len;
    while (true) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(rest % 10));
        rest /= 10;
        if (rest == 0) break;
    }
    return buf[i..];
}

fn formatHex(value: u64, buf: *[16]u8) []const u8 {
    const digits = "0123456789abcdef";
    var rest = value;
    var i: usize = buf.len;
    while (true) {
        i -= 1;
        buf[i] = digits[@intCast(rest & 0xf)];
        rest >>= 4;
        if (rest == 0) break;
    }
    return buf[i..];
}
