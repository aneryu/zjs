//! Zig interpreter for V8 Irregexp bytecode.
//!
//! Compile still lives in the C++ island. Exec is a labeled `switch` over
//! IRRX bytecode (`continue :dispatch nxt.op`), with a pointer PC and
//! comptime instruction sizes. ReleaseFast trusts compiler-emitted code.
const std = @import("std");
const builtin = @import("builtin");
const unicode = @import("unicode.zig");
const bc = @import("irregexp_bytecode.zig");

const Opcode = bc.Opcode;
const Off = bc.Off;

/// Compiler-emitted bytecode is trusted in ReleaseFast/ReleaseSmall the same
/// way V8's interpreter uses `DCHECK` rather than a per-instruction sandbox.
/// Debug and ReleaseSafe still reject out-of-range PCs, opcodes, and registers.
const trusted_code = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;

pub const Result = enum { success, failure };

pub const Interrupt = struct {
    check: ?*const fn (?*anyopaque) bool = null,
    ctx: ?*anyopaque = null,
};

const max_backtrack_slots: usize = (64 * 1024 * 1024) / @sizeOf(i32);
const inline_backtrack_slots: usize = 64;

const word_character_map: [256]u8 = blk: {
    var map = [_]u8{0} ** 256;
    var c: usize = '0';
    while (c <= '9') : (c += 1) map[c] = 0xff;
    c = 'A';
    while (c <= 'Z') : (c += 1) map[c] = 0xff;
    c = 'a';
    while (c <= 'z') : (c += 1) map[c] = 0xff;
    map['_'] = 0xff;
    break :blk map;
};

inline fn loadAt(comptime T: type, pc: [*]const u8, off: usize) T {
    const ptr: *align(1) const T = @ptrCast(pc + off);
    return ptr.*;
}

inline fn readI16(pc: [*]const u8, off: usize) i16 {
    return loadAt(i16, pc, off);
}

inline fn readI32(pc: [*]const u8, off: usize) i32 {
    return loadAt(i32, pc, off);
}

inline fn readU16(pc: [*]const u8, off: usize) u16 {
    return loadAt(u16, pc, off);
}

inline fn readU32(pc: [*]const u8, off: usize) u32 {
    return loadAt(u32, pc, off);
}

inline fn readU8(pc: [*]const u8, off: usize) u8 {
    return (pc + off)[0];
}

inline fn readTable(pc: [*]const u8, off: usize) *const [16]u8 {
    return @ptrCast(pc + off);
}

/// V8 `BacktrackStack`: 64 inline slots, then heap. Avoids a heap allocation
/// on every exec for the common case (`std.ArrayList.ensureTotalCapacity(64)`).
const BacktrackStack = struct {
    inline_buf: [inline_backtrack_slots]i32 = undefined,
    heap: []i32 = &.{},
    len: usize = 0,
    allocator: std.mem.Allocator,

    fn deinit(self: *BacktrackStack) void {
        if (self.heap.len != 0) self.allocator.free(self.heap);
    }

    inline fn storage(self: *BacktrackStack) []i32 {
        return if (self.heap.len != 0) self.heap else self.inline_buf[0..];
    }

    fn grow(self: *BacktrackStack) error{OutOfMemory}!void {
        const old = self.storage();
        const new_cap = @max(old.len * 2, inline_backtrack_slots * 2);
        const new_heap = try self.allocator.alloc(i32, new_cap);
        @memcpy(new_heap[0..self.len], old[0..self.len]);
        if (self.heap.len != 0) self.allocator.free(self.heap);
        self.heap = new_heap;
    }

    fn push(self: *BacktrackStack, value: i32) error{ BytecodeCorrupt, OutOfMemory }!void {
        if (self.len >= max_backtrack_slots) return error.BytecodeCorrupt;
        var slots = self.storage();
        if (self.len == slots.len) {
            @branchHint(.unlikely);
            try self.grow();
            slots = self.storage();
        }
        slots[self.len] = value;
        self.len += 1;
    }

    fn pop(self: *BacktrackStack) ?i32 {
        if (self.len == 0) return null;
        self.len -= 1;
        return self.storage()[self.len];
    }

    fn peek(self: *const BacktrackStack) ?i32 {
        if (self.len == 0) return null;
        const slots: []const i32 = if (self.heap.len != 0) self.heap else &self.inline_buf;
        return slots[self.len - 1];
    }

    fn truncate(self: *BacktrackStack, new_len: usize) void {
        self.len = new_len;
    }
};

fn indexInBounds(index: i32, length: i32) bool {
    return @as(u32, @bitCast(index)) < @as(u32, @bitCast(length));
}

