//! Phase 3b: compute_pc2line_info
//!
//! Mirrors `compute_pc2line_info` at `quickjs.c`.
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

const mem_ops = @import("../core/memory.zig");
const std = @import("std");
const bytecode = @import("../bytecode.zig");
const memory = @import("../core/memory.zig");
const runtime = @import("../core/runtime.zig");

/// PC2LINE encoding constants (mirror `quickjs.c`).
pub const PC2LINE_BASE: i32 = -1;
pub const PC2LINE_RANGE: i32 = 5;
pub const PC2LINE_OP_FIRST: i32 = 1;
pub const PC2LINE_DIFF_PC_MAX: i32 = (255 - PC2LINE_OP_FIRST) / PC2LINE_RANGE; // = 50

/// One source-location slot — mirrors `SourceLocSlot`.
pub const SourceLocSlot = struct {
    pc: u32,
    line_num: i32,
    col_num: i32,
};

/// Encoded pc2line buffer. Like QuickJS, the first two ULEB128 values are
/// the function's zero-based starting line and column; transition records
/// follow immediately. There is no parallel coordinate authority.
pub const Encoded = struct {
    bytes: []u8,
    memory: std.mem.Allocator,

    pub fn deinit(self: *Encoded) void {
        const bytes = self.bytes;
        self.bytes = &.{};
        if (bytes.len != 0) self.memory.free(bytes);
    }
};

/// Encode a sequence of source-location slots into a pc2line buffer.
///
/// `start_line_num` and `start_col_num` are the function's starting
/// position (used as the implicit pc=0 reference, matching QuickJS's
/// `s->line_num` / `s->col_num`).
pub fn encode(
    allocator: std.mem.Allocator,
    slots: []const SourceLocSlot,
    start_line_num: i32,
    start_col_num: i32,
) !Encoded {
    // First pass validates every delta and computes the exact encoded
    // length. The second pass writes directly into one accounted owner;
    // there is no growable temporary or shrink/copy allocation.
    var measure = Encoder{};
    try encodeInto(&measure, slots, start_line_num, start_col_num);
    const owned = try allocator.alloc(u8, measure.index);
    errdefer allocator.free(owned);
    var writer = Encoder{ .output = owned };
    try encodeInto(&writer, slots, start_line_num, start_col_num);
    if (writer.index != owned.len) return error.Pc2LineOverflow;
    return .{
        .bytes = owned,
        .memory = allocator,
    };
}

const Encoder = struct {
    output: ?[]u8 = null,
    index: usize = 0,

    fn putByte(self: *Encoder, byte: u8) !void {
        const next = std.math.add(usize, self.index, 1) catch return error.Pc2LineOverflow;
        if (self.output) |out| {
            if (self.index >= out.len) return error.Pc2LineOverflow;
            out[self.index] = byte;
        }
        self.index = next;
    }

    fn putLeb128(self: *Encoder, value: u32) !void {
        var v = value;
        while (true) {
            const byte: u8 = @intCast(v & 0x7f);
            v >>= 7;
            if (v == 0) {
                try self.putByte(byte);
                return;
            }
            try self.putByte(byte | 0x80);
        }
    }

    fn putSleb128(self: *Encoder, value: i32) !void {
        // QuickJS's dbuf_put_sleb128 uses zig-zag signed-to-unsigned
        // mapping followed by ordinary ULEB128.
        const bits: u32 = @bitCast(value);
        const encoded = (bits << 1) ^ (0 -% (bits >> 31));
        try self.putLeb128(encoded);
    }
};

