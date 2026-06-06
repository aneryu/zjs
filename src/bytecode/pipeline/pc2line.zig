//! Phase 3b: compute_pc2line_info
//!
//! Mirrors `compute_pc2line_info` at `quickjs.c:33995`.
//!
//! Encodes a sequence of (pc, line, col) source-location slots into a
//! compact buffer, mirroring QuickJS's pc2line format byte-for-byte.
//!
//! ## Encoding
//!
//! For each transition from the previous (last_pc, last_line, last_col)
//! to (pc, line, col):
//!
//!   diff_pc   = pc   - last_pc       (must be >= 0)
//!   diff_line = line - last_line
//!   diff_col  = col  - last_col
//!
//! If `diff_pc < 0` or `(diff_line == 0 and diff_col == 0)` — skip.
//!
//! Compact form (single byte + sleb128 col), when both:
//!   - PC2LINE_BASE <= diff_line < PC2LINE_BASE + PC2LINE_RANGE
//!   - diff_pc <= PC2LINE_DIFF_PC_MAX
//!
//!   byte = (diff_line - PC2LINE_BASE) + diff_pc * PC2LINE_RANGE + PC2LINE_OP_FIRST
//!   followed by sleb128(diff_col)
//!
//! Long form (marker 0 + leb128 pc + sleb128 line + sleb128 col):
//!   byte = 0
//!   leb128(diff_pc)
//!   sleb128(diff_line)
//!   sleb128(diff_col)

const std = @import("std");
const memory = @import("../../core/memory.zig");

/// PC2LINE encoding constants (mirror `quickjs.c:756`).
pub const PC2LINE_BASE: i32 = -1;
pub const PC2LINE_RANGE: i32 = 5;
pub const PC2LINE_OP_FIRST: i32 = 1;
pub const PC2LINE_DIFF_PC_MAX: i32 = (255 - PC2LINE_OP_FIRST) / PC2LINE_RANGE; // = 50

/// One source-location slot — mirrors `SourceLocSlot` (`quickjs.c:21395`).
pub const SourceLocSlot = struct {
    pc: u32,
    line_num: i32,
    col_num: i32,
};

/// Encoded pc2line buffer plus the (line, col) at pc=0 needed for decoding.
pub const Encoded = struct {
    bytes: []u8,
    line_num: i32,
    col_num: i32,
    memory: *memory.MemoryAccount,

    pub fn deinit(self: *Encoded) void {
        const bytes = self.bytes;
        self.bytes = &.{};
        if (bytes.len != 0) self.memory.free(u8, bytes);
    }
};

/// Encode a sequence of source-location slots into a pc2line buffer.
///
/// `start_line_num` and `start_col_num` are the function's starting
/// position (used as the implicit pc=0 reference, matching QuickJS's
/// `s->line_num` / `s->col_num`).
pub fn encode(
    account: *memory.MemoryAccount,
    slots: []const SourceLocSlot,
    start_line_num: i32,
    start_col_num: i32,
) !Encoded {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(account.allocator);

    var last_line_num: i32 = start_line_num;
    var last_col_num: i32 = start_col_num;
    var last_pc: u32 = 0;

    for (slots) |slot| {
        if (slot.line_num < 0) continue;
        if (slot.pc < last_pc) continue;

        const diff_pc: i32 = @intCast(slot.pc - last_pc);
        const diff_line: i32 = slot.line_num - last_line_num;
        const diff_col: i32 = slot.col_num - last_col_num;
        if (diff_line == 0 and diff_col == 0) continue;

        if (diff_line >= PC2LINE_BASE and
            diff_line < PC2LINE_BASE + PC2LINE_RANGE and
            diff_pc <= PC2LINE_DIFF_PC_MAX)
        {
            const byte: u8 = @intCast(
                (diff_line - PC2LINE_BASE) + diff_pc * PC2LINE_RANGE + PC2LINE_OP_FIRST,
            );
            try buf.append(account.allocator, byte);
        } else {
            try buf.append(account.allocator, 0);
            try putLeb128(&buf, account.allocator, @intCast(diff_pc));
            try putSleb128(&buf, account.allocator, diff_line);
        }
        try putSleb128(&buf, account.allocator, diff_col);

        last_pc = slot.pc;
        last_line_num = slot.line_num;
        last_col_num = slot.col_num;
    }

    const owned: []u8 = if (buf.items.len == 0) &.{} else blk: {
        const bytes = try account.alloc(u8, buf.items.len);
        @memcpy(bytes, buf.items);
        break :blk bytes;
    };
    return .{
        .bytes = owned,
        .line_num = start_line_num,
        .col_num = start_col_num,
        .memory = account,
    };
}

