//! Allocation trace sink. It is not a second heap ledger and it does not
//! walk memory. Account paths call it only when `enabled` is true, which is
//! test or Debug; ReleaseFast non-test stays silent even if a writer is set.
//!
//! `--trace` / `-T` lines stay:
//!   A <bytes> -> 0x<addr>.<bytes>
//!   F 0x<addr>
//! A writer error sets `failed` and later events are dropped. The allocation
//! itself is unchanged.
//!
//! Runtime allocation helpers and the Debug/test native adapter emit one
//! event each. The raw Runtime body has its own paired event. Production
//! native allocations bypass instrumentation entirely.

const std = @import("std");
const builtin = @import("builtin");

pub const enabled = builtin.is_test or builtin.mode == .Debug;

pub const Sink = struct {
    writer: ?*std.Io.Writer = null,
    failed: bool = false,
    profile_alloc_count: ?*u64 = null,

    pub fn recordAlloc(self: *Sink, bytes: usize, address: usize) void {
        if (self.profile_alloc_count) |counter| counter.* +|= 1;
        self.writeAlloc(bytes, address);
    }

    pub fn writeAlloc(self: *Sink, bytes: usize, address: usize) void {
        const writer = self.writer orelse return;
        if (self.failed) return;
        writer.print("A {d} -> 0x{x}.{d}\n", .{ bytes, address, bytes }) catch {
            self.failed = true;
        };
    }

    pub fn writeFree(self: *Sink, address: usize) void {
        const writer = self.writer orelse return;
        if (self.failed) return;
        writer.print("F 0x{x}\n", .{address}) catch {
            self.failed = true;
        };
    }
};

fn countNeedle(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        n += 1;
        rest = rest[index + needle.len ..];
    }
    return n;
}

test "trace sink records one alloc or free and ignores a null writer" {
    var ticks: u64 = 0;
    var silent = Sink{ .profile_alloc_count = &ticks };
    silent.recordAlloc(16, 0x20);
    silent.writeFree(0x20);
    try std.testing.expect(!silent.failed);
    try std.testing.expectEqual(@as(u64, 1), ticks);

    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var sink = Sink{ .writer = &writer, .profile_alloc_count = &ticks };
    sink.recordAlloc(16, 0xabc);
    sink.writeFree(0xabc);
    const text = writer.buffered();
    try std.testing.expectEqualStrings("A 16 -> 0xabc.16\nF 0xabc\n", text);
    try std.testing.expectEqual(@as(usize, 1), countNeedle(text, "A "));
    try std.testing.expectEqual(@as(usize, 1), countNeedle(text, "F "));
    try std.testing.expectEqual(@as(u64, 2), ticks);
}

test "trace sink remap lines do not tick the profile and a failed writer stops" {
    var ticks: u64 = 0;
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var sink = Sink{ .writer = &writer, .profile_alloc_count = &ticks };
    sink.writeFree(0x10);
    sink.writeAlloc(32, 0x40);
    try std.testing.expectEqual(@as(u64, 0), ticks);
    try std.testing.expectEqualStrings("F 0x10\nA 32 -> 0x40.32\n", writer.buffered());

    var tiny: [1]u8 = undefined;
    var failing = std.Io.Writer.fixed(&tiny);
    var stopped = Sink{ .writer = &failing, .profile_alloc_count = &ticks };
    stopped.recordAlloc(8, 0x1);
    try std.testing.expect(stopped.failed);
    try std.testing.expectEqual(@as(u64, 1), ticks);
    const stuck = failing.buffered().len;
    stopped.recordAlloc(8, 0x2);
    stopped.writeFree(0x2);
    try std.testing.expect(stopped.failed);
    try std.testing.expectEqual(@as(u64, 2), ticks);
    try std.testing.expectEqual(stuck, failing.buffered().len);
}