fn encodeInto(
    encoder: *Encoder,
    slots: []const SourceLocSlot,
    start_line_num: i32,
    start_col_num: i32,
) !void {
    if (start_line_num <= 0 or start_col_num <= 0) return error.Pc2LineOverflow;
    const initial_line: u32 = std.math.cast(u32, start_line_num - 1) orelse return error.Pc2LineOverflow;
    const initial_col: u32 = std.math.cast(u32, start_col_num - 1) orelse return error.Pc2LineOverflow;
    try encoder.putLeb128(initial_line);
    try encoder.putLeb128(initial_col);

    var last_line_num: i32 = start_line_num;
    var last_col_num: i32 = start_col_num;
    var last_pc: u32 = 0;
    for (slots) |slot| {
        if (slot.line_num < 0 or slot.pc < last_pc) continue;

        const diff_pc = slot.pc - last_pc;
        const diff_line = std.math.sub(i32, slot.line_num, last_line_num) catch return error.Pc2LineOverflow;
        const diff_col = std.math.sub(i32, slot.col_num, last_col_num) catch return error.Pc2LineOverflow;
        if (diff_line == 0 and diff_col == 0) continue;

        if (diff_line >= PC2LINE_BASE and
            diff_line < PC2LINE_BASE + PC2LINE_RANGE and
            diff_pc <= @as(u32, @intCast(PC2LINE_DIFF_PC_MAX)))
        {
            try encoder.putByte(@intCast(
                (diff_line - PC2LINE_BASE) + @as(i32, @intCast(diff_pc)) * PC2LINE_RANGE + PC2LINE_OP_FIRST,
            ));
        } else {
            try encoder.putByte(0);
            try encoder.putLeb128(diff_pc);
            try encoder.putSleb128(diff_line);
        }
        try encoder.putSleb128(diff_col);

        last_pc = slot.pc;
        last_line_num = slot.line_num;
        last_col_num = slot.col_num;
    }
}

pub const Header = struct {
    line_num: i32,
    col_num: i32,
    payload_offset: usize,
};

