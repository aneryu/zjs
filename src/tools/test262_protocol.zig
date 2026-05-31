const std = @import("std");

pub const mode_script: u8 = 0;
pub const mode_module: u8 = 1;

pub const status_passed: u8 = 0;
pub const status_failed: u8 = 1;
pub const status_timeout: u8 = 2;

pub const request_flag_can_block: u8 = 1 << 0;

pub const RequestHeader = extern struct {
    source_len: u32,
    path_len: u16,
    mode: u8,
    flags: u8 = 0,
    timeout_ms: u32,
};

pub const ResponseHeader = extern struct {
    stderr_len: u16,
    status: u8,
    reserved: u8 = 0,
};

pub fn modeName(mode: u8) []const u8 {
    return switch (mode) {
        mode_script => "script",
        mode_module => "module",
        else => "unknown",
    };
}

test "test262 protocol headers stay compact and explicit" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(RequestHeader));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(ResponseHeader));
}
