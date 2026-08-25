//! Zig interpreter for V8 Irregexp bytecode.
//!
//! The C++ island still compiles patterns into IRRX blobs. Exec no longer
//! crosses into Isolate / Handle / C ABI machinery on the match hot path.
//! Dispatch is a labeled `switch` (`continue :dispatch next_opcode`), Zig's
//! structured analog of V8's computed-goto interpreter.
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

inline fn loadUnaligned(comptime T: type, code: []const u8, pc: usize, off: usize) T {
    const ptr: *align(1) const T = @ptrCast(code.ptr + pc + off);
    return ptr.*;
}

fn readI16(code: []const u8, pc: usize, off: usize) i16 {
    return loadUnaligned(i16, code, pc, off);
}

fn readI32(code: []const u8, pc: usize, off: usize) i32 {
    return loadUnaligned(i32, code, pc, off);
}

fn readU16(code: []const u8, pc: usize, off: usize) u16 {
    return loadUnaligned(u16, code, pc, off);
}

fn readU32(code: []const u8, pc: usize, off: usize) u32 {
    return loadUnaligned(u32, code, pc, off);
}

fn readU8(code: []const u8, pc: usize, off: usize) u8 {
    return (code.ptr + pc + off)[0];
}

fn readTable(code: []const u8, pc: usize, off: usize) *const [16]u8 {
    return @ptrCast(code.ptr + pc + off);
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

inline fn decode(code: []const u8, pc: usize) error{BytecodeCorrupt}!Opcode {
    if (!trusted_code) {
        if (pc >= code.len) return error.BytecodeCorrupt;
        const raw = code.ptr[pc];
        if (raw >= bc.opcode_count) return error.BytecodeCorrupt;
        const op: Opcode = @enumFromInt(raw);
        if (pc + bc.opcode_size[@intFromEnum(op)] > code.len) return error.BytecodeCorrupt;
        return op;
    }
    return @enumFromInt(code.ptr[pc]);
}

/// Next-opcode operand for labeled-switch `continue`. ReleaseFast returns a
/// plain `Opcode` so LLVM can emit a per-arm jump instead of an error union.
inline fn nextOpcode(code: []const u8, pc: usize) Opcode {
    if (!trusted_code) {
        return decode(code, pc) catch unreachable;
    }
    return @enumFromInt(code.ptr[pc]);
}

inline fn sizeAt(code: []const u8, pc: usize) usize {
    return bc.opcode_size[code.ptr[pc]];
}

inline fn opcodeAt(code: []const u8, pc: usize) Opcode {
    return @enumFromInt(code.ptr[pc]);
}

pub fn execLatin1(
    allocator: std.mem.Allocator,
    code: []const u8,
    subject: []const u8,
    start_index: usize,
    registers: []i32,
    interrupt: Interrupt,
) !Result {
    return execGeneric(u8, allocator, code, subject, start_index, registers, interrupt);
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

    var pc: usize = 0;
    var backtrack = BacktrackStack{ .allocator = allocator };
    defer backtrack.deinit();

    const jump = struct {
        fn go(bytes: []const u8, at: usize, off: usize) error{BytecodeCorrupt}!usize {
            const target = readU32(bytes, at, off);
            if (!trusted_code and target >= bytes.len) return error.BytecodeCorrupt;
            return target;
        }
    }.go;

    const getReg = struct {
        fn get(regs: []i32, index: u16) error{BytecodeCorrupt}!i32 {
            if (!trusted_code and index >= regs.len) return error.BytecodeCorrupt;
            return regs.ptr[index];
        }
        fn ptr(regs: []i32, index: u16) error{BytecodeCorrupt}!*i32 {
            if (!trusted_code and index >= regs.len) return error.BytecodeCorrupt;
            return &regs.ptr[index];
        }
    };

    dispatch: switch (nextOpcode(code, pc)) {
        .break_ => return error.BytecodeCorrupt,
        .push_current_position => {
            try backtrack.push(current);
            pc += sizeAt(code, pc);
            continue :dispatch nextOpcode(code, pc);
        },
        .push_backtrack => {
            try backtrack.push(@bitCast(readU32(code, pc, Off.push_backtrack.label)));
            pc += sizeAt(code, pc);
            continue :dispatch nextOpcode(code, pc);
        },
        .push_register => {
            const index = readU16(code, pc, Off.push_register.register_index);
            try backtrack.push(try getReg.get(registers, index));
            pc += sizeAt(code, pc);
            continue :dispatch nextOpcode(code, pc);
        },
        .set_register => {
            const index = readU16(code, pc, Off.set_register.register_index);
            const value = readI32(code, pc, Off.set_register.value);
            (try getReg.ptr(registers, index)).* = value;
            pc += sizeAt(code, pc);
            continue :dispatch nextOpcode(code, pc);
        },
        .clear_registers => {
            const from_reg = readU16(code, pc, Off.clear_registers.from_register);
            const to_reg = readU16(code, pc, Off.clear_registers.to_register);
            if (from_reg > to_reg) return error.BytecodeCorrupt;
            if (!trusted_code and @as(usize, to_reg) >= registers.len) return error.BytecodeCorrupt;
            const from: usize = from_reg;
            const to_exclusive: usize = @as(usize, to_reg) + 1;
            @memset(registers.ptr[from..to_exclusive], -1);
            pc += sizeAt(code, pc);
            continue :dispatch nextOpcode(code, pc);
        },
        .advance_register => {
            const index = readU16(code, pc, Off.advance_register.register_index);
            const by = readI16(code, pc, Off.advance_register.by);
            (try getReg.ptr(registers, index)).* += by;
            pc += sizeAt(code, pc);
            continue :dispatch nextOpcode(code, pc);
        },
        .write_current_position_to_register => {
            const index = readU16(code, pc, Off.write_current_position_to_register.register_index);
            const cp_offset = readI16(code, pc, Off.write_current_position_to_register.cp_offset);
            (try getReg.ptr(registers, index)).* = current + cp_offset;
            pc += sizeAt(code, pc);
            continue :dispatch nextOpcode(code, pc);
        },
        .read_current_position_from_register => {
            const index = readU16(code, pc, Off.read_current_position_from_register.register_index);
            current = try getReg.get(registers, index);
            pc += sizeAt(code, pc);
            continue :dispatch nextOpcode(code, pc);
        },
        .write_stack_pointer_to_register => {
            const index = readU16(code, pc, Off.write_stack_pointer_to_register.register_index);
            (try getReg.ptr(registers, index)).* = @intCast(backtrack.len);
            pc += sizeAt(code, pc);
            continue :dispatch nextOpcode(code, pc);
        },
        .read_stack_pointer_from_register => {
            const index = readU16(code, pc, Off.read_stack_pointer_from_register.register_index);
            const new_sp = try getReg.get(registers, index);
            if (new_sp < 0 or @as(usize, @intCast(new_sp)) > backtrack.len) return error.BytecodeCorrupt;
            backtrack.truncate(@intCast(new_sp));
            pc += sizeAt(code, pc);
            continue :dispatch nextOpcode(code, pc);
        },
        .pop_current_position => {
            current = backtrack.pop() orelse return error.BytecodeCorrupt;
            pc += sizeAt(code, pc);
            continue :dispatch nextOpcode(code, pc);
        },
        .backtrack => {
            if (interrupt.check) |check| {
                if (check(interrupt.ctx)) return error.Timeout;
            }
            pc = @intCast(backtrack.pop() orelse return error.BytecodeCorrupt);
            continue :dispatch nextOpcode(code, pc);
        },
        .pop_register => {
            const index = readU16(code, pc, Off.pop_register.register_index);
            (try getReg.ptr(registers, index)).* = backtrack.pop() orelse return error.BytecodeCorrupt;
            pc += sizeAt(code, pc);
            continue :dispatch nextOpcode(code, pc);
        },
        .fail => return .failure,
        .succeed => return .success,
        .advance_current_position => {
            current += readI16(code, pc, Off.advance_current_position.by);
            pc += sizeAt(code, pc);
            continue :dispatch nextOpcode(code, pc);
        },
        .go_to => {
            pc = try jump(code, pc, Off.go_to.label);
            continue :dispatch nextOpcode(code, pc);
        },
        .advance_cp_and_goto => {
            const by = readI16(code, pc, Off.advance_cp_and_goto.by);
            pc = try jump(code, pc, Off.advance_cp_and_goto.on_goto);
            current += by;
            continue :dispatch nextOpcode(code, pc);
        },
        .check_fixed_length_loop => {
            const tos = backtrack.peek() orelse return error.BytecodeCorrupt;
            if (current == tos) {
                pc = try jump(code, pc, Off.check_fixed_length_loop.on_tos_equals_current_position);
                _ = backtrack.pop();
            } else {
                pc += sizeAt(code, pc);
            }
            continue :dispatch nextOpcode(code, pc);
        },
        .load_current_character => {
            const bounds = readI32(code, pc, Off.load_current_character.bounds_check_offset);
            if (!indexInBounds(current + bounds, length)) {
                pc = try jump(code, pc, Off.load_current_character.on_failure);
            } else {
                const cp_offset = readI16(code, pc, Off.load_current_character.cp_offset);
                current_char = subject[@intCast(current + cp_offset)];
                pc += sizeAt(code, pc);
            }
            continue :dispatch nextOpcode(code, pc);
        },
        .load_current_character_unchecked => {
            const cp_offset = readI16(code, pc, Off.load_current_character_unchecked.cp_offset);
            current_char = subject[@intCast(current + cp_offset)];
            pc += sizeAt(code, pc);
            continue :dispatch nextOpcode(code, pc);
        },
        .load2_current_chars => {
            const bounds = readI32(code, pc, Off.load2_current_chars.bounds_check_offset);
            if (!indexInBounds(current + bounds, length)) {
                pc = try jump(code, pc, Off.load2_current_chars.on_failure);
            } else {
                const cp_offset = readI16(code, pc, Off.load2_current_chars.cp_offset);
                current_char = load2(Char, subject, current + cp_offset);
                pc += sizeAt(code, pc);
            }
            continue :dispatch nextOpcode(code, pc);
        },
        .load2_current_chars_unchecked => {
            const cp_offset = readI16(code, pc, Off.load2_current_chars_unchecked.cp_offset);
            current_char = load2(Char, subject, current + cp_offset);
            pc += sizeAt(code, pc);
            continue :dispatch nextOpcode(code, pc);
        },
        .load4_current_chars => {
            if (Char != u8) return error.BytecodeCorrupt;
            const bounds = readI32(code, pc, Off.load4_current_chars.bounds_check_offset);
            if (!indexInBounds(current + bounds, length)) {
                pc = try jump(code, pc, Off.load4_current_chars.on_failure);
            } else {
                const cp_offset = readI16(code, pc, Off.load4_current_chars.cp_offset);
                current_char = load4(subject, current + cp_offset);
                pc += sizeAt(code, pc);
            }
            continue :dispatch nextOpcode(code, pc);
        },
        .load4_current_chars_unchecked => {
            if (Char != u8) return error.BytecodeCorrupt;
            const cp_offset = readI16(code, pc, Off.load4_current_chars_unchecked.cp_offset);
            current_char = load4(subject, current + cp_offset);
            pc += sizeAt(code, pc);
            continue :dispatch nextOpcode(code, pc);
        },
        .check4_chars => {
            if (readU32(code, pc, Off.check4_chars.characters) == current_char) {
                pc = try jump(code, pc, Off.check4_chars.on_equal);
            } else {
                pc += sizeAt(code, pc);
            }
            continue :dispatch nextOpcode(code, pc);
        },
        .check_character => {
            if (readU16(code, pc, Off.check_character.character) == current_char) {
                pc = try jump(code, pc, Off.check_character.on_equal);
            } else {
                pc += sizeAt(code, pc);
            }
            continue :dispatch nextOpcode(code, pc);
        },
        .check_not4_chars => {
            if (readU32(code, pc, Off.check_not4_chars.characters) != current_char) {
                pc = try jump(code, pc, Off.check_not4_chars.on_not_equal);
            } else {
                pc += sizeAt(code, pc);
            }
            continue :dispatch nextOpcode(code, pc);
        },
        .check_not_character => {
            if (readU16(code, pc, Off.check_not_character.character) != current_char) {
                pc = try jump(code, pc, Off.check_not_character.on_not_equal);
            } else {
                pc += sizeAt(code, pc);
            }
            continue :dispatch nextOpcode(code, pc);
        },
        .and_check4_chars => {
            const mask = readU32(code, pc, Off.and_check4_chars.mask);
            if (readU32(code, pc, Off.and_check4_chars.characters) == (current_char & mask)) {
                pc = try jump(code, pc, Off.and_check4_chars.on_equal);
            } else {
                pc += sizeAt(code, pc);
            }
            continue :dispatch nextOpcode(code, pc);
        },
        .check_character_after_and => {
            const mask = readU32(code, pc, Off.check_character_after_and.mask);
            if (readU16(code, pc, Off.check_character_after_and.character) == (current_char & mask)) {
                pc = try jump(code, pc, Off.check_character_after_and.on_equal);
            } else {
                pc += sizeAt(code, pc);
            }
            continue :dispatch nextOpcode(code, pc);
        },
        .and_check_not4_chars => {
            const mask = readU32(code, pc, Off.and_check_not4_chars.mask);
            if (readU32(code, pc, Off.and_check_not4_chars.characters) != (current_char & mask)) {
                pc = try jump(code, pc, Off.and_check_not4_chars.on_not_equal);
            } else {
                pc += sizeAt(code, pc);
            }
            continue :dispatch nextOpcode(code, pc);
        },
        .check_not_character_after_and => {
            const mask = readU32(code, pc, Off.check_not_character_after_and.mask);
            if (readU16(code, pc, Off.check_not_character_after_and.character) != (current_char & mask)) {
                pc = try jump(code, pc, Off.check_not_character_after_and.on_not_equal);
            } else {
                pc += sizeAt(code, pc);
            }
            continue :dispatch nextOpcode(code, pc);
        },
        .check_not_character_after_minus_and => {
            const minus = readU16(code, pc, Off.check_not_character_after_minus_and.minus);
            const mask = readU16(code, pc, Off.check_not_character_after_minus_and.mask);
            const character = readU16(code, pc, Off.check_not_character_after_minus_and.character);
            if (character != ((current_char -% minus) & mask)) {
                pc = try jump(code, pc, Off.check_not_character_after_minus_and.on_not_equal);
            } else {
                pc += sizeAt(code, pc);
            }
            continue :dispatch nextOpcode(code, pc);
        },
        .check_character_in_range => {
            const from = readU16(code, pc, Off.check_character_in_range.from);
            const to = readU16(code, pc, Off.check_character_in_range.to);
            if (from <= current_char and current_char <= to) {
                pc = try jump(code, pc, Off.check_character_in_range.on_in_range);
            } else {
                pc += sizeAt(code, pc);
            }
            continue :dispatch nextOpcode(code, pc);
        },
        .check_character_not_in_range => {
            const from = readU16(code, pc, Off.check_character_not_in_range.from);
            const to = readU16(code, pc, Off.check_character_not_in_range.to);
            if (from > current_char or current_char > to) {
                pc = try jump(code, pc, Off.check_character_not_in_range.on_not_in_range);
            } else {
                pc += sizeAt(code, pc);
            }
            continue :dispatch nextOpcode(code, pc);
        },
        .check_bit_in_table => {
            const table = readTable(code, pc, Off.check_bit_in_table.table);
            if (checkBitInTable(current_char, table)) {
                pc = try jump(code, pc, Off.check_bit_in_table.on_bit_set);
            } else {
                pc += sizeAt(code, pc);
            }
            continue :dispatch nextOpcode(code, pc);
        },
        .check_character_lt => {
            if (current_char < readU16(code, pc, Off.check_character_lt.limit)) {
                pc = try jump(code, pc, Off.check_character_lt.on_less);
            } else {
                pc += sizeAt(code, pc);
            }
            continue :dispatch nextOpcode(code, pc);
        },
        .check_character_gt => {
            if (current_char > readU16(code, pc, Off.check_character_gt.limit)) {
                pc = try jump(code, pc, Off.check_character_gt.on_greater);
            } else {
                pc += sizeAt(code, pc);
            }
            continue :dispatch nextOpcode(code, pc);
        },
        .if_register_lt => {
            const index = readU16(code, pc, Off.if_register_lt.register_index);
            const comparand = readI32(code, pc, Off.if_register_lt.comparand);
            if ((try getReg.get(registers, index)) < comparand) {
                pc = try jump(code, pc, Off.if_register_lt.on_less_than);
            } else {
                pc += sizeAt(code, pc);
            }
            continue :dispatch nextOpcode(code, pc);
        },
        .if_register_ge => {
            const index = readU16(code, pc, Off.if_register_ge.register_index);
            const comparand = readI32(code, pc, Off.if_register_ge.comparand);
            if ((try getReg.get(registers, index)) >= comparand) {
                pc = try jump(code, pc, Off.if_register_ge.on_greater_or_equal);
            } else {
                pc += sizeAt(code, pc);
            }
            continue :dispatch nextOpcode(code, pc);
        },
        .if_register_eq_pos => {
            const index = readU16(code, pc, Off.if_register_eq_pos.register_index);
            if ((try getReg.get(registers, index)) == current) {
                pc = try jump(code, pc, Off.if_register_eq_pos.on_eq);
            } else {
                pc += sizeAt(code, pc);
            }
            continue :dispatch nextOpcode(code, pc);
        },
        .check_not_back_ref,
        .check_not_back_ref_no_case,
        .check_not_back_ref_no_case_unicode,
        => {
            const start_reg = readU16(code, pc, Off.check_not_back_ref.start_reg);
            const from = try getReg.get(registers, start_reg);
            const end = try getReg.get(registers, start_reg + 1);
            const len = end - from;
            if (from >= 0 and len > 0) {
                if (current + len > length or from + len > length) {
                    pc = try jump(code, pc, Off.check_not_back_ref.on_not_equal);
                    continue :dispatch nextOpcode(code, pc);
                }
                const src = subject[@intCast(from)..][0..@intCast(len)];
                const dst = subject[@intCast(current)..][0..@intCast(len)];
                const equal = switch (opcodeAt(code, pc)) {
                    .check_not_back_ref => charsEqual(Char, src, dst),
                    .check_not_back_ref_no_case => charsEqualNoCase(Char, src, dst, false),
                    .check_not_back_ref_no_case_unicode => charsEqualNoCase(Char, src, dst, true),
                    else => unreachable,
                };
                if (!equal) {
                    pc = try jump(code, pc, Off.check_not_back_ref.on_not_equal);
                    continue :dispatch nextOpcode(code, pc);
                }
                current += len;
            }
            pc += sizeAt(code, pc);
            continue :dispatch nextOpcode(code, pc);
        },
        .check_not_back_ref_backward,
        .check_not_back_ref_no_case_backward,
        .check_not_back_ref_no_case_unicode_backward,
        => {
            const start_reg = readU16(code, pc, Off.check_not_back_ref_backward.start_reg);
            const from = try getReg.get(registers, start_reg);
            const end = try getReg.get(registers, start_reg + 1);
            const len = end - from;
            if (from >= 0 and len > 0) {
                if (current - len < 0 or from + len > length) {
                    pc = try jump(code, pc, Off.check_not_back_ref_backward.on_not_equal);
                    continue :dispatch nextOpcode(code, pc);
                }
                const src = subject[@intCast(from)..][0..@intCast(len)];
                const dst = subject[@intCast(current - len)..][0..@intCast(len)];
                const equal = switch (opcodeAt(code, pc)) {
                    .check_not_back_ref_backward => charsEqual(Char, src, dst),
                    .check_not_back_ref_no_case_backward => charsEqualNoCase(Char, src, dst, false),
                    .check_not_back_ref_no_case_unicode_backward => charsEqualNoCase(Char, src, dst, true),
                    else => unreachable,
                };
                if (!equal) {
                    pc = try jump(code, pc, Off.check_not_back_ref_backward.on_not_equal);
                    continue :dispatch nextOpcode(code, pc);
                }
                current -= len;
            }
            pc += sizeAt(code, pc);
            continue :dispatch nextOpcode(code, pc);
        },
        .check_at_start => {
            if (current + readI16(code, pc, Off.check_at_start.cp_offset) == 0) {
                pc = try jump(code, pc, Off.check_at_start.on_at_start);
            } else {
                pc += sizeAt(code, pc);
            }
            continue :dispatch nextOpcode(code, pc);
        },
        .check_not_at_start => {
            if (current + readI16(code, pc, Off.check_not_at_start.cp_offset) == 0) {
                pc += sizeAt(code, pc);
            } else {
                pc = try jump(code, pc, Off.check_not_at_start.on_not_at_start);
            }
            continue :dispatch nextOpcode(code, pc);
        },
        .set_current_position_from_end => {
            const by = readI16(code, pc, Off.set_current_position_from_end.by);
            pc += sizeAt(code, pc);
            if (length - current > by) {
                current = length - by;
                current_char = subject[@intCast(current - 1)];
            }
            continue :dispatch nextOpcode(code, pc);
        },
        .check_position => {
            const pos = current + readI16(code, pc, Off.check_position.cp_offset);
            if (pos >= length or pos < 0) {
                pc = try jump(code, pc, Off.check_position.on_failure);
            } else {
                pc += sizeAt(code, pc);
            }
            continue :dispatch nextOpcode(code, pc);
        },
        .check_special_class_ranges => {
            const set = readU8(code, pc, Off.check_special_class_ranges.character_set);
            if (specialClassMatches(current_char, set, one_byte)) {
                pc += sizeAt(code, pc);
            } else {
                pc = try jump(code, pc, Off.check_special_class_ranges.on_no_match);
            }
            continue :dispatch nextOpcode(code, pc);
        },
        .skip_until_char => {
            const cp_offset = readI16(code, pc, Off.skip_until_char.cp_offset);
            const advance_by = readI16(code, pc, Off.skip_until_char.advance_by);
            const character = readU16(code, pc, Off.skip_until_char.character);
            const bounds = readI32(code, pc, Off.skip_until_char.bounds_check_offset);
            while (indexInBounds(current + bounds, length)) {
                current_char = subject[@intCast(current + cp_offset)];
                if (character == current_char) {
                    pc = try jump(code, pc, Off.skip_until_char.on_match);
                    continue :dispatch nextOpcode(code, pc);
                }
                current += advance_by;
            }
            pc = try jump(code, pc, Off.skip_until_char.on_no_match);
            continue :dispatch nextOpcode(code, pc);
        },
        .skip_until_char_and => {
            const cp_offset = readI16(code, pc, Off.skip_until_char_and.cp_offset);
            const advance_by = readI16(code, pc, Off.skip_until_char_and.advance_by);
            const character = readU16(code, pc, Off.skip_until_char_and.character);
            const mask = readU32(code, pc, Off.skip_until_char_and.mask);
            const bounds = readI32(code, pc, Off.skip_until_char_and.bounds_check_offset);
            while (indexInBounds(current + bounds, length)) {
                current_char = subject[@intCast(current + cp_offset)];
                if (character == (current_char & mask)) {
                    pc = try jump(code, pc, Off.skip_until_char_and.on_match);
                    continue :dispatch nextOpcode(code, pc);
                }
                current += advance_by;
            }
            pc = try jump(code, pc, Off.skip_until_char_and.on_no_match);
            continue :dispatch nextOpcode(code, pc);
        },
        .skip_until_bit_in_table => {
            const cp_offset = readI16(code, pc, Off.skip_until_bit_in_table.cp_offset);
            const advance_by = readI16(code, pc, Off.skip_until_bit_in_table.advance_by);
            const table = readTable(code, pc, Off.skip_until_bit_in_table.table);
            const bounds = readI32(code, pc, Off.skip_until_bit_in_table.bounds_check_offset);
            while (indexInBounds(current + bounds, length)) {
                current_char = subject[@intCast(current + cp_offset)];
                if (checkBitInTable(current_char, table)) {
                    pc = try jump(code, pc, Off.skip_until_bit_in_table.on_match);
                    continue :dispatch nextOpcode(code, pc);
                }
                current += advance_by;
            }
            pc = try jump(code, pc, Off.skip_until_bit_in_table.on_no_match);
            continue :dispatch nextOpcode(code, pc);
        },
        .skip_until_gt_or_not_bit_in_table => {
            const cp_offset = readI16(code, pc, Off.skip_until_gt_or_not_bit_in_table.cp_offset);
            const advance_by = readI16(code, pc, Off.skip_until_gt_or_not_bit_in_table.advance_by);
            const character = readU16(code, pc, Off.skip_until_gt_or_not_bit_in_table.character);
            const table = readTable(code, pc, Off.skip_until_gt_or_not_bit_in_table.table);
            const bounds = readI32(code, pc, Off.skip_until_gt_or_not_bit_in_table.bounds_check_offset);
            while (indexInBounds(current + bounds, length)) {
                current_char = subject[@intCast(current + cp_offset)];
                if (current_char > character or !checkBitInTable(current_char, table)) {
                    pc = try jump(code, pc, Off.skip_until_gt_or_not_bit_in_table.on_match);
                    continue :dispatch nextOpcode(code, pc);
                }
                current += advance_by;
            }
            pc = try jump(code, pc, Off.skip_until_gt_or_not_bit_in_table.on_no_match);
            continue :dispatch nextOpcode(code, pc);
        },
        .skip_until_char_or_char => {
            const cp_offset = readI16(code, pc, Off.skip_until_char_or_char.cp_offset);
            const advance_by = readI16(code, pc, Off.skip_until_char_or_char.advance_by);
            const char1 = readU16(code, pc, Off.skip_until_char_or_char.char1);
            const char2 = readU16(code, pc, Off.skip_until_char_or_char.char2);
            const bounds = readI32(code, pc, Off.skip_until_char_or_char.bounds_check_offset);
            while (indexInBounds(current + bounds, length)) {
                current_char = subject[@intCast(current + cp_offset)];
                if (char1 == current_char or char2 == current_char) {
                    pc = try jump(code, pc, Off.skip_until_char_or_char.on_match);
                    continue :dispatch nextOpcode(code, pc);
                }
                current += advance_by;
            }
            pc = try jump(code, pc, Off.skip_until_char_or_char.on_no_match);
            continue :dispatch nextOpcode(code, pc);
        },
        .skip_until_one_of_masked => {
            if (Char != u8) return error.BytecodeCorrupt;
            const cp_offset = readI16(code, pc, Off.skip_until_one_of_masked.cp_offset);
            const advance_by = readI16(code, pc, Off.skip_until_one_of_masked.advance_by);
            const both_chars = readU32(code, pc, Off.skip_until_one_of_masked.both_chars);
            const both_mask = readU32(code, pc, Off.skip_until_one_of_masked.both_mask);
            const max_offset = readI32(code, pc, Off.skip_until_one_of_masked.max_offset);
            const chars1 = readU32(code, pc, Off.skip_until_one_of_masked.chars1);
            const mask1 = readU32(code, pc, Off.skip_until_one_of_masked.mask1);
            const chars2 = readU32(code, pc, Off.skip_until_one_of_masked.chars2);
            const mask2 = readU32(code, pc, Off.skip_until_one_of_masked.mask2);
            while (indexInBounds(current + max_offset, length)) {
                current_char = load4(subject, current + cp_offset);
                if (both_chars == (current_char & both_mask)) {
                    if (chars1 == (current_char & mask1)) {
                        pc = try jump(code, pc, Off.skip_until_one_of_masked.on_match1);
                        continue :dispatch nextOpcode(code, pc);
                    }
                    if (chars2 == (current_char & mask2)) {
                        pc = try jump(code, pc, Off.skip_until_one_of_masked.on_match2);
                        continue :dispatch nextOpcode(code, pc);
                    }
                }
                current += advance_by;
            }
            pc = try jump(code, pc, Off.skip_until_one_of_masked.on_failure);
            continue :dispatch nextOpcode(code, pc);
        },
        .skip_until_one_of_masked3 => {
            if (Char != u8) return error.BytecodeCorrupt;
            const bc0_cp_offset = readI16(code, pc, Off.skip_until_one_of_masked3.bc0_cp_offset);
            const bc0_advance_by = readI16(code, pc, Off.skip_until_one_of_masked3.bc0_advance_by);
            const bc0_table = readTable(code, pc, Off.skip_until_one_of_masked3.bc0_table);
            const bc1_bounds = readI32(code, pc, Off.skip_until_one_of_masked3.bc1_bounds_check_offset);
            const bc1_cp_offset = readI16(code, pc, Off.skip_until_one_of_masked3.bc1_cp_offset);
            const bc2_characters = readU32(code, pc, Off.skip_until_one_of_masked3.bc2_characters);
            const bc2_mask = readU32(code, pc, Off.skip_until_one_of_masked3.bc2_mask);
            const bc3_by = readI16(code, pc, Off.skip_until_one_of_masked3.bc3_by);
            const bc4_bounds = readI32(code, pc, Off.skip_until_one_of_masked3.bc4_bounds_check_offset);
            const bc4_cp_offset = readI16(code, pc, Off.skip_until_one_of_masked3.bc4_cp_offset);
            const bc5_characters = readU32(code, pc, Off.skip_until_one_of_masked3.bc5_characters);
            const bc5_mask = readU32(code, pc, Off.skip_until_one_of_masked3.bc5_mask);
            const bc6_characters = readU32(code, pc, Off.skip_until_one_of_masked3.bc6_characters);
            const bc6_mask = readU32(code, pc, Off.skip_until_one_of_masked3.bc6_mask);
            const bc7_characters = readU32(code, pc, Off.skip_until_one_of_masked3.bc7_characters);
            const bc7_mask = readU32(code, pc, Off.skip_until_one_of_masked3.bc7_mask);
            while (true) {
                while (indexInBounds(current + bc0_cp_offset, length)) {
                    current_char = subject[@intCast(current + bc0_cp_offset)];
                    if (checkBitInTable(current_char, bc0_table)) break;
                    current += bc0_advance_by;
                }
                if (!indexInBounds(current + bc1_bounds, length)) {
                    pc = try jump(code, pc, Off.skip_until_one_of_masked3.bc1_on_failure);
                    continue :dispatch nextOpcode(code, pc);
                }
                current_char = load4(subject, current + bc1_cp_offset);
                if (bc2_characters == (current_char & bc2_mask)) {
                    if (!indexInBounds(current + bc4_bounds, length)) {
                        current += bc3_by;
                        continue;
                    }
                    current_char = load4(subject, current + bc4_cp_offset);
                    if (bc5_characters == (current_char & bc5_mask)) {
                        pc = try jump(code, pc, Off.skip_until_one_of_masked3.bc5_on_equal);
                        continue :dispatch nextOpcode(code, pc);
                    }
                    if (bc6_characters == (current_char & bc6_mask)) {
                        pc = try jump(code, pc, Off.skip_until_one_of_masked3.bc6_on_equal);
                        continue :dispatch nextOpcode(code, pc);
                    }
                    if (bc7_characters == (current_char & bc7_mask)) {
                        pc = try jump(code, pc, Off.skip_until_one_of_masked3.fallthrough_jump_target);
                        continue :dispatch nextOpcode(code, pc);
                    }
                }
                current += bc3_by;
            }
        },
    }
}