/// Decode QuickJS's two mandatory pc2line header values without
/// allocating. Stored values are zero-based; engine source locations are
/// one-based.
pub fn decodeHeader(bytes: []const u8) !Header {
    var index: usize = 0;
    const stored_line = try readLeb128(bytes, &index);
    const stored_col = try readLeb128(bytes, &index);
    const line_num = std.math.cast(i32, stored_line) orelse return error.Pc2LineOverflow;
    const col_num = std.math.cast(i32, stored_col) orelse return error.Pc2LineOverflow;
    if (line_num == std.math.maxInt(i32) or col_num == std.math.maxInt(i32)) return error.Pc2LineOverflow;
    return .{
        .line_num = line_num + 1,
        .col_num = col_num + 1,
        .payload_offset = index,
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

    const header = try decodeHeader(encoded.bytes);
    var pc: u32 = 0;
    var line_num: i32 = header.line_num;
    var col_num: i32 = header.col_num;
    var i: usize = header.payload_offset;
    while (i < encoded.bytes.len) {
        const op = encoded.bytes[i];
        i += 1;
        if (op == 0) {
            const diff_pc = try readLeb128(encoded.bytes, &i);
            const diff_line = try readSleb128(encoded.bytes, &i);
            pc = std.math.add(u32, pc, diff_pc) catch return error.Pc2LineOverflow;
            line_num = std.math.add(i32, line_num, diff_line) catch return error.Pc2LineOverflow;
        } else {
            const adjusted: i32 = @as(i32, op) - PC2LINE_OP_FIRST;
            const diff_pc: i32 = @divFloor(adjusted, PC2LINE_RANGE);
            const diff_line: i32 = @mod(adjusted, PC2LINE_RANGE) + PC2LINE_BASE;
            pc = std.math.add(u32, pc, @intCast(diff_pc)) catch return error.Pc2LineOverflow;
            line_num = std.math.add(i32, line_num, diff_line) catch return error.Pc2LineOverflow;
        }
        const diff_col = try readSleb128(encoded.bytes, &i);
        col_num = std.math.add(i32, col_num, diff_col) catch return error.Pc2LineOverflow;

        try slots.append(allocator, .{
            .pc = pc,
            .line_num = line_num,
            .col_num = col_num,
        });
    }
    return slots.toOwnedSlice(allocator);
}

/// Resolve the source location at `target_pc` with the same strict
/// malformed-buffer behavior as QuickJS `find_line_num`. The header is the
/// location before the first transition, so a target before the first slot
/// (and a buffer with no slots) resolves to the function definition.
pub fn findSourceLocation(bytes: []const u8, target_pc: u32) !SourceLocSlot {
    const header = try decodeHeader(bytes);
    var current = SourceLocSlot{
        .pc = 0,
        .line_num = header.line_num,
        .col_num = header.col_num,
    };
    var i = header.payload_offset;
    while (i < bytes.len) {
        const marker = bytes[i];
        i += 1;

        var next_pc = current.pc;
        var next_line = current.line_num;
        if (marker == 0) {
            const diff_pc = try readLeb128(bytes, &i);
            const diff_line = try readSleb128(bytes, &i);
            next_pc = std.math.add(u32, next_pc, diff_pc) catch return error.Pc2LineOverflow;
            next_line = std.math.add(i32, next_line, diff_line) catch return error.Pc2LineOverflow;
        } else {
            const adjusted: i32 = @as(i32, marker) - PC2LINE_OP_FIRST;
            const diff_pc: u32 = @intCast(@divFloor(adjusted, PC2LINE_RANGE));
            const diff_line: i32 = @mod(adjusted, PC2LINE_RANGE) + PC2LINE_BASE;
            next_pc = std.math.add(u32, next_pc, diff_pc) catch return error.Pc2LineOverflow;
            next_line = std.math.add(i32, next_line, diff_line) catch return error.Pc2LineOverflow;
        }
        const diff_col = try readSleb128(bytes, &i);
        const next_col = std.math.add(i32, current.col_num, diff_col) catch return error.Pc2LineOverflow;

        if (target_pc < next_pc) return current;
        current = .{
            .pc = next_pc,
            .line_num = next_line,
            .col_num = next_col,
        };
    }
    return current;
}

// ---- LEB128 helpers ----

fn readLeb128(bytes: []const u8, i: *usize) !u32 {
    var result: u32 = 0;
    var shift: u32 = 0;
    while (true) {
        if (i.* >= bytes.len) return error.Pc2LineTruncated;
        const byte = bytes[i.*];
        i.* += 1;
        const payload: u32 = byte & 0x7f;
        if (shift == 28 and payload > 0x0f) return error.Pc2LineOverflow;
        result |= payload << @intCast(shift);
        if ((byte & 0x80) == 0) return result;
        if (shift == 28) return error.Pc2LineOverflow;
        shift += 7;
    }
}

fn readSleb128(bytes: []const u8, i: *usize) !i32 {
    const encoded = try readLeb128(bytes, i);
    const decoded: u32 = (encoded >> 1) ^ (0 -% (encoded & 1));
    return @bitCast(decoded);
}

test "pc2line: empty slot list contains the mandatory QuickJS header" {
    const account = try mem_ops.createTestRuntime(std.testing.allocator);
    defer account.destroy();
    var encoded = try encode(account.nativeAllocator(), &.{}, 1, 1);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, encoded.bytes);
    try std.testing.expectEqual(@as(usize, 1), account.diagnostics.allocations.alloc_calls);
    try std.testing.expectEqual(@as(usize, 1), account.diagnostics.allocations.allocation_count);
    try std.testing.expectEqual(@as(usize, 1), account.diagnostics.allocations.peak_allocation_count);
    const header = try decodeHeader(encoded.bytes);
    try std.testing.expectEqual(@as(i32, 1), header.line_num);
    try std.testing.expectEqual(@as(i32, 1), header.col_num);
    try std.testing.expectEqual(@as(usize, 2), header.payload_offset);
    encoded.deinit();
    try std.testing.expectEqual(@as(usize, 0), account.diagnostics.allocations.allocation_count);
}

test "pc2line: QuickJS header is zero-based ULEB128 byte-for-byte" {
    const account = try mem_ops.createTestRuntime(std.testing.allocator);
    defer account.destroy();
    var encoded = try encode(account.nativeAllocator(), &.{}, 130, 257);
    defer encoded.deinit();

    // 130 - 1 = 129 -> 0x81 0x01; 257 - 1 = 256 -> 0x80 0x02.
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x01, 0x80, 0x02 }, encoded.bytes);
    const header = try decodeHeader(encoded.bytes);
    try std.testing.expectEqual(@as(i32, 130), header.line_num);
    try std.testing.expectEqual(@as(i32, 257), header.col_num);
    try std.testing.expectEqual(encoded.bytes.len, header.payload_offset);
}