fn checkBitInTable(current_char: u32, table: *const [16]u8) bool {
    const masked = current_char & bc.table_mask;
    const byte = table[masked >> 3];
    const bit: u3 = @truncate(current_char);
    return (byte & (@as(u8, 1) << bit)) != 0;
}

fn isWhitespace(current_char: u32) bool {
    return current_char == ' ' or (current_char >= '\t' and current_char <= '\r') or current_char == 0xa0;
}

fn isLineTerminator(current_char: u32, comptime one_byte: bool) bool {
    if (current_char == '\n' or current_char == '\r') return true;
    if (!one_byte and (current_char == 0x2028 or current_char == 0x2029)) return true;
    return false;
}

fn isWord(current_char: u32, comptime one_byte: bool) bool {
    if (!one_byte and current_char > 'z') return false;
    if (current_char >= word_character_map.len) return false;
    return word_character_map[@intCast(current_char)] != 0;
}

fn specialClassMatches(current_char: u32, set: u8, comptime one_byte: bool) bool {
    return switch (set) {
        's' => isWhitespace(current_char),
        'S' => !isWhitespace(current_char),
        'w' => isWord(current_char, one_byte),
        'W' => !isWord(current_char, one_byte),
        'd' => current_char >= '0' and current_char <= '9',
        'D' => current_char < '0' or current_char > '9',
        'n' => isLineTerminator(current_char, one_byte),
        '.' => !isLineTerminator(current_char, one_byte),
        '*' => true,
        else => false,
    };
}

fn latin1NoCaseEqual(a: u8, b: u8) bool {
    if (a == b) return true;
    var old_char: u32 = a;
    var new_char: u32 = b;
    old_char |= 0x20;
    new_char |= 0x20;
    if (old_char != new_char) return false;
    if (old_char -% 'a' <= 'z' - 'a') return true;
    if (old_char -% 224 <= 254 - 224 and old_char != 247) return true;
    return false;
}

fn canonicalizeUnit(unit: u16, is_unicode: bool) u32 {
    return unicode.regexpCanonicalize(@as(u21, unit), is_unicode);
}

fn charsEqual(comptime Char: type, a: []const Char, b: []const Char) bool {
    return std.mem.eql(Char, a, b);
}

fn charsEqualNoCase(comptime Char: type, a: []const Char, b: []const Char, is_unicode: bool) bool {
    if (Char == u8) {
        for (a, b) |x, y| {
            if (!latin1NoCaseEqual(x, y)) return false;
        }
        return true;
    }
    for (a, b) |x, y| {
        if (x == y) continue;
        if (canonicalizeUnit(x, is_unicode) != canonicalizeUnit(y, is_unicode)) return false;
    }
    return true;
}

fn load2(comptime Char: type, subject: []const Char, index: i32) u32 {
    const ptr: [*]const Char = subject.ptr + @as(usize, @intCast(index));
    const shift = @bitSizeOf(Char);
    return @as(u32, ptr[0]) | (@as(u32, ptr[1]) << shift);
}

fn load4(subject: []const u8, index: i32) u32 {
    const ptr: *align(1) const u32 = @ptrCast(subject.ptr + @as(usize, @intCast(index)));
    return std.mem.littleToNative(u32, ptr.*);
}

inline fn nextOpcode(pc: [*]const u8) Opcode {
    if (!trusted_code) {
        if (pc[0] >= bc.opcode_count) unreachable;
    }
    return @enumFromInt(pc[0]);
}

inline fn skip(comptime op: Opcode) usize {
    return comptime bc.opcode_size[@intFromEnum(op)];
}

/// V8 ADVANCE/DECODE: next PC and opcode, so the continue operand is a
/// plain `Opcode` rather than a helper call.
const Next = struct {
    pc: [*]const u8,
    op: Opcode,
};

inline fn decodeAt(pc: [*]const u8) Next {
    return .{ .pc = pc, .op = nextOpcode(pc) };
}

inline fn decodeFallthrough(pc: [*]const u8, comptime op: Opcode) Next {
    return decodeAt(pc + skip(op));
}

inline fn decodeJump(code: []const u8, pc: [*]const u8, off: usize) Next {
    return decodeAt(jumpTo(code, pc, off));
}

inline fn decodeRestore(code: []const u8, offset: i32) Next {
    return decodeAt(restorePc(code, offset));
}

inline fn jumpTo(code: []const u8, pc: [*]const u8, off: usize) [*]const u8 {
    const target: usize = loadAt(u32, pc, off);
    if (!trusted_code and target >= code.len) unreachable;
    return code.ptr + target;
}

inline fn restorePc(code: []const u8, offset: i32) [*]const u8 {
    const target: usize = @as(usize, @intCast(offset));
    if (!trusted_code and target >= code.len) unreachable;
    return code.ptr + target;
}