/// Decode the pc2line buffer back into a sequence of (pc, line, col).
/// Inverse of `encode`. Used by tests and by the runtime when reporting
/// source positions for stack traces.
pub fn decode(
    allocator: std.mem.Allocator,
    encoded: Encoded,
) ![]SourceLocSlot {
    var slots: std.ArrayList(SourceLocSlot) = .empty;
    defer slots.deinit(allocator);

    var pc: u32 = 0;
    var line_num: i32 = encoded.line_num;
    var col_num: i32 = encoded.col_num;
    var i: usize = 0;
    while (i < encoded.bytes.len) {
        const op = encoded.bytes[i];
        i += 1;
        if (op == 0) {
            const diff_pc = try readLeb128(encoded.bytes, &i);
            const diff_line = try readSleb128(encoded.bytes, &i);
            pc += @intCast(diff_pc);
            line_num += diff_line;
        } else {
            const adjusted: i32 = @as(i32, op) - PC2LINE_OP_FIRST;
            const diff_pc: i32 = @divFloor(adjusted, PC2LINE_RANGE);
            const diff_line: i32 = @mod(adjusted, PC2LINE_RANGE) + PC2LINE_BASE;
            pc += @intCast(diff_pc);
            line_num += diff_line;
        }
        const diff_col = try readSleb128(encoded.bytes, &i);
        col_num += diff_col;

        try slots.append(allocator, .{
            .pc = pc,
            .line_num = line_num,
            .col_num = col_num,
        });
    }
    return slots.toOwnedSlice(allocator);
}

// ---- LEB128 helpers ----

fn putLeb128(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var v = value;
    while (true) {
        const byte: u8 = @intCast(v & 0x7f);
        v >>= 7;
        if (v == 0) {
            try buf.append(allocator, byte);
            return;
        }
        try buf.append(allocator, byte | 0x80);
    }
}

fn putSleb128(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i32) !void {
    var v = value;
    while (true) {
        const byte: u8 = @intCast(@as(u32, @bitCast(v)) & 0x7f);
        // Arithmetic right shift: preserve sign bit.
        v >>= 7;
        // Done when v is fully sign-extended and the sign bit of the
        // last 7-bit group matches (so the consumer reconstructs the
        // sign correctly).
        const sign_bit = (byte & 0x40) != 0;
        if ((v == 0 and !sign_bit) or (v == -1 and sign_bit)) {
            try buf.append(allocator, byte);
            return;
        }
        try buf.append(allocator, byte | 0x80);
    }
}

fn readLeb128(bytes: []const u8, i: *usize) !u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    while (true) {
        if (i.* >= bytes.len) return error.Pc2LineTruncated;
        const byte = bytes[i.*];
        i.* += 1;
        result |= @as(u32, byte & 0x7f) << shift;
        if ((byte & 0x80) == 0) return result;
        shift += 7;
        if (shift >= 32) return error.Pc2LineOverflow;
    }
}

fn readSleb128(bytes: []const u8, i: *usize) !i32 {
    var result: i32 = 0;
    var shift: u5 = 0;
    while (true) {
        if (i.* >= bytes.len) return error.Pc2LineTruncated;
        const byte = bytes[i.*];
        i.* += 1;
        result |= @as(i32, @intCast(byte & 0x7f)) << shift;
        shift += 7;
        if ((byte & 0x80) == 0) {
            // Sign-extend if the highest data bit of the final group is set.
            if (shift < 32 and (byte & 0x40) != 0) {
                result |= @as(i32, -1) << shift;
            }
            return result;
        }
        if (shift >= 32) return error.Pc2LineOverflow;
    }
}

test "pc2line: empty slot list produces empty buffer" {
    var account = memory.MemoryAccount.init(std.testing.allocator);
    var encoded = try encode(&account, &.{}, 1, 0);
    defer encoded.deinit();
    try std.testing.expectEqual(@as(usize, 0), encoded.bytes.len);
}