test "pc2line: compact encoding for small line/pc deltas" {
    const account = try mem_ops.createTestRuntime(std.testing.allocator);
    defer account.destroy();
    // Two slots: same line, small pc delta. Compact form is one byte
    // (line/pc compact) plus a sleb128 col diff.
    const slots = [_]SourceLocSlot{
        .{ .pc = 0, .line_num = 1, .col_num = 1 },
        .{ .pc = 5, .line_num = 1, .col_num = 4 },
    };
    var encoded = try encode(account.nativeAllocator(), &slots, 1, 1);
    defer encoded.deinit();

    // First slot has diff_pc=0, diff_line=0, diff_col=0 from start (1,1) → skipped.
    // Second slot has diff_pc=5, diff_line=0, diff_col=3 from previous.
    // Compact byte = (0 - (-1)) + 5*5 + 1 = 1 + 25 + 1 = 27, then
    // QuickJS zig-zag sleb128(3) = uleb128(6) = 0x06.
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 27, 6 }, encoded.bytes);
}

test "pc2line: long encoding for large pc delta" {
    const account = try mem_ops.createTestRuntime(std.testing.allocator);
    defer account.destroy();
    const slots = [_]SourceLocSlot{
        .{ .pc = 100, .line_num = 2, .col_num = 1 },
    };
    var encoded = try encode(account.nativeAllocator(), &slots, 1, 1);
    defer encoded.deinit();

    // diff_pc=100 > MAX(50) → long form: 0, leb128(100),
    // zig-zag sleb128(1)=2, zig-zag sleb128(0)=0.
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 100, 2, 0 }, encoded.bytes);
}