inline fn regGet(regs: []i32, index: u16) i32 {
    if (!trusted_code and index >= regs.len) unreachable;
    return regs.ptr[index];
}

inline fn regPtr(regs: []i32, index: u16) *i32 {
    if (!trusted_code and index >= regs.len) unreachable;
    return &regs.ptr[index];
}

pub fn execLatin1(
    allocator: std.mem.Allocator,
    code: []const u8,
    subject: []const u8,
    start_index: usize,
    registers: []i32,
    interrupt: Interrupt,
) !Result {
    return @call(.always_inline, execGeneric, .{ u8, allocator, code, subject, start_index, registers, interrupt });
}

pub fn execUtf16(
    allocator: std.mem.Allocator,
    code: []const u8,
    subject: []const u16,
    start_index: usize,
    registers: []i32,
    interrupt: Interrupt,
) !Result {
    return execGeneric(u16, allocator, code, subject, start_index, registers, interrupt);
}

fn execGeneric(
    comptime Char: type,
    allocator: std.mem.Allocator,
    code: []const u8,
    subject: []const Char,
    start_index: usize,
    registers: []i32,
    interrupt: Interrupt,
) !Result {
    if (code.len == 0) return error.BytecodeCorrupt;
    const one_byte = Char == u8;
    const length: i32 = std.math.cast(i32, subject.len) orelse return error.BytecodeCorrupt;
    var current: i32 = std.math.cast(i32, start_index) orelse return error.BytecodeCorrupt;
    var current_char: u32 = if (start_index == 0)
        '\n'
    else
        subject[start_index - 1];

    var pc: [*]const u8 = code.ptr;
    var backtrack = BacktrackStack{ .allocator = allocator };
    defer backtrack.deinit();

    dispatch: switch (nextOpcode(pc)) {
        .break_ => return error.BytecodeCorrupt,
        .push_current_position => {
            try backtrack.push(current);
            const nxt = decodeFallthrough(pc, .push_current_position);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .push_backtrack => {
            try backtrack.push(@bitCast(readU32(pc, Off.push_backtrack.label)));
            const nxt = decodeFallthrough(pc, .push_backtrack);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .push_register => {
            const index = readU16(pc, Off.push_register.register_index);
            try backtrack.push(regGet(registers, index));
            const nxt = decodeFallthrough(pc, .push_register);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .set_register => {
            const index = readU16(pc, Off.set_register.register_index);
            const value = readI32(pc, Off.set_register.value);
            (regPtr(registers, index)).* = value;
            const nxt = decodeFallthrough(pc, .set_register);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .clear_registers => {
            const from_reg = readU16(pc, Off.clear_registers.from_register);
            const to_reg = readU16(pc, Off.clear_registers.to_register);
            if (from_reg > to_reg) return error.BytecodeCorrupt;
            if (!trusted_code and @as(usize, to_reg) >= registers.len) return error.BytecodeCorrupt;
            const from: usize = from_reg;
            const to_exclusive: usize = @as(usize, to_reg) + 1;
            @memset(registers.ptr[from..to_exclusive], -1);
            const nxt = decodeFallthrough(pc, .clear_registers);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .advance_register => {
            const index = readU16(pc, Off.advance_register.register_index);
            const by = readI16(pc, Off.advance_register.by);
            (regPtr(registers, index)).* += by;
            const nxt = decodeFallthrough(pc, .advance_register);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .write_current_position_to_register => {
            const index = readU16(pc, Off.write_current_position_to_register.register_index);
            const cp_offset = readI16(pc, Off.write_current_position_to_register.cp_offset);
            (regPtr(registers, index)).* = current + cp_offset;
            const nxt = decodeFallthrough(pc, .write_current_position_to_register);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .read_current_position_from_register => {
            const index = readU16(pc, Off.read_current_position_from_register.register_index);
            current = regGet(registers, index);
            const nxt = decodeFallthrough(pc, .read_current_position_from_register);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .write_stack_pointer_to_register => {
            const index = readU16(pc, Off.write_stack_pointer_to_register.register_index);
            (regPtr(registers, index)).* = @intCast(backtrack.len);
            const nxt = decodeFallthrough(pc, .write_stack_pointer_to_register);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .read_stack_pointer_from_register => {
            const index = readU16(pc, Off.read_stack_pointer_from_register.register_index);
            const new_sp = regGet(registers, index);
            if (new_sp < 0 or @as(usize, @intCast(new_sp)) > backtrack.len) return error.BytecodeCorrupt;
            backtrack.truncate(@intCast(new_sp));
            const nxt = decodeFallthrough(pc, .read_stack_pointer_from_register);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .pop_current_position => {
            current = backtrack.pop() orelse return error.BytecodeCorrupt;
            const nxt = decodeFallthrough(pc, .pop_current_position);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .backtrack => {
            if (interrupt.check) |check| {
                if (check(interrupt.ctx)) return error.Timeout;
            }
            const nxt = decodeRestore(code, backtrack.pop() orelse return error.BytecodeCorrupt);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .pop_register => {
            const index = readU16(pc, Off.pop_register.register_index);
            (regPtr(registers, index)).* = backtrack.pop() orelse return error.BytecodeCorrupt;
            const nxt = decodeFallthrough(pc, .pop_register);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .fail => return .failure,
        .succeed => return .success,
        .advance_current_position => {
            current += readI16(pc, Off.advance_current_position.by);
            const nxt = decodeFallthrough(pc, .advance_current_position);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .go_to => {
            const nxt = decodeJump(code, pc, Off.go_to.label);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .advance_cp_and_goto => {
            const by = readI16(pc, Off.advance_cp_and_goto.by);
            const nxt = decodeJump(code, pc, Off.advance_cp_and_goto.on_goto);
            current += by;
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .check_fixed_length_loop => {
            const tos = backtrack.peek() orelse return error.BytecodeCorrupt;
            if (current == tos) {
                const nxt = decodeJump(code, pc, Off.check_fixed_length_loop.on_tos_equals_current_position);
                _ = backtrack.pop();
                pc = nxt.pc;
                continue :dispatch nxt.op;
            }
            const nxt = decodeFallthrough(pc, .check_fixed_length_loop);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .load_current_character => {
            const bounds = readI32(pc, Off.load_current_character.bounds_check_offset);
            if (!indexInBounds(current + bounds, length)) {
                const nxt = decodeJump(code, pc, Off.load_current_character.on_failure);
                pc = nxt.pc;
                continue :dispatch nxt.op;
            }
            const cp_offset = readI16(pc, Off.load_current_character.cp_offset);
            current_char = subject[@intCast(current + cp_offset)];
            const nxt = decodeFallthrough(pc, .load_current_character);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .load_current_character_unchecked => {
            const cp_offset = readI16(pc, Off.load_current_character_unchecked.cp_offset);
            current_char = subject[@intCast(current + cp_offset)];
            const nxt = decodeFallthrough(pc, .load_current_character_unchecked);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .load2_current_chars => {
            const bounds = readI32(pc, Off.load2_current_chars.bounds_check_offset);
            if (!indexInBounds(current + bounds, length)) {
                const nxt = decodeJump(code, pc, Off.load2_current_chars.on_failure);
                pc = nxt.pc;
                continue :dispatch nxt.op;
            }
            const cp_offset = readI16(pc, Off.load2_current_chars.cp_offset);
            current_char = load2(Char, subject, current + cp_offset);
            const nxt = decodeFallthrough(pc, .load2_current_chars);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .load2_current_chars_unchecked => {
            const cp_offset = readI16(pc, Off.load2_current_chars_unchecked.cp_offset);
            current_char = load2(Char, subject, current + cp_offset);
            const nxt = decodeFallthrough(pc, .load2_current_chars_unchecked);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .load4_current_chars => {
            if (Char != u8) return error.BytecodeCorrupt;
            const bounds = readI32(pc, Off.load4_current_chars.bounds_check_offset);
            if (!indexInBounds(current + bounds, length)) {
                const nxt = decodeJump(code, pc, Off.load4_current_chars.on_failure);
                pc = nxt.pc;
                continue :dispatch nxt.op;
            }
            const cp_offset = readI16(pc, Off.load4_current_chars.cp_offset);
            current_char = load4(subject, current + cp_offset);
            const nxt = decodeFallthrough(pc, .load4_current_chars);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .load4_current_chars_unchecked => {
            if (Char != u8) return error.BytecodeCorrupt;
            const cp_offset = readI16(pc, Off.load4_current_chars_unchecked.cp_offset);
            current_char = load4(subject, current + cp_offset);
            const nxt = decodeFallthrough(pc, .load4_current_chars_unchecked);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .check4_chars => {
            const nxt = if (readU32(pc, Off.check4_chars.characters) == current_char)
                decodeJump(code, pc, Off.check4_chars.on_equal)
            else
                decodeFallthrough(pc, .check4_chars);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .check_character => {
            const nxt = if (readU16(pc, Off.check_character.character) == current_char)
                decodeJump(code, pc, Off.check_character.on_equal)
            else
                decodeFallthrough(pc, .check_character);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .check_not4_chars => {
            const nxt = if (readU32(pc, Off.check_not4_chars.characters) != current_char)
                decodeJump(code, pc, Off.check_not4_chars.on_not_equal)
            else
                decodeFallthrough(pc, .check_not4_chars);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .check_not_character => {
            const nxt = if (readU16(pc, Off.check_not_character.character) != current_char)
                decodeJump(code, pc, Off.check_not_character.on_not_equal)
            else
                decodeFallthrough(pc, .check_not_character);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .and_check4_chars => {
            const mask = readU32(pc, Off.and_check4_chars.mask);
            const nxt = if (readU32(pc, Off.and_check4_chars.characters) == (current_char & mask))
                decodeJump(code, pc, Off.and_check4_chars.on_equal)
            else
                decodeFallthrough(pc, .and_check4_chars);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .check_character_after_and => {
            const mask = readU32(pc, Off.check_character_after_and.mask);
            const nxt = if (readU16(pc, Off.check_character_after_and.character) == (current_char & mask))
                decodeJump(code, pc, Off.check_character_after_and.on_equal)
            else
                decodeFallthrough(pc, .check_character_after_and);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .and_check_not4_chars => {
            const mask = readU32(pc, Off.and_check_not4_chars.mask);
            const nxt = if (readU32(pc, Off.and_check_not4_chars.characters) != (current_char & mask))
                decodeJump(code, pc, Off.and_check_not4_chars.on_not_equal)
            else
                decodeFallthrough(pc, .and_check_not4_chars);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .check_not_character_after_and => {
            const mask = readU32(pc, Off.check_not_character_after_and.mask);
            const nxt = if (readU16(pc, Off.check_not_character_after_and.character) != (current_char & mask))
                decodeJump(code, pc, Off.check_not_character_after_and.on_not_equal)
            else
                decodeFallthrough(pc, .check_not_character_after_and);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .check_not_character_after_minus_and => {
            const minus = readU16(pc, Off.check_not_character_after_minus_and.minus);
            const mask = readU16(pc, Off.check_not_character_after_minus_and.mask);
            const character = readU16(pc, Off.check_not_character_after_minus_and.character);
            const nxt = if (character != ((current_char -% minus) & mask))
                decodeJump(code, pc, Off.check_not_character_after_minus_and.on_not_equal)
            else
                decodeFallthrough(pc, .check_not_character_after_minus_and);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .check_character_in_range => {
            const from = readU16(pc, Off.check_character_in_range.from);
            const to = readU16(pc, Off.check_character_in_range.to);
            const nxt = if (from <= current_char and current_char <= to)
                decodeJump(code, pc, Off.check_character_in_range.on_in_range)
            else
                decodeFallthrough(pc, .check_character_in_range);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .check_character_not_in_range => {
            const from = readU16(pc, Off.check_character_not_in_range.from);
            const to = readU16(pc, Off.check_character_not_in_range.to);
            const nxt = if (from > current_char or current_char > to)
                decodeJump(code, pc, Off.check_character_not_in_range.on_not_in_range)
            else
                decodeFallthrough(pc, .check_character_not_in_range);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .check_bit_in_table => {
            const table = readTable(pc, Off.check_bit_in_table.table);
            const nxt = if (checkBitInTable(current_char, table))
                decodeJump(code, pc, Off.check_bit_in_table.on_bit_set)
            else
                decodeFallthrough(pc, .check_bit_in_table);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .check_character_lt => {
            const nxt = if (current_char < readU16(pc, Off.check_character_lt.limit))
                decodeJump(code, pc, Off.check_character_lt.on_less)
            else
                decodeFallthrough(pc, .check_character_lt);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .check_character_gt => {
            const nxt = if (current_char > readU16(pc, Off.check_character_gt.limit))
                decodeJump(code, pc, Off.check_character_gt.on_greater)
            else
                decodeFallthrough(pc, .check_character_gt);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .if_register_lt => {
            const index = readU16(pc, Off.if_register_lt.register_index);
            const comparand = readI32(pc, Off.if_register_lt.comparand);
            const nxt = if ((regGet(registers, index)) < comparand)
                decodeJump(code, pc, Off.if_register_lt.on_less_than)
            else
                decodeFallthrough(pc, .if_register_lt);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .if_register_ge => {
            const index = readU16(pc, Off.if_register_ge.register_index);
            const comparand = readI32(pc, Off.if_register_ge.comparand);
            const nxt = if ((regGet(registers, index)) >= comparand)
                decodeJump(code, pc, Off.if_register_ge.on_greater_or_equal)
            else
                decodeFallthrough(pc, .if_register_ge);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .if_register_eq_pos => {
            const index = readU16(pc, Off.if_register_eq_pos.register_index);
            const nxt = if ((regGet(registers, index)) == current)
                decodeJump(code, pc, Off.if_register_eq_pos.on_eq)
            else
                decodeFallthrough(pc, .if_register_eq_pos);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .check_not_back_ref,
        .check_not_back_ref_no_case,
        .check_not_back_ref_no_case_unicode,
        => {
            const start_reg = readU16(pc, Off.check_not_back_ref.start_reg);
            const from = regGet(registers, start_reg);
            const end = regGet(registers, start_reg + 1);
            const len = end - from;
            if (from >= 0 and len > 0) {
                if (current + len > length or from + len > length) {
                    const nxt = decodeJump(code, pc, Off.check_not_back_ref.on_not_equal);
                    pc = nxt.pc;
                    continue :dispatch nxt.op;
                }
                const src = subject[@intCast(from)..][0..@intCast(len)];
                const dst = subject[@intCast(current)..][0..@intCast(len)];
                const equal = switch (nextOpcode(pc)) {
                    .check_not_back_ref => charsEqual(Char, src, dst),
                    .check_not_back_ref_no_case => charsEqualNoCase(Char, src, dst, false),
                    .check_not_back_ref_no_case_unicode => charsEqualNoCase(Char, src, dst, true),
                    else => unreachable,
                };
                if (!equal) {
                    const nxt = decodeJump(code, pc, Off.check_not_back_ref.on_not_equal);
                    pc = nxt.pc;
                    continue :dispatch nxt.op;
                }
                current += len;
            }
            const nxt = decodeFallthrough(pc, .check_not_back_ref);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .check_not_back_ref_backward,
        .check_not_back_ref_no_case_backward,
        .check_not_back_ref_no_case_unicode_backward,
        => {
            const start_reg = readU16(pc, Off.check_not_back_ref_backward.start_reg);
            const from = regGet(registers, start_reg);
            const end = regGet(registers, start_reg + 1);
            const len = end - from;
            if (from >= 0 and len > 0) {
                if (current - len < 0 or from + len > length) {
                    const nxt = decodeJump(code, pc, Off.check_not_back_ref_backward.on_not_equal);
                    pc = nxt.pc;
                    continue :dispatch nxt.op;
                }
                const src = subject[@intCast(from)..][0..@intCast(len)];
                const dst = subject[@intCast(current - len)..][0..@intCast(len)];
                const equal = switch (nextOpcode(pc)) {
                    .check_not_back_ref_backward => charsEqual(Char, src, dst),
                    .check_not_back_ref_no_case_backward => charsEqualNoCase(Char, src, dst, false),
                    .check_not_back_ref_no_case_unicode_backward => charsEqualNoCase(Char, src, dst, true),
                    else => unreachable,
                };
                if (!equal) {
                    const nxt = decodeJump(code, pc, Off.check_not_back_ref_backward.on_not_equal);
                    pc = nxt.pc;
                    continue :dispatch nxt.op;
                }
                current -= len;
            }
            const nxt = decodeFallthrough(pc, .check_not_back_ref_backward);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .check_at_start => {
            const nxt = if (current + readI16(pc, Off.check_at_start.cp_offset) == 0)
                decodeJump(code, pc, Off.check_at_start.on_at_start)
            else
                decodeFallthrough(pc, .check_at_start);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .check_not_at_start => {
            const nxt = if (current + readI16(pc, Off.check_not_at_start.cp_offset) == 0)
                decodeFallthrough(pc, .check_not_at_start)
            else
                decodeJump(code, pc, Off.check_not_at_start.on_not_at_start);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .set_current_position_from_end => {
            const by = readI16(pc, Off.set_current_position_from_end.by);
            const nxt = decodeFallthrough(pc, .set_current_position_from_end);
            if (length - current > by) {
                current = length - by;
                current_char = subject[@intCast(current - 1)];
            }
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .check_position => {
            const pos = current + readI16(pc, Off.check_position.cp_offset);
            const nxt = if (pos >= length or pos < 0)
                decodeJump(code, pc, Off.check_position.on_failure)
            else
                decodeFallthrough(pc, .check_position);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .check_special_class_ranges => {
            const set = readU8(pc, Off.check_special_class_ranges.character_set);
            const nxt = if (specialClassMatches(current_char, set, one_byte))
                decodeFallthrough(pc, .check_special_class_ranges)
            else
                decodeJump(code, pc, Off.check_special_class_ranges.on_no_match);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .skip_until_char => {
            const cp_offset = readI16(pc, Off.skip_until_char.cp_offset);
            const advance_by = readI16(pc, Off.skip_until_char.advance_by);
            const character = readU16(pc, Off.skip_until_char.character);
            const bounds = readI32(pc, Off.skip_until_char.bounds_check_offset);
            while (indexInBounds(current + bounds, length)) {
                current_char = subject[@intCast(current + cp_offset)];
                if (character == current_char) {
                    const nxt = decodeJump(code, pc, Off.skip_until_char.on_match);
                    pc = nxt.pc;
                    continue :dispatch nxt.op;
                }
                current += advance_by;
            }
            const nxt = decodeJump(code, pc, Off.skip_until_char.on_no_match);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .skip_until_char_and => {
            const cp_offset = readI16(pc, Off.skip_until_char_and.cp_offset);
            const advance_by = readI16(pc, Off.skip_until_char_and.advance_by);
            const character = readU16(pc, Off.skip_until_char_and.character);
            const mask = readU32(pc, Off.skip_until_char_and.mask);
            const bounds = readI32(pc, Off.skip_until_char_and.bounds_check_offset);
            while (indexInBounds(current + bounds, length)) {
                current_char = subject[@intCast(current + cp_offset)];
                if (character == (current_char & mask)) {
                    const nxt = decodeJump(code, pc, Off.skip_until_char_and.on_match);
                    pc = nxt.pc;
                    continue :dispatch nxt.op;
                }
                current += advance_by;
            }
            const nxt = decodeJump(code, pc, Off.skip_until_char_and.on_no_match);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .skip_until_bit_in_table => {
            const cp_offset = readI16(pc, Off.skip_until_bit_in_table.cp_offset);
            const advance_by = readI16(pc, Off.skip_until_bit_in_table.advance_by);
            const table = readTable(pc, Off.skip_until_bit_in_table.table);
            const bounds = readI32(pc, Off.skip_until_bit_in_table.bounds_check_offset);
            while (indexInBounds(current + bounds, length)) {
                current_char = subject[@intCast(current + cp_offset)];
                if (checkBitInTable(current_char, table)) {
                    const nxt = decodeJump(code, pc, Off.skip_until_bit_in_table.on_match);
                    pc = nxt.pc;
                    continue :dispatch nxt.op;
                }
                current += advance_by;
            }
            const nxt = decodeJump(code, pc, Off.skip_until_bit_in_table.on_no_match);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .skip_until_gt_or_not_bit_in_table => {
            const cp_offset = readI16(pc, Off.skip_until_gt_or_not_bit_in_table.cp_offset);
            const advance_by = readI16(pc, Off.skip_until_gt_or_not_bit_in_table.advance_by);
            const character = readU16(pc, Off.skip_until_gt_or_not_bit_in_table.character);
            const table = readTable(pc, Off.skip_until_gt_or_not_bit_in_table.table);
            const bounds = readI32(pc, Off.skip_until_gt_or_not_bit_in_table.bounds_check_offset);
            while (indexInBounds(current + bounds, length)) {
                current_char = subject[@intCast(current + cp_offset)];
                if (current_char > character or !checkBitInTable(current_char, table)) {
                    const nxt = decodeJump(code, pc, Off.skip_until_gt_or_not_bit_in_table.on_match);
                    pc = nxt.pc;
                    continue :dispatch nxt.op;
                }
                current += advance_by;
            }
            const nxt = decodeJump(code, pc, Off.skip_until_gt_or_not_bit_in_table.on_no_match);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .skip_until_char_or_char => {
            const cp_offset = readI16(pc, Off.skip_until_char_or_char.cp_offset);
            const advance_by = readI16(pc, Off.skip_until_char_or_char.advance_by);
            const char1 = readU16(pc, Off.skip_until_char_or_char.char1);
            const char2 = readU16(pc, Off.skip_until_char_or_char.char2);
            const bounds = readI32(pc, Off.skip_until_char_or_char.bounds_check_offset);
            while (indexInBounds(current + bounds, length)) {
                current_char = subject[@intCast(current + cp_offset)];
                if (char1 == current_char or char2 == current_char) {
                    const nxt = decodeJump(code, pc, Off.skip_until_char_or_char.on_match);
                    pc = nxt.pc;
                    continue :dispatch nxt.op;
                }
                current += advance_by;
            }
            const nxt = decodeJump(code, pc, Off.skip_until_char_or_char.on_no_match);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .skip_until_one_of_masked => {
            if (Char != u8) return error.BytecodeCorrupt;
            const cp_offset = readI16(pc, Off.skip_until_one_of_masked.cp_offset);
            const advance_by = readI16(pc, Off.skip_until_one_of_masked.advance_by);
            const both_chars = readU32(pc, Off.skip_until_one_of_masked.both_chars);
            const both_mask = readU32(pc, Off.skip_until_one_of_masked.both_mask);
            const max_offset = readI32(pc, Off.skip_until_one_of_masked.max_offset);
            const chars1 = readU32(pc, Off.skip_until_one_of_masked.chars1);
            const mask1 = readU32(pc, Off.skip_until_one_of_masked.mask1);
            const chars2 = readU32(pc, Off.skip_until_one_of_masked.chars2);
            const mask2 = readU32(pc, Off.skip_until_one_of_masked.mask2);
            while (indexInBounds(current + max_offset, length)) {
                current_char = load4(subject, current + cp_offset);
                if (both_chars == (current_char & both_mask)) {
                    if (chars1 == (current_char & mask1)) {
                        const nxt = decodeJump(code, pc, Off.skip_until_one_of_masked.on_match1);
                        pc = nxt.pc;
                        continue :dispatch nxt.op;
                    }
                    if (chars2 == (current_char & mask2)) {
                        const nxt = decodeJump(code, pc, Off.skip_until_one_of_masked.on_match2);
                        pc = nxt.pc;
                        continue :dispatch nxt.op;
                    }
                }
                current += advance_by;
            }
            const nxt = decodeJump(code, pc, Off.skip_until_one_of_masked.on_failure);
            pc = nxt.pc;
            continue :dispatch nxt.op;
        },
        .skip_until_one_of_masked3 => {
            if (Char != u8) return error.BytecodeCorrupt;
            const bc0_cp_offset = readI16(pc, Off.skip_until_one_of_masked3.bc0_cp_offset);
            const bc0_advance_by = readI16(pc, Off.skip_until_one_of_masked3.bc0_advance_by);
            const bc0_table = readTable(pc, Off.skip_until_one_of_masked3.bc0_table);
            const bc1_bounds = readI32(pc, Off.skip_until_one_of_masked3.bc1_bounds_check_offset);
            const bc1_cp_offset = readI16(pc, Off.skip_until_one_of_masked3.bc1_cp_offset);
            const bc2_characters = readU32(pc, Off.skip_until_one_of_masked3.bc2_characters);
            const bc2_mask = readU32(pc, Off.skip_until_one_of_masked3.bc2_mask);
            const bc3_by = readI16(pc, Off.skip_until_one_of_masked3.bc3_by);
            const bc4_bounds = readI32(pc, Off.skip_until_one_of_masked3.bc4_bounds_check_offset);
            const bc4_cp_offset = readI16(pc, Off.skip_until_one_of_masked3.bc4_cp_offset);
            const bc5_characters = readU32(pc, Off.skip_until_one_of_masked3.bc5_characters);
            const bc5_mask = readU32(pc, Off.skip_until_one_of_masked3.bc5_mask);
            const bc6_characters = readU32(pc, Off.skip_until_one_of_masked3.bc6_characters);
            const bc6_mask = readU32(pc, Off.skip_until_one_of_masked3.bc6_mask);
            const bc7_characters = readU32(pc, Off.skip_until_one_of_masked3.bc7_characters);
            const bc7_mask = readU32(pc, Off.skip_until_one_of_masked3.bc7_mask);
            while (true) {
                while (indexInBounds(current + bc0_cp_offset, length)) {
                    current_char = subject[@intCast(current + bc0_cp_offset)];
                    if (checkBitInTable(current_char, bc0_table)) break;
                    current += bc0_advance_by;
                }
                if (!indexInBounds(current + bc1_bounds, length)) {
                    const nxt = decodeJump(code, pc, Off.skip_until_one_of_masked3.bc1_on_failure);
                    pc = nxt.pc;
                    continue :dispatch nxt.op;
                }
                current_char = load4(subject, current + bc1_cp_offset);
                if (bc2_characters == (current_char & bc2_mask)) {
                    if (!indexInBounds(current + bc4_bounds, length)) {
                        current += bc3_by;
                        continue;
                    }
                    current_char = load4(subject, current + bc4_cp_offset);
                    if (bc5_characters == (current_char & bc5_mask)) {
                        const nxt = decodeJump(code, pc, Off.skip_until_one_of_masked3.bc5_on_equal);
                        pc = nxt.pc;
                        continue :dispatch nxt.op;
                    }
                    if (bc6_characters == (current_char & bc6_mask)) {
                        const nxt = decodeJump(code, pc, Off.skip_until_one_of_masked3.bc6_on_equal);
                        pc = nxt.pc;
                        continue :dispatch nxt.op;
                    }
                    if (bc7_characters == (current_char & bc7_mask)) {
                        const nxt = decodeJump(code, pc, Off.skip_until_one_of_masked3.fallthrough_jump_target);
                        pc = nxt.pc;
                        continue :dispatch nxt.op;
                    }
                }
                current += bc3_by;
            }
        },
    }
}