test "pc2line: compact encoding for small line/pc deltas" {
    var account = memory.MemoryAccount.init(std.testing.allocator);
    // Two slots: same line, small pc delta. Compact form is one byte
    // (line/pc compact) plus a sleb128 col diff.
    const slots = [_]SourceLocSlot{
        .{ .pc = 0, .line_num = 1, .col_num = 1 },
        .{ .pc = 5, .line_num = 1, .col_num = 4 },
    };
    var encoded = try encode(&account, &slots, 1, 1);
    defer encoded.deinit();

    // First slot has diff_pc=0, diff_line=0, diff_col=0 from start (1,1) → skipped.
    // Second slot has diff_pc=5, diff_line=0, diff_col=3 from previous.
    // Compact byte = (0 - (-1)) + 5*5 + 1 = 1 + 25 + 1 = 27, then sleb128(3) = 0x03.
    try std.testing.expectEqual(@as(usize, 2), encoded.bytes.len);
    try std.testing.expectEqual(@as(u8, 27), encoded.bytes[0]);
    try std.testing.expectEqual(@as(u8, 3), encoded.bytes[1]);
}

test "pc2line: long encoding for large pc delta" {
    var account = memory.MemoryAccount.init(std.testing.allocator);
    const slots = [_]SourceLocSlot{
        .{ .pc = 100, .line_num = 2, .col_num = 1 },
    };
    var encoded = try encode(&account, &slots, 1, 1);
    defer encoded.deinit();

    // diff_pc=100 > MAX(50) → long form: 0, leb128(100), sleb128(1), sleb128(0).
    try std.testing.expectEqual(@as(usize, 4), encoded.bytes.len);
    try std.testing.expectEqual(@as(u8, 0), encoded.bytes[0]);
    try std.testing.expectEqual(@as(u8, 100), encoded.bytes[1]);
    try std.testing.expectEqual(@as(u8, 1), encoded.bytes[2]); // sleb128(1) for diff_line
    try std.testing.expectEqual(@as(u8, 0), encoded.bytes[3]); // sleb128(0) for diff_col
}

test "pc2line: encode/decode round-trip" {
    var account = memory.MemoryAccount.init(std.testing.allocator);
    const input_slots = [_]SourceLocSlot{
        .{ .pc = 5, .line_num = 1, .col_num = 4 },
        .{ .pc = 10, .line_num = 2, .col_num = 1 },
        .{ .pc = 200, .line_num = 5, .col_num = 12 },
        .{ .pc = 250, .line_num = 5, .col_num = 25 },
    };
    var encoded = try encode(&account, &input_slots, 1, 1);
    defer encoded.deinit();

    const decoded = try decode(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqual(input_slots.len, decoded.len);
    for (input_slots, decoded) |expected, actual| {
        try std.testing.expectEqual(expected.pc, actual.pc);
        try std.testing.expectEqual(expected.line_num, actual.line_num);
        try std.testing.expectEqual(expected.col_num, actual.col_num);
    }
}

test "pc2line: skips slots with no real change or backward pc" {
    var account = memory.MemoryAccount.init(std.testing.allocator);
    const slots = [_]SourceLocSlot{
        .{ .pc = 10, .line_num = 1, .col_num = 5 },
        .{ .pc = 10, .line_num = 1, .col_num = 5 }, // duplicate → skipped
        .{ .pc = 5, .line_num = 1, .col_num = 5 }, // backward pc → skipped
        .{ .pc = 15, .line_num = -1, .col_num = 5 }, // line < 0 → skipped
        .{ .pc = 20, .line_num = 1, .col_num = 8 }, // valid
    };
    var encoded = try encode(&account, &slots, 1, 1);
    defer encoded.deinit();

    const decoded = try decode(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqual(@as(usize, 2), decoded.len);
    try std.testing.expectEqual(@as(u32, 10), decoded[0].pc);
    try std.testing.expectEqual(@as(u32, 20), decoded[1].pc);
}

test "pc2line: negative line delta encoded compactly" {
    var account = memory.MemoryAccount.init(std.testing.allocator);
    const slots = [_]SourceLocSlot{
        .{ .pc = 5, .line_num = 5, .col_num = 1 },
        .{ .pc = 10, .line_num = 4, .col_num = 1 }, // diff_line = -1, in compact range
    };
    var encoded = try encode(&account, &slots, 1, 1);
    defer encoded.deinit();

    const decoded = try decode(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqual(@as(usize, 2), decoded.len);
    try std.testing.expectEqual(@as(i32, 5), decoded[0].line_num);
    try std.testing.expectEqual(@as(i32, 4), decoded[1].line_num);
}