test "pc2line: encode/decode round-trip" {
    const account = try mem_ops.createTestRuntime(std.testing.allocator);
    defer account.destroy();
    const input_slots = [_]SourceLocSlot{
        .{ .pc = 5, .line_num = 1, .col_num = 4 },
        .{ .pc = 10, .line_num = 2, .col_num = 1 },
        .{ .pc = 200, .line_num = 5, .col_num = 12 },
        .{ .pc = 250, .line_num = 5, .col_num = 25 },
    };
    var encoded = try encode(account.nativeAllocator(), &input_slots, 1, 1);
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

test "pc2line: source lookup covers definition, slots, and trailing pc" {
    const account = try mem_ops.createTestRuntime(std.testing.allocator);
    defer account.destroy();
    const input_slots = [_]SourceLocSlot{
        .{ .pc = 5, .line_num = 11, .col_num = 7 },
        .{ .pc = 12, .line_num = 14, .col_num = 2 },
    };
    var encoded = try encode(account.nativeAllocator(), &input_slots, 10, 3);
    defer encoded.deinit();

    const before = try findSourceLocation(encoded.bytes, 4);
    try std.testing.expectEqual(@as(i32, 10), before.line_num);
    try std.testing.expectEqual(@as(i32, 3), before.col_num);

    const first = try findSourceLocation(encoded.bytes, 5);
    try std.testing.expectEqual(@as(i32, 11), first.line_num);
    try std.testing.expectEqual(@as(i32, 7), first.col_num);

    const middle = try findSourceLocation(encoded.bytes, 11);
    try std.testing.expectEqual(@as(i32, 11), middle.line_num);
    try std.testing.expectEqual(@as(i32, 7), middle.col_num);

    const trailing = try findSourceLocation(encoded.bytes, 1000);
    try std.testing.expectEqual(@as(i32, 14), trailing.line_num);
    try std.testing.expectEqual(@as(i32, 2), trailing.col_num);
}

test "pc2line: malformed header or transition never returns a partial location" {
    try std.testing.expectError(error.Pc2LineTruncated, decodeHeader(&.{}));
    try std.testing.expectError(error.Pc2LineTruncated, decodeHeader(&.{0}));
    try std.testing.expectError(
        error.Pc2LineOverflow,
        decodeHeader(&.{ 0x80, 0x80, 0x80, 0x80, 0x10, 0 }),
    );

    // Valid 1:1 header followed by a truncated long record and a compact
    // record missing its signed column delta.
    try std.testing.expectError(error.Pc2LineTruncated, findSourceLocation(&.{ 0, 0, 0 }, 0));
    try std.testing.expectError(error.Pc2LineTruncated, findSourceLocation(&.{ 0, 0, 1 }, 0));

    // Signed deltas use QuickJS zig-zag over ULEB, so the same fifth-group
    // u32 overflow rule applies to them.
    try std.testing.expectError(
        error.Pc2LineOverflow,
        findSourceLocation(&.{ 0, 0, 0, 0, 0x80, 0x80, 0x80, 0x80, 0x10 }, 0),
    );
}

test "pc2line: full u32 pc delta is encoded without narrowing traps" {
    const account = try mem_ops.createTestRuntime(std.testing.allocator);
    defer account.destroy();
    const slots = [_]SourceLocSlot{
        .{ .pc = std.math.maxInt(u32), .line_num = 1, .col_num = 2 },
    };
    var encoded = try encode(account.nativeAllocator(), &slots, 1, 1);
    defer encoded.deinit();

    const decoded = try decode(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqual(@as(usize, 1), decoded.len);
    try std.testing.expectEqual(std.math.maxInt(u32), decoded[0].pc);
    try std.testing.expectEqual(@as(i32, 2), decoded[0].col_num);
}

test "pc2line: skips slots with no real change or backward pc" {
    const account = try mem_ops.createTestRuntime(std.testing.allocator);
    defer account.destroy();
    const slots = [_]SourceLocSlot{
        .{ .pc = 10, .line_num = 1, .col_num = 5 },
        .{ .pc = 10, .line_num = 1, .col_num = 5 }, // duplicate → skipped
        .{ .pc = 5, .line_num = 1, .col_num = 5 }, // backward pc → skipped
        .{ .pc = 15, .line_num = -1, .col_num = 5 }, // line < 0 → skipped
        .{ .pc = 20, .line_num = 1, .col_num = 8 }, // valid
    };
    var encoded = try encode(account.nativeAllocator(), &slots, 1, 1);
    defer encoded.deinit();

    const decoded = try decode(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqual(@as(usize, 2), decoded.len);
    try std.testing.expectEqual(@as(u32, 10), decoded[0].pc);
    try std.testing.expectEqual(@as(u32, 20), decoded[1].pc);
}

test "pc2line: negative line delta encoded compactly" {
    const account = try mem_ops.createTestRuntime(std.testing.allocator);
    defer account.destroy();
    const slots = [_]SourceLocSlot{
        .{ .pc = 5, .line_num = 5, .col_num = 1 },
        .{ .pc = 10, .line_num = 4, .col_num = 1 }, // diff_line = -1, in compact range
    };
    var encoded = try encode(account.nativeAllocator(), &slots, 1, 1);
    defer encoded.deinit();

    const decoded = try decode(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqual(@as(usize, 2), decoded.len);
    try std.testing.expectEqual(@as(i32, 5), decoded[0].line_num);
    try std.testing.expectEqual(@as(i32, 4), decoded[1].line_num);
}

test "pc2line: QuickJS signed deltas use zig-zag bytes" {
    const account = try mem_ops.createTestRuntime(std.testing.allocator);
    defer account.destroy();
    const slots = [_]SourceLocSlot{
        .{ .pc = 1, .line_num = 1, .col_num = 1 },
    };
    var encoded = try encode(account.nativeAllocator(), &slots, 1, 2);
    defer encoded.deinit();

    // Header is (line-1=0, col-1=1). The compact transition marker is 7;
    // QuickJS maps signed column delta -1 to unsigned 1 before ULEB.
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 7, 1 }, encoded.bytes);

    const long_slots = [_]SourceLocSlot{
        .{ .pc = 100, .line_num = 1, .col_num = 1 },
    };
    var long_encoded = try encode(account.nativeAllocator(), &long_slots, 2, 3);
    defer long_encoded.deinit();
    // Header=(1,2), long marker, pc delta 100, then zig-zag(-1)=1
    // and zig-zag(-2)=3. This pins signed transition bytes independently
    // of the symmetric decoder.
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 0, 100, 1, 3 }, long_encoded.bytes);
}
